# frozen_string_literal: true

require "monitor"
require_relative "type_registry"
require_relative "instance"
require_relative "reuse"
require_relative "notices"
require_relative "concurrency_gate"
require_relative "scoped_registry"
require_relative "completion"
require_relative "dependency"

module Rubik
  module Orchestrator
    module Subagent
      class DepthExceededError < StandardError; end
      class ConcurrencyExceededError < StandardError; end

      # Root Supervisor Agent governing the entire subagent process hierarchy:
      # this class models Linux init's PID-1 supervisory ROLE (parent of the
      # tree, orphan reaper) and is driven by the maestro persona (machine id
      # `agent-0`). Also owns concurrent pool limits and LIFO shutdown (Plan 94).
      class Supervisor
        attr_accessor :tool_registry, :router, :init
        attr_reader :root_context, :type_registry, :instances, :max_depth, :max_concurrency, :default_max_steps, :provider_gate

        include RedeploySupervisor
        include ReaperSupervisor
        include CompletionSupervisor
        include DependencySupervisor

        def initialize(root_context:, buffer_manager: nil, tool_registry: nil,
                       provider: nil, router: nil, config: nil, root_dir: Dir.pwd, event_bus: nil, init: nil)
          @root_context = root_context
          @buffer_manager = buffer_manager
          @tool_registry = tool_registry
          @provider = provider
          @router = router
          @config = config
          @root_dir = root_dir
          @event_bus = event_bus
          @init = init

          @type_registry = TypeRegistry.new
          @instances = {}
          @deferred = {}
          @monitor = Monitor.new
          @counter = 0
          @max_depth = (config&.fetch("subagents.max_depth", 2) || 2).to_i
          @max_concurrency = (config&.fetch("subagents.max_concurrency", 10) || 10).to_i
          @default_max_steps = (config&.fetch("subagents.default_max_steps", Budget::DEFAULT_MAX_STEPS) || Budget::DEFAULT_MAX_STEPS).to_i
          @provider_concurrency = (config&.fetch("subagents.provider_concurrency", 2) || 2).to_i
          @provider_gate = ConcurrencyGate.new(@provider_concurrency)

          # Register inverse in root context (maestro hook)
          @root_context.register_disposable { shutdown_all } if @root_context.respond_to?(:register_disposable)
        end

        def spawn(role:, prompt:, type_name: "research", system_prompt: nil,
                  parent_id: "agent-0", workspace: "inherit", model: "inherit",
                  max_steps: nil, provider: nil, depends_on: nil, reserved_id: nil)
          role_str = role.to_s.strip
          prompt_str = prompt.to_s.strip
          raise ArgumentError, "Subagent role cannot be empty" if role_str.empty?
          raise ArgumentError, "Subagent prompt cannot be empty" if prompt_str.empty?

          # Bağımlı spec doğrudan spawn edilmez: kuyruğa girer (FS/SS
          # kısıtı), bırakma süpürmesi gerçek koreografiyi oynatır.
          if depends_on
            return spawn_batch([{ role: role_str, prompt: prompt_str, type_name: type_name,
                                  system_prompt: system_prompt, parent_id: parent_id, workspace: workspace,
                                  model: model, max_steps: max_steps, provider: provider, depends_on: depends_on }]).first[1]
          end

          created = @monitor.synchronize do
            validate_concurrency!
            validate_depth!(parent_id)

            type_def = @type_registry.get(type_name) || @type_registry.get("research")
            effective_sys_prompt = system_prompt || type_def.system_prompt

            child_ctx = @root_context.respond_to?(:extend) ? @root_context.extend : nil
            # child ctx yoksa (extend'siz duck-type host) question/sender
            # coeffect'leri kurulamaz — sessiz degradasyonu görünür kıl.
            Rubik::Log.warn(:orchestrator, "subagent spawn: root context lacks #extend — no child ctx; subagent planes degrade") unless child_ctx
            effective_buffer = branch_or_inherit_buffer(workspace)
            scoped_registry = build_scoped_registry(type_def, child_ctx, effective_buffer)
            prov, effective_model = resolve_provider_and_model(model)
            prov = provider if provider

            # Kuyruktan bırakılan spec kendi REZERVE id'siyle doğar — modelin
            # depends_on/wait referansı kopmaz. Taze spawn yalnız sayaç ilerletir.
            subagent_id = reserved_id || "subagent-#{@counter += 1}"

            inst = Instance.new(
              id: subagent_id, parent_id: parent_id, role: role_str, type_name: type_def.name,
              prompt: prompt_str, system_prompt: effective_sys_prompt, workspace: workspace,
              model: effective_model, context: child_ctx, tool_registry: scoped_registry,
              provider: prov, buffer_manager: effective_buffer, max_steps: (max_steps || @default_max_steps).to_i,
              provider_gate: @provider_gate, root_dir: @root_dir, config: @config,
              context_limit: (@config.respond_to?(:fetch) ? @config.fetch("context.max_tokens", 32_768) : 32_768),
              event_bus: @event_bus, transcript_storage: absorb_storage
            )

            @instances[subagent_id] = inst
            # ask_question'ın subagent düzlemi: instance kendi child ctx'ine
            # asker olarak publish edilir (Instance.new sonrası, start_async
            # öncesi — coeffect resolution execute anında gerçekleşir).
            child_ctx&.provide(Rubik::Coeffects::SUBAGENT_QUESTION_ASKER, inst)
            # send_message atfı: subagent→maestro mesajları gerçek gönderen
            # id'siyle taşır (coeffect yoksa root default'u yanlış atıf yapar).
            child_ctx&.provide(Rubik::Coeffects::SUBAGENT_SENDER_ID, subagent_id)
            eff_init = @init || (@root_context.respond_to?(:get) && Rubik::Coeffects.get(@root_context, Rubik::Coeffects::INIT))
            eff_init&.register(Rubik::Kernel::SubagentUnit.new(inst, context: child_ctx))
            inst.start_async do |completed_inst|
              handle_subagent_completion(completed_inst)
            end
            inst
          end
          # SS bırakma kancası: yeni başlayan instance, onu bekleyen kuyruk
          # spesifikasyonlarını serbest bırakır (kilit DIŞINDA — emit kuralı).
          release_ready!
          created
        end

        def wait_for(ids = nil, timeout: Notices::DEFAULT_WAIT_TIMEOUT, wait_for_budget: true)
          target_ids = Array(ids).compact.map(&:to_s)
          deadline = Time.now + [timeout.to_i, 1].max

          loop do
            active_targets = @monitor.synchronize do
              candidates = target_ids.empty? ? @instances.values : target_ids.map { |id| @instances[id] }.compact
              candidates.select do |inst|
                inst.active? && !inst.error_paused? && !inst.awaiting_human? && (!wait_for_budget || !inst.awaiting_budget?)
              end
            end

            # Kuyruğa takılı hedefler wait'i canlı tutar (zincir bitene dek).
            break if (active_targets.empty? && !deferred_pending?(target_ids)) || Time.now >= deadline

            sleep 0.1
          end

          @monitor.synchronize do
            candidates = target_ids.empty? ? @instances.values : target_ids.map { |id| @instances[id] || queued_spec(id) }.compact
            candidates.map(&:to_h)
          end
        end

        # Tombstone + kuyruk dahil arama: reap/rezervasyon sonrası da
        # status/transcript/list sorgulanır.
        def get(id) = @monitor.synchronize { @instances[id.to_s] || (@finished ||= {})[id.to_s] || queued_spec(id.to_s) }

        def extend_budget(id, steps = Budget::DEFAULT_GRANT_STEPS)
          inst = get(id)
          return false unless inst.is_a?(Instance)

          inst.extend_budget(steps)
        end

        def resume(id, additional_steps: nil)
          inst = get(id)
          inst.respond_to?(:resume!) ? inst.resume!(additional_steps: additional_steps) : false
        end

        def resume_all
          @monitor.synchronize do
            @instances.values.select(&:parked?).map do |i|
              i.resume! ? i.id : nil
            end.compact
          end
        end

        def list(parent_id: nil)
          @monitor.synchronize do
            items = @instances.values + (@finished ||= {}).values + @deferred.values
            items = items.select { |i| i.parent_id == parent_id.to_s } if parent_id
            items.sort_by { |i| i.started_at || Time.at(0) }
          end
        end

        # İki-düzlem adlandırma (plan 2026-10-02): makine "agent-0" (parent_id/
        # sender; persisted spec'ler round-trip eder), persona "maestro" (model'e
        # görünen metinler; init-0'dan 2026-10-03'te yeniden adlandırıldı —
        # "init-0" yalnızca eski transcriptlerin yönlendirmesi için legacy
        # alıcı alias'ı olarak korunur). "root"/"parent" alias; dördü de köke
        # yönlendirir.
        ROOT_RECIPIENT_ALIASES = ["agent-0", "init-0", "root", "parent"].map(&:downcase).freeze

        def send_message(recipient_id, message, sender_id: "agent-0", additional_steps: nil, **kwargs)
          rec = recipient_id.to_s.strip
          eff_sender = kwargs[:_sender_id] || sender_id
          if ROOT_RECIPIENT_ALIASES.include?(rec.downcase)
            Notices.emit(@event_bus, Notices::MESSAGE_EVENT, { sender_id: eff_sender, recipient: rec, message: message })
            return true
          end

          inst = get(rec)
          return false unless inst&.deliverable?

          inst.post_message(message, sender: eff_sender, additional_steps: additional_steps)
          true
        end

        def kill(id, cascade: false)
          cancelled = []
          found = @monitor.synchronize do
            kill_locked(id.to_s, cascade, cancelled)
          end
          # Emit + süpürme kilidin DIŞINDA: cascade kill'in iç emit'i global
          # monitörü 2s'ye kadar bloklar (emit kuralı ihlali olurdu).
          announce_cancellations(cancelled)
          release_ready!
          found
        end

        def kill_all(parent_id: nil)
          cancelled = []
          @monitor.synchronize do
            cancelled.concat(cancel_dependents_of(parent_id ? [] : @instances.keys + @deferred.keys))
            @deferred.clear if parent_id.nil?
            targets = parent_id ? @instances.values.select { |i| i.parent_id == parent_id.to_s } : @instances.values
            targets.each(&:kill)
            true
          end
          announce_cancellations(cancelled)
        end

        def shutdown_all
          @monitor.synchronize do
            # maestro: orderly LIFO shutdown of all instances
            @instances.values.reverse_each(&:kill)
            @instances.clear
            @deferred.clear
          end
        end

        def reap_orphans
          @monitor.synchronize do
            sweep_disposed_and_finished
            surviving = @instances.values.select(&:active?).to_set(&:id)
            @instances.each_value do |inst|
              inst.parent_id = "agent-0" if inst.parent_id != "agent-0" && !surviving.include?(inst.parent_id)
            end
          end
        end

        def active_count
          @monitor.synchronize do
            @instances.values.count(&:active?)
          end
        end

        private

        def validate_concurrency!
          active = @instances.values.count(&:active?)
          return unless active >= @max_concurrency

          raise ConcurrencyExceededError,
                "Max subagent concurrency limit reached (#{@max_concurrency}). Please wait for active subagents to finish or kill idle tasks."
        end

        def validate_depth!(parent_id)
          depth = calculate_depth(parent_id)
          return unless depth >= @max_depth

          raise DepthExceededError,
                "Subagent recursion depth limit exceeded (current depth: #{depth}, max: #{@max_depth}). Nested subagent creation is restricted."
        end

        def calculate_depth(parent_id)
          depth = 0
          curr = parent_id.to_s
          while curr != "agent-0" && !curr.empty?
            parent_inst = @instances[curr]
            break unless parent_inst

            depth += 1
            curr = parent_inst.parent_id
          end
          depth
        end

        def branch_or_inherit_buffer(workspace)
          return @buffer_manager unless workspace == "branch" && @buffer_manager

          Rubik::Buffer::Manager.new(
            root_dir: @buffer_manager.root_dir,
            additional_roots: @buffer_manager.additional_roots,
            allowed_external_dirs: @buffer_manager.allowed_external_dirs,
            allow_external_writes: @buffer_manager.allow_external_writes,
            guard: @buffer_manager.guard,
            config: @buffer_manager.config
          )
        end

        def effective_tool_registry
          @tool_registry || (Rubik::Coeffects.get(@root_context, :tool_registry) if @root_context.respond_to?(:get))
        end

        def resolve_provider_and_model(requested_model)
          req = requested_model.to_s.strip
          if @router
            role = case req.downcase
                   when "flash", "flash_lite", "fast" then :fast
                   when "pro", "advanced" then :advanced
                   else :default
                   end
            begin
              routed = @router.route(task_type: role)
              if routed && routed[:provider]
                is_custom = req.downcase != "inherit" && !req.empty? && !["flash", "flash_lite", "fast", "pro", "advanced"].include?(req.downcase)
                eff_model = is_custom ? req : routed[:model]
                return [routed[:provider], eff_model]
              end
            rescue StandardError => e
              Rubik::Log.warn(:orchestrator, "subagent router failed (#{e.class}: #{e.message}); falling back to default provider")
              nil
            end
          end

          prov = @provider || (Rubik::Coeffects.get(@root_context, Rubik::Coeffects::LLM_CLIENT) if @root_context.respond_to?(:get))
          [prov, req == "inherit" ? nil : req]
        end

        def build_scoped_registry(type_def, child_ctx, buffer)
          ScopedRegistry.build(source_registry: effective_tool_registry, type_def: type_def,
                               child_ctx: child_ctx, buffer: buffer, parent_buffer: @buffer_manager)
        end

        # Storage (rubik://storage FS-DB) KULLANIM ANINDA çözülür — ctor
        # anında snapshot alınamaz: supervisor Composition'da (shell.rb),
        # STORAGE_STORE provide'u ise Phase 4'te (lifecycle.rb) olur; ctor
        # snapshot'ı üretime ölü kod bırakır (review bulgusu 1). Absorb
        # yalnız açık config onayıyla (defaults: true; bare construction
        # legacy kalır).
        def storage_store
          Rubik::Coeffects.get(@root_context, Rubik::Coeffects::STORAGE_STORE) if @root_context.respond_to?(:get)
        end

        def absorb_storage
          store = storage_store
          store && Rubik::Storage::Layout.absorb_artifacts?(@config) ? store : nil
        end
      end
    end
  end
end

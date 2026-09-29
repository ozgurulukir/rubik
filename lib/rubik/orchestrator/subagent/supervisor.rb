# frozen_string_literal: true

require "monitor"
require_relative "type_registry"
require_relative "instance"
require_relative "notices"
require_relative "concurrency_gate"
require_relative "../auto_apply"

module Rubik
  module Orchestrator
    module Subagent
      class DepthExceededError < StandardError; end
      class ConcurrencyExceededError < StandardError; end

      # Root Supervisor Agent (Init 0 / PID 1) governing the entire subagent process
      # hierarchy, orphan reaping, concurrent pool limits, and LIFO shutdown (Plan 94).
      class Supervisor
        attr_accessor :tool_registry, :router, :init
        attr_reader :root_context, :type_registry, :instances, :max_depth, :max_concurrency, :default_max_steps, :provider_gate

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
          @monitor = Monitor.new
          @counter = 0
          @max_depth = (config&.fetch("subagents.max_depth", 2) || 2).to_i
          @max_concurrency = (config&.fetch("subagents.max_concurrency", 10) || 10).to_i
          @default_max_steps = (config&.fetch("subagents.default_max_steps", Budget::DEFAULT_MAX_STEPS) || Budget::DEFAULT_MAX_STEPS).to_i
          @provider_concurrency = (config&.fetch("subagents.provider_concurrency", 2) || 2).to_i
          @provider_gate = ConcurrencyGate.new(@provider_concurrency)

          # Register inverse in root context (init 0 hook)
          @root_context.register_disposable { shutdown_all } if @root_context.respond_to?(:register_disposable)
        end

        def spawn(role:, prompt:, type_name: "research", system_prompt: nil,
                  parent_id: "agent-0", workspace: "inherit", model: "inherit",
                  max_steps: nil, provider: nil)
          role_str = role.to_s.strip
          prompt_str = prompt.to_s.strip
          raise ArgumentError, "Subagent role cannot be empty" if role_str.empty?
          raise ArgumentError, "Subagent prompt cannot be empty" if prompt_str.empty?

          @monitor.synchronize do
            validate_concurrency!
            validate_depth!(parent_id)

            type_def = @type_registry.get(type_name) || @type_registry.get("research")
            effective_sys_prompt = system_prompt || type_def.system_prompt

            child_ctx = @root_context.respond_to?(:extend) ? @root_context.extend : nil
            effective_buffer = branch_or_inherit_buffer(workspace)
            scoped_registry = build_scoped_registry(type_def, child_ctx, effective_buffer)
            prov, effective_model = resolve_provider_and_model(model)
            prov = provider if provider

            @counter += 1
            subagent_id = "subagent-#{@counter}"

            inst = Instance.new(
              id: subagent_id, parent_id: parent_id, role: role_str, type_name: type_def.name,
              prompt: prompt_str, system_prompt: effective_sys_prompt, workspace: workspace,
              model: effective_model, context: child_ctx, tool_registry: scoped_registry,
              provider: prov, buffer_manager: effective_buffer, max_steps: (max_steps || @default_max_steps).to_i,
              provider_gate: @provider_gate, root_dir: @root_dir, config: @config,
              context_limit: (@config.respond_to?(:fetch) ? @config.fetch("context.max_tokens", 32_768) : 32_768),
              event_bus: @event_bus
            )

            @instances[subagent_id] = inst
            eff_init = @init || (@root_context.respond_to?(:get) && Rubik::Coeffects.get(@root_context, Rubik::Coeffects::INIT))
            eff_init&.register(Rubik::Kernel::SubagentUnit.new(inst, context: child_ctx))
            inst.start_async do |completed_inst|
              handle_subagent_completion(completed_inst)
            end
            inst
          end
        end

        def wait_for(ids = nil, timeout: Notices::DEFAULT_WAIT_TIMEOUT, wait_for_budget: true)
          target_ids = Array(ids).compact.map(&:to_s)
          deadline = Time.now + [timeout.to_i, 1].max

          loop do
            active_targets = @monitor.synchronize do
              candidates = target_ids.empty? ? @instances.values : target_ids.map { |id| @instances[id] }.compact
              candidates.select do |inst|
                inst.active? && (!wait_for_budget || inst.state != :waiting_budget) && inst.state != :paused_error
              end
            end

            break if active_targets.empty? || Time.now >= deadline

            sleep 0.1
          end

          @monitor.synchronize do
            candidates = target_ids.empty? ? @instances.values : target_ids.map { |id| @instances[id] }.compact
            candidates.map(&:to_h)
          end
        end

        def get(id)
          @monitor.synchronize { @instances[id.to_s] }
        end

        def extend_budget(id, steps = Budget::DEFAULT_GRANT_STEPS)
          inst = get(id)
          return false unless inst

          inst.extend_budget(steps)
        end

        def resume(id, additional_steps: nil)
          get(id)&.resume!(additional_steps: additional_steps)
        end

        def resume_all
          @monitor.synchronize do
            @instances.values.select { |i| [:paused_error, :waiting_budget, :budget_exhausted].include?(i.state) }.map do |i|
              i.resume! ? i.id : nil
            end.compact
          end
        end

        def list(parent_id: nil)
          @monitor.synchronize do
            items = @instances.values
            items = items.select { |i| i.parent_id == parent_id.to_s } if parent_id
            items.sort_by { |i| i.started_at || Time.at(0) }
          end
        end

        def send_message(recipient_id, message, sender_id: "agent-0", additional_steps: nil, **kwargs)
          rec = recipient_id.to_s.strip
          eff_sender = kwargs[:_sender_id] || sender_id
          if ["agent-0", "init-0", "root", "parent"].include?(rec.downcase)
            @event_bus&.emit(:subagent_message_to_parent, { sender_id: eff_sender, recipient: rec, message: message })
            return true
          end

          inst = get(rec)
          return false unless inst && (inst.active? || inst.state == :budget_exhausted)

          inst.post_message(message, additional_steps: additional_steps)
          true
        end

        def kill(id, cascade: false)
          @monitor.synchronize do
            inst = @instances[id.to_s]
            return false unless inst

            if cascade
              children = @instances.values.select { |i| i.parent_id == inst.id }
              children.each { |c| kill(c.id, cascade: true) }
            end

            inst.kill
          end
        end

        def kill_all(parent_id: nil)
          @monitor.synchronize do
            targets = parent_id ? @instances.values.select { |i| i.parent_id == parent_id.to_s } : @instances.values
            targets.each(&:kill)
            true
          end
        end

        def shutdown_all
          @monitor.synchronize do
            # init 0: orderly LIFO shutdown of all instances
            @instances.values.reverse_each(&:kill)
            @instances.clear
          end
        end

        def reap_orphans
          @monitor.synchronize do
            @instances.delete_if { |_k, v| v.state == :disposed }
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
          source_reg = effective_tool_registry
          return nil unless source_reg

          new_reg = Rubik::Tools::Registry.new(coeffect_ctx: child_ctx)
          filter = type_def.tool_filter

          source_reg.list.each do |tool|
            next unless filter.nil? || filter.call(tool.name)

            new_reg.register(bind_tool_buffer(tool, buffer))
          end
          new_reg
        end

        def bind_tool_buffer(tool, buffer)
          return tool unless buffer && buffer != @buffer_manager

          case tool.name
          when "read_file" then Rubik::Tools::ReadFileTool.new(buffer)
          when "write_file" then Rubik::Tools::WriteFileTool.new(buffer)
          when "replace_file_content" then Rubik::Tools::ReplaceFileContentTool.new(buffer)
          when "apply_buffer" then Rubik::Tools::ApplyBufferTool.new(buffer)
          else tool
          end
        end

        def handle_subagent_completion(inst)
          merge_branch_buffer(inst) if inst.workspace == "branch" && inst.state == :completed
          auto_apply_subagent_buffer(inst) if inst.state == :completed
          reap_orphans
          # Result is deliberately absent: notices announce, the model retrieves
          # via manage_subagents wait — the wait protocol stays authoritative.
          # max_steps rides along so the budget-exhausted guidance can count.
          @event_bus&.emit(Notices::COMPLETED_EVENT, { id: inst.id, role: inst.role, state: inst.state, max_steps: inst.max_steps })
        end

        # Completion-time spelling of the shared auto-apply policy: the
        # subagents flag OR the buffer.auto_apply mode decides (previously
        # this site read the flag alone and ignored the mode), and a failed
        # apply surfaces as a notice instead of a silent rescue. The child
        # context is already disposed here, so :shell resolves from the root.
        def auto_apply_subagent_buffer(inst)
          return unless AutoApply.apply?(@config, trigger: :completion, subagent: true)

          begin
            buffer = @buffer_manager || inst.buffer_manager
            AutoApply.apply_and_sync(buffer, Rubik::Coeffects.get(@root_context, Rubik::Coeffects::SHELL))
            AutoApply.report_conflicts(@event_bus, buffer,
                                       id: inst.id, role: inst.role, state: inst.state, trigger: :completion)
          rescue StandardError => e
            AutoApply.report_failure(@event_bus, id: inst.id, role: inst.role, state: inst.state,
                                                 trigger: :completion, reason: "#{e.class}: #{e.message}")
          end
        end

        def merge_branch_buffer(inst)
          return unless inst.buffer_manager && @buffer_manager && inst.buffer_manager != @buffer_manager

          inst.buffer_manager.dirty_files.each_key do |path|
            @buffer_manager.write(path, inst.buffer_manager.read(path))
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "monitor"
require_relative "type_registry"
require_relative "instance"

module Rubik
  module Orchestrator
    module Subagent
      class DepthExceededError < StandardError; end
      class ConcurrencyExceededError < StandardError; end

      # Root Supervisor Agent (Init 0 / PID 1) governing the entire subagent process
      # hierarchy, orphan reaping, concurrent pool limits, and LIFO shutdown (Plan 94).
      class Supervisor
        attr_accessor :tool_registry, :router, :on_budget_exhausted
        attr_reader :root_context, :type_registry, :instances, :max_depth, :max_concurrency

        def initialize(root_context:, buffer_manager: nil, tool_registry: nil,
                       provider: nil, router: nil, config: nil, root_dir: Dir.pwd, event_bus: nil)
          @root_context = root_context
          @buffer_manager = buffer_manager
          @tool_registry = tool_registry
          @provider = provider
          @router = router
          @config = config
          @root_dir = root_dir
          @event_bus = event_bus

          @type_registry = TypeRegistry.new
          @instances = {}
          @monitor = Monitor.new
          @counter = 0
          @max_depth = (config&.fetch("subagents.max_depth", 2) || 2).to_i
          @max_concurrency = (config&.fetch("subagents.max_concurrency", 10) || 10).to_i
          @on_budget_exhausted = nil

          # Register inverse in root context (init 0 hook)
          @root_context.register_disposable { shutdown_all } if @root_context.respond_to?(:register_disposable)
        end

        def spawn(role:, prompt:, type_name: "research", system_prompt: nil,
                  parent_id: "agent-0", workspace: "inherit", model: "inherit",
                  max_steps: 15, on_notify: nil, on_budget_exhausted: nil, provider: nil)
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
              id: subagent_id,
              parent_id: parent_id,
              role: role_str,
              type_name: type_def.name,
              prompt: prompt_str,
              system_prompt: effective_sys_prompt,
              workspace: workspace,
              model: effective_model,
              context: child_ctx,
              tool_registry: scoped_registry,
              provider: prov,
              buffer_manager: effective_buffer,
              max_steps: max_steps,
              root_dir: @root_dir
            )

            inst.on_budget_exhausted = lambda do |i|
              on_budget_exhausted&.call(i)
              @on_budget_exhausted&.call(i)
              @event_bus&.emit(:subagent_budget_exhausted, { id: i.id, role: i.role, state: i.state, max_steps: i.max_steps })
            end

            @instances[subagent_id] = inst
            inst.start_async do |completed_inst|
              handle_subagent_completion(completed_inst, on_notify)
            end
            inst
          end
        end

        def wait_for(ids = nil, timeout: 30, wait_for_budget: true)
          target_ids = Array(ids).compact.map(&:to_s)
          deadline = Time.now + [timeout.to_i, 1].max

          loop do
            active_targets = @monitor.synchronize do
              candidates = target_ids.empty? ? @instances.values : target_ids.map { |id| @instances[id] }.compact
              candidates.select do |inst|
                inst.active? && (!wait_for_budget || inst.state != :waiting_budget)
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

        def extend_budget(id, steps = 10)
          inst = get(id)
          return false unless inst

          inst.extend_budget(steps)
        end

        def list(parent_id: nil)
          @monitor.synchronize do
            items = @instances.values
            items = items.select { |i| i.parent_id == parent_id.to_s } if parent_id
            items.sort_by { |i| i.started_at || Time.at(0) }
          end
        end

        def send_message(recipient_id, message, _sender_id: "agent-0", additional_steps: nil)
          inst = get(recipient_id)
          return false unless inst&.active?

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
            rescue StandardError
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

        def handle_subagent_completion(inst, on_notify)
          merge_branch_buffer(inst) if inst.workspace == "branch" && inst.state == :completed
          reap_orphans
          on_notify&.call(inst)
          @event_bus&.emit(:subagent_completed, { id: inst.id, role: inst.role, state: inst.state, result: inst.result })
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

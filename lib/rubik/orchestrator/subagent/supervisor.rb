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
        attr_reader :root_context, :type_registry, :instances, :max_depth, :max_concurrency

        def initialize(root_context:, buffer_manager: nil, tool_registry: nil,
                       provider: nil, config: nil, root_dir: Dir.pwd)
          @root_context = root_context
          @buffer_manager = buffer_manager
          @tool_registry = tool_registry
          @provider = provider
          @config = config
          @root_dir = root_dir

          @type_registry = TypeRegistry.new
          @instances = {}
          @monitor = Monitor.new
          @counter = 0
          @max_depth = (config&.fetch("subagents.max_depth", 2) || 2).to_i
          @max_concurrency = (config&.fetch("subagents.max_concurrency", 5) || 5).to_i

          # Register inverse in root context (init 0 hook)
          @root_context.register_disposable { shutdown_all } if @root_context.respond_to?(:register_disposable)
        end

        def spawn(role:, prompt:, type_name: "research", system_prompt: nil,
                  parent_id: "agent-0", workspace: "inherit", model: "inherit",
                  max_steps: 15, on_notify: nil)
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
            scoped_registry = build_scoped_registry(type_def, child_ctx)

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
              model: model,
              context: child_ctx,
              tool_registry: scoped_registry,
              provider: @provider,
              buffer_manager: @buffer_manager,
              max_steps: max_steps,
              root_dir: @root_dir
            )

            @instances[subagent_id] = inst
            inst.start_async do |completed_inst|
              handle_subagent_completion(completed_inst, on_notify)
            end
            inst
          end
        end

        def get(id)
          @monitor.synchronize { @instances[id.to_s] }
        end

        def list(parent_id: nil)
          @monitor.synchronize do
            items = @instances.values
            items = items.select { |i| i.parent_id == parent_id.to_s } if parent_id
            items.sort_by { |i| i.started_at || Time.at(0) }
          end
        end

        def send_message(recipient_id, message, _sender_id: "agent-0")
          inst = get(recipient_id)
          return false unless inst&.active?

          inst.post_message(message)
          true
        end

        def kill(id)
          @monitor.synchronize do
            inst = @instances[id.to_s]
            return false unless inst

            # Cascade kill to any children spawned by this subagent
            children = @instances.values.select { |i| i.parent_id == inst.id }
            children.each(&:kill)

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

        def build_scoped_registry(type_def, child_ctx)
          return nil unless @tool_registry

          new_reg = Rubik::Tools::Registry.new(coeffect_ctx: child_ctx)
          filter = type_def.tool_filter

          @tool_registry.list.each do |tool|
            new_reg.register(tool) if filter.nil? || filter.call(tool.name)
          end
          new_reg
        end

        def handle_subagent_completion(inst, on_notify)
          reap_orphans
          on_notify&.call(inst)
        end
      end
    end
  end
end

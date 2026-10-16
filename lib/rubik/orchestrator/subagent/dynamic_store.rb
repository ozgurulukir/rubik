# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # Reversible dynamic registration stack management for TypeRegistry.
      # Tracks monotonic revisions, LIFO unregistration, and dead-context pruning.
      module DynamicStore
        def init_dynamic_store
          @stacks = {}
          @registrations = {}
          @revision_counter = 0
        end

        def register_dynamic(type_def, context: nil)
          handle = nil
          @monitor.synchronize do
            @revision_counter += 1
            rev = @revision_counter

            handle = RegistrationHandle.new(revision: rev, type_def: type_def, context: context, registry: self)
            type_def.handle = handle
            type_def.revision = rev
            type_def.context = context

            reg = Registration.new(revision: rev, name: type_def.name, type_def: type_def, handle: handle, context: context, active: true)
            @registrations[rev] = reg
            (@stacks[type_def.name] ||= []) << reg
          end

          context.register_disposable { unregister_dynamic(handle) } if context.respond_to?(:register_disposable)
          handle
        end

        def unregister_dynamic(target)
          @monitor.synchronize do
            rev = resolve_revision(target)
            reg = @registrations[rev]
            return false unless reg && reg.active

            reg.active = false
            handle = reg.handle
            handle.instance_variable_set(:@active, false) if handle

            stack = @stacks[reg.name]
            if stack
              if stack.last == reg
                stack.pop
                prune_dead_entries(reg.name)
              else
                stack.delete(reg)
              end
            end
            @registrations.delete(rev)
            true
          end
        end

        private

        def resolve_revision(target)
          if target.respond_to?(:revision)
            target.revision
          elsif target.is_a?(Integer)
            target
          else
            clean = target.to_s.downcase.strip
            stack = @stacks[clean]
            stack&.last&.revision
          end
        end

        def prune_dead_entries(clean_name)
          stack = @stacks[clean_name]
          return unless stack

          while stack.any?
            top = stack.last
            is_dead = !top.active || (top.context&.respond_to?(:disposed?) && top.context.disposed?)
            if is_dead
              top.active = false
              @registrations.delete(top.revision)
              stack.pop
            else
              break
            end
          end
          @stacks.delete(clean_name) if stack.empty?
        end
      end
    end
  end
end

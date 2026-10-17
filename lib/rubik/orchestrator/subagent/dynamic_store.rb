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

        def register_dynamic(type_def, context: nil, replace: false)
          owner_ctx = context || type_def.context || @default_context
          raise ArgumentError, "Dynamic archetypes require an active owner context." unless owner_ctx

          raise ArgumentError, "Cannot define archetype in a disposed context." if owner_ctx.respond_to?(:disposed?) && owner_ctx.disposed?

          raise ArgumentError, "Dynamic archetype owner context must support disposal cleanup." unless
            owner_ctx.respond_to?(:register_disposable) || owner_ctx.respond_to?(:on_dispose)

          clean_name = type_def.name.to_s.downcase.strip
          raise ArgumentError, "Subagent type name cannot be empty" if clean_name.empty?

          handle = nil
          previous_type_state = nil
          registration_type_def = type_def
          @monitor.synchronize do
            prune_dead_entries(clean_name)

            raise ArgumentError, "Cannot define archetype '#{clean_name}' because built-in system archetypes are reserved." if @builtins.key?(clean_name)

            stack = @stacks[clean_name]
            if stack&.any? && !replace
              raise ArgumentError, "Cannot define archetype '#{clean_name}' because it is already registered. To fix, choose a different name or specify replace: true."
            end

            # A definition already owned by an active revision is shared state.
            # Copy it before stamping the new revision so disposing that revision
            # cannot leave the older registration pointing at its context/handle.
            if @registrations.values.any? { |registration| registration.active && registration.type_def.equal?(type_def) }
              registration_type_def = type_def.dup
            end

            @revision_counter += 1
            rev = @revision_counter

            previous_type_state = [registration_type_def.name, registration_type_def.context,
                                   registration_type_def.custom_prompt, registration_type_def.handle,
                                   registration_type_def.revision]
            registration_type_def.name = clean_name
            registration_type_def.context = owner_ctx
            registration_type_def.custom_prompt = true
            handle = RegistrationHandle.new(revision: rev, type_def: registration_type_def, context: owner_ctx, registry: self)
            registration_type_def.handle = handle
            registration_type_def.revision = rev

            reg = Registration.new(revision: rev, name: clean_name, type_def: registration_type_def,
                                   handle: handle, context: owner_ctx, active: true)
            @registrations[rev] = reg
            (@stacks[clean_name] ||= []) << reg
          end

          begin
            cleanup_method = owner_ctx.respond_to?(:register_disposable) ? :register_disposable : :on_dispose
            owner_ctx.public_send(cleanup_method) { unregister_dynamic(handle) }
            raise ArgumentError, "Cannot define archetype in a disposed context." unless handle.active?
          rescue StandardError
            unregister_dynamic(handle)
            registration_type_def.name, registration_type_def.context, registration_type_def.custom_prompt,
              registration_type_def.handle, registration_type_def.revision = previous_type_state if previous_type_state
            raise
          end
          handle
        end

        def unregister_dynamic(target)
          @monitor.synchronize do
            rev = resolve_revision(target)
            reg = @registrations[rev]
            return false unless reg&.active

            reg.active = false
            handle = reg.handle
            handle&.instance_variable_set(:@active, false)

            stack = @stacks[reg.name]
            if stack&.last == reg
              stack.pop
              prune_dead_entries(reg.name)
            elsif stack
              stack.delete(reg)
            end
            @registrations.delete(rev)
            true
          end
        end

        private

        def resolve_revision(target)
          return target.revision if target.respond_to?(:revision)
          return target if target.is_a?(Integer)

          clean = target.to_s.downcase.strip
          stack = @stacks[clean]
          stack&.last&.revision
        end

        def prune_dead_entries(clean_name)
          stack = @stacks[clean_name]
          return unless stack

          while stack.any?
            top = stack.last
            is_dead = !top.active || (top.context.respond_to?(:disposed?) && top.context.disposed?)
            break unless is_dead

            top.active = false
            top.handle&.instance_variable_set(:@active, false)
            @registrations.delete(top.revision)
            stack.pop
          end
          @stacks.delete(clean_name) if stack.empty?
        end
      end
    end
  end
end

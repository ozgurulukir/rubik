# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # Owns the transactional boundary for one subagent spawn. Kept separate
      # from the root supervisor's query and lifecycle APIs.
      module SpawnSupervisor
        RESERVED_ROLE_PROFILES = {
          "vakanüvis distiller" => "vakanuvis",
          "context pruner" => "pruner"
        }.freeze

        CHILD_CONTEXT_COEFFECTS = [
          Rubik::Coeffects::SUBAGENT_QUESTION_ASKER,
          Rubik::Coeffects::SUBAGENT_SENDER_ID,
          Rubik::Coeffects::TASK_CANCELLATION
        ].freeze

        def spawn(role:, prompt:, type_name: "research", system_prompt: nil,
                  parent_id: ConversationId::ROOT_ID, workspace: "inherit", model: "inherit",
                  max_steps: nil, provider: nil, depends_on: nil, reserved_id: nil, owner: nil)
          role_str = role.to_s.strip
          prompt_str = prompt.to_s.strip
          raise ArgumentError, "Subagent role cannot be empty" if role_str.empty?
          raise ArgumentError, "Subagent prompt cannot be empty" if prompt_str.empty?

          # Issue #125: the owner's task was cancelled — refuse before any
          # reservation, slot or context work happens.
          refute_cancelled_owner!(owner)

          # Bağımlı spec doğrudan spawn edilmez: kuyruğa girer (FS/SS
          # kısıtı), bırakma süpürmesi gerçek koreografiyi oynatır.
          if depends_on
            return spawn_batch([{ role: role_str, prompt: prompt_str, type_name: type_name,
                                  system_prompt: system_prompt, parent_id: parent_id, workspace: workspace,
                                  model: model, max_steps: max_steps, provider: provider, depends_on: depends_on }],
                               owner: owner).first[1]
          end

          created = @monitor.synchronize do
            validate_concurrency!
            validate_depth!(parent_id)

            profile_snapshot = resolve_profile_snapshot(type_name: type_name, role: role_str,
                                                        system_prompt: system_prompt)
            effective_sys_prompt = profile_snapshot.effective_system_prompt
            # A profile update must not redirect rollback to a newly provided
            # init supervisor after this spawn registered its unit.
            activation_init = init_for_activation
            # Transcript persistence needs the full custom prompt, whereas an
            # unchanged built-in prompt can be reconstructed from its type.
            prompt_reconstructible = system_prompt.to_s.strip.empty? && !profile_snapshot.custom_prompt

            # Queued specs already reserved this id; fresh spawns reserve the
            # next sequence number here and return it if activation rolls back.
            generated_id = reserved_id.nil?
            subagent_id = generated_id ? "subagent-#{@counter + 1}" : reserved_id.to_s
            id_in_use = @instances.key?(subagent_id) || (@finished || {}).key?(subagent_id)
            raise ArgumentError, "Subagent id '#{subagent_id}' is already in use." if id_in_use

            @counter += 1 if generated_id

            child_ctx = nil
            inst = nil
            begin
              child_ctx = extend_root_context!(:spawn)
              effective_buffer = branch_or_inherit_buffer(workspace)
              scoped_registry = build_scoped_registry(profile_snapshot, child_ctx, effective_buffer)
              prov, effective_model = resolve_provider_and_model(model)
              prov = provider if provider

              inst = Instance.new(
                id: subagent_id, parent_id: parent_id, role: role_str, type_name: profile_snapshot.name,
                prompt: prompt_str, system_prompt: effective_sys_prompt, workspace: workspace,
                model: effective_model, context: child_ctx, tool_registry: scoped_registry,
                provider: prov, buffer_manager: effective_buffer, max_steps: (max_steps || @default_max_steps).to_i,
                provider_gate: @provider_gate, root_dir: @root_dir, config: @config,
                context_limit: (@config.respond_to?(:fetch) ? @config.fetch("context.max_tokens", 32_768) : 32_768),
                event_bus: @event_bus, transcript_storage: absorb_storage, owner_task: owner,
                prompt_reconstructible: prompt_reconstructible, profile_snapshot: profile_snapshot
              )

              @instances[subagent_id] = inst
              activate_instance!(inst, child_ctx: child_ctx, owner_token: owner,
                                       init_supervisor: activation_init, defer_start: true)
              raise "Subagent worker start gate could not be released." unless inst.release_start!

              inst
            rescue StandardError
              rollback_spawn!(subagent_id: subagent_id, inst: inst, child_ctx: child_ctx,
                              init_supervisor: activation_init, generated_id: generated_id)
              raise
            end
          end
          # SS bırakma kancası: yeni başlayan instance, onu bekleyen kuyruk
          # spesifikasyonlarını serbest bırakır (kilit DIŞINDA — emit kuralı).
          begin
            release_ready!
          rescue StandardError => e
            Rubik::Log.warn(:orchestrator, "subagent dependency release failed after successful spawn (#{e.class}: #{e.message})")
          end
          created
        end

        private

        def resolve_profile_snapshot(type_name:, role:, system_prompt:)
          reserved_name = RESERVED_ROLE_PROFILES[role.to_s.downcase.strip]
          if reserved_name
            requested = type_name.to_s.downcase.strip
            unless requested.empty? || requested == "research" || requested == reserved_name
              raise ReservedProfileError,
                    "Reserved subagent role '#{role}' must use built-in archetype '#{reserved_name}', not '#{requested}'."
            end

            type_def = @type_registry.builtins.find { |candidate| candidate.name.to_s.downcase == reserved_name }
            unless type_def
              raise ReservedProfileError,
                    "Reserved subagent role '#{role}' requires built-in archetype '#{reserved_name}', which is unavailable."
            end

            if !system_prompt.to_s.strip.empty? && system_prompt.to_s != type_def.system_prompt.to_s
              raise ReservedProfileError, "Reserved subagent role '#{role}' cannot override its built-in system prompt."
            end

            effective_prompt = type_def.system_prompt
          else
            type_def = @type_registry.get(type_name) || @type_registry.get("research")
            raise ReservedProfileError, "No subagent archetype is available for '#{type_name}'." unless type_def

            effective_prompt = system_prompt.nil? ? type_def.system_prompt : system_prompt
          end

          snapshot = ProfileSnapshot.capture(type_def, effective_system_prompt: effective_prompt)
          missing = snapshot.requires.reject do |name|
            CHILD_CONTEXT_COEFFECTS.include?(name) || !Rubik::Coeffects.get(@root_context, name).nil?
          end
          raise UnsatisfiedCoeffectsError.new(snapshot.name, missing) unless missing.empty?

          snapshot
        end

        def rollback_spawn!(subagent_id:, inst:, child_ctx:, init_supervisor:, generated_id:)
          @instances.delete(subagent_id) if inst && @instances[subagent_id].equal?(inst)

          begin
            inst&.abort_start!
          rescue StandardError => e
            Rubik::Log.warn(:orchestrator, "subagent spawn thread rollback failed (#{e.class}: #{e.message})")
          end

          begin
            init_supervisor&.unregister(inst.unit) if inst&.unit
          rescue StandardError => e
            Rubik::Log.warn(:orchestrator, "subagent kernel unit rollback failed (#{e.class}: #{e.message})")
          end

          begin
            child_ctx&.dispose
          rescue StandardError => e
            Rubik::Log.warn(:orchestrator, "subagent context rollback failed (#{e.class}: #{e.message})")
          end

          @counter -= 1 if generated_id && subagent_id == "subagent-#{@counter}"
        end
      end
    end
  end
end

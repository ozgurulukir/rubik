# frozen_string_literal: true

# Provider/model catalog CRUD (G21 extraction from config.rb): the mutating
# verbs over the `models.<role>` and `providers.<name>` storage shapes. The
# read-side `model_spec` stays typed access in config.rb (Plan 66 ruling).
# Public API is unchanged — these are Config instance methods via include;
# config never prints, outcome hashes (ok/error/reason) let callers report.
module Rubik
  class Config
    module ModelCatalog
      def set_model_spec(role, provider:, name:, endpoint: nil, host: nil, persist: nil)
        role_str = role.to_s.downcase
        old_spec = fetch("models.#{role_str}")
        @data["models"] ||= {}
        spec_hash = {
          "provider" => provider.to_s,
          "name" => name.to_s
        }
        target_endpoint = endpoint || host
        spec_hash["endpoint"] = target_endpoint if target_endpoint
        @data["models"][role_str] = spec_hash

        @data["model"] = spec_hash.dup if role_str == "default"

        res = persisting?(persist) ? persist_result(save!(persist)) : { ok: true }
        res[:reason] = :persist_failed unless res[:ok]
        notify_change("models.#{role_str}", spec_hash, old_spec)
        notify_change("model", spec_hash, old_spec) if role_str == "default"
        res
      end

      # ── Provider-model catalog (providers.<name> storage shape) ──────────
      # The spec hash and its "models" array (Hash entries with "name" /
      # "context_limit"; legacy bare String names tolerated) are storage
      # shape: commands ask intent here instead of re-encoding it per
      # !model/!provider branch.

      # Live spec hash for `provider`, or nil when unknown (absent or empty —
      # the historical !provider "not found" semantics).
      def provider_spec(provider)
        spec = fetch("providers.#{provider}")
        spec.is_a?(Hash) && !spec.empty? ? spec : nil
      end

      # Replace (or append) provider's catalog entry for `model` with the
      # given context limit. {ok: false, reason: :unknown_provider} when the
      # provider is unknown.
      def upsert_provider_model(provider, model, context_limit:, persist: nil)
        mutate_provider_models(provider, persist: persist) do |models|
          models.reject! { |m| model_entry_name(m) == model }
          models << { "name" => model, "context_limit" => context_limit }
        end
      end

      # Drop provider's catalog entry for `model`. {ok: false,
      # reason: :unknown_provider} when the provider is unknown; removing an
      # absent model is a successful no-op (matches the historical
      # !provider remove-model report).
      def remove_provider_model(provider, model, persist: nil)
        mutate_provider_models(provider, persist: persist) do |models|
          models.reject! { |m| model_entry_name(m) == model }
        end
      end

      # Drop a provider and its catalog entirely. Like the model verbs this
      # notifies no listener — callers refresh the runtime explicitly. Routed
      # through delete so the removal survives the disk merge.
      def remove_provider(provider, persist: nil)
        return { ok: false, error: "Provider '#{provider}' not found", reason: :unknown_provider } unless provider_spec(provider)

        delete("providers.#{provider}", persist: persist)
      end

      private

      def mutate_provider_models(provider, persist:)
        p_spec = provider_spec(provider)
        return { ok: false, error: "Provider '#{provider}' not found", reason: :unknown_provider } unless p_spec

        models = Array(p_spec["models"]).dup
        yield models
        p_spec["models"] = models
        set("providers.#{provider}", p_spec, persist: persist)
      end

      # Catalog entries are Hash-shaped today; older configs stored bare model
      # name Strings. One predicate keeps the tolerance from drifting per verb.
      def model_entry_name(entry)
        entry.is_a?(Hash) ? entry["name"] : entry.to_s
      end
    end
  end
end

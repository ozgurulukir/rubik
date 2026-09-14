# frozen_string_literal: true

require_relative "../test_helper"

module Rubik
  module Orchestrator
    class DummyShapeProvider; end # class-name fallback -> "dummyshape"

    module LLM
      class FakeOllamaProvider; end # namespace fallback -> "fakeollama"
    end

    class TestProviderResolver < Minitest::Test
      def test_registry_key_prefers_explicit_name_downcased
        provider = Object.new
        def provider.name = "InternLM"
        assert_equal "internlm", build(provider).registry_key
      end

      def test_registry_key_strips_provider_suffix_from_class_name
        assert_equal "dummyshape", build(DummyShapeProvider.new).registry_key
      end

      def test_registry_key_uses_last_namespace_segment
        assert_equal "fakeollama", build(LLM::FakeOllamaProvider.new).registry_key
      end

      def test_registry_key_empty_name_counts_as_unnamed
        provider = Object.new
        def provider.name = ""
        assert_equal "dummyshape", build(provider, klass: DummyShapeProvider).registry_key
      end

      def test_registry_key_provider_without_name_method
        assert_equal "dummyshape", build(Object.new, klass: DummyShapeProvider).registry_key
      end

      def test_provider_scoped_override_beats_global
        cfg = config_with("providers.internlm.stream_timeout" => 90, "llm.stream_timeout" => 150)
        assert_equal 90, build(named("internlm"), cfg).llm_config("stream_timeout", 120)
      end

      def test_scoped_nil_counts_as_unset_falls_through_to_global
        cfg = config_with("providers.internlm.stream_timeout" => nil, "llm.stream_timeout" => 150)
        assert_equal 150, build(named("internlm"), cfg).llm_config("stream_timeout", 120)
      end

      def test_explicit_false_is_preserved_not_coerced_to_default
        cfg = config_with("llm.stream" => false)
        assert_equal false, build(named("internlm"), cfg).llm_config("stream", true)
      end

      def test_plain_hash_config_missing_key_returns_default_not_keyerror
        assert_equal true, build(named("internlm"), {}).llm_config("stream", true)
      end

      def test_config_without_fetch_returns_default
        assert_equal 42, build(named("internlm"), nil).llm_config("stream_timeout", 42)
      end

      def test_config_fetch_crash_returns_default
        boom = Object.new
        def boom.fetch(*) = raise "boom"
        assert_equal 42, build(named("internlm"), boom).llm_config("stream_timeout", 42)
      end

      private

      def build(provider, config = nil, klass: nil)
        # klass, anonim provider'ın class-name fallback'ini test içi dublo
        # sınıfına bağlamak için singleton_class ile taklit edilir.
        if klass
          provider.define_singleton_method(:class) { klass }
        end
        ProviderResolver.new(provider: provider, config: config)
      end

      def named(name)
        provider = Object.new
        provider.define_singleton_method(:name) { name }
        provider
      end

      def config_with(pairs)
        Rubik::Config.new(root_dir: Dir.mktmpdir, home_dir: Dir.mktmpdir).tap do |cfg|
          pairs.each { |k, v| cfg.set(k, v) }
        end
      end
    end
  end
end

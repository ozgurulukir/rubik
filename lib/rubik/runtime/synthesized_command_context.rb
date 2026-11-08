# frozen_string_literal: true

require_relative "sealed_coeffects"

module Rubik
  module Runtime
    # Sealed execution context for synthesized and overlay commands (Pillar 2, Feature 11).
    #
    # Unlike the interactive REPL `CommandContext` (which exposes `guard`, `config`,
    # `sandbox_runner`, `buffer_manager`, `shell`, and session mutations),
    # `SynthesizedCommandContext` exposes ONLY:
    #   - Output methods: `out` (wrapped stream), `puts`, `print`, `flush` (and alias `output`)
    #   - Safe mediated coeffects: `coeffect(name)`
    #
    # All access to internal subsystems (.guard, .config, .sandbox_runner, .shell,
    # .buffer_manager, .commands, etc.) is blocked; calling them raises NoMethodError.
    class SynthesizedCommandContext
      include SealedCoeffects

      attr_reader :out
      alias output out

      def self.wrap(ctx, shell: nil, runtime_manager: nil)
        return ctx if ctx.is_a?(self)

        output_io = if ctx.respond_to?(:out) then ctx.out
                    elsif ctx then ctx
                    elsif shell.respond_to?(:output) then shell.output
                    else $stdout
                    end
        runtime_ctx = if runtime_manager&.context then runtime_manager.context
                      elsif shell.respond_to?(:runtime_manager) then shell.runtime_manager&.context
                      elsif ctx.respond_to?(:runtime_manager) then ctx.runtime_manager&.context
                      end
        new(output: output_io, coeffects: runtime_ctx || {})
      end

      def initialize(output: $stdout, coeffects: {})
        @out = output || $stdout
        @coeffects = coeffects || {}
      end

      # IO conveniences delegating to @out
      def puts(*)
        @out.puts(*)
      end

      def print(*)
        @out.print(*)
      end

      def flush
        @out.flush if @out.respond_to?(:flush)
      end

      # Safe mediated coeffect accessor.
      # Returns nil if the coeffect is blocked or not satisfied.
      def coeffect(name)
        return nil if name.nil?

        key = name.to_s.downcase.strip
        return nil if blocked?(key)

        if @coeffects.is_a?(Hash)
          @coeffects[key] || @coeffects[name] || @coeffects[name.to_s] || @coeffects[name.to_sym]
        elsif @coeffects.respond_to?(:get)
          @coeffects.get(key)
        elsif @coeffects.respond_to?(:resolve)
          @coeffects.resolve(key)
        elsif @coeffects.respond_to?(:[])
          @coeffects[key] || @coeffects[name]
        end
      end
    end
  end

  module REPL
    SynthesizedCommandContext = Rubik::Runtime::SynthesizedCommandContext
  end
end

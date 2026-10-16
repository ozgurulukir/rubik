# frozen_string_literal: true

require_relative "assessment"

module Rubik
  module RuntimeValidation
    # Renders raw observations and the same verdicts used by the command.
    class ReportFormatter
      def self.format(data)
        new(data).to_markdown
      end

      def initialize(data)
        @d = data
      end

      def to_markdown
        sys = @d[:system_info]
        [
          "# Runtime Capacity Validation",
          "Date: #{@d[:timestamp]}\n\nOverall verdict: **#{@d[:verdict]}**\n\n" \
            "Ruby: #{sys[:ruby_version]} (#{sys[:ruby_platform]}); OS: #{sys[:host_os]}; CPU: #{sys[:cpu_arch]}\n\n" \
            "Seed: #{@d[:seed]}; configured epochs: #{@d[:epochs]}; duration: #{@d[:total_duration_s]}s",
          resource_section,
          soak_section,
          scheduler_section,
          cache_section,
          "## Reproduction\n\n```sh\nbundle exec ruby dev/validate_runtime_capacity.rb --epochs=#{@d[:epochs]} --seed=#{@d[:seed]}\n```\n\n" \
            "Exit status: 0 PASS, 1 FAIL, 2 INCONCLUSIVE. No external API or credentials required."
        ].join("\n\n")
      end

      private

      def status(value)
        value.nil? ? "INCONCLUSIVE" : (value ? "PASS" : "FAIL")
      end

      def resource_section
        baseline = @d[:telemetry][:baseline]
        final = @d[:telemetry][:final]
        limits = { threads: 0, child_processes: 0, ruby_fibers: 0, child_contexts: 0, open_fds: 3, rss_kb: 61_440 }
        rows = limits.map do |key, limit|
          delta = final[key] - baseline[key] if final[key] && baseline[key]
          "| #{key} | #{baseline[key] || 'N/A'} | #{final[key] || 'N/A'} | #{delta || 'N/A'} | <= #{limit} | #{status(@d[:resource_checks][key])} |"
        end
        "## Resources\n\nSnapshots follow GC; threads exclude the stdlib timeout daemon. " \
          "FD/RSS and process counts use Linux /proc; unavailable probes are INCONCLUSIVE. " \
          "Ruby fibers count live Fiber objects; contexts count retained Context objects after GC.\n\n" \
          "| Metric | Baseline | Final | Delta | Tolerance | Verdict |\n|---|---|---|---|---|---|\n#{rows.join("\n")}"
      end

      def soak_section
        rows = @d[:soak_results].map do |r|
          verdict = r[:inconclusive] ? "INCONCLUSIVE" : status(r[:passed])
          "| #{r[:name]} | #{r[:epochs]} | #{r[:duration_ms]} | #{verdict} | #{r[:violations].join('; ')} |"
        end
        samples = @d[:soak_results].map do |r|
          "### #{r[:name]} resource samples\n\n```json\n#{JSON.pretty_generate(r[:telemetry_samples] || [])}\n```"
        end
        "## Lifecycle Soak\n\n| Family | Actual epochs | Duration ms | Verdict | Violations |\n|---|---|---|---|---|\n" \
          "#{rows.join("\n")}\n\n#{samples.join("\n\n")}"
      end

      def scheduler_section
        results = @d[:scheduler_results]
        rows = [:requests100, :requests1000].map do |key|
          r = results[key]
          "### #{key}: #{status(Assessment.requests_passed?(r))}\n\n```json\n#{JSON.pretty_generate(r)}\n```"
        end
        rows.concat([:timeout_cancel, :scheduler_comparison].map do |key|
          r = results[key]
          "### #{key}: #{r[:inconclusive] ? 'INCONCLUSIVE' : status(r[:passed])}\n\n```json\n#{JSON.pretty_generate(r)}\n```"
        end)
        "## Scheduler\n\nLoopback HTTP, eight server workers. Durations use CLOCK_MONOTONIC. " \
          "Request thresholds: 100/1000 successes; duration <3/<6s; p50 <500/<2000ms; p95 <1000/<4000ms. " \
          "Comparison requires >=1.5x speedup. Timeout disables HTTP retries; cancellation interrupts a parked fiber.\n\n#{rows.join("\n\n")}"
      end

      def cache_section
        c = @d[:cache_results]
        "## AST Cache: #{status(c[:passed])}\n\nSynthetic Ruby fixture, cold extraction + save versus warm validated load; " \
          "requires all fixture entries, warm load <500ms, nonempty cache, and warm faster than cold.\n\n```json\n#{JSON.pretty_generate(c)}\n```"
      end
    end
  end
end

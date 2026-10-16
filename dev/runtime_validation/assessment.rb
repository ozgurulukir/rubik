# frozen_string_literal: true

module Rubik
  module RuntimeValidation
    # One verdict policy shared by the command and its report.
    module Assessment
      module_function

      def resource_checks(baseline, final)
        {
          threads: delta_check(baseline, final, :threads, 0),
          child_processes: delta_check(baseline, final, :child_processes, 0),
          ruby_fibers: delta_check(baseline, final, :ruby_fibers, 0),
          child_contexts: delta_check(baseline, final, :child_contexts, 0),
          open_fds: delta_check(baseline, final, :open_fds, 3),
          rss_kb: delta_check(baseline, final, :rss_kb, 60 * 1024)
        }
      end

      def delta_check(baseline, final, key, tolerance)
        return nil if baseline[key].nil? || final[key].nil?

        final[key] - baseline[key] <= tolerance
      end

      def requests_passed?(result)
        return nil if result[:inconclusive]
        return false if result[:error]

        small = result[:count] == 100
        result[:failed].zero? && result[:duration_s] < (small ? 3.0 : 6.0) &&
          result[:p50_ms] < (small ? 500 : 2000) && result[:p95_ms] < (small ? 1000 : 4000)
      end

      def verdict(checks)
        return "FAIL" if checks.include?(false)
        return "INCONCLUSIVE" if checks.include?(nil)

        "PASS"
      end
    end
  end
end

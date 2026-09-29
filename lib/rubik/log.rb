# frozen_string_literal: true

# Central leveled logging core (G6 early slice): one seam for runtime
# diagnostics, replacing ad-hoc Kernel#warn call sites as they are triaged
# (see _plan/rescue-standarderror-triage-2026-09-29.md). Single-line format
# follows the repo's [rubik] prefix convention. Emit is error-isolated: a
# logger must never raise, least of all from inside a rescue body.
#
# warn/error always print (current behavior). debug/info are filtered by
# RUBIK_LOG_LEVEL (default "warn"); the RUBIK_DEBUG-gated debug_warn stays a
# separate mechanism and is NOT migrated by this slice.
module Rubik
  module Log
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze

    module_function

    def level
      LEVELS.fetch(ENV.fetch("RUBIK_LOG_LEVEL", "warn").downcase.to_sym, LEVELS[:warn])
    end

    def debug(subsystem, message) = emit(:debug, subsystem, message)
    def info(subsystem, message) = emit(:info, subsystem, message)
    def warn(subsystem, message) = emit(:warn, subsystem, message)
    def error(subsystem, message) = emit(:error, subsystem, message)

    def emit(level_name, subsystem, message)
      return if LEVELS.fetch(level_name) < level

      # $stderr.puts, not Kernel#warn: warn is silenced when $VERBOSE is nil
      # (bundler/rake -W0), which would make logging vanish in test and
      # bundler contexts.
      $stderr.puts "[rubik] #{level_name} #{subsystem}: #{message}" # rubocop:disable Style/StderrPuts
    rescue StandardError
      nil
    end
  end
end

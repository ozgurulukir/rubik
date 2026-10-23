# frozen_string_literal: true

require "open3"
require_relative "../log"

module Rubik
  module Context
    # Fast file listing via `git ls-files` (C-speed walk + gitignore handling).
    # Returns nil whenever git cannot answer (not a repo, spawn failure) so
    # the caller falls back to its own walker — a missing git must degrade,
    # never raise. Spawn is call-scoped: no persistent process, thread, or
    # listener is kept alive.
    module GitLister
      module_function

      # @return [Array<String>, nil] POSIX-style paths relative to root_dir,
      #   or nil when git is unusable.
      def files(root_dir)
        out, _err, status = Open3.capture3(
          "git", "-C", root_dir.to_s,
          "ls-files", "-z", "--cached", "--others", "--exclude-standard"
        )
        return nil unless status.success?

        # PERF: NUL-split with conditional in-place backslash translation and
        # in-place deduplication avoids intermediate array and string allocations.
        res = out.split("\x00", -1).reject(&:empty?)
        res.map! { |p| p.tr("\\", "/") } if out.include?("\\")
        res.uniq!
        res
      rescue StandardError => e
        Rubik::Log.debug(:context, "git ls-files execution failed for #{root_dir}: #{e.class}: #{e.message}")
        nil
      end

      # Switch resolution shared with the scanner: ENV beats config, anything
      # other than "off" (auto/on/unknown) attempts the fast path first.
      def enabled?(config_value, env: ENV)
        mode = env["RUBIK_NATIVE"] || config_value || "auto"
        mode.to_s.strip.downcase != "off"
      end
    end
  end
end

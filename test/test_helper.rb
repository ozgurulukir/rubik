# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "tmpdir"
require "fileutils"

real_cache_dir = ENV["XDG_CACHE_HOME"] || File.expand_path("~/.cache")
ENV["HOME"] = Dir.mktmpdir("rubik_test_home")
ENV["XDG_CACHE_HOME"] ||= real_cache_dir
ENV["RUBIK_TEST"] = "1"

require "minitest/autorun"
require "rubik"

# Ruby ≤ 3.4: Open3.capture3 can leak a reader-thread
# "IOError: stream closed in another thread" (ruby/ruby#8180). It is
# cosmetic, flaky (0–2 occurrences per suite run) and harmless — the
# capture still returns and all assertions stay green. We deliberately
# do NOT silence it at the process level: a stderr filter would hide
# real test failures under a race we do not control, and any pipe-based
# interception reintroduces the same deadlock class we rejected for the
# callersite fix. Upstream fix (Ruby 3.5+ open3 rewrite) will close this
# without touching the codebase.

# Windows: temp-dir removal can transiently hit Errno::EACCES while a file
# handle is still being released (antivirus/indexer sweep). Best-effort
# retry keeps teardown deterministic without masking real assertions.
def remove_temp_dir(path)
  attempts = 0
  begin
    FileUtils.remove_entry(path)
  rescue Errno::ENOENT
    nil
  rescue Errno::EACCES, Errno::ENOTEMPTY
    attempts += 1
    if attempts < 5
      sleep 0.2
      retry
    end
    warn "[test] could not remove temp dir #{path} after #{attempts} attempts"
  end
end

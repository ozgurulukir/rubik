# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "tmpdir"
require "fileutils"

real_cache_dir = ENV["XDG_CACHE_HOME"] || File.expand_path("~/.cache")
ENV["HOME"] = Dir.mktmpdir("rubik_test_home")
ENV["XDG_CACHE_HOME"] ||= real_cache_dir
ENV["RUBIK_TEST"] = "1"

require "minitest"

# Fail-closed environment shield: Ruby >= 4.0 ships minitest 6.0 as a default
# gem (minitest/mock removed, API changes). The Gemfile pins "~> 5.20"; running
# the tests without bundler silently loads 6.0 and produces false FAIL/ERROR
# storms. Abort with an actionable message instead of failing misleadingly.
def assert_supported_minitest!(version = Minitest::VERSION)
  return if Gem::Version.new(version) < Gem::Version.new("6")

  abort(<<~MSG)
    [test] minitest #{version} detected, but this project pins minitest "~> 5.20" (Gemfile).
    Minitest 6 (Ruby default gem) removed minitest/mock and changed APIs, which
    produces false FAIL/ERROR results. Run the suite through bundler:

        bundle exec rake test           # full suite (unit + integration)
        bundle exec rake test:fast      # unit without the slow files
        bundle exec rake test:slow      # only the slow unit files
        bundle exec ruby -Ilib -Itest test/unit/test_some_file.rb

    Or install the pinned gems first: bundle install
  MSG
end

assert_supported_minitest!
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

# Writes a minimal valid SKILL.md under <skills_root>/<name>/ and returns
# the skill directory. skills_root is a skills directory itself (a
# .rubik/skills root or an extra-path root), NOT a workspace root.
# extra_frontmatter lines (if any) must each end with a newline.
def write_skill_md(skills_root, name, description: "d", body: "\nBody\n", extra_frontmatter: "")
  dir = File.join(skills_root, name)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "SKILL.md"),
             "---\nname: #{name}\ndescription: #{description}\n#{extra_frontmatter}---\n#{body}")
  dir
end

# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "tmpdir"
require "fileutils"

ENV["HOME"] = Dir.mktmpdir("rubik_test_home")
ENV["RUBIK_TEST"] = "1"

require "minitest/autorun"
require "rubik"

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

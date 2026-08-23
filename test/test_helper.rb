# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "tmpdir"
require "fileutils"

ENV["HOME"] = Dir.mktmpdir("rubik_test_home")
ENV["RUBIK_TEST"] = "1"

require "minitest/autorun"
require "rubik"

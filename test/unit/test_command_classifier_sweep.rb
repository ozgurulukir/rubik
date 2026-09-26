# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require_relative "../../lib/rubik/security/classifier/database"
require_relative "../../lib/rubik/security/classifier/matcher"
require_relative "../../lib/rubik/security/classifier/models"

require_relative "../../lib/rubik/security/classifier/parsers/bash"

class TestCommandClassifierSweep < Minitest::Test
  Database = Rubik::Security::Classifier::CommandDatabase
  Matcher = Rubik::Security::Classifier::Matcher
  Parser = Rubik::Security::Classifier::Parsers::Bash
  CommandInvocation = Rubik::Security::Classifier::CommandInvocation

  def setup
    @db = Database.new
    @commands_dir = File.expand_path("../../lib/rubik/security/classifier/commands", __dir__)
    @yaml_files = Dir.glob(File.join(@commands_dir, "*.yaml"))
  end

  def test_all_command_yaml_files_are_valid_and_non_empty
    refute_empty @yaml_files, "Expected to find command YAML rule files"
    assert @yaml_files.size >= 160, "Expected at least 160 command definitions"

    @yaml_files.each do |file|
      basename = File.basename(file)
      raw = File.read(file)

      parsed = begin
        YAML.safe_load(raw, permitted_classes: [Symbol], aliases: true)
      rescue StandardError => e
        flunk("Failed to parse YAML for #{basename}: #{e.message}")
      end

      assert_instance_of Hash, parsed, "File #{basename} must define a Hash"
      assert parsed.key?("command"), "File #{basename} must specify 'command' field"
      refute_empty parsed["command"].to_s.strip, "File #{basename} must have non-empty 'command'"

      has_spec = parsed.key?("classification") ||
                 parsed.key?("subcommands") ||
                 parsed.key?("alias_of") ||
                 parsed.key?("delegates_to")
      assert has_spec, "File #{basename} must define classification, subcommands, alias_of, or delegates_to"
    end
  end

  def test_all_command_definitions_load_into_database_and_compile
    @yaml_files.each do |file|
      basename = File.basename(file)
      cmd_name = File.basename(file, ".yaml")

      cmd_def = @db[cmd_name]
      refute_nil cmd_def, "CommandDatabase must load #{cmd_name} (#{basename})"
      assert_equal cmd_name, cmd_def.command

      # Ensure Matcher can evaluate a baseline invocation without raising exceptions
      inv = CommandInvocation.new(argv: [cmd_name])
      warns = []
      result = Matcher.match_command(inv, @db, warns)
      refute_nil result, "Matcher must return a CommandResult for #{cmd_name}"
      assert_includes [:readonly, :local_effects, :external_effects, :dangerous, :unknown, :unclassified], result.classification
    end
  end

  def test_dangerous_flag_elevation_sweep
    # Check that commands with DANGEROUS option overrides correctly elevate classification
    dangerous_cases = [
      { cmd: "rm", args: ["--no-preserve-root"], expected: :dangerous },
      { cmd: "dd", args: ["of=/dev/sda"], expected: :dangerous },
      { cmd: "mkfs", args: ["/dev/sda1"], expected: :dangerous }
    ]

    dangerous_cases.each do |tc|
      cmd_def = @db[tc[:cmd]]
      next unless cmd_def

      inv = CommandInvocation.new(argv: [tc[:cmd], *tc[:args]])
      warns = []
      result = Matcher.match_command(inv, @db, warns)
      assert_equal tc[:expected], result.classification,
                   "#{tc[:cmd]} #{tc[:args].join(' ')} should be classified as #{tc[:expected]}"
    end
  end
end

# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"
require "rubik/cli/workspace_trust"

class TestWorkspaceTrust < Minitest::Test
  class PromptDouble
    def initialize(choice)
      @choice = choice
    end

    def select(_question, choices, default:, **)
      expected_choices = [Rubik::CLI::WorkspaceTrust::TRUST_OPTION, Rubik::CLI::WorkspaceTrust::EXIT_OPTION]
      raise "unexpected trust prompt choices" unless choices == expected_choices
      raise "trust prompt must default to Exit" unless default == Rubik::CLI::WorkspaceTrust::EXIT_OPTION
      raise "unexpected prompt" if @choice == :unexpected

      @choice
    end
  end

  def setup
    @workspace = Dir.mktmpdir("rubik_trust_workspace")
    @home = Dir.mktmpdir("rubik_trust_home")
    @store_path = File.join(@home, "trusted_workspaces.yml")
    @output = StringIO.new
  end

  def teardown
    remove_temp_dir(@workspace)
    remove_temp_dir(@home)
  end

  def test_noninteractive_launch_skips_prompt_and_persistence
    assert_equal true, authorize(interactive: false, choice: :unexpected)
    assert_empty @output.string
    refute File.exist?(@store_path)
  end

  def test_exit_does_not_trust_workspace
    assert_equal false, authorize(choice: Rubik::CLI::WorkspaceTrust::EXIT_OPTION)
    refute Rubik::CLI::WorkspaceTrust.trusted?(@workspace, store_path: @store_path)
  end

  def test_trust_choice_persists_workspace_and_explains_command_authority
    assert_equal true, authorize(choice: Rubik::CLI::WorkspaceTrust::TRUST_OPTION)

    assert Rubik::CLI::WorkspaceTrust.trusted?(@workspace, store_path: @store_path)
    assert_includes @output.string, @workspace
    assert_includes @output.string, "foreground and background commands"
    assert_includes @output.string, "buffer.model_can_apply: false"
    assert_equal 0o600, File.stat(@store_path).mode & 0o777 unless Rubik::Platform.windows?
  end

  def test_existing_trust_skips_prompt
    Rubik::CLI::WorkspaceTrust.trust!(@workspace, store_path: @store_path)

    assert_equal true, authorize(choice: :unexpected)
    assert_empty @output.string
  end

  private

  def authorize(choice:, interactive: true)
    prompt = PromptDouble.new(choice)
    Rubik::UI::Capability.stub(:interactive?, interactive) do
      TTY::Prompt.stub(:new, prompt) do
        Rubik::CLI::WorkspaceTrust.authorize!(
          workspace: @workspace,
          input: StringIO.new,
          output: @output,
          store_path: @store_path
        )
      end
    end
  end
end

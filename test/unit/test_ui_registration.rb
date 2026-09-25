# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/ui"
require_relative "../../lib/rubik/runtime/context"
require_relative "../../lib/rubik/config"

class TestUIRegistration < Minitest::Test
  class FakeShell
    attr_reader :config, :output

    def initialize(output)
      @config = Rubik::Config.new
      @output = output
    end
  end

  def setup
    @ctx = Rubik::Runtime::Context.new
    @out1 = StringIO.new
    @shell1 = FakeShell.new(@out1)
  end

  def teardown
    @ctx.dispose unless @ctx.disposed
  end

  def test_initial_registration_sets_ui_and_theme
    renderer = Rubik::UI::RenderService.register(@ctx, shell: @shell1)
    assert_equal renderer, @ctx.get("ui")
    assert @ctx.has?("theme")
  end

  def test_context_dispose_cleans_up_renderer_spinner
    renderer = Rubik::UI::RenderService.register(@ctx, shell: @shell1)
    # Start spinner
    renderer.spinner.start
    assert renderer.spinner.spinning?, "Spinner should be running"

    @ctx.dispose
    refute renderer.spinner.spinning?, "Disposing context should kill active spinner"
  end

  def test_reregistration_kills_stale_spinner_immediately
    renderer1 = Rubik::UI::RenderService.register(@ctx, shell: @shell1)
    renderer1.spinner.start
    assert renderer1.spinner.spinning?, "First spinner should be running"

    out2 = StringIO.new
    shell2 = FakeShell.new(out2)
    renderer2 = Rubik::UI::RenderService.register(@ctx, shell: shell2)

    refute renderer1.spinner.spinning?, "Re-registering UI should kill stale spinner from previous renderer"
    assert_equal renderer2, @ctx.get("ui")
  end

  def test_reregistration_does_not_grow_omega_accumulator
    # Initial registration adds 2 services (ui, theme) with 2 delete inverses + 1 dispose inverse
    Rubik::UI::RenderService.register(@ctx, shell: @shell1)
    initial_count = @ctx.disposable_count

    5.times do
      out = StringIO.new
      shell = FakeShell.new(out)
      Rubik::UI::RenderService.register(@ctx, shell: shell)
    end

    assert_equal initial_count, @ctx.disposable_count,
                 "Repeated UI registrations should not leak inverses into Omega accumulator"
  end

  def test_context_dispose_kills_latest_renderer_spinner_after_reregistration
    Rubik::UI::RenderService.register(@ctx, shell: @shell1)

    out2 = StringIO.new
    shell2 = FakeShell.new(out2)
    renderer2 = Rubik::UI::RenderService.register(@ctx, shell: shell2)
    renderer2.spinner.start
    assert renderer2.spinner.spinning?

    @ctx.dispose
    refute renderer2.spinner.spinning?, "Disposing context should kill latest renderer's active spinner"
  end
end

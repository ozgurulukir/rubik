# frozen_string_literal: true

module Rubik
  module REPL
    # Presentation helpers mixed into Shell (the Confirmations pattern):
    # display-layer lifecycle, banner/statusline printing, input-box prompt
    # segments and the shared step-event renderer used by free-text turns,
    # !plan and !goal. Kept out of shell.rb to respect the decoupling budget
    # enforced by test_repl_command_decoupling.
    module Presentation
      # Rebuilds the display layer after runtime UI config changes
      # (`!config set ui.*`, `!verbose`). The old spinner is killed before
      # swap, then registration is delegated to RenderService so the
      # refresh and init paths can never drift apart. The renderer binds to
      # the REAL terminal — refresh typically fires from inside a command
      # handler where @output is a transient capture TeeIO.
      def refresh_ui!
        @ui_renderer&.spinner&.kill
        real_output = Rubik::UI::Capability.unwrap_tee(@output)
        if real_output.nil? && @output.is_a?(Rubik::REPL::TeeIO)
          # Piped/command-capture context: bind to the tee's first target
          # (the original stream) instead of the transient capture wrapper.
          real_output = @output.targets.first || @output
        end
        @ui_renderer = Rubik::UI::RenderService.register(@runtime_manager, shell: self, output: real_output)
        @ui_theme = @ui_renderer&.theme
        @terminal_guard.quiet = (@config.respond_to?(:fetch) ? @config.fetch("ui.quiet_notices", false) : false) == true if @terminal_guard
      end

      # Single accessor for the active display theme; call sites never
      # rebuild it themselves.
      def theme
        @ui_theme || Rubik::UI::Theme.for(@output, @config)
      end

      # Renders one orchestrator step event through the UI renderer and
      # prints it. Shared by !plan and !goal; free-text turns additionally
      # stream :chunk deltas through UI::MarkdownStream.
      def render_step_event(step_info)
        formatted = @ui_renderer&.render(step_info)
        return if formatted.nil? || formatted.empty?

        @output.puts formatted
        @output.flush if @output.respond_to?(:flush)
      end

      def print_banner
        banner = Rubik::UI::Banner.render(self, theme)
        @output.puts banner if banner
      end

      # Renders the context strip above the prompt (model, context usage,
      # dirty buffer, sandbox posture). Honors `ui.statusline`.
      def print_statusline
        line = Rubik::UI::Statusline.render(self, theme)
        @output.puts line if line
      end

      # Prompt line for `ui.input_box`: the editing line prefixed with a left
      # rail. ALWAYS a plain String — Reline (0.6.x) applies String#gsub to
      # the prompt, so an Array prompt crashes readline outright. The top
      # border is printed as a separate line before readline (see
      # read_and_process_line) and the bottom border after the line is
      # accepted; a live right rail is a renderer-level feature Reline
      # cannot offer. No ANSI in the prompt (cursor math must stay exact).
      def box_prompt_lines(base_prompt, boxed:)
        return base_prompt unless boxed

        "#{theme.glyph(:rail)} #{base_prompt}"
      end

      def box_top_border
        Rubik::UI::Frame.top_border(theme, width: Rubik::UI::Frame.width(@output), title: "rubik")
      end

      def box_bottom_border
        Rubik::UI::Frame.bottom_border(theme, width: Rubik::UI::Frame.width(@output))
      end

      # Prints the per-line prompt decorations (statusline strip and the
      # ui.input_box top border — both plain lines above the prompt) and
      # returns [effective_prompt_string, boxed?]. Reline 0.6 applies
      # String#gsub to the prompt, so it must remain a single String — an
      # Array prompt crashes readline outright; the bottom border is the
      # caller's job after the line is accepted.
      def prepare_prompt_line(heredoc_active)
        print_statusline unless heredoc_active
        boxed = @config.fetch("ui.input_box", false) == true && !heredoc_active
        @output.puts box_top_border if boxed
        base = heredoc_active ? "... > " : prompt
        [box_prompt_lines(base, boxed: boxed), boxed]
      end

      def prompt
        project_name = File.basename(Dir.pwd)
        git_branch = detect_git_branch
        branch_part = git_branch ? " [#{git_branch}]" : ""
        show_indicator = @config.fetch("buffer.prompt_indicator", true)
        dirty_count = @buffer_manager&.dirty? ? @buffer_manager.dirty_files.size : 0
        dirty_part = show_indicator && dirty_count.positive? ? " [DIRTY: #{dirty_count} ✎]" : ""
        "rubik (#{project_name})#{branch_part}#{dirty_part} > "
      end

      def detect_git_branch
        git_dir =
          if File.file?(".git")
            # Linked worktree / submodule: .git is a FILE holding
            # "gitdir: <path>"; HEAD lives in that directory.
            content = Rubik::Platform.read_text(".git").strip
            File.expand_path(content.delete_prefix("gitdir:").strip, Dir.pwd) if content.start_with?("gitdir:")
          elsif File.directory?(".git")
            ".git"
          end
        return nil unless git_dir

        head_file = File.join(git_dir, "HEAD")
        return nil unless File.exist?(head_file)

        content = Rubik::Platform.read_text(head_file).strip
        return nil if content.empty?

        if content.start_with?("ref: refs/heads/")
          content.sub("ref: refs/heads/", "")
        else
          content[0..6]
        end
      rescue StandardError
        nil
      end
    end
  end
end

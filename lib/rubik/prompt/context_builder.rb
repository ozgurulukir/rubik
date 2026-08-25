# frozen_string_literal: true

require "json"

module Rubik
  module Prompt
    class ContextBuilder
      PROTOCOL_CANDIDATES = [
        "AGENTS.md",
        ".rubik/AGENTS.md",
        "RULES.md",
        ".rubik/RULES.md",
        "CLAUDE.md"
      ].freeze

      def self.find_protocol_files(root_dir = Dir.pwd)
        found = []
        PROTOCOL_CANDIDATES.each do |candidate|
          full_path = File.join(root_dir, candidate)
          found << { path: candidate, full_path: full_path } if File.file?(full_path)
        end
        found
      end

      def self.build_protocol_xml(root_dir = Dir.pwd)
        files = find_protocol_files(root_dir)
        return "" if files.empty?

        blocks = files.map do |f|
          content = File.read(f[:full_path]).strip
          <<~XML
            <protocol source="#{f[:path]}">
            #{content}
            </protocol>
          XML
        end
        blocks.join("\n").strip
      end

      def self.build_workspace_xml(context_index = nil, root_dir = Dir.pwd)
        proj_name = File.basename(root_dir)
        git_branch = detect_git_branch(root_dir) || "no-git"

        summary = context_index&.status_summary || { file_count: 0, languages: [] }
        file_count = summary[:file_count] || 0
        langs = (summary[:languages] || []).join(", ")
        langs_str = langs.empty? ? "none detected" : langs

        files_hash = context_index&.files || {}

        structure_xml = if file_count > 0 && file_count <= 30
                          file_tags = files_hash.map do |path, info|
                            lang_attr = info[:language] ? " lang=\"#{info[:language]}\"" : ""
                            "    <file#{lang_attr}>#{path}</file>"
                          end.join("\n")
                          <<~FILES.strip
                            <workspace_files count="#{file_count}">
                            #{file_tags}
                            </workspace_files>
                          FILES
                        elsif file_count > 30
                          top_dirs = files_hash.keys.map { |f| f.include?("/") ? f.split("/").first : nil }.compact.uniq.sort
                          entry_points = files_hash.keys.select do |f|
                            %w[Gemfile package.json Cargo.toml go.mod Makefile pyproject.toml Rakefile index.html README.md].include?(File.basename(f)) ||
                              f.start_with?("bin/") || f.start_with?("main.") || f.start_with?("app.") || f.start_with?("index.")
                          end

                          dirs_str = top_dirs.empty? ? "root" : top_dirs.map { |d| "#{d}/" }.join(", ")
                          entries_str = entry_points.empty? ? "none" : entry_points.join(", ")

                          <<~STRUCT.strip
                            <workspace_structure count="#{file_count}">
                              <top_level_directories>#{dirs_str}</top_level_directories>
                              <entry_points>#{entries_str}</entry_points>
                            </workspace_structure>
                          STRUCT
                        else
                          "<workspace_files count=\"0\" />"
                        end

        <<~XML.strip
          <workspace_status>
            <project_name>#{proj_name}</project_name>
            <working_directory>#{root_dir}</working_directory>
            <git_branch>#{git_branch}</git_branch>
            <languages>#{langs_str}</languages>
            #{structure_xml}
          </workspace_status>
        XML
      end

      def self.build_buffer_xml(buffer_manager = nil, snapshot_store = nil, auto_apply: "manual")
        dirty = buffer_manager&.dirty? || false
        dirty_list = if buffer_manager.nil?
                       []
                     elsif buffer_manager.dirty_files.is_a?(Hash)
                       buffer_manager.dirty_files.keys
                     else
                       Array(buffer_manager.dirty_files)
                     end
        snap_count = if snapshot_store.respond_to?(:snapshots)
                       snapshot_store.snapshots.size
                     elsif snapshot_store.respond_to?(:history)
                       snapshot_store.history.size
                     else
                       0
                     end

        dirty_tags = dirty_list.map { |f| "    <file>#{f}</file>" }.join("\n")
        dirty_section = dirty_list.empty? ? "" : "\n#{dirty_tags}\n  "
        notice = if dirty
                   "\n    <notice>⚠️ Notice: #{dirty_list.size} unapplied buffer changes in memory. External shell and test tools run against disk. Use 'apply_buffer' or '!apply' to sync.</notice>"
                 else
                   ""
                 end

        <<~XML.strip
          <buffer_status dirty="#{dirty}" auto_apply="#{auto_apply}">
            <dirty_files count="#{dirty_list.size}">#{dirty_section}</dirty_files>
            <snapshot_count>#{snap_count}</snapshot_count>#{notice}
          </buffer_status>
        XML
      end

      def self.build_operational_rules_xml
        <<~XML.strip
          <operational_rules>
            1. Code Exploration & Review: Use native tools directly (`list_files`, `grep_search`, `search_symbols`, `get_outline`, `read_file`, `find_references`). Do NOT look for or execute imaginary REPL commands such as `!review` or `!check`. For conceptual queries (e.g. "code review", "refactoring candidates", "code quality"), do NOT search for the literal words "refactor" or "review"; instead, inspect the directory structure (`list_files`), search codebase for patterns (`grep_search`), examine core modules (`get_outline`, `read_file`), search for TODO/FIXME markers, and evaluate architecture structurally.
            2. Code Editing: Use `write_file` to stage changes into the in-memory buffer.
            3. Testing & Execution: Use native tools `run_tests` and `run_command` directly. Do NOT wrap them in `exec_repl_command`. Commands in `run_command` run directly in the project working directory (`<working_directory>`); do NOT prepend `cd` commands or guess non-existent paths (e.g. `/home/ubuntu`). Always fulfill the user's primary requested action (e.g. merge, build, test, commit) to completion.
            4. REPL Bang Commands: `exec_repl_command` is strictly reserved for runtime configuration, snapshot rollback, and system diagnostic inspection (`!config`, `!model`, `!undo`, `!rollback`, `!runtime`, `!fibers`, `!services`).
          </operational_rules>
        XML
      end

      def self.build_commands_xml(shell_or_commands = nil, include_builtins: false)
        commands = if shell_or_commands.is_a?(Hash)
                     shell_or_commands
                   elsif shell_or_commands.respond_to?(:commands)
                     shell_or_commands.commands
                   else
                     {}
                   end

        return "" if commands.empty?

        filtered = if include_builtins
                     commands
                   else
                     commands.select { |_k, v| v.is_a?(Hash) && v[:custom] }
                   end

        return "" if filtered.empty?

        cmd_tags = filtered.sort.map do |name, meta|
          desc = (meta.is_a?(Hash) ? meta[:description] : meta) || ""
          "  <command name=\"!#{name}\">#{desc}</command>"
        end.join("\n")

        tag_name = include_builtins ? "repl_commands" : "custom_commands"

        <<~XML.strip
          <#{tag_name}>
          #{cmd_tags}
          </#{tag_name}>
        XML
      end

      def self.build_lsp_xml(lsp_manager = nil)
        return "" unless lsp_manager && lsp_manager.enabled?

        summary = lsp_manager.status_summary
        active_servers = summary[:servers].select { |_k, v| v[:running] }.keys

        all_diags = lsp_manager.all_diagnostics
        total_errors = 0
        diag_tags = []

        all_diags.each do |fpath, diags|
          diags.each do |d|
            sev = d["severity"] == 1 ? "error" : "warning"
            total_errors += 1 if sev == "error"
            start_line = (d.dig("range", "start", "line") || 0) + 1
            msg = d["message"].to_s.gsub("<", "&lt;").gsub(">", "&gt;")
            diag_tags << "    <diagnostic file=\"#{fpath}\" line=\"#{start_line}\" severity=\"#{sev}\">#{msg}</diagnostic>"
          end
        end

        if diag_tags.empty?
          <<~XML.strip
            <lsp_status enabled="true" active_servers="#{active_servers.join(', ')}" clean="true" />
          XML
        else
          <<~XML.strip
            <lsp_diagnostics active_servers="#{active_servers.join(', ')}" total_issues="#{diag_tags.size}" errors="#{total_errors}">
            #{diag_tags.join("\n")}
            </lsp_diagnostics>
          XML
        end
      end

      def self.build_system_context(shell: nil, config: nil, commands: nil, buffer_manager: nil, snapshot_store: nil, context_index: nil, lsp_manager: nil, context_limit: nil, root_dir: Dir.pwd, extra_context: "")
        sections = []

        rules_xml = build_operational_rules_xml
        sections << rules_xml unless rules_xml.empty?

        protocol_xml = build_protocol_xml(root_dir)
        sections << protocol_xml unless protocol_xml.empty?

        workspace_xml = build_workspace_xml(context_index, root_dir)
        sections << workspace_xml unless workspace_xml.empty?

        auto_apply_mode = (config || shell&.config)&.fetch("buffer.auto_apply", "manual") || "manual"
        buffer_xml = build_buffer_xml(buffer_manager, snapshot_store, auto_apply: auto_apply_mode)
        sections << buffer_xml unless buffer_xml.empty?

        effective_lsp = lsp_manager || shell&.instance_variable_get(:@lsp_manager)
        lsp_xml = build_lsp_xml(effective_lsp)
        sections << lsp_xml unless lsp_xml.empty?

        if context_limit && context_limit.to_i.positive?
          sections << "<context_budget limit=\"#{context_limit.to_i}\" unit=\"tokens\" />"
        end

        commands_xml = build_commands_xml(commands || shell)
        sections << commands_xml unless commands_xml.empty?

        if extra_context && !extra_context.strip.empty?
          sections << "<extra_context>\n#{extra_context.strip}\n</extra_context>"
        end

        <<~XML.strip
          <system_context>
          #{sections.join("\n\n")}
          </system_context>
        XML
      end

      def self.build_system_prompt(mode: :default, tool_schemas: [], shell: nil, config: nil, commands: nil, buffer_manager: nil, snapshot_store: nil, context_index: nil, lsp_manager: nil, context_limit: nil, root_dir: Dir.pwd, extra_context: "")
        # Deprecation note: `shell:` is kept for backward compatibility but
        # callers should pass `config:` and `commands:` directly. We will
        # remove the `shell:` keyword in a future major version.
        xml_context = build_system_context(
          shell: shell,
          config: config,
          commands: commands,
          buffer_manager: buffer_manager,
          snapshot_store: snapshot_store,
          context_index: context_index,
          lsp_manager: lsp_manager,
          context_limit: context_limit,
          root_dir: root_dir,
          extra_context: extra_context
        )

        role_header = case mode.to_sym
        when :plan
          <<~HDR
            You are Rubik, a helpful AI coding assistant in PLAN-ONLY mode.
            Analyze the user's task within <user_task> and output a concise, numbered step-by-step implementation plan.
            Do NOT call write tools or execute commands yet. Specify what files will be created or edited.
          HDR
        when :goal
          <<~HDR
            You are Rubik, a helpful autonomous AI coding assistant in AUTONOMOUS GOAL mode.
            Fulfill the goal within <user_task>:
            1. Formulate a sub-task strategy.
            2. Use `list_files`, `grep_search`, `search_symbols`, `read_file` to understand the codebase.
            3. Use `write_file` to prepare changes in the in-memory buffer.
            4. Use `run_tests` to verify your changes.
            5. If tests fail, inspect diagnostics and fix your code until all tests pass.
            6. Call `finish` only when the goal is verified and complete.
          HDR
        else
          <<~HDR
            You are Rubik, a helpful AI pair programming assistant.
            You help the user explore, edit, test, and maintain codebases using tools and commands.
          HDR
        end

        tool_section = if tool_schemas && !tool_schemas.empty?
          <<~TLS

            You can call tools by outputting a JSON block:
            ```json
            { "tool": "tool_name", "args": { ... } }
            ```
            Available tools:
            #{JSON.dump(tool_schemas)}
          TLS
        else
          ""
        end

        <<~PROMPT.strip
          #{role_header.strip}
          #{tool_section}

          #{xml_context}
        PROMPT
      end

      def self.format_user_task(prompt)
        <<~XML.strip
          <user_task>
          #{prompt.to_s.strip}
          </user_task>
        XML
      end

      private

      def self.detect_git_branch(root_dir)
        git_dir = File.join(root_dir, ".git")
        return nil unless File.directory?(git_dir)

        head_file = File.join(git_dir, "HEAD")
        return nil unless File.exist?(head_file)

        content = File.read(head_file).strip
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

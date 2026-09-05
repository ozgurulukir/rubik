# frozen_string_literal: true

require "json"
require_relative "../platform"
require_relative "../sandbox/shell_resolver"
require_relative "../context/repo_context_reader"

module Rubik
  module Prompt
    class ContextBuilder
      def self.find_protocol_files(root_dir = Dir.pwd)
        Rubik::Context::RepoContextReader.new(root_dir: root_dir).find_protocol_files
      end

      def self.build_protocol_xml(root_dir = Dir.pwd)
        Rubik::Context::RepoContextReader.new(root_dir: root_dir).read_protocol_xml
      end

      def self.build_workspace_xml(context_index = nil, root_dir = Dir.pwd)
        proj_name = File.basename(root_dir)
        git_branch = detect_git_branch(root_dir) || "no-git"

        summary = context_index&.status_summary || { file_count: 0, languages: [] }
        file_count = summary[:file_count] || 0
        langs = (summary[:languages] || []).join(", ")
        langs_str = langs.empty? ? "none detected" : langs

        files_hash = context_index&.files || {}

        structure_xml = if file_count.positive? && file_count <= 30
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
                            ["Gemfile", "package.json", "Cargo.toml", "go.mod", "Makefile", "pyproject.toml", "Rakefile", "index.html",
                             "README.md"].include?(File.basename(f)) ||
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
        conflicts = if buffer_manager.respond_to?(:last_conflicts)
                      Array(buffer_manager.last_conflicts)
                    else
                      []
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
        conflict_section = if conflicts.any?
                             tags = conflicts.map { |c| "    <conflict path=\"#{c}\" reason=\"externally modified on disk\" />" }.join("\n")
                             "\n  <conflicts count=\"#{conflicts.size}\">\n#{tags}\n  </conflicts>"
                           else
                             ""
                           end
        notice = if conflicts.any?
                   "\n    <notice>⚠️ Conflict: #{conflicts.size} file(s) had external disk modifications during apply. " \
                     "Use 'read_file(path: ..., reload: true)' to inspect latest disk content.</notice>"
                 elsif dirty
                   "\n    <notice>⚠️ Notice: #{dirty_list.size} unapplied buffer changes in memory. " \
                     "External shell and test tools run against disk. Use 'apply_buffer' or '!apply' to sync.</notice>"
                 else
                   ""
                 end

        <<~XML.strip
          <buffer_status dirty="#{dirty}" auto_apply="#{auto_apply}">
            <dirty_files count="#{dirty_list.size}">#{dirty_section}</dirty_files>
            <snapshot_count>#{snap_count}</snapshot_count>#{conflict_section}#{notice}
          </buffer_status>
        XML
      end

      def self.build_operational_rules_xml
        <<~XML.strip
          <operational_rules>
            1. Code Exploration & Review: Use native tools directly (`list_files`, `grep_search`, `search_symbols`, `get_outline`, `read_file`, `find_references`). If neither a tool nor a listed command matches your need, inspect the codebase structurally: examine the directory layout (`list_files`), search for patterns (`grep_search`), read core modules (`get_outline`, `read_file`), and look for TODO/FIXME markers. For conceptual queries (e.g. "code review", "code quality"), do NOT search for the literal words "refactor" or "review"; evaluate the architecture structurally.
            2. Code Editing & Targeted Changes: For modifying existing files, prefer `replace_file_content` with exact verbatim `target_content` and `replacement_content` (and optional `start_line`/`end_line` to narrow the range). For creating new files or completely rewriting small files, use `write_file`. All edits stage safely into the in-memory buffer. If `apply_buffer` reports `[CONFLICT]` due to external modifications, inspect latest disk changes with `read_file(path: "...", reload: true)` before reconciling.
            3. Testing & Execution: Use native tools `run_tests` and `run_command` directly. Do NOT wrap them in `exec_repl_command`. Commands in `run_command` run directly in the project working directory (`<working_directory>`); do NOT prepend `cd` commands or guess non-existent paths (e.g. `/home/ubuntu`). Always fulfill the user's primary requested action (e.g. merge, build, test, commit) to completion.
            4. REPL Bang Commands: `exec_repl_command` runs only the session-safe commands listed in <agent_commands> — runtime configuration, context and step-budget self-management, buffer review and rollback, runtime introspection, and code validation. If that section is absent, do not invoke REPL commands. File, code, test, and shell operations always use direct tools (`read_file`, `replace_file_content`, `write_file`, `run_tests`, `run_command`). Buffer-review commands (`!diff`, `!undo`, `!rollback`) operate on the in-memory staging buffer (unapplied edits) — they are a preview layer, not file ground truth: verify file content with `read_file` and git history with `run_command`.
            5. Autonomous Tool Synthesis: When you need a specialized capability not available in the built-in toolbelt (such as custom AST transformers, data converters, or domain-specific benchmarkers), dynamically create and register your own tool at runtime using `synthesize_tool(name: '...', description: '...', code: '->(args) { ... }')`.
          </operational_rules>
        XML
      end

      def self.build_commands_xml(shell_or_commands = nil)
        commands = if shell_or_commands.is_a?(Hash)
                     shell_or_commands
                   elsif shell_or_commands.respond_to?(:commands)
                     shell_or_commands.commands
                   else
                     {}
                   end

        return "" if commands.empty?

        sections = []
        agent_xml = build_agent_commands_xml(commands)
        sections << agent_xml unless agent_xml.empty?
        custom_xml = build_custom_commands_xml(commands)
        sections << custom_xml unless custom_xml.empty?

        return "" if sections.empty?

        sections.join("\n")
      end

      # Built-in commands published to the agent (audience contract, Plan 53).
      def self.build_agent_commands_xml(commands)
        agent_names = commands.select do |_name, meta|
          meta.is_a?(Hash) && !meta[:custom] && [:agent, :both].include?(meta[:audience])
        end.keys.sort
        return "" if agent_names.empty?

        name_list = agent_names.map { |n| "!#{n}" }.join(", ")
        "<agent_commands via=\"exec_repl_command\">#{name_list}</agent_commands>"
      end

      def self.build_custom_commands_xml(commands)
        custom = commands.select { |_k, v| v.is_a?(Hash) && v[:custom] }
        return "" if custom.empty?

        cmd_tags = custom.sort.map do |name, meta|
          desc = (meta.is_a?(Hash) ? meta[:description] : meta) || ""
          "  <command name=\"!#{name}\">#{desc}</command>"
        end.join("\n")
        "<custom_commands>\n#{cmd_tags}\n</custom_commands>"
      end

      def self.build_lsp_xml(lsp_manager = nil)
        return "" unless lsp_manager&.enabled?

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

      def self.build_system_context(shell: nil, config: nil, commands: nil, buffer_manager: nil, snapshot_store: nil, context_index: nil, lsp_manager: nil,
                                    context_limit: nil, root_dir: Dir.pwd, extra_context: "")
        sections = []

        rules_xml = build_operational_rules_xml
        sections << rules_xml unless rules_xml.empty?

        # Machine-readable shell facts (Plan 55 D-6), generated from the same
        # ShellResolver the sandbox driver spawns through.
        sections << Rubik::Sandbox::ShellResolver.environment_line((config || shell&.config)&.fetch("sandbox.shell", "auto") || "auto")

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

        sections << "<context_budget limit=\"#{context_limit.to_i}\" unit=\"tokens\" />" if context_limit&.to_i&.positive?

        commands_xml = build_commands_xml(commands || shell)
        sections << commands_xml unless commands_xml.empty?

        sections << "<extra_context>\n#{extra_context.strip}\n</extra_context>" if extra_context && !extra_context.strip.empty?

        <<~XML.strip
          <system_context>
          #{sections.join("\n\n")}
          </system_context>
        XML
      end

      def self.build_system_prompt(mode: :default, tool_schemas: [], shell: nil, config: nil, commands: nil, buffer_manager: nil, snapshot_store: nil,
                                   context_index: nil, lsp_manager: nil, context_limit: nil, root_dir: Dir.pwd, extra_context: "")
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
                          Do NOT call apply_buffer, write_file, replace_file_content, run_tests, or run_command yet. Proposed changes may sit in the buffer — do not apply them. Specify what files will be created or edited.
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
                           #{Rubik::Platform.safe_json_dump(tool_schemas)}
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

      def self.detect_git_branch(root_dir)
        Rubik::Context::RepoContextReader.new(root_dir: root_dir).read_git_branch
      rescue StandardError
        nil
      end
    end
  end
end

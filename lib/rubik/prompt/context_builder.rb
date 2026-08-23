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

        <<~XML.strip
          <workspace_status>
            <project_name>#{proj_name}</project_name>
            <git_branch>#{git_branch}</git_branch>
            <indexed_files count="#{file_count}">#{langs_str}</indexed_files>
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

      def self.build_commands_xml(shell_or_commands = nil)
        commands = if shell_or_commands.is_a?(Hash)
                     shell_or_commands
                   elsif shell_or_commands.respond_to?(:commands)
                     shell_or_commands.commands
                   else
                     {}
                   end

        return "" if commands.empty?

        cmd_tags = commands.sort.map do |name, meta|
          desc = meta[:description] || ""
          "  <command name=\"!#{name}\">#{desc}</command>"
        end.join("\n")

        <<~XML.strip
          <repl_commands>
          #{cmd_tags}
          </repl_commands>
        XML
      end

      def self.build_system_context(shell: nil, buffer_manager: nil, snapshot_store: nil, context_index: nil, root_dir: Dir.pwd, extra_context: "")
        sections = []

        protocol_xml = build_protocol_xml(root_dir)
        sections << protocol_xml unless protocol_xml.empty?

        workspace_xml = build_workspace_xml(context_index, root_dir)
        sections << workspace_xml unless workspace_xml.empty?

        auto_apply_mode = shell&.config&.fetch("buffer.auto_apply", "manual") || "manual"
        buffer_xml = build_buffer_xml(buffer_manager, snapshot_store, auto_apply: auto_apply_mode)
        sections << buffer_xml unless buffer_xml.empty?

        commands_xml = build_commands_xml(shell)
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

      def self.build_system_prompt(mode: :default, tool_schemas: [], shell: nil, buffer_manager: nil, snapshot_store: nil, context_index: nil, root_dir: Dir.pwd, extra_context: "")
        xml_context = build_system_context(
          shell: shell,
          buffer_manager: buffer_manager,
          snapshot_store: snapshot_store,
          context_index: context_index,
          root_dir: root_dir,
          extra_context: extra_context
        )

        role_header = case mode.to_sym
        when :plan
          <<~HDR
            You are Rubik AI Coding Agent in PLAN-ONLY mode.
            Analyze the user's task within <user_task> and output a concise, numbered step-by-step implementation plan.
            Do NOT call write tools or execute commands yet. Specify what files will be created or edited.
          HDR
        when :goal
          <<~HDR
            You are Rubik AI Coding Agent in AUTONOMOUS GOAL mode.
            You must independently fulfill the goal within <user_task>:
            1. Formulate a sub-task strategy.
            2. Use `list_files`, `search_symbols`, `read_file` to understand the codebase.
            3. Use `write_file` to prepare changes in the in-memory buffer.
            4. Use `run_tests` to verify your changes.
            5. If tests fail, inspect diagnostics and fix your code until all tests pass.
            6. Call `finish` only when the goal is verified and complete.
          HDR
        else
          <<~HDR
            You are Rubik AI Coding Agent, an autonomous pair programmer with Spatiotemporal Composability & Self-Evolving runtime.
            You interact with the codebase through tools and REPL commands.
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

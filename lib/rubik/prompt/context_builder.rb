# frozen_string_literal: true

require_relative "../platform"
require_relative "../sandbox/shell_resolver"
require_relative "../context/repo_context_reader"
# All doctrine prose (rules, headers, guidance) lives in Prompt::Doctrine;
# this module is the assembler: structure + service data only.
require_relative "doctrine"
require_relative "services"

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
        esc = Rubik::Platform.method(:xml_escape)
        proj_name = File.basename(root_dir)
        git_branch = detect_git_branch(root_dir) || "no-git"

        summary = context_index&.status_summary || { file_count: 0, languages: [] }
        file_count = summary[:file_count] || 0
        langs = (summary[:languages] || []).join(", ")
        langs_str = langs.empty? ? "none detected" : langs

        files_hash = context_index&.files || {}

        structure_xml = if file_count.positive? && file_count <= 30
                          file_tags = files_hash.map do |path, info|
                            lang_attr = info[:language] ? " lang=\"#{esc.call(info[:language])}\"" : ""
                            "    <file#{lang_attr}>#{esc.call(path)}</file>"
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

                          dirs_str = top_dirs.empty? ? "root" : top_dirs.map { |d| "#{esc.call(d)}/" }.join(", ")
                          entries_str = entry_points.empty? ? "none" : entry_points.map { |e| esc.call(e) }.join(", ")

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
            <project_name>#{esc.call(proj_name)}</project_name>
            <working_directory>#{esc.call(root_dir)}</working_directory>
            <git_branch>#{esc.call(git_branch)}</git_branch>
            <languages>#{esc.call(langs_str)}</languages>
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

        dirty_tags = dirty_list.map { |f| "    <file>#{Rubik::Platform.xml_escape(f)}</file>" }.join("\n")
        dirty_section = dirty_list.empty? ? "" : "\n#{dirty_tags}\n  "
        conflict_section = if conflicts.any?
                             tags = conflicts.map do |c|
                               "    <conflict path=\"#{Rubik::Platform.xml_escape(c)}\" reason=\"externally modified on disk\" />"
                             end.join("\n")
                             "\n  <conflicts count=\"#{conflicts.size}\">\n#{tags}\n  </conflicts>"
                           else
                             ""
                           end
        notice = if conflicts.any?
                   "\n    <notice>⚠️ Conflict: #{conflicts.size} file(s) had external disk modifications during apply. " \
                     "Use 'read_file(path: ..., reload: true)' to inspect latest disk content.</notice>"
                 elsif dirty
                   "\n    <notice>⚠️ Notice: #{dirty_list.size} unapplied buffer changes in memory. " \
                     "External shell and test tools run against disk. Use 'apply_buffer' to sync.</notice>"
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

      # Level-1 progressive disclosure (agentskills.io): name + description
      # (+ scope) only; the `skill` tool fetches the full SKILL.md on demand.
      def self.build_skills_xml(skills_index = nil)
        return "" if skills_index.nil? || skills_index.empty?

        esc = Rubik::Platform.method(:xml_escape)
        tags = skills_index.sort_by { |s| s[:name].to_s }.map do |s|
          "  <skill name=\"#{esc.call(s[:name])}\" scope=\"#{esc.call(s[:scope].to_s)}\">#{esc.call(s[:description])}</skill>"
        end.join("\n")
        <<~XML.strip
          <skills count="#{skills_index.size}">
          #{Doctrine.skills_preamble}
          #{tags}
          </skills>
        XML
      end

      def self.build_subagents_xml(type_registry = nil)
        return "" if type_registry.nil?

        types = if type_registry.respond_to?(:list)
                  type_registry.list
                elsif type_registry.is_a?(Array)
                  type_registry
                else
                  []
                end
        return "" if types.empty?

        esc = Rubik::Platform.method(:xml_escape)
        tags = types.map do |t|
          name = esc.call(t.name.to_s)
          tools_mode = if t.name.to_s == "self"
                         "full_clone"
                       elsif t.enable_write_tools
                         "read_write_test"
                       else
                         "read_only"
                       end
          workspace = t.name.to_s == "coder" ? "branch" : "inherit"
          desc = esc.call(t.description.to_s)
          "  <subagent name=\"#{name}\" tools=\"#{tools_mode}\" default_workspace=\"#{workspace}\">#{desc}</subagent>"
        end.join("\n")

        guidance = Doctrine.orchestration_guidance_bullets.map { |bullet| "    • #{bullet}" }.join("\n")

        <<~XML.strip
          <subagents count="#{types.size}">
          Available archetypes for `invoke_subagent`:
          #{tags}
            <orchestration_guidance>
          #{guidance}
            </orchestration_guidance>
          </subagents>
        XML
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
            msg = Rubik::Platform.xml_escape(d["message"])
            diag_tags << "    <diagnostic file=\"#{Rubik::Platform.xml_escape(fpath)}\" line=\"#{start_line}\" severity=\"#{sev}\">#{msg}</diagnostic>"
          end
        end

        if active_servers.empty?
          # Session review B2: "clean=true" with zero connected servers read
          # as "all good" while every LSP tool was dead for the session's
          # language. Name the no-server state explicitly instead.
          <<~XML.strip
            <lsp_status enabled="true" active_servers="" state="no_servers" />
            LSP is enabled but NO language server is connected (no server
            registered for this project's languages, or all failed to start).
            lsp_diagnostics/lsp_hover will return nothing — use run_command or
            read tools instead.
          XML
        elsif diag_tags.empty?
          <<~XML.strip
            <lsp_status enabled="true" active_servers="#{Rubik::Platform.xml_escape(active_servers.join(', '))}" clean="true" />
          XML
        else
          <<~XML.strip
            <lsp_diagnostics active_servers="#{Rubik::Platform.xml_escape(active_servers.join(', '))}" total_issues="#{diag_tags.size}" errors="#{total_errors}">
            #{diag_tags.join("\n")}
            </lsp_diagnostics>
          XML
        end
      end

      # `services:` is the only input: a frozen Prompt::Services view built
      # at the composition boundary (Shell integration happens once, in
      # Services.from_shell — see orchestrator/loop.rb). Defaults live in
      # Prompt::Services; unsatisfied slots degrade to omitted sections.
      def self.build_system_context(services:)
        svc = services
        sections = []

        rules_xml = Doctrine.operational_rules_xml
        sections << rules_xml unless rules_xml.empty?

        # Machine-readable shell facts (Plan 55 D-6), generated from the same
        # ShellResolver the sandbox driver spawns through.
        sections << Rubik::Sandbox::ShellResolver.environment_line(svc.config&.fetch("sandbox.shell", "auto") || "auto")

        protocol_xml = build_protocol_xml(svc.root_dir)
        sections << protocol_xml unless protocol_xml.empty?

        workspace_xml = build_workspace_xml(svc.context_index, svc.root_dir)
        sections << workspace_xml unless workspace_xml.empty?

        auto_apply_mode = svc.config&.fetch("buffer.auto_apply", "manual") || "manual"
        buffer_xml = build_buffer_xml(svc.buffer_manager, svc.snapshot_store, auto_apply: auto_apply_mode)
        sections << buffer_xml unless buffer_xml.empty?

        lsp_xml = build_lsp_xml(svc.lsp_manager)
        sections << lsp_xml unless lsp_xml.empty?

        sections << "<context_budget limit=\"#{svc.context_limit.to_i}\" unit=\"tokens\" />" if svc.context_limit&.to_i&.positive?
        sections << "<output_budget limit=\"#{svc.max_output_tokens.to_i}\" unit=\"tokens\" />" if svc.max_output_tokens&.to_i&.positive?

        commands_xml = build_commands_xml(svc.commands)
        sections << commands_xml unless commands_xml.empty?

        skills_xml = build_skills_xml(svc.skills_index)
        sections << skills_xml unless skills_xml.empty?

        subagents_xml = build_subagents_xml(svc.type_registry)
        sections << subagents_xml unless subagents_xml.empty?

        sections << "<extra_context>\n#{Rubik::Platform.xml_escape(svc.extra_context.to_s.strip)}\n</extra_context>" unless svc.extra_context.to_s.strip.empty?

        <<~XML.strip
          <system_context>
          #{sections.join("\n\n")}
          </system_context>
        XML
      end

      # native_tools: true when the tool schemas are also sent via the
      # provider's native function-calling parameter. In that case the prompt
      # carries only a compact name listing (the full JSON dump would double
      # the token cost every step); the JSON-block convention is documented
      # as a fallback only.
      def self.build_system_prompt(services:, mode: :default, tool_schemas: [], native_tools: false)
        # Plan mode is text-only: never publish the toolbelt, regardless of
        # what callers pass. Execution-side gating lives in Orchestrator::Loop.
        tool_schemas = [] if mode.to_sym == :plan

        xml_context = build_system_context(services: services)

        role_header = Doctrine.role_header(mode)

        tool_section = if tool_schemas.nil? || tool_schemas.empty?
                         ""
                       elsif native_tools
                         names = tool_schemas.map { |t| t[:name] || t["name"] }.compact.join(", ")
                         Doctrine.native_tools_note(names)
                       else
                         Doctrine.json_tools_note(tool_schemas)
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
          #{Rubik::Platform.xml_escape(prompt.to_s.strip)}
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

# frozen_string_literal: true

require "json"
require_relative "../platform"
require_relative "../sandbox/shell_resolver"
require_relative "../context/repo_context_reader"
# Vocabulary leaf ONLY, never the orchestrator barrel: orchestrator sits
# above the prompt layer; this pure platform-only module renders the
# manage_subagents snippets the rules below teach. Do not widen this edge.
require_relative "../orchestrator/subagent/notices"

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

      def self.build_operational_rules_xml
        # Maestro doktrini (kullanıcı kararı 2026-10-01): init-0 HER modda
        # orkestratör. Devir caveat'i kural 2-3'ün BAŞINA yazılır — sondaki
        # ek caveat zayıf modellerde atlanıyordu (opencode-personal bulgusu);
        # doktrin kendi promptunun içinde çelişmemeli.
        <<~XML.strip
          <operational_rules>
            1. Code Exploration & Review (read-only: shape subagent assignments and answer the user): Use native tools directly (`list_files`, `grep_search`, `search_symbols`, `get_outline`, `read_file`, `find_references`). If neither a tool nor a listed command matches your need, inspect the codebase structurally: examine the directory layout (`list_files`), search for patterns (`grep_search`), read core modules (`get_outline`, `read_file`), and look for TODO/FIXME markers. For conceptual queries (e.g. "code review", "code quality"), do NOT search for the literal words "refactor" or "review"; evaluate the architecture structurally.
            2. Code Editing & Targeted Changes: MAESTRO OVERRIDE — this rule is delegated wholesale: route ALL edits through 'coder' subagents and never stage edits in your own context (the runtime refuses direct edit tools). The mechanics below are what your coder subagents use. For modifying existing files, prefer `replace_file_content` with exact verbatim `target_content` (or `old_content`) and `replacement_content` (or `new_content`). For creating new files or completely rewriting files, use `write_file`. All edits stage safely into the in-memory buffer. Call `apply_buffer` to persist buffer edits to disk. If `apply_buffer` reports `[CONFLICT]` due to external modifications (e.g. from code formatters or external processes), inspect latest disk changes with `read_file(path: "...", reload: true)` or overwrite deliberately with `apply_buffer(force: true)`.
            3. Testing & Execution: MAESTRO OVERRIDE — this rule is delegated wholesale: subagents run tests and commands; you read their reports and never execute them yourself (the runtime refuses direct run tools). The mechanics below are what your coder subagents use. Use native tools `run_tests` and `run_command` directly. Do NOT wrap them in `exec_repl_command`. Commands in `run_command` run directly in the project working directory (`<working_directory>`); do NOT prepend `cd` commands or guess non-existent paths (e.g. `/home/ubuntu`). Always fulfill the user's primary requested action (e.g. merge, build, test, commit) to completion.
            4. REPL Bang Commands: `exec_repl_command` runs only the session-safe commands listed in <agent_commands> — runtime configuration, context and step-budget self-management, buffer review and rollback, runtime introspection, and code validation. If that section is absent, do not invoke REPL commands. File, code, test, and shell operations always use direct tools (`read_file`, `replace_file_content`, `write_file`, `run_tests`, `run_command`). Buffer-review commands (`!diff`, `!undo`, `!rollback`) operate on the in-memory staging buffer (unapplied edits) — they are a preview layer, not file ground truth: verify file content with `read_file` and git history with `run_command`.
            5. Autonomous Tool Synthesis: When you need a specialized capability not available in the built-in toolbelt (such as custom AST transformers, data converters, or domain-specific benchmarkers), dynamically create and register your own tool at runtime using `synthesize_tool(name: '...', description: '...', code: '->(args) { ... }')`.
            6. Output Budget & Conciseness: Respect your output token budget (`<output_budget>`). Produce direct, high-signal responses and avoid unnecessary pleasantries, verbose conversational preambles, or duplicated context blocks that waste generation quota.
            7. Subagent Delegation & Parallelism (Maestro): As init-0 you orchestrate — ALL execution work (exploration, code changes, verification) is delegated via `invoke_subagent`, in every mode. Match task to archetype: use 'research' for read-only codebase exploration; MUST use 'coder' for code modifications, refactoring, and test execution ('research' has no write or test tools). Subagents execute asynchronously in disposable sub-contexts in the background. After dispatching subagents, do NOT block with 'wait' unless you strictly depend on their output in the current turn — conclude your turn and liberate the prompt so the user can interact concurrently. Completion, budget-pause, error, and message notifications arrive reactively: during your turn via your notification inbox; while you are idle, the runtime automatically wakes you with a dedicated notification-evaluation turn — evaluate the pending notifications, act (extend budget, steer with send_message, retrieve results, wrap up, or report to the user), and conclude your turn again. Subagents can ask YOU questions mid-flight via `ask_question` — a question notification means that subagent is BLOCKED until you reply: answer it promptly with `send_message(recipient: '<id>', message: '<your answer>')` (it times out otherwise). Call `#{Rubik::Orchestrator::Subagent::Notices.wait_hint_template}` only when synchronous waiting is strictly required. Never poll 'status' repeatedly in a loop.
            8. Runtime Introspection, Self-Healing & Human Feedback: If internal errors or service degradation occur, inspect runtime state with `inspect_runtime` and repair failed services via `repair_runtime_service`. When critical requirements are underspecified or high-impact architectural choices require user confirmation, use `ask_question` with structured multiple-choice options.
          9. Central Storage & Clean Worktree: Persist agent workfiles — goals, plans, memory notes, wiki knowledge, reviews — in the central `storage` database (`storage` tool: put/get/list/search/set_ref/delete), NOT as scattered files in the repository worktree. Read entities back with `read_file(path: 'rubik://storage/<type>/<id>')`; browse with `rubik://storage/index` and `rubik://storage/<type>` listings. Subagent transcripts are indexed automatically as `transcript` entities (alias `subagent-<storage-id>`).
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
          The skills below bundle specialized instructions. When a task matches one, invoke the `skill` tool with its name to load its full SKILL.md instructions first; files it references (scripts/, references/, assets/) are read with read_file relative to its directory.
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

        <<~XML.strip
          <subagents count="#{types.size}">
          Available archetypes for `invoke_subagent`:
          #{tags}
            <orchestration_guidance>
              • Archetype selection: Use 'research' for read-only exploration; MUST use 'coder' for code changes/bug fixes (read-only agents cannot modify files or run tests).
              • Asynchronous execution: Subagents run concurrently in the background. Conclude your turn to liberate the prompt for the user — completion, pause, error, and message notices arrive reactively in your inbox and automatically wake you with a notification-evaluation turn while you are idle. Call `#{Rubik::Orchestrator::Subagent::Notices.wait_hint_template}` only if you have an immediate blocking dependency within the current turn. Do NOT poll 'status' in a loop.
              • Workspace isolation: 'inherit' shares project workspace directly; 'branch' isolates edits in a virtual buffer merged atomically upon completion.
              • Budget escalation: A subagent paused at its step budget (WAITING_BUDGET) is NOT terminal: `#{Rubik::Orchestrator::Subagent::Notices.extend_budget_hint('[...]')}` resumes it with context intact. Extend BEFORE absorbing the task yourself; re-spawn only if its transcript shows the objective changed.
              • Context reuse: A finished (completed/failed) subagent not yet reaped holds its accumulated context — hand it a follow-up with `manage_subagents(action: 'redeploy', conversation_id: '<id>', prompt: '<new task>')` instead of re-spawning and re-explaining. A reaped (archived) subagent cannot be redeployed: spawn a fresh one.
              • Staged dispatch (dependencies): A spec may declare `depends_on` — an array of predecessor ids (strings ⇒ FS: launches when the predecessor completes) or `{'id': ..., 'type': 'SS'}` (launches when it starts). Queued specs hold no slot and cost nothing; `list`/`status` show them as QUEUED with their unmet deps, and `wait` accepts queued ids (blocks until the whole chain settles). A failed/killed predecessor CANCELS its dependents — re-dispatch with the new information; a budget-paused predecessor keeps them queued — extend it instead.
              • Diligent cleanup: Finished subagents are reaped automatically after a grace period (`subagents.reap_finished_after`) — in-memory context is reclaimed while the durable transcript stays readable at its transcript URI and in `rubik://storage` search. `manage_subagents(action: 'reap')` reaps finished subagents immediately.
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

        if diag_tags.empty?
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

      def self.build_system_context(shell: nil, config: nil, commands: nil, buffer_manager: nil, snapshot_store: nil, context_index: nil, lsp_manager: nil,
                                    context_limit: nil, max_output_tokens: nil, root_dir: Dir.pwd, extra_context: "", skills_index: nil, type_registry: nil)
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
        sections << "<output_budget limit=\"#{max_output_tokens.to_i}\" unit=\"tokens\" />" if max_output_tokens&.to_i&.positive?

        commands_xml = build_commands_xml(commands || shell)
        sections << commands_xml unless commands_xml.empty?

        skills_xml = build_skills_xml(skills_index)
        sections << skills_xml unless skills_xml.empty?

        supervisor = (shell.respond_to?(:subagent_supervisor) ? shell.subagent_supervisor : nil) || shell&.instance_variable_get(:@subagent_supervisor)
        effective_types = type_registry || supervisor&.type_registry
        subagents_xml = build_subagents_xml(effective_types)
        sections << subagents_xml unless subagents_xml.empty?

        sections << "<extra_context>\n#{Rubik::Platform.xml_escape(extra_context.strip)}\n</extra_context>" if extra_context && !extra_context.strip.empty?

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
      def self.build_system_prompt(mode: :default, tool_schemas: [], shell: nil, config: nil, commands: nil, buffer_manager: nil, snapshot_store: nil,
                                   context_index: nil, lsp_manager: nil, context_limit: nil, max_output_tokens: nil, root_dir: Dir.pwd,
                                   extra_context: "", native_tools: false, skills_index: nil, type_registry: nil)
        # Plan mode is text-only: never publish the toolbelt, regardless of
        # what callers pass. Execution-side gating lives in Orchestrator::Loop.
        tool_schemas = [] if mode.to_sym == :plan

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
          max_output_tokens: max_output_tokens,
          root_dir: root_dir,
          extra_context: extra_context,
          skills_index: skills_index,
          type_registry: type_registry
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
                          You are Rubik (init-0), an autonomous AI coding SUPERVISOR (maestro) in AUTONOMOUS GOAL mode.
                          You own the goal in <user_task> and MUST drive it to verified completion as a pure orchestrator — you conduct, subagents perform. All research, code changes, and verification run in subagent contexts, never in yours:
                          1. Decompose the goal into staged subagent work: at minimum a plan/research stage, a build stage, a review/audit stage whose findings feed a fix stage, and a final verification stage. You decide the exact stages. Declare cross-stage ordering IN THE SAME dispatch with `depends_on` (FS default: the successor launches automatically once the predecessor completes; SS: once it starts) — never fire a stage in parallel with its own predecessors.
                          2. Dispatch every stage with `invoke_subagent`. You MAY explore read-only yourself (`list_files`, `grep_search`, `read_file`) to shape assignments, but ALL code changes and test runs belong to subagents — MUST use the 'coder' archetype for any file modification ('research' is read-only).
                          3. Keep YOUR context lean and managerial: no code drafts, no test output, no full-file reads in your own context — consume stage reports, `rubik://storage/...` summaries, and notification digests instead. Answer subagent `ask_question` prompts promptly.
                          4. Work the notifications, never a poll loop: conclude your turn, react to completion/pause/error notices, extend a budget-paused subagent (`manage_subagents` action: 'extend_budget') instead of absorbing its task yourself.
                          5. Close every stage through verification: read subagent reports, integrate verified results, and run final verification as a subagent stage — a 'coder' mandated to `run_tests` whose green/red report you read. Iterate the review→fix stages until the verifier reports green.
                          6. Live goal snapshot (status, step budget, extensions): read it with `read_file(path: 'rubik://goal/state')`.
                          7. Persist pipeline knowledge in the central storage (`storage` tool): the decomposed plan, per-stage memory notes, review findings, and the final goal record — link stages with entity ids (`links: {"goal": "goal.N.<hash16>"}`) so the audit trail survives the session. Keep the repository worktree free of agent workfiles. Transcripts of finished subagents are indexed automatically (searchable via `storage` action 'search') and persist after the subagent is reaped.
                          8. Call `finish` only when the goal is verified and complete, summarizing what each stage produced.
                        HDR
                      else
                        <<~HDR
                          You are Rubik (init-0), a maestro coding orchestrator for the human operator.
                          You ALWAYS work through subagents: research, code changes, and verification run in subagent contexts via `invoke_subagent` (MUST use the 'coder' archetype for any file modification — 'research' is read-only), never in your own context.
                          Keep your own context lean and managerial: you MAY explore read-only (`list_files`, `grep_search`, `read_file`) to understand requests and shape assignments, but no code drafts, no test runs, no full-file dumps — consume subagent reports and `rubik://storage/...` summaries instead.
                          Focus on driving tasks to completion: decompose the user's request into subagent tasks, work the reactive notices (completion, budget pause, error, question), steer with `send_message` / `manage_subagents` ('extend_budget', 'redeploy'), and answer subagent `ask_question` prompts promptly — they block until you reply.
                          Prefer reuse over re-spawning: hand follow-up tasks to a finished subagent with `manage_subagents(action: 'redeploy', conversation_id: '<id>', prompt: '<new task>')` — its accumulated context survives.
                          Small talk, explanations of earlier reports, and questions you can answer from read-only context or subagent findings are yours directly; every unit of execution work belongs to a subagent.
                        HDR
                      end

        tool_section = if tool_schemas.nil? || tool_schemas.empty?
                         ""
                       elsif native_tools
                         names = tool_schemas.map { |t| t[:name] || t["name"] }.compact.join(", ")
                         <<~TLS

                           Tools are available via native function calling (the request's `tools` parameter): invoke them with native tool calls.
                           As a fallback, a JSON block also works:
                           ```json
                           { "tool": "tool_name", "args": { ... } }
                           ```
                           Available tools: #{names}
                         TLS
                       else
                         <<~TLS

                           You can call tools by outputting a JSON block:
                           ```json
                           { "tool": "tool_name", "args": { ... } }
                           ```
                           Available tools:
                           #{Rubik::Platform.safe_json_dump(tool_schemas)}
                         TLS
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

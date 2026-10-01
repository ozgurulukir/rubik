# frozen_string_literal: true

require "monitor"

module Rubik
  module Orchestrator
    module Subagent
      # Registered archetype representing a subagent role profile, baseline
      # system prompt, and capability filtering policies (Plan 94).
      TypeDefinition = Struct.new(
        :name,
        :description,
        :system_prompt,
        :tool_filter,
        :enable_write_tools,
        :enable_subagent_tools,
        keyword_init: true
      )

      # Catalog of built-in and dynamically synthesized subagent archetypes.
      class TypeRegistry
        READ_ONLY_TOOLS = [
          "read_file", "list_files", "grep_search", "search_symbols",
          "get_outline", "find_references", "get_symbol", "lsp_hover",
          "lsp_definition", "lsp_diagnostics", "ask_question"
        ].freeze

        CODER_TOOLS = [
          "read_file", "write_file", "replace_file_content", "apply_buffer", "list_files",
          "grep_search", "run_tests", "lsp_diagnostics", "storage", "ask_question"
        ].freeze

        SUBAGENT_SPAWN_TOOLS = ["invoke_subagent", "define_subagent"].freeze

        # Ekrana-bas sözleşmesi (show_file) yalnız kök StepExecutor'da var:
        # subagent yolu (dispatch_subagent_tool) :user_output kancası
        # taşımadığından bu araç subagent yüzeyinden gizlenir — aksi halde
        # tam gövde sessizce subagent bağlamına girer, kullanıcıya hiçbir
        # şey ulaşmaz (silent-failure incelemesi, storage-show-surface).
        SUBAGENT_HIDDEN_TOOLS = ["show_file"].freeze

        def initialize
          @types = {}
          @monitor = Monitor.new
          register_default_types
        end

        def register(type_def)
          @monitor.synchronize do
            @types[type_def.name.to_s.downcase] = type_def
          end
        end

        def get(name)
          @monitor.synchronize do
            @types[name.to_s.downcase]
          end
        end

        def list
          @monitor.synchronize do
            @types.values.dup
          end
        end

        def define_custom(name:, description:, system_prompt:, enable_write_tools: false, enable_subagent_tools: false)
          clean_name = name.to_s.downcase.strip
          raise ArgumentError, "Subagent type name cannot be empty" if clean_name.empty?

          filter = lambda do |tool_name|
            return false if SUBAGENT_HIDDEN_TOOLS.include?(tool_name)
            return false if !enable_subagent_tools && SUBAGENT_SPAWN_TOOLS.include?(tool_name)
            return false if !enable_write_tools && ["write_file", "replace_file_content", "apply_buffer", "run_command", "storage"].include?(tool_name)

            true
          end

          type_def = TypeDefinition.new(
            name: clean_name,
            description: description.to_s.strip,
            system_prompt: system_prompt.to_s.strip,
            tool_filter: filter,
            enable_write_tools: enable_write_tools,
            enable_subagent_tools: enable_subagent_tools
          )
          register(type_def)
          type_def
        end

        private

        def register_default_types
          # 1. Research Subagent: Strictly read-only exploration and analysis
          register(TypeDefinition.new(
                     name: "research",
                     description: "Read-only research subagent for exploring codebases, reading files, " \
                                  "searching symbols, and analyzing architecture without mutating state.",
                     system_prompt: "You are a specialized Codebase Research Subagent. Your primary role is to explore, " \
                                    "locate, read, and analyze code accurately and concisely. You have read-only access. " \
                                    "Do not attempt to modify files or run destructive commands. Synthesize clear, " \
                                    "factual reports for your supervisor. Central storage entities (goals, plans, memory, " \
                                    "wiki, transcripts) are readable via read_file 'rubik://storage/...' URIs — start " \
                                    "from 'rubik://storage/index' to discover them. If the task is genuinely ambiguous, " \
                                    "ask init-0 with the ask_question tool — it blocks until answered.",
                     tool_filter: ->(name) { READ_ONLY_TOOLS.include?(name) },
                     enable_write_tools: false,
                     enable_subagent_tools: false
                   ))

          # 2. Self Subagent: Full clone of parent capabilities, with recursion protection
          register(TypeDefinition.new(
                     name: "self",
                     description: "Subagent that inherits the parent agent's full persona, configuration, " \
                                  "and tools (except nested subagent spawning).",
                     system_prompt: nil,
                     tool_filter: ->(name) { !SUBAGENT_SPAWN_TOOLS.include?(name) && !SUBAGENT_HIDDEN_TOOLS.include?(name) },
                     enable_write_tools: true,
                     enable_subagent_tools: false
                   ))

          # 3. Coder Subagent: Focused on file modifications and test verification
          register(TypeDefinition.new(
                     name: "coder",
                     description: "Focused implementation subagent for drafting code edits, persisting buffer, and running tests.",
                     system_prompt: "You are a specialized Coding Subagent. Your role is to implement focused code changes " \
                                    "and verify them with unit tests. Use write_file / replace_file_content to stage edits in buffer, " \
                                    "and call apply_buffer to persist changes to disk before running tests or finishing. " \
                                    "Work cleanly, avoid breaking changes, and report diffs. Persist work notes, findings, " \
                                    "and memory to the central store with the 'storage' tool — never scatter workfiles " \
                                    "into the repository. If a requirement is genuinely ambiguous, ask init-0 with the " \
                                    "ask_question tool — it blocks until answered.",
                     tool_filter: ->(name) { CODER_TOOLS.include?(name) },
                     enable_write_tools: true,
                     enable_subagent_tools: false
                   ))
        end
      end
    end
  end
end

# frozen_string_literal: true

# Domain-grouped home of the 34 built-in agent tools (Plan 54 D-3, Plan 92, Plan 93,
# storage-show-surface 2026-09-30, vakanuvis-chronicler 2026-10-04, context-pruner
# 2026-10-09, following the repl/commands/*.rb loader pattern). This file is only the
# loader; every tool class lives in the file matching its domain (subagent_lifecycle
# holds the action modules consumed by ManageSubagentsTool, not a tool class).

require_relative "uri_resolver"
require_relative "builtins/files"
require_relative "builtins/grep"
require_relative "builtins/symbols"
require_relative "builtins/lsp"
require_relative "builtins/skill"
require_relative "builtins/exec"
require_relative "builtins/task"
require_relative "builtins/synthesis"
require_relative "builtins/unsynthesize"
require_relative "builtins/runtime"
require_relative "builtins/lifecycle"
require_relative "builtins/interactive"
require_relative "builtins/subagent"
require_relative "builtins/send_message"
require_relative "builtins/subagent_lifecycle"
require_relative "builtins/dmesg"
require_relative "builtins/storage"
require_relative "builtins/vakanuvis"
require_relative "builtins/pruner"
require_relative "builtins/show_file"

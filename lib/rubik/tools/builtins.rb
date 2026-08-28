# frozen_string_literal: true

# Domain-grouped home of the 21 built-in agent tools (Plan 54 D-3, following
# the repl/commands/*.rb loader pattern). This file is only the loader; every
# tool class lives in the file matching its domain.

require_relative "builtins/files"
require_relative "builtins/grep"
require_relative "builtins/symbols"
require_relative "builtins/lsp"
require_relative "builtins/exec"
require_relative "builtins/synthesis"
require_relative "builtins/runtime"
require_relative "builtins/lifecycle"

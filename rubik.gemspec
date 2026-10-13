# frozen_string_literal: true

require_relative "lib/rubik/version"

Gem::Specification.new do |spec|
  spec.name          = "rubik"
  spec.version       = Rubik::VERSION
  spec.authors       = ["Özgür Ulukır", "Rubik Team"]
  spec.email         = ["info@rubik.dev"]

  spec.summary       = "Rubik AI Coding Agent CLI"
  spec.description   = "Polyglot AI coding agent with spatiotemporal composability, file buffering, and automated repair."
  spec.homepage      = "https://github.com/ozgurulukir/rubik"
  spec.license       = "MIT"
  # Floor follows the tested surface: the full suite runs on Ruby 4.0 (CI,
  # Windows) and 3.4 was verified on Linux; 3.3 is untested and not claimed.
  spec.required_ruby_version = ">= 3.4.0"

  spec.files         = Dir["lib/**/*.{rb,yaml}", "bin/rubik", "README.md", "LICENSE", "CHANGELOG.md", "ATTRIBUTION.md"]
  spec.bindir        = "bin"
  spec.executables   = ["rubik"]
  spec.require_paths = ["lib"]

  spec.add_dependency "diff-lcs", ">= 1.5", "< 3.0"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "strings-ansi", "~> 0.2"
  spec.add_dependency "tree_sitter_language_pack", "~> 1.16"
  spec.add_dependency "tty-markdown", "~> 0.7"
  spec.add_dependency "tty-prompt", "~> 0.23"
  spec.add_dependency "tty-spinner", "~> 0.9"
  spec.add_dependency "tty-which", "~> 0.2"

  # stdlib gems being unbundled in Ruby 3.4/3.5: pin explicitly so the
  # requires stay green on 3.5+ and stop the "will no longer be part of
  # the default gems" warnings on 3.4.
  spec.add_dependency "benchmark" # lib/rubik/benchmark/runner.rb
  spec.add_dependency "fiddle"    # reline 1.x requires fiddle/import in reline/io/windows.rb on Windows (Ruby 4.0 unbundles fiddle)
  spec.add_dependency "logger"    # lib/rubik/event_bus.rb, plugin/manager.rb, repl/hooks.rb
  spec.add_dependency "pstore"    # lib/rubik/config/store.rb (yaml/store)
  # Reactive-wakeup floor: TerminalGuard#safe_wakeup! injects an Enter through
  # Reline.ungetc, which only reaches a reader already blocked in the gate's
  # getc loop on reline >= 0.7.0 (per-poll ungetc re-check); on 0.6.x the
  # injected Enter strands until the next keystroke. Hard requirement, not an
  # optimization — pinned by test_gemspec_integrity and
  # test/integration/test_reline_wakeup_contract.rb (real gate, PTY).
  spec.add_dependency "reline", ">= 0.7" # lib/rubik/repl/shell.rb, repl/interrupt_handler.rb

  # prism is a bundled gem (Ruby 3.3+): required directly by
  # lib/rubik/ast/ruby_extractor.rb and must be declared so bundlers resolve
  # it explicitly instead of relying on the Ruby installation shipping it.
  spec.add_dependency "prism"

  # source_code_uri doubles as the homepage link; setting homepage_uri to the
  # same value makes RubyGems warn about duplicate uris.
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
end

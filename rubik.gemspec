# frozen_string_literal: true

require_relative "lib/rubik/version"

Gem::Specification.new do |spec|
  spec.name          = "rubik"
  spec.version       = Rubik::VERSION
  spec.authors       = ["Rubik Team"]
  spec.email         = ["info@rubik.dev"]

  spec.summary       = "Rubik AI Coding Agent CLI"
  spec.description   = "Polyglot AI coding agent with spatiotemporal composability, file buffering, and automated repair."
  spec.homepage      = "https://github.com/ozgurulukir/rubik"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.files         = Dir["lib/**/*.rb", "bin/*", "README.md", "LICENSE"]
  spec.bindir        = "bin"
  spec.executables   = ["rubik"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "pastel", "~> 0.8"
  spec.add_runtime_dependency "strings-ansi", "~> 0.2"
  spec.add_runtime_dependency "tty-markdown", "~> 0.7"
  spec.add_runtime_dependency "tty-prompt", "~> 0.23"
  spec.add_runtime_dependency "tty-spinner", "~> 0.9"
  spec.add_runtime_dependency "tty-which", "~> 0.2"
end

# frozen_string_literal: true

require "shellwords"
require_relative "../platform"

module Rubik
  module Runtime
    module Discovery
      LSP_CANDIDATES = {
        "ruby" => [
          "solargraph stdio",
          "ruby-lsp",
          "typeprof --lsp --stdio"
        ],
        "python" => [
          "pyright-langserver --stdio",
          "pylsp",
          "jedi-language-server"
        ],
        "rust" => [
          "rust-analyzer"
        ],
        "go" => [
          "gopls"
        ],
        "zig" => [
          "zls"
        ],
        "c" => [
          "clangd"
        ],
        "cpp" => [
          "clangd"
        ],
        "typescript" => [
          "typescript-language-server --stdio",
          "vtsls --stdio"
        ],
        "javascript" => [
          "typescript-language-server --stdio",
          "vtsls --stdio"
        ],
        "bash" => [
          "bash-language-server start"
        ],
        "crystal" => [
          "crystalline"
        ],
        "gleam" => [
          "gleam lsp"
        ],
        "vue" => [
          "vue-language-server --stdio",
          "@vue/language-server --stdio",
          "vls"
        ]
      }.freeze

      FORMATTER_CANDIDATES = {
        "ruby" => [
          "rubocop -a",
          "standardrb --fix",
          "rufo"
        ],
        "python" => [
          "ruff format",
          "black"
        ],
        "rust" => [
          "rustfmt"
        ],
        "go" => [
          "gofmt -w",
          "goimports -w"
        ],
        "c" => [
          "clang-format -i"
        ],
        "cpp" => [
          "clang-format -i"
        ],
        "zig" => [
          "zig fmt"
        ],
        "typescript" => [
          "prettier --write",
          "biome format --write"
        ],
        "javascript" => [
          "prettier --write",
          "biome format --write"
        ],
        "node" => [
          "prettier --write",
          "biome format --write"
        ],
        "vue" => [
          "prettier --write",
          "biome format --write"
        ],
        "crystal" => [
          "crystal tool format"
        ]
      }.freeze

      TEST_RUNNER_MARKERS = {
        "ruby" => [
          { marker: "Gemfile", candidates: ["bundle exec rspec", "bundle exec rake test", "rake test"] },
          { marker: "Rakefile", candidates: ["bundle exec rake test", "rake test"] }
        ],
        "python" => [
          { marker: "pyproject.toml", candidates: ["pytest", "python3 -m unittest"] },
          { marker: "pytest.ini", candidates: ["pytest"] },
          { marker: "setup.py", candidates: ["pytest", "python3 -m unittest"] },
          { marker: "requirements.txt", candidates: ["pytest", "python3 -m unittest"] }
        ],
        "rust" => [
          { marker: "Cargo.toml", candidates: ["cargo nextest run", "cargo test"] }
        ],
        "go" => [
          { marker: "go.mod", candidates: ["go test ./..."] }
        ],
        "zig" => [
          { marker: "build.zig", candidates: ["zig build test", "zig test"] }
        ],
        "typescript" => [
          { marker: "pnpm-lock.yaml", candidates: ["pnpm test"] },
          { marker: "yarn.lock", candidates: ["yarn test"] },
          { marker: "package-lock.json", candidates: ["npm test"] },
          { marker: "package.json", candidates: ["npm test", "pnpm test", "yarn test"] }
        ],
        "javascript" => [
          { marker: "pnpm-lock.yaml", candidates: ["pnpm test"] },
          { marker: "yarn.lock", candidates: ["yarn test"] },
          { marker: "package-lock.json", candidates: ["npm test"] },
          { marker: "package.json", candidates: ["npm test", "pnpm test", "yarn test"] }
        ],
        "vue" => [
          { marker: "pnpm-lock.yaml", candidates: ["pnpm test"] },
          { marker: "yarn.lock", candidates: ["yarn test"] },
          { marker: "bun.lockb", candidates: ["bun test"] },
          { marker: "package-lock.json", candidates: ["npm test"] },
          { marker: "package.json", candidates: ["npm test", "pnpm test", "yarn test", "bun test"] }
        ],
        "node" => [
          { marker: "pnpm-lock.yaml", candidates: ["pnpm test"] },
          { marker: "yarn.lock", candidates: ["yarn test"] },
          { marker: "bun.lockb", candidates: ["bun test"] },
          { marker: "package-lock.json", candidates: ["npm test"] },
          { marker: "package.json", candidates: ["npm test", "pnpm test", "yarn test", "bun test"] }
        ],
        "c" => [
          { marker: "CMakeLists.txt", candidates: ["ctest", "make test"] },
          { marker: "Makefile", candidates: ["make test", "ctest"] }
        ],
        "crystal" => [
          { marker: "shard.yml", candidates: ["crystal spec"] },
          { marker: "shard.lock", candidates: ["crystal spec"] }
        ]
      }.freeze

      DEFAULT_TEST_RUNNERS = {
        "ruby" => "rake test",
        "python" => "pytest",
        "rust" => "cargo test",
        "go" => "go test ./...",
        "zig" => "zig test",
        "c" => "ctest",
        "crystal" => "crystal spec",
        "typescript" => "npm test",
        "javascript" => "npm test",
        "vue" => "npm test",
        "node" => "npm test"
      }.freeze

      class << self
        def lsp_candidates(lang)
          LSP_CANDIDATES[lang.to_s.downcase] || []
        end

        def binary_available?(cmd, root_dir: nil)
          return false if cmd.nil? || cmd.to_s.strip.empty?

          bin = cmd.to_s.strip.split.first
          if root_dir && bin && (bin.include?("/") || (Rubik::Platform.windows? && bin.include?("\\")))
            full_path = File.expand_path(bin, root_dir)
            return true if Rubik::Platform.executable_file?(full_path)
          end

          !Rubik::Platform.which(cmd).nil?
        end

        def probe_lsp(lang, dir = nil, root_dir: nil, custom_cmd: nil)
          effective_root = root_dir || dir || Dir.pwd
          lang_key = lang.to_s.downcase
          candidates = []
          candidates << custom_cmd.to_s.strip if custom_cmd && !custom_cmd.to_s.strip.empty?
          candidates.concat(lsp_candidates(lang_key))
          candidates.uniq!

          candidates.find { |c| binary_available?(c, root_dir: effective_root) }
        end

        def test_runner_candidates(lang, dir = nil, root_dir: nil, config: nil)
          effective_root = root_dir || dir || Dir.pwd
          lang_key = lang.to_s.downcase
          marker_rules = TEST_RUNNER_MARKERS[lang_key] || []
          matched_candidates = []
          # Ruby-specific: a committed Gemfile.lock pins the gem stack, so any
          # bare (non-bundler) fallback runner must be suppressed — otherwise
          # a default-gem (e.g. minitest 6) silently diverges from the pinned
          # stack. See _plan/test-stratifikasyonu-2026-09-14.md (Package C).
          ruby_lock_pinned = lang_key == "ruby" &&
                             File.exist?(File.join(effective_root, "Gemfile.lock"))

          marker_rules.each do |rule|
            marker_path = File.join(effective_root, rule[:marker])
            next unless File.exist?(marker_path)

            candidates = rule[:candidates]
            if lang_key == "ruby" && rule[:marker] == "Gemfile"
              has_spec_dir = File.directory?(File.join(effective_root, "spec"))
              has_lock = File.exist?(File.join(effective_root, "Gemfile.lock"))
              # A committed lockfile means the operator pinned the gem stack;
              # running bare `rake`/`ruby` would bypass it and can silently
              # load a different (e.g. default-gem) version. With a lockfile
              # only bundler-wrapped commands are offered; without one the
              # historical candidate order is preserved.
              candidates = if has_spec_dir
                             ["bundle exec rspec", "bundle exec rake test", "rake test"]
                           elsif has_lock
                             ["bundle exec rake test"]
                           else
                             ["bundle exec rake test", "rake test", "bundle exec rspec"]
                           end
            end
            matched_candidates.concat(candidates)
          end

          # Add default fallback (suppressed when a ruby lockfile pins bundler)
          default_runner = DEFAULT_TEST_RUNNERS[lang_key]
          if default_runner && !(ruby_lock_pinned && !default_runner.start_with?("bundle exec"))
            matched_candidates << default_runner
          end

          # Prepend explicit test command from config if configured
          cfg_cmd = resolve_config_test_cmd(config, lang_key)
          matched_candidates.unshift(cfg_cmd) if cfg_cmd && !cfg_cmd.empty?

          matched_candidates.uniq
        end

        def discover_test_runners(dir = nil, root_dir: nil, lang: nil, config: nil)
          effective_root = root_dir || (dir.is_a?(String) ? dir : nil) || Dir.pwd
          target_lang = lang ? lang.to_s.downcase : detect_primary_language(effective_root)
          return [] unless target_lang

          candidates = test_runner_candidates(target_lang, root_dir: effective_root, config: config)
          candidates.select { |cmd| binary_available?(cmd, root_dir: effective_root) }
        end

        def discover_formatters(dir = nil, root_dir: nil, lang: nil)
          effective_root = root_dir || (dir.is_a?(String) ? dir : nil) || Dir.pwd
          target_lang = lang ? lang.to_s.downcase : detect_primary_language(effective_root)
          return [] unless target_lang

          candidates = FORMATTER_CANDIDATES[target_lang] || []
          candidates.select { |cmd| binary_available?(cmd, root_dir: effective_root) }
        end

        def detect_primary_language(dir = nil, root_dir: nil)
          effective_root = root_dir || dir || Dir.pwd

          # Check root project marker files
          return "ruby" if File.exist?(File.join(effective_root, "Gemfile")) || File.exist?(File.join(effective_root, "Rakefile"))
          return "rust" if File.exist?(File.join(effective_root, "Cargo.toml"))
          return "go" if File.exist?(File.join(effective_root, "go.mod"))
          return "zig" if File.exist?(File.join(effective_root, "build.zig"))
          return "python" if File.exist?(File.join(effective_root,
                                                   "pyproject.toml")) || File.exist?(File.join(effective_root,
                                                                                               "setup.py")) || File.exist?(File.join(effective_root,
                                                                                                                                     "requirements.txt"))
          return "typescript" if File.exist?(File.join(effective_root, "tsconfig.json"))
          return "javascript" if File.exist?(File.join(effective_root, "package.json"))
          return "c" if File.exist?(File.join(effective_root, "CMakeLists.txt"))

          # Fallback: inspect extensions in directory
          ext_counts = Hash.new(0)
          begin
            Dir.children(effective_root).each do |entry|
              next if entry.start_with?(".")

              full_p = File.join(effective_root, entry)
              if File.file?(full_p)
                ext = File.extname(entry).downcase
                ext_counts[ext] += 1
              end
            end
          rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
            # ignore
          end

          ext_to_lang = {
            ".rb" => "ruby",
            ".rs" => "rust",
            ".go" => "go",
            ".py" => "python",
            ".zig" => "zig",
            ".ts" => "typescript",
            ".js" => "javascript",
            ".vue" => "vue",
            ".c" => "c",
            ".cpp" => "c"
          }

          best_ext = ext_counts.max_by { |_ext, count| count }&.first
          ext_to_lang[best_ext] || "ruby"
        end

        private

        def resolve_config_test_cmd(config, lang_key)
          return nil unless config

          cmd = if config.is_a?(Hash)
                  config["adapter.#{lang_key}.test_command"] ||
                    config["project.test_command"] ||
                    config.dig("adapter", lang_key, "test_command") ||
                    config.dig("adapter", lang_key.to_sym, "test_command") ||
                    config.dig("project", "test_command")
                elsif config.respond_to?(:fetch)
                  begin
                    config.fetch("adapter.#{lang_key}.test_command", nil) ||
                      config.fetch("project.test_command", nil)
                  rescue KeyError, NoMethodError, TypeError
                    nil
                  end
                end
          cmd&.to_s&.strip
        end
      end
    end
  end
end

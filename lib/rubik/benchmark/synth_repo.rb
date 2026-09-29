# frozen_string_literal: true

require "fileutils"

module Rubik
  module Benchmark
    # Deterministic synthetic repository generator for tool-latency and
    # acceptance benchmarks (Plan 52 §8). Default profile is small enough
    # for the test suite; tool_latency.rb uses the 5.000-file profile.
    module SynthRepo
      module_function

      EXTENSIONS = [".rb", ".rb", ".rb", ".ts", ".py", ".rs", ".go"].freeze

      # @return [Integer] number of files written
      def generate(root_dir, count: 200)
        FileUtils.rm_rf(root_dir)
        FileUtils.mkdir_p(root_dir)

        count.times do |idx|
          dir = File.join(root_dir, format("src/mod_%03d", idx % 20))
          FileUtils.mkdir_p(dir)
          ext = EXTENSIONS[idx % EXTENSIONS.size]
          marker = (idx % 50).zero? ? "needle_rare_marker" : "ordinary_#{idx}"
          File.write(File.join(dir, "worker_#{idx}#{ext}"), source(idx, marker))
        end

        File.write(File.join(root_dir, ".gitignore"), "node_modules/\ntmp/\n*.log\n")
        init_git(root_dir)
        count
      end

      # Best-effort `git init` so the GitLister fast path is exercised; a
      # missing git leaves a plain directory (fast path then skips itself).
      def init_git(root_dir)
        system("git", "-C", root_dir, "init", "-q", out: File::NULL, err: File::NULL)
      rescue SystemCallError
        nil
      end

      def source(idx, marker)
        body = (1..30).map { |step| "  step_#{step} = compute(#{step}, payload) # context line" }.join("\n")
        <<~SRC
          # Synthetic module #{idx}
          class Worker#{idx}
            def initialize(payload)
            #{body}
            end

            def process_#{idx}
              result = transform(#{marker})
              result
            end
          end
        SRC
      end
    end
  end
end

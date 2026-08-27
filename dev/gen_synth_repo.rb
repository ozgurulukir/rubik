# frozen_string_literal: true

# Standalone synthetic-repo generator (wraps Rubik::Benchmark::SynthRepo).
# Usage: ruby dev/gen_synth_repo.rb [root_dir] [count]
#   root_dir defaults to <tmpdir>/rubik_synth, count defaults to 5000.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"

root = ARGV[0] || File.join(Dir.tmpdir, "rubik_synth")
count = (ARGV[1] || 5_000).to_i
written = Rubik::Benchmark::SynthRepo.generate(File.expand_path(root), count: count)
puts "generated #{written} files under #{root}"
puts "it is a git repo (best-effort init) so the GitLister fast path is exercised"

# frozen_string_literal: true

# Reproduces the Windows rg stdin trap (Plan 52 §2.4): rg spawned with a
# pipe stdin decides from a heuristic to search STDIN instead of "./" and
# exits with zero results. Run from any git repository:
#
#   ruby dev/debug_rg_stdin_trap.rb [root_dir] [pattern]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "open3"

root = File.expand_path(ARGV[0] || ".")
pattern = ARGV[1] || "def"

puts "root: #{root}"

out, _err, status = Open3.capture3("rg", "-l", pattern, chdir: root)
puts "\n[trap] rg without path arg  : exit=#{status.exitstatus} matches=#{out.lines.size}"
puts "  -> a repo that definitely matches reports zero matches: rg searched STDIN"

out2, _err2, status2 = Open3.capture3("rg", "-l", pattern, ".", chdir: root)
puts "[fix ] rg with explicit '.' : exit=#{status2.exitstatus} matches=#{out2.lines.size}"

_debug_out, debug_err, = Open3.capture3("rg", "--debug", "-l", pattern, ".", chdir: root)
puts "\n rg --debug heuristic lines:"
debug_err.lines.grep(/stdin|heuristic|search/i).first(4).each { |line| puts "  #{line.strip}" }

# frozen_string_literal: true

# Guard classifier matrix probe (dev scaffold): prints PASS/BLOCK + reason
# for a fixed set of commands through Rubik::Security::Guard.
require "./lib/rubik"

guard = Rubik::Security::Guard.new(audit_log_path: nil)
cmds = [
  "bash --version",
  "sh --version",
  "node --version",
  "bash -c \"echo hi\"",
  "rm -rf /",
  "git push",
  "sed -i 's/a/b/' f.txt",
  "perl -i -pe 's/a/b/' f.txt",
  "python3 -c 'print(1)'",
  "python3 script.py"
]
cmds.each do |c|
  begin
    guard.verify_command_safety!(c)
    puts "PASSED : #{c}"
  rescue Rubik::Security::BlockedWriteError => e
    puts "BLOCKED: #{e.message}"
  end
end

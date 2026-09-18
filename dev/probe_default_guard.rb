# frozen_string_literal: true

require "./lib/rubik"

guard = Rubik::Security::Guard.new
begin
  guard.verify_command_safety!("bash --version")
  puts "default-guard probe: PASS"
rescue Rubik::Security::BlockedWriteError => e
  puts "default-guard probe: BLOCKED (#{e.message})"
end

runner = Rubik::Sandbox::Runner.new(root_dir: Dir.pwd)
tool = Rubik::Tools::RunCommandTool.new(guard: guard, runner: runner, root_dir: Dir.pwd)
res = tool.execute("command" => "bash --version")
puts "tool output: #{res.lines.first(3).join}"

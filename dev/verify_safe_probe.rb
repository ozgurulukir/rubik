# frozen_string_literal: true

# Verification scaffold for the safe-probe + message-variants work.
require "./lib/rubik"

# 1) Probe exemption + audit logging
tmp = Dir.mktmpdir("rubik_probe_verify")
audit = File.join(tmp, "audit.log")
guard = Rubik::Security::Guard.new(audit_log_path: audit)
guard.verify_command_safety!("bash --version")
actions = File.readlines(audit).filter_map { |l| (JSON.parse(l)["action"] rescue nil) }
puts "audit after probe: #{actions.inspect}"

# 2) Probe exemption can be disabled
guard2 = Rubik::Security::Guard.new(audit_log_path: nil, allow_safe_probes: false)
begin
  guard2.verify_command_safety!("bash --version")
  puts "disabled: PASSED (unexpected)"
rescue Rubik::Security::BlockedWriteError => e
  puts "disabled: BLOCKED as expected"
end

# 3) Message variants through RunCommandTool
runner = Rubik::Sandbox::Runner.new(root_dir: Dir.pwd)
tool = Rubik::Tools::RunCommandTool.new(guard: guard, runner: runner, root_dir: Dir.pwd)
["python3 -c 'print(1)'", "rm -rf /"].each do |cmd|
  out = tool.execute("command" => cmd)
  puts "--- [#{cmd}]"
  puts out
end

# 4) MISSING_BINARY localization (Windows exit 9009 + Turkish stderr)
diag = Rubik::Runtime::DiagnosticEngine.diagnose(
  cmd: "python3 --version", exit_code: 49,
  stderr: "Python bulunamadı", stdout: ""
)
puts "category: #{diag.category} (expect missing_binary)"
puts diag.format_for_llm

# 5) Allowlist still works (regression)
g3 = Rubik::Security::Guard.new(command_allowlist: ["node .gitnexus/run.cjs"], audit_log_path: nil)
begin
  g3.verify_command_safety!("node .gitnexus/run.cjs impact x --repo .")
  puts "allowlist regression: PASS"
rescue Rubik::Security::BlockedWriteError => e
  puts "allowlist regression: FAIL (#{e.message})"
end

FileUtils.remove_entry(tmp) if File.directory?(tmp)

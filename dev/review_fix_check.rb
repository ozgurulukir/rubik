# frozen_string_literal: true

# Fresh-eye diff review verification (post-fix):
#   1. probe branch beats text-munging for `python3 --version`
#   2. unstructured non-chdir block keeps message, NO dangling "!allow-cmd add"
#   3. chdir-gate block points at !allow-dir
#   4. log_audit nil-safety
require "./lib/rubik"
require "tmpdir"

require "./lib/rubik/tools/builtins/exec"

def guidance_for(err)
  Rubik::Tools::RunCommandTool.blocked_guidance(err)
end

failures = []
check = ->(name, cond) { puts(cond ? "PASS #{name}" : "FAIL #{name}"); failures << name unless cond }

# 1) probe_shape beats text_munging
err = Rubik::Security::BlockedWriteError.new("blocked")
err.blocked_command = "python3 --version"
err.rule_name = "python3"
err.probe_like = true
g1 = guidance_for(err)
check.call("python3 --version gets probe variant", g1.include?("even for version checks"))
check.call("python3 --version does NOT get munging variant", !g1.include?("text-munging"))

# munging still wins for real edits
err_m = Rubik::Security::BlockedWriteError.new("blocked")
err_m.blocked_command = "sed -i 's/a/b/' file.txt"
err_m.rule_name = "sed"
err_m.probe_like = false
check.call("sed -i gets munging variant", guidance_for(err_m).include?("text-munging"))

# 2) unstructured (no attrs) keeps message, no dangling add-line
plain = Rubik::Security::BlockedWriteError.new("Write blocked on critical path: Gemfile.lock")
g2 = guidance_for(plain)
check.call("critical-write keeps message", g2.include?("Write blocked on critical path: Gemfile.lock"))
check.call("no dangling add-line when cmd nil", !g2.include?("!allow-cmd add \n") && !g2.end_with?("!allow-cmd add "))

# 3) chdir gate -> !allow-dir
chdir_err = Rubik::Security::BlockedWriteError.new(
  "Execution blocked: chdir directory 'C:/temp' (C:/temp) is outside of allowed workspace roots and external dirs."
)
g3 = guidance_for(chdir_err)
check.call("chdir gate mentions !allow-dir", g3.include?("!allow-dir add"))
check.call("chdir gate does NOT mention !allow-cmd", !g3.include?("!allow-cmd"))
check.call("chdir gate extracts path", g3.include?('"C:/temp"'))

# 4) log_audit nil-safety
g = Rubik::Security::Guard.new(audit_log_path: File.join(Dir.mktmpdir, "audit.log"))
begin
  g.send(:log_audit, "probe", nil)
  puts "PASS log_audit(nil details) no-crash"
rescue StandardError => e
  puts "FAIL log_audit(nil details) raised: #{e.class}: #{e.message}"
  failures << "log_audit nil"
end
begin
  g.send(:log_audit, "probe", { command: nil })
  puts "PASS log_audit(nil value) no-crash"
rescue StandardError => e
  puts "FAIL log_audit(nil value) raised: #{e.class}: #{e.message}"
  failures << "log_audit nil value"
end

puts failures.empty? ? "\nALL CHECKS PASS" : "\n#{failures.size} FAILURE(S)"
exit(failures.empty? ? 0 : 1)

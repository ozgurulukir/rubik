# frozen_string_literal: true

# Temporary verification script — Plan: komut-allowlist security gate (Paket A acceptance probes).
# Usage: ruby dev/verify_allowlist.rb
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "rubik"
require "tmpdir"
require "json"

Dir.mktmpdir("rubik_allowlist_probe") do |tmp|
  audit = File.join(tmp, "audit.log")
  g = Rubik::Security::Guard.new(command_allowlist: ["node .gitnexus/run.cjs"], audit_log_path: audit)

  passes = 0
  fails  = 0

  check = lambda do |ok, label|
    ok ? passes += 1 : fails += 1
    puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  end

  # 1. Allowlisted prefix passes (the exact GitNexus penetration-tour case)
  begin
    g.verify_command_safety!(%q(node .gitnexus/run.cjs impact "verify_command_safety" --direction upstream --repo .))
    check.call(true, "1: allowlisted GitNexus command passes")
  rescue Rubik::Security::BlockedWriteError => e
    check.call(false, "1: allowlisted GitNexus command passes (#{e.message})")
  end

  # 2. Non-allowlisted node invocation still blocked
  begin
    g.verify_command_safety!("node evil.js")
    check.call(false, "2: non-allowlisted node command blocked")
  rescue Rubik::Security::BlockedWriteError
    check.call(true, "2: non-allowlisted node command blocked")
  end

  # 3. rm -rf / blocked even under allowlist (catastrophic fallback regex not bypassed)
  begin
    g.verify_command_safety!("node .gitnexus/run.cjs impact x --repo . ; rm -rf /")
    check.call(false, "3: rm -rf / blocked under allowlist")
  rescue Rubik::Security::BlockedWriteError
    check.call(true, "3: rm -rf / blocked under allowlist")
  end

  # 4. Multi-segment chain: allowlisted first segment cannot rescue a dangerous sibling
  begin
    g.verify_command_safety!("node .gitnexus/run.cjs impact x && node evil.js")
    check.call(false, "4: chain with dangerous sibling blocked (no partial rescue)")
  rescue Rubik::Security::BlockedWriteError
    check.call(true, "4: chain with dangerous sibling blocked (no partial rescue)")
  end

  # 5. Live reconfiguration: set_allowed_commands takes effect without restart
  g.set_allowed_commands(["git push"])
  begin
    g.verify_command_safety!("node .gitnexus/run.cjs status")
    check.call(false, "5: cleared allowlist re-blocks previously allowed prefix")
  rescue Rubik::Security::BlockedWriteError
    check.call(true, "5: cleared allowlist re-blocks previously allowed prefix")
  end

  # 6. Audit log holds both allowed_command and blocked_command evidence
  actions = File.readlines(audit).filter_map { |l| (JSON.parse(l)["action"] rescue nil) }
  check.call(actions.include?("allowed_command"), "6a: audit log contains allowed_command")
  check.call(actions.include?("blocked_command"), "6b: audit log contains blocked_command")

  # 7. Dangerous builtins (`source`) never rescuable by allowlist
  g.set_allowed_commands(["source"])
  begin
    g.verify_command_safety!("source ~/.bashrc")
    check.call(false, "7: dangerous builtin 'source' not rescuable")
  rescue Rubik::Security::BlockedWriteError
    check.call(true, "7: dangerous builtin 'source' not rescuable")
  end

  puts "\n#{passes} passed, #{fails} failed"
  exit(fails.zero? ? 0 : 1)
end

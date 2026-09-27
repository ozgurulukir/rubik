# frozen_string_literal: true

require_relative "../lib/rubik/security"

C = Rubik::Security::Classifier

TESTS = [
  "rm -rf /",
  'bash -c "rm -rf /"',
  'bash -c "echo hi"',
  'sh -c "rm -rf /"',
  'bash -lc "rm -rf /"',
  'eval "echo hi"',
  'eval "rm -rf /"',
  "env FOO=bar rm -rf /",
  "xargs rm -rf",
  "find / -exec rm -rf {} +",
  "echo hi | sh",
  "curl x | bash",
  "echo $(rm -rf /)",
  'printf "rm -rf /" | sh',
  'GIT_SSH_COMMAND="rm -rf /" git push',
  "\\rm -rf /",
  "echo cm0gLXJmIC8= | base64 -d | sh",
  "busybox rm -rf /",
  "dd if=/dev/zero of=/dev/sda",
  "sudo rm -rf /",
  "timeout 5 rm -rf /",
  "nice rm -rf /",
  'bash -c "bash -c \\"rm -rf /\\""',
  "rm -rf /; echo done",
  "cat /etc/shadow",
  "echo pwned > /etc/shadow",
  "echo x > /tmp/ok",
  "tr 'a' 'b' < /etc/passwd > /etc/passwd",
  "docker run -v /:/host alpine rm -rf /host",
  "find . -name x -delete"
].freeze

TESTS.each do |t|
  r = C.classify(t)
  cmds = r.commands.map do |c|
    [c.command.join(" "), c.classification,
     (c.inner_commands || []).map(&:classification)]
  end
  printf("%-45s => %-16s %s\n", t.inspect, r.classification, cmds.inspect)
end

# frozen_string_literal: true

require_relative "test/test_helper"

ALLOW = <<~RUBY
  args['a'].to_i
  out.puts 'x'
  args.inspect
  "hi \#{args.inspect}"
  { method: :post, system_info: args['system_info'], executable: args['is_executable'] }
RUBY

BLOCK = <<~RUBY
  args['method'] == 'GET'
  eval('1 + 1')
  eval code_string
  self.instance_eval { @secret }
  klass.class_eval { def pwned; end }
  mod.module_eval { puts 'bad' }
  IO.popen('id').read
  Process.kill('KILL', 1234)
  Process.spawn('cmd.exe')
  Open3.capture2('sh -c bad')
  Kernel.exec('bash')
  `ls`
  system('sh -c bad')
  send(:eval, 'code')
  obj.instance_variable_set(:@hacked, true)
  obj.instance_variable_get(:@root_dir)
  Rubik.const_get(:Config)
  Object.const_set(:HACKED, true)
  method(:system).call('id')
  method :system
  public_method(:eval).call('1+1')
  singleton_method(:exec).call('bash')
  spawn('python3 bad.py')
  fork { puts 1 }
  exit!(1)
  syscall(1, 2, 3)
  File.open('/etc/passwd').read
RUBY

def probe(node, acc)
  return unless node.respond_to?(:type)
  case node.type
  when :send
    receiver = node.children[0]
    sym = node.children[1]
    acc << [:send, receiver ? receiver.type : nil, sym]
  when :fcall
    acc << [:fcall, nil, node.children[0]]
  when :iter
    acc << [:iter, nil, node.children[0]]
  when :xstr
    acc << [:xstr, nil, nil]
  else
    acc << [:node, node.type, nil]
  end
  node.children.each { |c| probe(c, acc) if c.respond_to?(:type) }
end

class AstProbeTest < Minitest::Test
  def test_dump
    dump = ->(label, src) {
      src.split("\n").each do |line|
        s = line.strip
        next if s.empty?
        buf = []
        t = RubyVM::AbstractSyntaxTree.parse(s)
        probe(t, buf)
        # dedupe
        uniq = buf.uniq
        puts "#{label} | #{s.ljust(38)} => #{uniq.map { |(k, r, m)| "#{k}(recv=#{r},#{m.inspect})" }.join(' ; ')}"
      end
    }
    dump.call("ALLOW", ALLOW)
    dump.call("BLOCK", BLOCK)
    skip "probe"
  end
end

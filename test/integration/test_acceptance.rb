# frozen_string_literal: true

require_relative "../test_helper"

class TestAcceptance < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @snapshot_store = Rubik::Buffer::SnapshotStore.new(storage_dir: File.join(@temp_dir, "snaps"))
    @guard = Rubik::Security::Guard.new(audit_log_path: File.join(@temp_dir, "audit.log"))
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_end_to_end_fizzbuzz_creation_flow
    # 1. Write FizzBuzz module to in-memory buffer
    fizzbuzz_code = <<~RUBY
      module FizzBuzz
        def self.call(n)
          if n % 15 == 0 then "FizzBuzz"
          elsif n % 3 == 0 then "Fizz"
          elsif n % 5 == 0 then "Buzz"
          else n.to_s
          end
        end
      end
    RUBY

    # Security check on path before buffer write
    assert @guard.verify_path_write!("lib/fizz_buzz.rb")
    @buffer_manager.write("lib/fizz_buzz.rb", fizzbuzz_code)
    assert @buffer_manager.dirty?

    # 2. Disk file does not exist yet (strictly in-memory)
    refute File.exist?(File.join(@temp_dir, "lib/fizz_buzz.rb"))

    # 3. Create snapshot
    @snapshot_store.create_snapshot(@buffer_manager)

    # 4. Apply changes atomically to disk
    applied = @buffer_manager.apply!
    assert_equal ["lib/fizz_buzz.rb"], applied
    refute @buffer_manager.dirty?
    assert File.exist?(File.join(@temp_dir, "lib/fizz_buzz.rb"))

    # 5. Verify syntax using Ruby adapter
    adapter = Rubik::Adapter::RubyAdapter.new
    res = adapter.check_syntax(File.join(@temp_dir, "lib/fizz_buzz.rb"))
    assert res[:ok], "Generated FizzBuzz module should have valid syntax"
  end
end

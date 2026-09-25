# frozen_string_literal: true

require_relative "base"

module Rubik
  module REPL
    module Commands
      # REPL bang command (!dmesg) for inspecting kernel event ring buffer (Plan 102).
      module Dmesg
        extend Base

        USAGE_DMESG = "Usage: !dmesg [-n <count>] [-l <level>] [-s <subsystem>] [--since <seq>] [clear]"

        def self.register(shell)
          handler = lambda do |args, ctx|
            dmesg = resolve_dmesg(ctx)
            unless dmesg
              ctx.out.puts "Kernel dmesg ring buffer is not available."
              return
            end

            if args.include?("clear") || args.include?("-c") || args.include?("--clear")
              dmesg.clear!
              ctx.out.puts "Kernel dmesg buffer cleared."
              return
            end

            opts = parse_args(args)
            records = dmesg.tail(opts[:limit], level: opts[:level], subsystem: opts[:subsystem], since_seq: opts[:since_seq])

            if records.empty?
              ctx.out.puts "Kernel dmesg log buffer is empty."
            else
              ctx.out.puts dmesg.formatted(records, color: false)
            end
          end

          shell.register_command(
            "dmesg",
            description: "Display or filter kernel event ring buffer",
            usage: USAGE_DMESG,
            audience: :both,
            &handler
          )
        end

        def self.resolve_dmesg(ctx)
          if ctx.respond_to?(:dmesg) && ctx.dmesg
            ctx.dmesg
          elsif ctx.respond_to?(:runtime_manager) && ctx.runtime_manager&.context
            ctx.runtime_manager.context.get(:dmesg)
          end
        end

        def self.parse_args(args)
          opts = { limit: 50, level: nil, subsystem: nil, since_seq: nil }
          i = 0
          while i < args.size
            arg = args[i]
            case arg
            when "-n", "--limit", "--count"
              i += 1
              opts[:limit] = args[i].to_i if args[i]
            when "-l", "--level"
              i += 1
              opts[:level] = args[i] if args[i]
            when "-s", "--subsystem"
              i += 1
              opts[:subsystem] = args[i] if args[i]
            when "--since"
              i += 1
              opts[:since_seq] = args[i].to_i if args[i]
            when /\A-n(\d+)\z/
              opts[:limit] = ::Regexp.last_match(1).to_i
            when /\A-l(.+)\z/
              opts[:level] = ::Regexp.last_match(1)
            when /\A-s(.+)\z/
              opts[:subsystem] = ::Regexp.last_match(1)
            end
            i += 1
          end
          opts
        end
      end
    end
  end
end

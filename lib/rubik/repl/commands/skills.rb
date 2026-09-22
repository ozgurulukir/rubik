# frozen_string_literal: true

module Rubik
  module REPL
    module Commands
      module Skills
        def self.register(shell)
          handler = proc do |args, ctx|
            manager = ctx.skill_manager
            unless manager
              ctx.out.puts "Skill manager is not initialized."
              next
            end

            args = args.split if args.is_a?(String)
            subcommand = args[0] || "list"

            case subcommand
            when "list"   then list_skills(ctx, manager)
            when "show"   then show_skill(ctx, manager, args[1])
            when "info"   then info_skill(ctx, manager, args[1])
            when "reload" then reload_skills(ctx, manager)
            else
              ctx.out.puts "Unknown subcommand: #{subcommand}. Usage: !skill [list|show <name>|info <name>|reload]"
            end
          end

          shell.register_command("skill", description: "Agent skills (agentskills.io): list, show <name>, info <name>, reload",
                                 audience: :both, &handler)
          shell.register_command("skills", description: "List discovered agent skills", audience: :human) do |_args, ctx|
            handler.call(["list"], ctx)
          end
        end

        def self.list_skills(ctx, manager)
          summary = manager.status_summary
          skills = manager.all
          ctx.out.puts "🧠 Agent Skills — #{skills.size} active (#{summary[:skipped]} skipped, #{summary[:notes]} notes)"
          if skills.empty?
            ctx.out.puts "No skills discovered. Add .rubik/skills/<name>/SKILL.md (project), " \
                         "~/.rubik/skills/<name>/SKILL.md (user), or extend the skills.paths config."
          else
            skills.each do |skill|
              desc = skill.description.length > 72 ? "#{skill.description[0, 69]}..." : skill.description
              ctx.out.puts format("  %-24s [%-7s] %s", skill.name, skill.scope, desc)
            end
          end
          print_shadowed(ctx, summary[:shadowed])
          print_issues(ctx, manager)
        end

        def self.show_skill(ctx, manager, name)
          skill = manager.find(name.to_s)
          return ctx.out.puts "Unknown skill '#{name}'. Use '!skill list'." unless skill

          ctx.out.puts Rubik::Platform.read_text(skill.path)
        rescue StandardError => e
          ctx.out.puts "Error reading skill '#{name}': #{e.message}"
        end

        def self.info_skill(ctx, manager, name)
          skill = manager.find(name.to_s)
          return ctx.out.puts "Unknown skill '#{name}'. Use '!skill list'." unless skill

          ctx.out.puts "=== Skill '#{skill.name}' ==="
          ctx.out.puts "  Scope         : #{skill.scope}"
          ctx.out.puts "  Directory     : #{skill.root}"
          ctx.out.puts "  Description   : #{skill.description}"
          ctx.out.puts "  License       : #{skill.license || '-'}"
          ctx.out.puts "  Compatibility : #{skill.compatibility || '-'}"
          allowed = skill.allowed_tools.empty? ? "-" : "#{skill.allowed_tools.join(' ')} (advisory, not enforced)"
          ctx.out.puts "  Allowed tools : #{allowed}"
          meta = skill.metadata.empty? ? "-" : skill.metadata.map { |k, v| "#{k}=#{v}" }.join(", ")
          ctx.out.puts "  Metadata      : #{meta}"
          aux = skill.auxiliary_files
          resources = aux.empty? ? "none" : aux.map { |dir, files| "#{dir}/ (#{files.size})" }.join(", ")
          ctx.out.puts "  Resources     : #{resources}"
          skill.warnings.each { |warning| ctx.out.puts "  ⚠ #{warning.field} #{warning.message}" }
        end

        def self.reload_skills(ctx, manager)
          manager.reload!
          summary = manager.status_summary
          scopes = summary[:by_scope].map { |scope, count| "#{scope}: #{count}" }.join(", ")
          ctx.out.puts "🔄 Skills reloaded: #{summary[:total]} active (#{scopes.empty? ? 'none' : scopes}), " \
                       "#{summary[:skipped]} skipped, #{summary[:notes]} notes."
          print_shadowed(ctx, summary[:shadowed])
          print_issues(ctx, manager)
        end

        def self.print_shadowed(ctx, shadowed)
          shadowed.each do |name, entry|
            losers = entry[:loser_scopes].join(", ")
            ctx.out.puts "  ⇢ '#{name}' shadowed: #{losers} copy ignored (winner: #{entry[:winner_scope]})"
          end
        end

        def self.print_issues(ctx, manager)
          manager.issues.each do |issue|
            mark = issue.error? ? "⚠" : "·"
            ctx.out.puts "  #{mark} #{File.basename(issue.path)}: #{issue.field} #{issue.message}"
          end
        end
      end
    end
  end
end

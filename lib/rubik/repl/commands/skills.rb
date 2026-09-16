# frozen_string_literal: true

require_relative "../../coeffects"

module Rubik
  module REPL
    module Commands
      module Skills
        def self.register(shell)
          handler = proc do |args|
            manager = Rubik::Coeffects.get(shell.runtime_manager&.context, Rubik::Coeffects::SKILL_MANAGER)
            manager ||= shell.skill_manager if shell.respond_to?(:skill_manager)
            unless manager
              shell.output.puts "Skill manager is not initialized."
              next
            end

            args = args.split if args.is_a?(String)
            subcommand = args[0] || "list"

            case subcommand
            when "list"   then list_skills(shell, manager)
            when "show"   then show_skill(shell, manager, args[1])
            when "info"   then info_skill(shell, manager, args[1])
            when "reload" then reload_skills(shell, manager)
            else
              shell.output.puts "Unknown subcommand: #{subcommand}. Usage: !skill [list|show <name>|info <name>|reload]"
            end
          end

          shell.register_command("skill", description: "Agent skills (agentskills.io): list, show <name>, info <name>, reload",
                                 audience: :both, &handler)
          shell.register_command("skills", description: "List discovered agent skills", audience: :human) do
            handler.call(["list"])
          end
        end

        def self.list_skills(shell, manager)
          summary = manager.status_summary
          skills = manager.all
          shell.output.puts "🧠 Agent Skills — #{skills.size} active (#{summary[:skipped]} skipped, #{summary[:notes]} notes)"
          if skills.empty?
            shell.output.puts "No skills discovered. Add .rubik/skills/<name>/SKILL.md (project), " \
                              "~/.rubik/skills/<name>/SKILL.md (user), or extend the skills.paths config."
          else
            skills.each do |skill|
              desc = skill.description.length > 72 ? "#{skill.description[0, 69]}..." : skill.description
              shell.output.puts format("  %-24s [%-7s] %s", skill.name, skill.scope, desc)
            end
          end
          print_shadowed(shell, summary[:shadowed])
          print_issues(shell, manager)
        end

        def self.show_skill(shell, manager, name)
          skill = manager.find(name.to_s)
          return shell.output.puts "Unknown skill '#{name}'. Use '!skill list'." unless skill

          shell.output.puts Rubik::Platform.read_text(skill.path)
        rescue StandardError => e
          shell.output.puts "Error reading skill '#{name}': #{e.message}"
        end

        def self.info_skill(shell, manager, name)
          skill = manager.find(name.to_s)
          return shell.output.puts "Unknown skill '#{name}'. Use '!skill list'." unless skill

          shell.output.puts "=== Skill '#{skill.name}' ==="
          shell.output.puts "  Scope         : #{skill.scope}"
          shell.output.puts "  Directory     : #{skill.root}"
          shell.output.puts "  Description   : #{skill.description}"
          shell.output.puts "  License       : #{skill.license || '-'}"
          shell.output.puts "  Compatibility : #{skill.compatibility || '-'}"
          allowed = skill.allowed_tools.empty? ? "-" : "#{skill.allowed_tools.join(' ')} (advisory, not enforced)"
          shell.output.puts "  Allowed tools : #{allowed}"
          meta = skill.metadata.empty? ? "-" : skill.metadata.map { |k, v| "#{k}=#{v}" }.join(", ")
          shell.output.puts "  Metadata      : #{meta}"
          aux = skill.auxiliary_files
          resources = aux.empty? ? "none" : aux.map { |dir, files| "#{dir}/ (#{files.size})" }.join(", ")
          shell.output.puts "  Resources     : #{resources}"
          skill.warnings.each { |warning| shell.output.puts "  ⚠ #{warning.field} #{warning.message}" }
        end

        def self.reload_skills(shell, manager)
          manager.reload!
          summary = manager.status_summary
          scopes = summary[:by_scope].map { |scope, count| "#{scope}: #{count}" }.join(", ")
          shell.output.puts "🔄 Skills reloaded: #{summary[:total]} active (#{scopes.empty? ? 'none' : scopes}), " \
                            "#{summary[:skipped]} skipped, #{summary[:notes]} notes."
          print_shadowed(shell, summary[:shadowed])
          print_issues(shell, manager)
        end

        def self.print_shadowed(shell, shadowed)
          shadowed.each do |name, entry|
            losers = entry[:loser_scopes].join(", ")
            shell.output.puts "  ⇢ '#{name}' shadowed: #{losers} copy ignored (winner: #{entry[:winner_scope]})"
          end
        end

        def self.print_issues(shell, manager)
          manager.issues.each do |issue|
            mark = issue.error? ? "⚠" : "·"
            shell.output.puts "  #{mark} #{File.basename(issue.path)}: #{issue.field} #{issue.message}"
          end
        end
      end
    end
  end
end

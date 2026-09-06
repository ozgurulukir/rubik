# frozen_string_literal: true

require_relative "models"

module Rubik
  module Security
    module Classifier
      module PwshRules
        def self.definitions
          @definitions ||= build_definitions
        end

        def self.[](name)
          definitions[name.to_s.downcase]
        end

        def self.key?(name)
          definitions.key?(name.to_s.downcase)
        end

        def self.build_definitions
          defs = {}

          remove_item = CommandDef.new(
            command: "Remove-Item",
            aliases: ["del", "erase", "rd", "ri", "rm", "rmdir"],
            classification: :local_effects,
            risk: :medium,
            strict: false,
            options: {
              "-recurse" => OptionDef.new(aliases: ["-r"]),
              "-force" => OptionDef.new(aliases: ["-f", "-fo"]),
              "-path" => OptionDef.new(takes_value: true)
            }
          )
          register_cmd(defs, remove_item)

          get_child_item = CommandDef.new(
            command: "Get-ChildItem",
            aliases: ["dir", "gci", "ls"],
            classification: :readonly,
            risk: :low,
            strict: false,
            options: {
              "-path" => OptionDef.new(takes_value: true, captures_directory: true),
              "-recurse" => OptionDef.new(aliases: ["-s", "-r"])
            }
          )
          register_cmd(defs, get_child_item)

          get_content = CommandDef.new(
            command: "Get-Content",
            aliases: ["cat", "gc", "type"],
            classification: :readonly,
            risk: :low,
            strict: false,
            options: { "-path" => OptionDef.new(takes_value: true) }
          )
          register_cmd(defs, get_content)

          stop_process = CommandDef.new(
            command: "Stop-Process",
            aliases: ["kill", "spps"],
            classification: :local_effects,
            risk: :medium,
            strict: false,
            options: {
              "-name" => OptionDef.new(takes_value: true),
              "-id" => OptionDef.new(takes_value: true),
              "-force" => OptionDef.new(overrides: :local_effects, risk: :medium)
            }
          )
          register_cmd(defs, stop_process)

          invoke_webrequest = CommandDef.new(
            command: "Invoke-WebRequest",
            aliases: ["curl", "iwr", "wget"],
            classification: :external_effects,
            risk: :medium,
            strict: false,
            options: {
              "-uri" => OptionDef.new(takes_value: true),
              "-outfile" => OptionDef.new(takes_value: true)
            }
          )
          register_cmd(defs, invoke_webrequest)

          invoke_restmethod = CommandDef.new(
            command: "Invoke-RestMethod",
            aliases: ["irm"],
            classification: :external_effects,
            risk: :medium,
            strict: false,
            options: {
              "-uri" => OptionDef.new(takes_value: true),
              "-outfile" => OptionDef.new(takes_value: true)
            }
          )
          register_cmd(defs, invoke_restmethod)

          start_process = CommandDef.new(
            command: "Start-Process",
            aliases: ["saps", "start"],
            classification: :local_effects,
            risk: :medium,
            strict: false,
            delegates_to: DelegationConfig.new(mode: :rest_are_argv),
            options: {
              "-filepath" => OptionDef.new(takes_value: true),
              "-argumentlist" => OptionDef.new(takes_value: true)
            }
          )
          register_cmd(defs, start_process)

          set_content = CommandDef.new(
            command: "Set-Content",
            aliases: ["sc"],
            classification: :local_effects,
            risk: :medium,
            strict: false,
            options: { "-path" => OptionDef.new(takes_value: true) }
          )
          register_cmd(defs, set_content)

          add_content = CommandDef.new(
            command: "Add-Content",
            aliases: ["ac"],
            classification: :local_effects,
            risk: :medium,
            strict: false,
            options: { "-path" => OptionDef.new(takes_value: true) }
          )
          register_cmd(defs, add_content)

          out_file = CommandDef.new(
            command: "Out-File",
            classification: :local_effects,
            risk: :medium,
            strict: false,
            options: { "-filepath" => OptionDef.new(takes_value: true) }
          )
          register_cmd(defs, out_file)

          dangerous_cmdlets = [
            "Format-Volume", "Clear-Disk", "Initialize-Disk",
            "Remove-Partition", "Set-Disk", "Stop-Computer", "Restart-Computer"
          ]
          dangerous_cmdlets.each do |cmd_name|
            register_cmd(
              defs,
              CommandDef.new(command: cmd_name, classification: :dangerous, risk: :high, strict: false)
            )
          end

          defs
        end

        def self.register_cmd(defs, command_def)
          defs[command_def.command.downcase] = command_def
          command_def.aliases.each do |alias_name|
            defs[alias_name.downcase] = command_def
          end
        end
      end
    end
  end
end

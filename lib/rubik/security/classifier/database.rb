# frozen_string_literal: true

require "monitor"
require "yaml"
require_relative "models"
require_relative "pwsh_rules"

module Rubik
  module Security
    module Classifier
      class CommandDatabase
        include MonitorMixin

        ALIAS_FORBIDDEN_KEYS = [
          "classification", "risk", "subcommands", "options", "global_options", "subcommand_mode", "delegates_to", "strict"
        ].freeze

        attr_reader :builtin_dir, :user_dir

        def self.default_commands_dir
          File.expand_path("commands", __dir__)
        end

        def self.user_commands_dir
          cfg = ENV["BASH_CLASSIFY_CONFIG_DIR"] || ENV.fetch("RUBIK_COMMAND_CONFIG_DIR", nil)
          return File.join(cfg, "commands") if cfg

          File.join(Dir.home, ".config", "rubik", "commands")
        end

        def initialize(builtin_dir: nil, user_dir: nil)
          super()
          @builtin_dir = builtin_dir || self.class.default_commands_dir
          @user_dir = user_dir || (File.directory?(self.class.user_commands_dir) ? self.class.user_commands_dir : nil)
          @files = {}
          @cache = {}

          index_dir(@builtin_dir) if @builtin_dir && File.directory?(@builtin_dir)
          index_dir(@user_dir) if @user_dir && File.directory?(@user_dir)
        end

        def [](key, shell: nil)
          get(key, nil, shell: shell)
        end

        def get(key, default = nil, shell: nil)
          return default if key.nil?

          key_s = self.class.yaml_str(key)

          return PwshRules[key_s] if shell == :powershell && PwshRules.key?(key_s)

          synchronize do
            if @cache.key?(key_s)
              @cache[key_s]
            elsif @files.key?(key_s)
              cmd_def = self.class.load_command_file(@files[key_s])
              @cache[key_s] = cmd_def
              cmd_def
            elsif PwshRules.key?(key_s)
              PwshRules[key_s]
            else
              default
            end
          end
        end

        def key?(key, shell: nil)
          return false if key.nil?

          key_s = self.class.yaml_str(key)
          return true if shell == :powershell && PwshRules.key?(key_s)

          @cache.key?(key_s) || @files.key?(key_s) || PwshRules.key?(key_s)
        end

        def resolve_alias(command_def)
          return command_def if command_def.nil? || command_def.alias_of.nil?

          target_name = command_def.alias_of
          target_def = get(target_name)
          raise ArgumentError, "#{command_def.command} aliases '#{target_name}' which is not in the database" unless target_def

          raise ArgumentError, "alias chain too deep: #{command_def.command} -> #{target_name} -> #{target_def.alias_of}" if target_def.alias_of

          target_def
        end

        def keys
          (@files.keys + PwshRules.definitions.keys).uniq
        end

        def size
          keys.size
        end

        def self.yaml_str(value)
          return "true" if value == true
          return "false" if value == false

          value.to_s
        end

        def self.load_command_file(yaml_file)
          data = YAML.safe_load_file(yaml_file, permitted_classes: [Symbol])
          raise ArgumentError, "Empty YAML file: #{yaml_file}" if data.nil?
          raise ArgumentError, "Expected a YAML mapping in #{yaml_file}" unless data.is_a?(Hash)

          command_name = yaml_str(data["command"] || File.basename(yaml_file, ".yaml"))
          parse_command_def(data, command_name)
        rescue StandardError => e
          raise ArgumentError, "Error loading #{yaml_file}: #{e.message}"
        end

        def self.parse_command_def(data, command_name, is_subcommand: false)
          raise ArgumentError, "command '#{command_name}': 'aliases' is only valid on subcommands; use alias_of" if data.key?("aliases") && !is_subcommand

          if data.key?("alias_of")
            conflicting = ALIAS_FORBIDDEN_KEYS & data.keys
            raise ArgumentError, "alias file for '#{command_name}' combines alias_of with: #{conflicting.join(', ')}" if conflicting.any?

            return CommandDef.new(command: command_name, alias_of: yaml_str(data["alias_of"]))
          end

          CommandDef.new(
            command: command_name,
            aliases: parse_aliases(data["aliases"], command_name),
            classification: Classification.normalize(data["classification"]),
            risk: Risk.normalize(data["risk"]),
            global_options: parse_options(data["global_options"]),
            subcommands: parse_subcommands(data["subcommands"]),
            options: parse_options(data["options"]),
            strict: data.fetch("strict", true),
            subcommand_mode: data["subcommand_mode"] == "match_all" ? :match_all : :hierarchical,
            delegates_to: parse_delegation_config(data["delegates_to"])
          )
        end

        def self.parse_options(raw)
          return {} unless raw.is_a?(Hash)

          options = {}
          raw.each do |name, props|
            props = {} unless props.is_a?(Hash)
            aliases = (props["aliases"] || []).map { |a| yaml_str(a) }
            opt_def = OptionDef.new(
              takes_value: props.fetch("takes_value", false),
              aliases: aliases,
              overrides: Classification.normalize(props["overrides"]),
              risk: Risk.normalize(props["risk"]),
              captures_directory: props.fetch("captures_directory", false),
              delegates_to: parse_delegation_config(props["delegates_to"])
            )
            options[name] = opt_def
            aliases.each { |a| options[a] = opt_def }
          end
          options
        end

        def self.parse_aliases(raw, command_name)
          return [] if raw.nil?
          raise ArgumentError, "subcommand '#{command_name}': 'aliases' must be a list" unless raw.is_a?(Array)

          raw.map { |a| yaml_str(a) }
        end

        def self.parse_subcommands(raw)
          return {} unless raw.is_a?(Hash)

          subcommands = {}
          raw.each do |name, props|
            canonical = yaml_str(name)
            subcommands[canonical] = parse_command_def(props || {}, canonical, is_subcommand: true)
          end

          aliased_by = {}
          subcommands.dup.each do |canonical, definition|
            definition.aliases.each do |alias_name|
              raise ArgumentError, "subcommand '#{canonical}' declares alias '#{alias_name}' already a subcommand" if subcommands.key?(alias_name)
              raise ArgumentError, "alias '#{alias_name}' already declared by '#{aliased_by[alias_name]}'" if aliased_by.key?(alias_name)

              aliased_by[alias_name] = canonical
            end
          end

          aliased_by.each { |alias_name, canonical| subcommands[alias_name] = subcommands[canonical] }
          subcommands
        end

        def self.parse_delegation_config(raw)
          return nil unless raw.is_a?(Hash) && raw["mode"]

          DelegationConfig.new(
            mode: raw["mode"].to_sym,
            separator: raw["separator"],
            terminator: raw["terminator"],
            flag: raw["flag"],
            strip_assignments: raw.fetch("strip_assignments", false),
            skip_leading_positionals: raw.fetch("skip_leading_positionals", 0).to_i,
            min_classification: Classification.normalize(raw["min_classification"])
          )
        end

        private

        def index_dir(dir)
          Dir.glob(File.join(dir, "*.yaml")).each do |path|
            stem = File.basename(path, ".yaml")
            @files[stem] = path
          end
        end
      end
    end
  end
end

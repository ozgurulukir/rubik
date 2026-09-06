# frozen_string_literal: true

require "tree_sitter_language_pack"
require_relative "../models"

module Rubik
  module Security
    module Classifier
      module Parsers
        class PowerShell
          def self.parser
            Thread.current[:rubik_ts_pwsh_parser] ||= TreeSitterLanguagePack.get_parser("powershell")
          end

          def self.parse(expression)
            new.parse(expression)
          end

          def parse(expression)
            tree = self.class.parser.parse(expression)
            warnings = []
            warnings << "tree-sitter reported a syntax error in expression: #{expression.inspect}" if tree.root_node.has_error

            invocations = walk_node(tree.root_node, expression, context: "toplevel", operator_before: nil)
            [invocations, warnings]
          end

          private

          def walk_node(node, expression, context:, operator_before:, pipeline_position: 0, pipeline_length: 1)
            results = []
            case node.kind
            when "program", "statement_list", "script_block", "script_block_body"
              results.concat(walk_statements(node, expression, context: context))
            when "pipeline_chain"
              results.concat(walk_pipeline_chain(node, expression, context: context, operator_before: operator_before))
            when "command"
              inv, nested_blocks = extract_command(
                node, expression, context: context, operator_before: operator_before,
                                  pipeline_position: pipeline_position, pipeline_length: pipeline_length
              )
              results << inv if inv
              nested_blocks.each do |block|
                results.concat(walk_node(block, expression, context: "script_block", operator_before: nil))
              end
            else
              node_children(node).each do |child|
                results.concat(walk_node(
                                 child, expression, context: context, operator_before: operator_before,
                                                    pipeline_position: pipeline_position, pipeline_length: pipeline_length
                               ))
              end
            end
            results
          end

          def walk_statements(node, expression, context:)
            results = []
            op_before = nil
            node_children(node).each do |child|
              if [";", "\n"].include?(child.kind) || child.kind == "empty_statement"
                op_before = ";"
                next
              end
              results.concat(walk_node(child, expression, context: context, operator_before: op_before))
              op_before = nil
            end
            results
          end

          def walk_pipeline_chain(node, expression, context:, operator_before:)
            commands = node_children(node).select { |c| c.kind == "command" }
            pipe_len = [commands.size, 1].max
            results = []
            commands.each_with_index do |cmd, i|
              op = (i.zero? ? operator_before : "|")
              inv, nested = extract_command(
                cmd, expression, context: context, operator_before: op,
                                 pipeline_position: i, pipeline_length: pipe_len
              )
              results << inv if inv
              nested.each do |block|
                results.concat(walk_node(block, expression, context: "script_block", operator_before: nil))
              end
            end
            results
          end

          def extract_command(node, expression, context:, operator_before:, pipeline_position:, pipeline_length:)
            argv = []
            redirects = []
            nested_blocks = []

            node_children(node).each do |child|
              case child.kind
              when "command_name", "command_invokation_operator"
                argv << node_text(child, expression)
              when "command_name_expr"
                find_nested_blocks(child, nested_blocks)
                argv << node_text(child, expression) if argv.empty?
              when "command_elements"
                parse_command_elements(child, expression, argv, redirects, nested_blocks)
              end
            end

            return [nil, nested_blocks] if argv.empty?

            inv = CommandInvocation.new(
              argv: argv,
              redirects: redirects,
              position_in_pipeline: pipeline_position,
              pipeline_length: pipeline_length,
              context: context,
              operator_before: operator_before,
              is_background: false
            )
            [inv, nested_blocks]
          end

          def parse_command_elements(node, expression, argv, redirects, nested_blocks)
            node_children(node).each do |elem|
              case elem.kind
              when "command_argument_sep"
                next
              when "command_parameter"
                argv << node_raw_text(elem, expression).strip
              when "redirection"
                red = parse_redirection(elem, expression)
                redirects << red if red
              else
                text = node_text(elem, expression).strip
                argv << text unless text.empty?
                find_nested_blocks(elem, nested_blocks)
              end
            end
          end

          def parse_redirection(node, expression)
            op = ">"
            target = ""
            node_children(node).each do |c|
              if c.kind == "file_redirection_operator"
                op = node_raw_text(c, expression).strip
              elsif c.kind == "redirected_file_name"
                target = node_text(c, expression).strip
              end
            end
            target = target.sub(/\A\s+/, "")
            affects = [">", ">>", "2>", "2>>", "*>"].include?(op)
            Redirect.new(operator: op, target: target, affects_classification: affects)
          end

          def find_nested_blocks(node, nested_blocks)
            if node.kind == "script_block"
              nested_blocks << node
            else
              node_children(node).each { |c| find_nested_blocks(c, nested_blocks) }
            end
          end

          def node_children(node)
            (0...node.child_count).map { |i| node.child(i) }
          end

          def node_raw_text(node, expression)
            return "" if node.nil?

            expression.byteslice(node.start_byte...node.end_byte) || ""
          end

          def node_text(node, expression)
            raw = node_raw_text(node, expression)
            clean = raw.strip
            if clean.length >= 2 && ((clean.start_with?('"') && clean.end_with?('"')) ||
               (clean.start_with?("'") && clean.end_with?("'")))
              return clean[1..-2]
            end

            clean
          end
        end
      end
    end
  end
end

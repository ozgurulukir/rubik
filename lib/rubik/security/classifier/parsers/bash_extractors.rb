# frozen_string_literal: true

require_relative "../models"

module Rubik
  module Security
    module Classifier
      module Parsers
        module BashExtractors
          OPERATORS = [">", ">>", "<", ">&", "&>", "&>>", "<&", "<<", "<<<"].freeze

          def self.node_children(node)
            (0...node.child_count).map { |i| node.child(i) }
          end

          def self.node_raw_text(node, expression)
            return "" if node.nil?

            expression.byteslice(node.start_byte...node.end_byte) || ""
          end

          def self.node_text(node, expression)
            raw = node_raw_text(node, expression)
            case node.kind
            when "string"
              raw.length >= 2 && raw.start_with?('"') && raw.end_with?('"') ? raw[1..-2] : raw
            when "raw_string", "ansi_c_string"
              if raw.length >= 3 && raw.start_with?("$'") && raw.end_with?("'")
                raw[2..-2]
              elsif raw.length >= 2 && raw.start_with?("'") && raw.end_with?("'")
                raw[1..-2]
              else
                raw
              end
            when "concatenation"
              node_children(node).map { |c| node_text(c, expression) }.join
            else
              raw
            end
          end

          def self.redirect_affects_classification(operator, target)
            return false if target == File::NULL
            return false if operator.include?(">&") && target =~ /\A\d+\z/

            return true if [">", ">>", "&>", "&>>"].include?(operator) || (operator.end_with?(">") && !operator.include?("<"))

            operator.length >= 2 && operator[0] =~ /\d/ && operator.include?(">")
          end

          def self.extract_redirects_from_node(node, expression)
            redirects = []
            node_children(node).each do |child|
              case child.kind
              when "file_redirect"
                red = parse_file_redirect(child, expression)
                redirects << red if red
              when "heredoc_redirect"
                red = parse_heredoc_redirect(child, expression)
                redirects << red if red
              when "herestring_redirect"
                red = parse_herestring_redirect(child, expression)
                redirects << red if red
              end
            end
            redirects
          end

          def self.parse_file_redirect(node, expression)
            operator_parts = []
            target = ""

            node_children(node).each do |child|
              if child.kind == "file_descriptor" || OPERATORS.include?(child.kind)
                operator_parts << node_raw_text(child, expression)
              elsif child.is_named
                target = node_text(child, expression)
              else
                text = node_raw_text(child, expression)
                if OPERATORS.include?(text)
                  operator_parts << text
                elsif target.empty?
                  target = text
                end
              end
            end

            operator = operator_parts.join
            if operator.empty?
              full = node_raw_text(node, expression)
              operator = full.split.first || full if full.include?(">") || full.include?("<")
            end

            affects = redirect_affects_classification(operator, target)
            Redirect.new(operator: operator, target: target, affects_classification: affects)
          end

          def self.parse_heredoc_redirect(node, expression)
            operator = "<<"
            target = ""

            node_children(node).each do |child|
              if ["<<", "<<-"].include?(child.kind)
                operator = node_raw_text(child, expression)
              elsif child.kind == "heredoc_start"
                target = node_raw_text(child, expression)
              end
            end

            Redirect.new(operator: operator, target: target, affects_classification: false)
          end

          def self.parse_herestring_redirect(node, expression)
            target = ""
            node_children(node).each do |child|
              next if child.kind == "<<<"

              if child.is_named
                target = node_text(child, expression)
              else
                t = node_raw_text(child, expression)
                target = t if t != "<<<" && target.empty?
              end
            end

            Redirect.new(operator: "<<<", target: target, affects_classification: false)
          end

          def self.extract_command(node, expression, context:, operator_before:, pipeline_position:, pipeline_length:)
            argv = []
            has_command_name = false

            node_children(node).each do |child|
              case child.kind
              when "variable_assignment"
                argv << node_text(child, expression) if has_command_name
              when "command_name"
                has_command_name = true
                argv << node_text(child, expression)
              when "file_redirect", "heredoc_redirect", "herestring_redirect", "comment"
                next
              else
                argv << node_text(child, expression)
              end
            end

            return nil if argv.empty?

            redirects = extract_redirects_from_node(node, expression)
            CommandInvocation.new(
              argv: argv,
              redirects: redirects,
              position_in_pipeline: pipeline_position,
              pipeline_length: pipeline_length,
              context: context,
              operator_before: operator_before,
              is_background: false
            )
          end

          def self.extract_test_command(node, expression, context:, operator_before:, pipeline_position:, pipeline_length:)
            argv = extract_test_tokens(node, expression)
            return nil if argv.empty?

            CommandInvocation.new(
              argv: argv,
              redirects: [],
              position_in_pipeline: pipeline_position,
              pipeline_length: pipeline_length,
              context: context,
              operator_before: operator_before,
              is_background: false
            )
          end

          def self.extract_test_tokens(node, expression)
            tokens = []
            node_children(node).each do |child|
              if ["[", "[["].include?(child.kind)
                tokens << node_raw_text(child, expression)
              elsif ["]", "]]"].include?(child.kind)
                next
              elsif child.child_count.positive?
                tokens.concat(extract_test_tokens(child, expression))
              else
                t = node_text(child, expression).strip
                tokens << t unless t.empty?
              end
            end
            tokens
          end

          def self.find_nested_substitutions(node, expression, &walker)
            results = []
            case node.kind
            when "command_substitution"
              results.concat(walker.call(node, "command_substitution"))
            when "process_substitution"
              results.concat(walker.call(node, "process_substitution"))
            else
              node_children(node).each do |child|
                results.concat(find_nested_substitutions(child, expression, &walker))
              end
            end
            results
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "tree_sitter_language_pack"
require_relative "../models"
require_relative "bash_extractors"

module Rubik
  module Security
    module Classifier
      module Parsers
        class Bash
          HEREDOC_STRUCTURE_NODES = ["<<", "<<-", "heredoc_start", "heredoc_body", "heredoc_end"].freeze
          LIST_OPERATORS = ["&&", "||"].freeze

          def self.parser
            Thread.current[:rubik_ts_bash_parser] ||= TreeSitterLanguagePack.get_parser("bash")
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
            when "program"
              results.concat(walk_children_as_list(node, expression, context: context))
            when "list"
              results.concat(walk_list_node(node, expression, context: context, operator_before: operator_before))
            when "pipeline"
              results.concat(walk_pipeline_node(node, expression, context: context, operator_before: operator_before))
            when "command"
              inv = BashExtractors.extract_command(
                node, expression, context: context, operator_before: operator_before,
                                  pipeline_position: pipeline_position, pipeline_length: pipeline_length
              )
              results << inv if inv
              results.concat(extract_nested_from_command_args(node, expression))
            when "redirected_statement"
              results.concat(walk_redirected_statement(
                               node, expression, context: context, operator_before: operator_before,
                                                 pipeline_position: pipeline_position, pipeline_length: pipeline_length
                             ))
            when "subshell"
              results.concat(walk_subshell(node, expression, context: "subshell", operator_before: operator_before))
            when "command_substitution"
              results.concat(walk_compound_inner(node, expression, context: "command_substitution"))
            when "process_substitution"
              results.concat(walk_compound_inner(node, expression, context: "process_substitution"))
            when "test_command"
              inv = BashExtractors.extract_test_command(
                node, expression, context: context, operator_before: operator_before,
                                  pipeline_position: pipeline_position, pipeline_length: pipeline_length
              )
              results << inv if inv
            when "negated_command"
              BashExtractors.node_children(node).each do |child|
                next if child.kind == "!"

                results.concat(walk_node(
                                 child, expression, context: context, operator_before: operator_before,
                                                    pipeline_position: pipeline_position, pipeline_length: pipeline_length
                               ))
              end
            else
              BashExtractors.node_children(node).each do |child|
                results.concat(walk_node(
                                 child, expression, context: context, operator_before: operator_before,
                                                    pipeline_position: pipeline_position, pipeline_length: pipeline_length
                               ))
              end
            end
            results
          end

          def walk_children_as_list(node, expression, context:)
            results = []
            operator_before = nil
            BashExtractors.node_children(node).each do |child|
              if ["\n", ";", "&", ";;"].include?(child.kind)
                if child.kind == ";"
                  operator_before = ";"
                elsif child.kind == "&"
                  mark_last_background(results)
                  operator_before = nil
                end
                next
              end
              results.concat(walk_node(child, expression, context: context, operator_before: operator_before))
              operator_before = nil
            end
            results
          end

          def walk_list_node(node, expression, context:, operator_before:)
            results = []
            curr_op = operator_before
            BashExtractors.node_children(node).each do |child|
              if ["&&", "||", ";"].include?(child.kind)
                curr_op = child.kind
                next
              elsif child.kind == "&"
                mark_last_background(results)
                curr_op = nil
                next
              elsif child.kind == "\n"
                next
              end
              results.concat(walk_node(child, expression, context: context, operator_before: curr_op))
              curr_op = nil
            end
            results
          end

          def walk_pipeline_node(node, expression, context:, operator_before:)
            members = flatten_pipeline_members(node)
            results = []
            members.each_with_index do |cmd_node, i|
              op = (i.zero? ? operator_before : nil)
              results.concat(walk_node(
                               cmd_node, expression, context: context, operator_before: op,
                                                     pipeline_position: i, pipeline_length: members.size
                             ))
            end
            results
          end

          def walk_redirected_statement(node, expression, context:, operator_before:, pipeline_position:, pipeline_length:)
            redirects = BashExtractors.extract_redirects_from_node(node, expression)
            body_node = BashExtractors.node_children(node).find do |child|
              !["file_redirect", "heredoc_redirect", "herestring_redirect"].include?(child.kind)
            end
            return [] unless body_node

            followers = heredoc_follower_segments(node)
            followers_pipe_len = followers.sum do |op, child|
              continues_pipeline?(op, child) ? flatten_pipeline_members(child).size : 0
            end
            pipe_len = pipeline_length + followers_pipe_len

            inner = walk_node(
              body_node, expression, context: context, operator_before: operator_before,
                                     pipeline_position: pipeline_position, pipeline_length: pipe_len
            )

            results = []
            redirects_attached = false
            inner.each do |inv|
              if !redirects_attached && inv.position_in_pipeline == pipeline_position
                inv = inv.with(redirects: (inv.redirects + redirects))
                redirects_attached = true
              end
              results << inv
            end

            results.concat(walk_heredoc_followers(
                             followers, expression, context: context,
                                                    pipeline_position: pipeline_position, pipeline_length: pipe_len
                           ))
            results
          end

          def walk_subshell(node, expression, context:, operator_before:)
            results = []
            BashExtractors.node_children(node).each do |child|
              next if ["(", ")"].include?(child.kind)

              results.concat(walk_node(child, expression, context: context, operator_before: operator_before))
              operator_before = nil
            end
            results
          end

          def walk_compound_inner(node, expression, context:)
            results = []
            BashExtractors.node_children(node).each do |child|
              next if ["$(", ")", "<(", ">(", "`"].include?(child.kind)

              results.concat(walk_node(child, expression, context: context, operator_before: nil))
            end
            results
          end

          def extract_nested_from_command_args(node, expression)
            results = []
            BashExtractors.node_children(node).each do |child|
              if child.kind == "command_name"
                BashExtractors.node_children(child).each do |sub|
                  results.concat(BashExtractors.find_nested_substitutions(sub, expression) do |inner_node, ctx|
                    walk_compound_inner(inner_node, expression, context: ctx)
                  end)
                end
              elsif ["file_redirect", "heredoc_redirect", "herestring_redirect", "variable_assignment"].include?(child.kind)
                next
              else
                results.concat(BashExtractors.find_nested_substitutions(child, expression) do |inner_node, ctx|
                  walk_compound_inner(inner_node, expression, context: ctx)
                end)
              end
            end
            results
          end

          def flatten_pipeline_members(node)
            members = []
            BashExtractors.node_children(node).each do |child|
              next if ["|", "|&"].include?(child.kind)

              if child.kind == "pipeline"
                members.concat(flatten_pipeline_members(child))
              else
                members << child
              end
            end
            members
          end

          def heredoc_follower_segments(node)
            segments = []
            heredocs = BashExtractors.node_children(node).select { |c| c.kind == "heredoc_redirect" }
            heredocs.each do |redirect|
              pending_op = nil
              BashExtractors.node_children(redirect).each do |child|
                next if HEREDOC_STRUCTURE_NODES.include?(child.kind)

                if LIST_OPERATORS.include?(child.kind)
                  pending_op = child.kind
                  next
                end
                segments << [pending_op, child]
                pending_op = nil
              end
            end
            segments
          end

          def continues_pipeline?(operator, child)
            operator.nil? && child.kind == "pipeline"
          end

          def walk_heredoc_followers(segments, expression, context:, pipeline_position:, pipeline_length:)
            results = []
            pos = pipeline_position
            segments.each do |op, child|
              if continues_pipeline?(op, child)
                flatten_pipeline_members(child).each do |member|
                  pos += 1
                  results.concat(walk_node(
                                   member, expression, context: context, operator_before: nil,
                                                       pipeline_position: pos, pipeline_length: pipeline_length
                                 ))
                end
              else
                results.concat(walk_node(child, expression, context: context, operator_before: op))
              end
            end
            results
          end

          def mark_last_background(results)
            return if results.empty?

            results[-1] = results.last.with(is_background: true)
          end
        end
      end
    end
  end
end

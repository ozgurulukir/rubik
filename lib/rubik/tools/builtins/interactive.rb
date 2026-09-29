# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../ui/dialog"

module Rubik
  module Tools
    # Prompts the human operator with structured questions to resolve ambiguity,
    # clarify design decisions, or choose between implementation paths (Plan 92).
    class AskQuestionTool < BaseTool
      attr_reader :shell, :dialog

      def initialize(shell: nil, dialog: nil)
        super(
          name: "ask_question",
          description: "Prompts the human operator with structured questions to clarify underspecified requirements, solicit preferences, or choose options.",
          risk: :read,
          aliases: ["ask", "question"],
          params_schema: {
            type: "object",
            properties: {
              "questions" => {
                type: "array",
                description: "List of questions to ask the operator.",
                items: {
                  type: "object",
                  properties: {
                    "question" => { type: "string", description: "The clear question text to display." },
                    "options" => {
                      type: "array",
                      items: { type: "string" },
                      minItems: 2,
                      description: "List of selectable answer options (at least 2). Recommended option should be prefixed with '(Recommended)'."
                    },
                    "is_multi_select" => { type: "boolean", description: "True if multiple options can be chosen simultaneously." }
                  },
                  required: ["question", "options"]
                }
              }
            },
            required: ["questions"]
          }
        )
        @shell = shell
        @dialog = dialog || Rubik::UI::Dialog.new(shell: shell)
      end

      def execute(args = {})
        raw_questions = args["questions"] || args[:questions]
        raw_questions = [args] if raw_questions.nil? && (args["question"] || args[:question])
        return ToolOutput.error("Missing required parameter: questions (must be a non-empty array of question objects).") unless raw_questions.is_a?(Array) && raw_questions.any?

        results = []
        raw_questions.each_with_index do |q_data, idx|
          res = process_single_question(q_data, index: idx + 1)
          return res if res.is_a?(ToolOutput) && res.error?

          results << res[:text]
          break if res[:cancelled]
        end

        ToolOutput.ok(results.join("\n\n"))
      rescue StandardError => e
        ToolOutput.error("ask_question failed: #{e.message}")
      end

      private

      def process_single_question(q_data, index:)
        return ToolOutput.error("Invalid question #{index}: item must be an object with 'question' and 'options' properties.") unless q_data.is_a?(Hash)

        q_text = (q_data["question"] || q_data[:question]).to_s.strip
        raw_options = q_data["options"] || q_data[:options]
        is_multi = q_data["is_multi_select"] || q_data[:is_multi_select] || false

        return ToolOutput.error("Invalid question #{index}: question text cannot be blank.") if q_text.empty?
        return ToolOutput.error("Invalid question #{index}: must provide an array of selectable options.") unless raw_options.is_a?(Array)

        options = raw_options.map(&:to_s).map(&:strip).reject(&:empty?).uniq
        return ToolOutput.error("Invalid question #{index}: must provide at least 2 distinct non-empty selectable options.") if options.size < 2

        if @dialog.interactive?
          ask_interactively(q_text, options, is_multi)
        else
          { text: auto_select_fallback(q_text, options, is_multi), cancelled: false }
        end
      end

      def ask_interactively(q_text, options, is_multi)
        if is_multi
          ans = @dialog.ask_multi(q_text, options)
          if ans == :cancelled
            { text: "User cancelled question prompt without selection: \"#{q_text}\"", cancelled: true }
          else
            { text: "Question: \"#{q_text}\"\nUser response: #{Array(ans).inspect}", cancelled: false }
          end
        else
          ans = @dialog.ask_single(q_text, options)
          if ans == :cancelled
            { text: "User cancelled question prompt without selection: \"#{q_text}\"", cancelled: true }
          elsif ans.to_s.start_with?("Other (write-in): ")
            clean_ans = ans.to_s.sub(/\AOther \(write-in\):\s*/, "")
            { text: "Question: \"#{q_text}\"\nUser response (custom write-in): #{clean_ans}", cancelled: false }
          elsif ans.to_s.start_with?("Other (")
            { text: "Question: \"#{q_text}\"\nUser response (custom write-in): #{ans}", cancelled: false }
          else
            { text: "Question: \"#{q_text}\"\nUser response: #{ans}", cancelled: false }
          end
        end
      end

      def auto_select_fallback(q_text, options, is_multi)
        recommended = options.find { |opt| opt =~ /\A\s*\(recommended\)/i } || options.first
        selection = is_multi ? [recommended] : recommended
        selection_label = is_multi ? selection.inspect : selection

        "[Non-interactive session: automatically selected '#{selection_label}' for question: \"#{q_text}\"]"
      end
    end
  end
end

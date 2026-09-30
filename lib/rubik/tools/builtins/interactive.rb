# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../ui/dialog"
require_relative "../../coeffects"

module Rubik
  module Tools
    # Prompts the human operator with structured questions to resolve ambiguity,
    # clarify design decisions, or choose between implementation paths (Plan 92).
    # Subagent plane: when the SUBAGENT_QUESTION_ASKER coeffect is satisfied on
    # the runtime context (supervisor#spawn provides the instance into its child
    # context), the question routes to init-0 instead of a human dialog — the
    # caller blocks until init-0 answers via send_message or the question times
    # out. No REQUIRES constant on purpose: the root agent must keep the tool.
    class AskQuestionTool < BaseTool
      attr_reader :shell, :dialog

      def initialize(shell: nil, dialog: nil, runtime_context: nil)
        super(
          name: "ask_question",
          description: "Ask a structured question with selectable options — either to the human operator, " \
                       "or, from a subagent, to the init-0 supervisor (blocks until answered).",
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
        @runtime_context = runtime_context
      end

      def execute(args = {})
        raw_questions = args["questions"] || args[:questions]
        raw_questions = [args] if raw_questions.nil? && (args["question"] || args[:question])
        return ToolOutput.error("Missing required parameter: questions (must be a non-empty array of question objects).") unless raw_questions.is_a?(Array) && raw_questions.any?

        asker = init0_asker
        return ask_init0(asker, raw_questions) if asker

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

      # The subagent plane: resolves ONLY when this tool instance was bound to
      # a subagent child context (ScopedRegistry rebind); the root-context
      # instance stays nil here and keeps the human-dialog behavior.
      def init0_asker
        return nil unless @runtime_context.respond_to?(:get)

        Rubik::Coeffects.get(@runtime_context, Rubik::Coeffects::SUBAGENT_QUESTION_ASKER)
      end

      # One blocking round-trip for the whole batch: init-0 answers once and
      # the reply covers every numbered question — N sequential blocks would
      # burn the subagent's wall-clock budget for one interaction.
      def ask_init0(asker, raw_questions)
        validated = raw_questions.each_with_index.map do |q_data, idx|
          res = validate_question(q_data, index: idx + 1)
          return res if res.is_a?(ToolOutput)

          res
        end
        combined = validated.each_with_index.map do |res, idx|
          validated.size == 1 ? res[:question] : "#{idx + 1}. #{res[:question]}"
        end.join("\n")

        answer = asker.ask_init0(combined, options: validated.flat_map { |res| res[:options] }.uniq)
        if answer == :unavailable
          ToolOutput.ok("[Question routing unavailable (no supervisor channel) — proceed autonomously. Question: #{combined}]")
        elsif answer.nil?
          ToolOutput.ok("[No answer from init-0 within the question timeout — proceed with your best judgment. Question: #{combined}]")
        else
          ToolOutput.ok("Question: #{combined}\nInit-0 answered: #{answer}")
        end
      end

      def process_single_question(q_data, index:)
        parsed = validate_question(q_data, index: index)
        return parsed if parsed.is_a?(ToolOutput)

        if @dialog.interactive?
          ask_interactively(parsed[:question], parsed[:options], parsed[:is_multi])
        else
          { text: auto_select_fallback(parsed[:question], parsed[:options], parsed[:is_multi]), cancelled: false }
        end
      end

      # Shared validation for both planes; returns a question Hash or a
      # ToolOutput error.
      def validate_question(q_data, index:)
        return ToolOutput.error("Invalid question #{index}: item must be an object with 'question' and 'options' properties.") unless q_data.is_a?(Hash)

        q_text = (q_data["question"] || q_data[:question]).to_s.strip
        raw_options = q_data["options"] || q_data[:options]
        is_multi = q_data["is_multi_select"] || q_data[:is_multi_select] || false

        return ToolOutput.error("Invalid question #{index}: question text cannot be blank.") if q_text.empty?
        return ToolOutput.error("Invalid question #{index}: must provide an array of selectable options.") unless raw_options.is_a?(Array)

        options = raw_options.map(&:to_s).map(&:strip).reject(&:empty?).uniq
        return ToolOutput.error("Invalid question #{index}: must provide at least 2 distinct non-empty selectable options.") if options.size < 2

        { question: q_text, options: options, is_multi: is_multi }
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

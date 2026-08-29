# frozen_string_literal: true

require "json"
require "tempfile"

module Rubik
  module Repair
    class Loop
      attr_reader :max_attempts, :attempts_made

      def initialize(provider:, buffer_manager:, snapshot_store:, adapter_registry:, max_attempts: 3)
        @provider = provider
        @buffer_manager = buffer_manager
        @snapshot_store = snapshot_store
        @adapter_registry = adapter_registry
        @max_attempts = max_attempts
        @attempts_made = 0
      end

      def repair(diagnostics, target_file, lang = :ruby)
        @attempts_made = 0
        current_diag = diagnostics

        while @attempts_made < @max_attempts
          @attempts_made += 1

          @snapshot_store.create_snapshot(@buffer_manager)

          prompt = build_repair_prompt(current_diag, target_file, @attempts_made)
          res = @provider.complete([{ role: "user", content: prompt }])
          proposed_code = extract_code(res.text)

          @buffer_manager.write(target_file, proposed_code)

          # Verify syntax against in-memory buffer via tempfile
          check_res = check_buffer_syntax(target_file, lang)

          return { ok: true, attempts: @attempts_made, code: proposed_code } if check_res[:ok]

          current_diag = Rubik::Diagnostics::Parser.parse(check_res[:output], lang)
          @snapshot_store.undo(@buffer_manager)

        end

        { ok: false, attempts: @attempts_made, last_diagnostics: current_diag }
      end

      private

      def check_buffer_syntax(target_file, lang)
        adapter = @adapter_registry.get(lang.to_s)
        return { ok: true } unless adapter

        content = @buffer_manager.read(target_file)
        ext = File.extname(target_file)

        Tempfile.create(["rubik_repair_", ext]) do |tmp|
          tmp.write(content)
          tmp.flush
          adapter.check_syntax(tmp.path)
        end
      end

      def build_repair_prompt(diagnostics, target_file, attempt_num)
        diag_str = diagnostics.map { |d| d.format_prompt_snippet(nil, @buffer_manager.root_dir, @buffer_manager) }.join("\n\n")
        current_content = @buffer_manager.read(target_file) || ""

        <<~PROMPT
          You are repairing code that failed with compiler/test errors.
          Attempt #{attempt_num} of #{@max_attempts}.

          Target File: #{target_file}
          Current Content:
          ```
          #{current_content}
          ```

          Diagnostics:
          #{diag_str}

          Output ONLY the corrected code for #{target_file} wrapped in ```code``` blocks.
        PROMPT
      end

      def extract_code(text)
        if text.include?("```")
          text.split("```").at(1).to_s.sub(/^[a-z]+\n/, "").strip
        else
          text.strip
        end
      end
    end
  end
end

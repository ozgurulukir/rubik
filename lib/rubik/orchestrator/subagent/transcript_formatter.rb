# frozen_string_literal: true

require "fileutils"
require "json"
require "digest"
require_relative "../../security/redactor"
require_relative "../../storage/layout"

module Rubik
  module Orchestrator
    module Subagent
      # Formats and persists human-readable and JSONL subagent transcripts (Plan 94).
      module TranscriptFormatter
        # Yazma tarafı kararı: storage (absorb) verilmişse transcript proje
        # storage köküne mint edilir — worktree .rubik/'sü temiz kalır.
        # storage nil ise klasik konum (transcript_path_for) korunur.
        def self.mint_path(root_dir, id, storage: nil)
          return transcript_path_for(root_dir, id) unless storage

          Rubik::Storage::Layout.absorbed_transcript_path(storage.root, storage.project, id)
        end

        # Okuma tarafı kararı: absorbe yolu varsa o, yoksa klasik konum —
        # eski transcriptlar okunmaya devam eder. Storage yoksa klasik.
        def self.resolve(root_dir, id, storage: nil)
          return transcript_path_for(root_dir, id) unless storage

          absorbed = Rubik::Storage::Layout.absorbed_transcript_path(storage.root, storage.project, id)
          File.exist?(absorbed) ? absorbed : transcript_path_for(root_dir, id)
        end

        # Kalıcı serileştirme sözleşmesi (2026-10-10 transcript sağlığı
        # paketi): history'nin 1. satırı runtime'da kurulmuş (assembled)
        # system prompt'tur. KURULABİLİR prompt (builtin archetype'tan
        # türeyen) defaults'tan yeniden kurulabildiği için dosyaya meta
        # stub yazar: "[assembled system prompt omitted]
        # prompt_sha256=<16 hex>" (hash orijinal tam metinden). Custom tip
        # (define_custom) veya çağıranın verdiği system_prompt başka hiçbir
        # yerde kayıtlı olmadığından bire bir kopyalanır. Karar daima
        # çağıranındır (Instance#save_transcript!); save! jenerik kalır,
        # kwarg yoksa korumacı davranıp ham kopya yazar. Tüm satırlar ayrıca
        # dosyaya yazarken Redactor maskesinden geçer (root Session::Recorder
        # paritesi — hafızada ham kalır, wire sadakati korunur). In-memory
        # @history ASLA değişmez — yalnız dosyaya giden kopya dönüşür
        # (compaction ve canlı format görünümü dokunulmaz).
        def self.save!(file_path, history, monitor, prompt_reconstructible: false)
          dir = File.dirname(file_path)
          FileUtils.mkdir_p(dir)
          entries = monitor.synchronize { history.dup }
          # Dönüşüm truncate penceresinin DIŞINDA: File.open("w") açılır
          # açılmaz eski dosyayı sıfırlar — dönüşüm burada raise ederse
          # önceki iyi transcript boş dosyaya iner (review bulgusu).
          durable = durable_entries(entries, prompt_reconstructible: prompt_reconstructible)
          File.open(file_path, "w") do |f|
            durable.each { |item| f.puts(Rubik::Platform.safe_json_generate(item)) }
          end
          file_path
        rescue StandardError => e
          warn("[Subagent transcript] Failed to save #{file_path}: #{e.class}: #{e.message}")
          nil
        end

        # Satır-rolü sözleşmesi korunur: 1. satır role:"system" olarak kalır,
        # yalnız content meta stub'a iner. Diğer satırlar Redactor maskesinden
        # geçerek yeni yapı olarak akar (girdi asla mutlenmez).
        def self.durable_entries(entries, prompt_reconstructible:)
          entries.each_with_index.map do |entry, index|
            if prompt_reconstructible && index.zero? && system_row?(entry)
              { role: "system", content: system_prompt_stub(entry) }
            else
              Rubik::Security::Redactor.mask_value(entry)
            end
          end
        end

        def self.system_row?(entry)
          (entry[:role] || entry["role"]) == "system"
        end

        def self.system_prompt_stub(entry)
          content = entry[:content] || entry["content"]
          digest = Digest::SHA256.hexdigest(content.to_s)
          "[assembled system prompt omitted] prompt_sha256=#{digest[0, 16]}"
        end

        # THE single decision for where a subagent transcript lives: Instance
        # mints the path once at construction (storage id from StorageId.mint,
        # joined under its injected root_dir) and the rubik:// read handler
        # passes the URL's storage dir segment verbatim into this join. The
        # join itself cannot drift; the ROOT must simply be shared — the
        # composition root feeds the supervisor and the reader's buffer
        # manager from the same root_dir (pinned by the round-trip test's
        # root-alignment construction).
        def self.transcript_path_for(root_dir, id)
          File.join(root_dir, ".rubik", "subagents", id, "transcript.jsonl")
        end

        def self.format(instance, history, monitor)
          lines = []
          monitor.synchronize do
            lines = [
              "=== Subagent Transcript: [#{instance.id}] '#{instance.role}' (#{instance.type_name}) ===",
              "State: #{instance.state} | Steps: #{instance.current_step}/#{instance.max_steps} | Uptime: #{instance.uptime.round(2)}s",
              "Started: #{instance.started_at&.iso8601} | Ended: #{instance.ended_at&.iso8601}",
              "Model: #{instance.model || 'default'} | Workspace: #{instance.workspace}",
              "---"
            ]
            history.each { |entry| lines << format_entry(entry) }
            lines.compact!
            lines << "[No in-memory history — durable transcript: #{instance.transcript_uri}]" if history.empty?
            lines << "[LAST ERROR]\n#{instance.last_error}\n---" if instance.last_error
            lines << "[FINAL RESULT]\n#{instance.result || '(no result recorded)'}"
          end
          lines.join("\n")
        end

        def self.format_entry(entry)
          role = entry[:role] || entry["role"]
          content = entry[:content] || entry["content"]
          case role
          when "system" then "[SYSTEM PROMPT]\n#{content}\n---"
          when "user" then "[USER PROMPT]\n#{content}\n---"
          when "assistant"
            tcs = entry[:tool_calls] || entry["tool_calls"]
            tc_desc = tcs&.map { |tc| "  • #{tc['tool'] || tc[:tool]}(#{tc['args'] || tc[:args]})" }&.join("\n")
            out = []
            out << "[ASSISTANT]\n#{content}" if content && !content.empty?
            out << "[TOOL CALLS]\n#{tc_desc}" if tc_desc
            out << "---"
            out.join("\n")
          when "tool"
            t_name = entry[:tool_name] || entry["tool_name"]
            text = content.to_s
            truncated = text.length > 2000 ? "#{text.slice(0, 2000)}\n... [truncated #{text.length - 2000} chars]" : text
            "[TOOL RESULT: #{t_name}]\n#{truncated}\n---"
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "monitor"
require "time"
require_relative "../platform"

module Rubik
  module Orchestrator
    # !goal döngüsünün canlı durum anlık görüntüsü. maestro VE alt ajanlar
    # rubik://goal/state üzerinden aynı nesneyi okur; yazma yalnızca REPL
    # thread'indedir (on_step + komut sonuç dalı) ama Monitor ile kilitlenir
    # — okuma (read_file) her an güvenli olmalıdır.
    class GoalState
      # Bitiş olayının bus adı (Vakanüvis kronikçisinin goal kancası — K3;
      # REPL bu olaya abone değildir, notice/wake üretilmez).
      FINISH_EVENT = :goal_finished
      # Askı olayının bus adı (issue #106): transient transport hatası
      # goal'u terminal değil SUSPENDED'a götürür — kronikçi askıyı da
      # görsün; REPL yine abone değildir.
      SUSPEND_EVENT = :goal_suspended

      def initialize(event_bus: nil)
        @monitor = Monitor.new
        @event_bus = event_bus
        @status = :idle
        @goal = ""
        @step_count = 0
        @max_steps = 0
        @extensions = 0
        @last_error = nil
        @output_summary = nil
        @started_at = nil
        @finished_at = nil
        @tokens = { input: 0, output: 0 }
      end

      attr_reader :status, :goal, :step_count, :max_steps, :extensions,
                  :last_error, :output_summary, :started_at, :finished_at, :tokens

      # Goal-ledger planı A: son Σ revizyon satırının storage id'si — yalnız
      # goal.ledger.enabled iken !goal komutu set eder; OFF yolunda hiç set
      # edilmez (snapshot/payload/to_xml render'ları bayt-özdeş kalır).
      attr_accessor :ledger_id

      def running? = @monitor.synchronize { @status == :running }

      # SUSPENDED ≙ PENDING (AGENTS.md §2 mapping): sayaçlar korunur, sadece
      # durum flip'ler; resume ≙ Activating.
      def suspended? = @monitor.synchronize { @status == :suspended }

      # Yeni bir koşu: tekrarlanan !goal çağrılarında sıfırlar (provide swap
      # semantiğiyle eşleşir — Context#provide inverse yığmaz).
      def start!(text, max_steps)
        @monitor.synchronize do
          @goal = text.to_s
          @max_steps = max_steps.to_i
          @step_count = 0
          @extensions = 0
          @last_error = nil
          @output_summary = nil
          @tokens = { input: 0, output: 0 }
          @started_at = Time.now
          @finished_at = nil
          @status = :running
        end
        self
      end

      # Monotonik sayaç: on_step olayları bir adım içinde tekrarlanır
      # (:thinking, :llm_thought, :tool_*); geriye gitmek bir hata değil
      # sıralama gürültüsüdür — görmezden gelinir. Yükselen max (canlı
      # !steps uzatması) kabul edilir.
      def update_steps(current, max)
        @monitor.synchronize do
          @step_count = current.to_i if current.to_i >= @step_count
          @max_steps = max.to_i if max.to_i >= @max_steps
        end
      end

      def extend!(new_max)
        @monitor.synchronize do
          return self unless @status == :running

          @extensions += 1
          @max_steps = new_max.to_i if new_max.to_i > @max_steps
        end
        self
      end

      def record_tokens!(usage)
        @monitor.synchronize do
          u = usage.to_h
          @tokens[:input] += u[:input].to_i
          @tokens[:output] += u[:output].to_i
        end
        self
      end

      def complete!(output_summary = nil, tokens: nil)
        @monitor.synchronize do
          return self unless @status == :running

          @output_summary = output_summary.to_s.split("\n").first.to_s.slice(0, 200)
          finish_unlocked!(:completed, tokens)
        end
        notify_finish
        self
      end

      def fail!(error, tokens: nil)
        @monitor.synchronize do
          return self unless @status == :running

          @last_error = Rubik::Platform.safe_utf8(error.to_s).slice(0, 300)
          finish_unlocked!(:failed, tokens)
        end
        notify_finish
        self
      end

      def stop!(reason)
        @monitor.synchronize do
          return self unless @status == :running

          @last_error = Rubik::Platform.safe_utf8(reason.to_s).slice(0, 300)
          finish_unlocked!(:stopped, nil)
        end
        notify_finish
        self
      end

      # Askıya alma (issue #106): terminal DEĞİLDİR — sayaçlar korunur,
      # finished_at yazılmaz, status :suspended olur ve :goal_suspended
      # olayı düşer. Terminal yollarla aynı :running guard'ı taşır: çift
      # askı / askı-sonrası terminal yarışlarında sessiz no-op.
      def suspend!(reason, tokens: nil)
        @monitor.synchronize do
          return self unless @status == :running

          @last_error = Rubik::Platform.safe_utf8(reason.to_s).slice(0, 300)
          t = tokens.to_h
          @tokens[:input] += t[:input].to_i
          @tokens[:output] += t[:output].to_i
          @status = :suspended
        end
        notify_suspend
        self
      end

      # !goal resume'un Activating adımı: SUSPENDED → RUNNING, sayaçlar ve
      # started_at dokunulmaz (aynı koşunun devamı), askı sebebi temizlenir.
      def resume!
        @monitor.synchronize do
          return self unless @status == :suspended

          @last_error = nil
          @status = :running
        end
        self
      end

      # Çapraz-süreç resume (issue #106 Faz 2a): yeni GoalState örneğine Σ
      # damgasındaki mutlak sayaçlar geri yüklenir. start!'ın sıfırlama
      # sözleşmesini AŞAR — yalnız resume handler'ı çağırır. tokens hem
      # sembol hem dizge anahtarı kabul eder (damga JSON roundtrip'i
      # dizgeleştirir).
      def restore_counters!(steps:, max_steps:, extensions: 0, tokens: {})
        @monitor.synchronize do
          @step_count = steps.to_i
          @max_steps = max_steps.to_i
          @extensions = extensions.to_i
          t = tokens.to_h
          @tokens = { input: (t[:input] || t["input"]).to_i,
                      output: (t[:output] || t["output"]).to_i }
        end
        self
      end

      def snapshot
        @monitor.synchronize do
          snap = { status: @status, goal: @goal, steps: @step_count, max_steps: @max_steps,
                   extensions: @extensions, last_error: @last_error, output_summary: @output_summary,
                   started_at: @started_at, finished_at: @finished_at, tokens: @tokens.dup }
          snap[:ledger_id] = @ledger_id if @ledger_id
          snap
        end
      end

      # rubik://goal/state gövdesi (read_file çıktısı). Nitelikler yoksa
      # boş basılmaz — tüketici (LLM) boşlukla değil yoklukla muhatap olur.
      def to_xml
        s = snapshot
        esc = Rubik::Platform.method(:xml_escape)
        attrs = %(status="#{s[:status]}" steps="#{s[:steps]}" max_steps="#{s[:max_steps]}" ) +
                %(extensions="#{s[:extensions]}" started_at="#{iso(s[:started_at])}")
        attrs += %( finished_at="#{iso(s[:finished_at])}") if s[:finished_at]
        attrs += %( last_error="#{esc.call(s[:last_error])}") if s[:last_error]
        attrs += %( ledger_id="#{esc.call(s[:ledger_id])}") if s[:ledger_id]
        <<~XML.strip
          <goal_state #{attrs}>
            <goal>#{esc.call(s[:goal])}</goal>
            <tokens input="#{s[:tokens][:input]}" output="#{s[:tokens][:output]}" />
          </goal_state>
        XML
      end

      private

      # Vakanüvis goal kancası (K3): bitiş anlık görüntüsünü bus'a GÖNDERİR
      # (post — senkron drain yok, monitor kapanışından SONRA çağrılır).
      # REPL bu olaya abone değildir: notice/wake üretilmez, yalnızca
      # kronikçi (varsa) ve dmesg görür. Bus yoksa (bağımsız kullanım)
      # sessizce atlanır.
      def notify_finish
        post_lifecycle(FINISH_EVENT) do |s|
          { status: s[:status].to_s, goal: s[:goal].to_s, steps: s[:steps],
            max_steps: s[:max_steps], output_summary: s[:output_summary].to_s,
            last_error: s[:last_error].to_s }
        end
      end

      # Askı olayı (issue #106): bitişle aynı taşıma disiplini (post, REPL
      # abone değil) — kronikçi askıyı kroniğe işler.
      def notify_suspend
        post_lifecycle(SUSPEND_EVENT) do |s|
          { status: s[:status].to_s, goal: s[:goal].to_s, steps: s[:steps],
            max_steps: s[:max_steps], last_error: s[:last_error].to_s }
        end
      end

      def post_lifecycle(event)
        return unless @event_bus.respond_to?(:post)

        s = snapshot
        payload = yield s
        payload[:ledger_id] = s[:ledger_id] if s[:ledger_id]
        @event_bus.post(event, payload, subsystem: :orchestrator, level: :info)
      rescue StandardError => e
        Rubik::Log.warn(:orchestrator, "goal lifecycle event post failed: #{e.class}: #{e.message}")
      end

      # @monitor altında çağrılır — çift finish (Interrupt yarışı) no-op'tır.
      def finish_unlocked!(status, tokens)
        @status = status
        @finished_at = Time.now
        t = tokens.to_h
        @tokens[:input] += t[:input].to_i
        @tokens[:output] += t[:output].to_i
      end

      def iso(time) = time ? time.utc.iso8601 : ""
    end
  end
end

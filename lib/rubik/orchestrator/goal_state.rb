# frozen_string_literal: true

require "monitor"
require "time"
require_relative "../platform"

module Rubik
  module Orchestrator
    # !goal döngüsünün canlı durum anlık görüntüsü. init-0 VE alt ajanlar
    # rubik://goal/state üzerinden aynı nesneyi okur; yazma yalnızca REPL
    # thread'indedir (on_step + komut sonuç dalı) ama Monitor ile kilitlenir
    # — okuma (read_file) her an güvenli olmalıdır.
    class GoalState
      def initialize
        @monitor = Monitor.new
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

      def running? = @monitor.synchronize { @status == :running }

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
        self
      end

      def fail!(error, tokens: nil)
        @monitor.synchronize do
          return self unless @status == :running

          @last_error = Rubik::Platform.safe_utf8(error.to_s).slice(0, 300)
          finish_unlocked!(:failed, tokens)
        end
        self
      end

      def stop!(reason)
        @monitor.synchronize do
          return self unless @status == :running

          @last_error = Rubik::Platform.safe_utf8(reason.to_s).slice(0, 300)
          finish_unlocked!(:stopped, nil)
        end
        self
      end

      def snapshot
        @monitor.synchronize do
          { status: @status, goal: @goal, steps: @step_count, max_steps: @max_steps,
            extensions: @extensions, last_error: @last_error, output_summary: @output_summary,
            started_at: @started_at, finished_at: @finished_at, tokens: @tokens.dup }
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
        <<~XML.strip
          <goal_state #{attrs}>
            <goal>#{esc.call(s[:goal])}</goal>
            <tokens input="#{s[:tokens][:input]}" output="#{s[:tokens][:output]}" />
          </goal_state>
        XML
      end

      private

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

# frozen_string_literal: true

module Rubik
  module Kernel
    SEVERITY_LEVELS = {
      emerg: 0,
      alert: 1,
      crit: 2,
      err: 3,
      warn: 4,
      notice: 5,
      info: 6,
      debug: 7
    }.freeze

    LEVEL_COLORS = {
      emerg: "\e[1;31m",
      alert: "\e[1;31m",
      crit: "\e[1;31m",
      err: "\e[31m",
      warn: "\e[33m",
      notice: "\e[36m",
      info: "\e[32m",
      debug: "\e[90m"
    }.freeze

    LEVEL_ALIASES = {
      "error" => :err,
      "warning" => :warn,
      "critical" => :crit,
      "emergency" => :emerg,
      "informational" => :info
    }.freeze

    Record = Data.define(:seq, :uptime, :subsystem, :level, :facility_id, :message, :data) do
      def format_line(color: false)
        Rubik::Kernel.format_line(self, color: color)
      end
      alias_method :formatted, :format_line
      alias_method :to_s, :format_line

      def self.format_line(record, color: false)
        Rubik::Kernel.format_line(record, color: color)
      end
    end

    def self.normalize_level(lvl)
      key = lvl.to_s.downcase.strip
      sym = LEVEL_ALIASES.fetch(key, key.to_sym)
      SEVERITY_LEVELS.key?(sym) ? sym : :info
    end

    def self.format_line(record, color: false)
      uptime_str = format("[%+12.6f]", record.uptime)
      fac = record.facility_id.to_s
      tag = fac.empty? ? "[#{record.subsystem}]" : "[#{record.subsystem}/#{fac}]"
      lvl_str = "#{record.level.to_s.upcase}:"
      lvl_fmt = color ? "#{LEVEL_COLORS[record.level.to_sym] || ''}#{lvl_str}\e[0m" : lvl_str
      "#{uptime_str} #{tag} #{lvl_fmt} #{record.message}#{payload_suffix(record)}"
    end

    # Session review B1: bus events land as message="event:<name>" with the
    # facts (which server, why it failed) in `data` — rendered nowhere. Append
    # a bounded key=value summary (6 keys, 160-char tails, flat newlines).
    # safe_utf8 first: payload values carry raw error bodies (binary/UTF-16)
    # and one poisoned record would cost the model the whole dmesg view.
    def self.payload_suffix(record)
      data = record.respond_to?(:data) ? record.data : nil
      return "" unless data.is_a?(Hash) && !data.empty?

      pairs = data.first(6).filter_map do |k, v|
        flat = begin
          Rubik::Platform.safe_utf8(v.to_s)
        rescue StandardError
          next
        end.strip.tr("\r\n", " ").squeeze(" ")
        next if flat.empty?

        flat.length > 160 ? "#{k}=...#{flat[-160, 160]}" : "#{k}=#{flat}"
      end
      pairs << "(+#{data.size - 6} more)" if data.size > 6
      pairs.empty? ? "" : " #{pairs.join(' ')}"
    end
  end
end

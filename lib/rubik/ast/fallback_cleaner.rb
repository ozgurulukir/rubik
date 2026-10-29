# frozen_string_literal: true

module Rubik
  module AST
    # Quote/comment/heredoc-aware view of Ruby source, used only by
    # RubyExtractor's Prism-less fallback scanner (Plan 54 D-7). This is
    # deliberately a "lexer-lite", not a parser: it blanks string bodies,
    # comments, regex literals, heredoc bodies, =begin/=end blocks,
    # :keyword symbol literals and everything after __END__ so naive
    # end-matching cannot be fooled by them. Known, accepted limits:
    # %-literals (%w[end]), multiple heredocs per line, char classes
    # containing slashes inside regexes, and `x <<identifier` (no space)
    # being read as a heredoc.
    module FallbackCleaner
      SYMBOL_KEYWORDS = /:(?:class|module|def|do|if|unless|case|begin|while|for|until|end)\b/
      HEREDOC_START = /\A<<([~-]?)([A-Za-z_]\w*)/
      REGEX_PRECEDERS = "(=,~!&|{[;:^"
      REGEX_KEYWORDS = ["and", "begin", "case", "do", "else", "elsif", "if", "not", "or", "return", "then", "unless", "until", "while"].freeze

      module_function

      def code_lines(raw_lines)
        cleaned = []
        quote = nil
        terminator = nil
        cut = false

        raw_lines.each do |raw|
          if cut || terminator
            terminator = nil if heredoc_closed?(raw, terminator)
            cleaned << blank(raw)
          elsif raw.match?(/\A\s*=/) # =begin/=end block comments
            cleaned << blank(raw)
          else
            line, quote, terminator = clean_line(raw, quote)
            cleaned << blank_symbol_keywords(line)
          end

          cut = true if !cut && terminator.nil? && cleaned.last.strip == "__END__"
        end
        cleaned
      end

      # Cleans one line of code. Returns [cleaned_line, open_quote,
      # heredoc_terminator]; an open quote carries across lines so
      # multi-line string bodies are blanked too. Delimiters are kept,
      # contents are blanked; comments and heredoc openers blank the rest
      # of the line, regex literals blank their span.
      def clean_line(raw, quote)
        out = +""
        i = 0
        while i < raw.length
          ch = raw[i]
          if quote
            if ch == "\\" && i + 1 < raw.length
              out << "  "
              i += 2
              next
            end
            quote = nil if ch == quote
            out << (quote ? " " : ch)
            i += 1
          elsif ch == "/" && (fin = regex_span_end(raw, i))
            out << blank(raw[i..fin])
            i = fin + 1
          elsif ch == "?" && "\"'`".include?(raw[i + 1].to_s) # ?" ?' ?` char literals
            out << raw[i, 2]
            i += 2
          else
            case ch
            when "#"
              out << blank(raw[i..])
              return [out, quote, nil]
            when '"', "'", "`"
              quote = ch
              out << ch
              i += 1
            when "<"
              heredoc = heredoc_at(raw, i)
              return [out << blank(raw[i..]), nil, heredoc] if heredoc

              out << ch
              i += 1
            else
              out << ch
              i += 1
            end
          end
        end
        [out, quote, nil]
      end

      def blank(str)
        " " * str.length
      end

      # Returns [terminator_id, indent_allowed] when raw[pos..] opens a
      # heredoc, else nil.
      def heredoc_at(raw, pos)
        m = raw[pos..].match(HEREDOC_START)
        [m[2], m[1] != ""] if m
      end

      # A plain <<EOS heredoc only terminates at column zero; <<-/<<~
      # allow an indented terminator.
      def heredoc_closed?(raw, terminator)
        id, indent_allowed = terminator
        return false unless raw.strip == id

        indent_allowed || raw !~ /\A[ \t]/
      end

      # Index of the closing "/" of a regex literal opened at raw[start],
      # nil when the "/" is division rather than an opener.
      def regex_span_end(raw, start)
        return nil unless regex_context?(raw, start)

        j = start + 1
        while j < raw.length
          j += 1 if raw[j] == "\\"
          break if raw[j] == "/"

          j += 1
        end
        [j, raw.length - 1].min
      end

      # Crude regex-opener detection: a "/" starts a regex when the previous
      # significant char is an operator/opening bracket, line start, or one
      # of the keywords that takes a bare expression.
      def regex_context?(raw, start)
        k = start - 1
        k -= 1 while !k.negative? && " \t\n".include?(raw[k])
        return true if k.negative?
        return true if REGEX_PRECEDERS.include?(raw[k])

        word_start = k
        word_start -= 1 while word_start >= 0 && raw[word_start].match?(/\w/)
        REGEX_KEYWORDS.include?(raw[(word_start + 1)..k])
      end

      def blank_symbol_keywords(line)
        line.gsub(SYMBOL_KEYWORDS) { |m| " " * m.length }
      end
    end
  end
end

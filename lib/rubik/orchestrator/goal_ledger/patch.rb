# frozen_string_literal: true

require "json"

module Rubik
  module Orchestrator
    module GoalLedger
      # ΔΣ patch'i için immutable value object — RFC 6902 alt kümesi
      # (add/replace/remove; move/copy/test bilinçli dışarıda). Parse ASLA
      # raise etmez: her başarısızlık model-okunur reason verisidir, çünkü
      # model girdisinde "her başarısızlık veridir" (retry feedback'i
      # message+hint'in birebir yankısıdır).
      #
      # Doküman ve value içerikleri daima string-key JSON şekli kalır
      # (storage round-trip'inde drift olmaz); yalnızca op'un kendi kontrol
      # alanları (:op, :path, :tokens, :index) semboldür.
      class Patch
        OP_VERBS = ["add", "replace", "remove"].freeze
        OP_KEYS = ["op", "path", "value"].freeze
        HEADER_KEYS = ["rev", "ops"].freeze

        attr_reader :rev, :ops, :raw_bytesize

        def initialize(rev, ops, raw_bytesize)
          @rev = rev
          @ops = ops
          @raw_bytesize = raw_bytesize
          freeze
        end

        # -> [:ok, Patch] | [:rejected, [reason, ...]]
        def self.parse(text, max_bytes: MAX_PATCH_BYTES)
          body = Rubik::Platform.safe_utf8(text.to_s)
          if body.bytesize > max_bytes
            return [:rejected, [GoalLedger.reason(
              :syntax, op_index: nil, path: "",
                       message: "patch body is #{body.bytesize} bytes; the cap is #{max_bytes}",
                       hint: "send a smaller patch — split the work across several update calls"
            )]]
          end

          begin
            doc = JSON.parse(body)
          rescue JSON::ParserError => e
            return [:rejected, [GoalLedger.reason(
              :syntax, op_index: nil, path: "",
                       message: "invalid JSON: #{e.message.to_s.slice(0, 120)}",
                       hint: "strict JSON only: no trailing commas, no comments, quote every key and string"
            )]]
          end

          header_reasons = header_reasons(doc)
          return [:rejected, header_reasons] unless header_reasons.empty?

          rev = doc["rev"]
          unless rev.is_a?(Integer) && rev >= 0
            return [:rejected, [GoalLedger.reason(
              :schema, op_index: nil, path: "",
                       message: "rev must be a non-negative integer (got #{GoalLedger.json_type_name(rev)})",
                       hint: "send the ledger's current rev in the patch header"
            )]]
          end

          ops_in = doc["ops"]
          if !ops_in.is_a?(Array) || ops_in.empty?
            return [:rejected, [GoalLedger.reason(
              :schema, op_index: nil, path: "",
                       message: "ops must be a non-empty JSON array (got #{GoalLedger.json_type_name(ops_in)})",
                       hint: "carry at least one op — an empty patch would bump rev without changing anything"
            )]]
          end
          if ops_in.size > MAX_OPS
            return [:rejected, [GoalLedger.reason(
              :schema, op_index: nil, path: "",
                       message: "patch carries #{ops_in.size} ops; the cap is #{MAX_OPS}",
                       hint: "split the work across several update calls"
            )]]
          end

          reasons = []
          ops = []
          ops_in.each_with_index do |raw, idx|
            op, errs = normalize_op(raw, idx)
            reasons.concat(errs)
            ops << op if op
          end
          return [:rejected, reasons] unless reasons.empty?

          [:ok, new(rev, ops.freeze, body.bytesize)]
        end

        # ---- sınıf-içi (private semantik; module_function köprüsü şart değil)

        def self.header_reasons(doc)
          unless doc.is_a?(Hash)
            return [GoalLedger.reason(
              :schema, op_index: nil, path: "",
                       message: "the patch must be a single JSON object (got #{GoalLedger.json_type_name(doc)})",
                       hint: 'the patch shape is {"rev": <current ledger rev>, "ops": [ ... ]}'
            )]
          end

          reasons = []
          missing = HEADER_KEYS - doc.keys
          unknown = doc.keys - HEADER_KEYS
          unless missing.empty?
            reasons << GoalLedger.reason(
              :schema, op_index: nil, path: "",
                       message: "patch is missing the #{missing.join(', ')} key(s)",
                       hint: 'the patch header is {"rev": <current ledger rev>, "ops": [ ... ]}'
            )
          end
          unless unknown.empty?
            reasons << GoalLedger.reason(
              :schema, op_index: nil, path: "",
                       message: "unknown patch key(s) #{unknown.join(', ')}",
                       hint: "allowed top-level keys: rev, ops"
            )
          end
          reasons
        end

        def self.normalize_op(raw, idx)
          return [nil, [op_shape_reason(idx)]] unless raw.is_a?(Hash)

          unknown = raw.keys - OP_KEYS
          unless unknown.empty?
            return [nil, [GoalLedger.reason(
              :schema, op_index: idx, path: "",
                       message: "op #{idx} carries unknown key(s) #{unknown.join(', ')}",
                       hint: "allowed op keys: op, path, value"
            )]]
          end

          verb = raw["op"]
          unless OP_VERBS.include?(verb)
            return [nil, [GoalLedger.reason(
              :schema, op_index: idx, path: "",
                       message: "op #{idx} has unknown verb #{GoalLedger.json_type_name(verb)}#{verb_inspect(verb)}",
                       hint: "allowed verbs: add, replace, remove"
            )]]
          end

          path = raw["path"]
          unless path.is_a?(String)
            return [nil, [GoalLedger.reason(
              :schema, op_index: idx, path: "",
                       message: "op #{idx} path must be a JSON string (got #{GoalLedger.json_type_name(path)})",
                       hint: 'address sections with JSON pointers like "/tasks/3/status" or "/findings/-"'
            )]]
          end

          unless path.start_with?("/")
            return [nil, [GoalLedger.reason(
              :schema, op_index: idx, path: path,
                       message: "op #{idx} path '#{path}' is not a JSON pointer",
                       hint: 'pointers start with "/" — use /section, /section/idx, /section/idx/field or /section/-'
            )]]
          end

          if path == "/"
            return [nil, [GoalLedger.reason(
              :schema, op_index: idx, path: path,
                       message: "op #{idx} addresses the whole ledger root",
                       hint: "the ledger root is not replaceable; address sections individually " \
                             "(/tasks/3/status, /findings/-, ...)"
            )]]
          end

          tokens, err = tokenize(path, idx)
          return [nil, [err]] if err

          if verb == "remove" && raw.key?("value")
            return [nil, [GoalLedger.reason(
              :schema, op_index: idx, path: path,
                       message: "op #{idx} (remove) must not carry a value",
                       hint: "to change a value use replace; remove deletes the item outright"
            )]]
          end
          unless verb == "remove" || raw.key?("value")
            return [nil, [GoalLedger.reason(
              :schema, op_index: idx, path: path,
                       message: "op #{idx} (#{verb}) is missing its value",
                       hint: 'carry the value in the op: {"op": "add", "path": "/findings/-", "value": ...}'
            )]]
          end

          if hyphen_violation(tokens, verb)
            return [nil, [GoalLedger.reason(
              :schema, op_index: idx, path: path,
                       message: "op #{idx} path '#{path}' uses '-' outside an append position",
                       hint: "'-' appends and may only be the final token of an add path " \
                             "(e.g. /findings/-); use a numeric index for existing items"
            )]]
          end

          value = verb == "remove" ? nil : deep_freeze(raw["value"])
          [{ op: verb.to_sym, path: path, tokens: tokens, value: value, index: idx }.freeze, []]
        end

        def self.op_shape_reason(idx)
          GoalLedger.reason(
            :schema, op_index: idx, path: "",
                     message: "op #{idx} must be a JSON object (got non-object)",
                     hint: 'each op looks like {"op": "add", "path": "/findings/-", "value": ...}'
          )
        end

        def self.verb_inspect(verb)
          verb.is_a?(String) ? " '#{verb}'" : ""
        end

        # JSON-pointer tokenize: ~0 → ~, ~1 → / (yalnızbu iki escape meşru);
        # boş segment (//) geçersiz. Dönen dizi frozen'dır.
        def self.tokenize(path, idx)
          raw_tokens = path.split("/", -1)[1..]
          tokens = []
          raw_tokens.each do |seg|
            if seg.empty?
              return nil, GoalLedger.reason(
                :schema, op_index: idx, path: path,
                         message: "op #{idx} path '#{path}' has an empty pointer segment",
                         hint: "JSON pointers do not contain empty segments — use /section, /section/idx or /section/-"
              )
            end
            if seg.include?("~")
              unless seg.match?(/\A(?:[^~]|~0|~1)*\z/)
                return nil, GoalLedger.reason(
                  :schema, op_index: idx, path: path,
                           message: "op #{idx} path '#{path}' uses an invalid escape in '#{seg}'",
                           hint: "only ~0 (literal tilde) and ~1 (literal slash) escapes exist in JSON pointers"
                )
              end

              seg = seg.gsub("~1", "/").gsub("~0", "~")
            end
            tokens << seg
          end
          [tokens.freeze, nil]
        end

        # '-' yalnızca add path'inin SON token'ı olabilir; replace/remove
        # hiçbir konumda '-' kullanamaz.
        def self.hyphen_violation(tokens, verb)
          tokens.each_with_index do |tok, pos|
            return true if tok == "-" && !(pos == tokens.length - 1 && verb == "add")
          end
          nil
        end

        def self.deep_freeze(value)
          case value
          when Hash then value.each do |k, v|
            deep_freeze(k)
            deep_freeze(v)
          end.freeze
          when Array then value.each { |v| deep_freeze(v) }.freeze
          when String then value.dup.freeze
          else value # nil / true / false / Integer / Float zaten immutable
          end
        end

        private_class_method :header_reasons, :normalize_op, :op_shape_reason, :verb_inspect,
                             :tokenize, :hyphen_violation, :deep_freeze
      end
    end
  end
end

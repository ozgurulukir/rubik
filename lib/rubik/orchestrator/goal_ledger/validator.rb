# frozen_string_literal: true

module Rubik
  module Orchestrator
    module GoalLedger
      # Atomic validate-then-apply. Op'lar sırayla, ÖNCEKİ op'ların
      # uygulanmış olduğu working copy üzerinde valide edilir (RFC 6902
      # semantiği); fail-fast YOK — tüm op'lar teşhis edilir ki tek retry
      # her şeyi düzeltsin (bounded-retry bütçesi: DEFAULT_MAX_RETRIES;
      # retry loop'unu feature katmanı yazar). Herhangi bir reason düşerse
      # working copy ÇÖPE gider ve current_doc HİÇ dokunulmadan döner —
      # §1.A "atomic failure rollback"in veri-düzlemi ikizi. Kabul edilirse
      # rev tam olarak bir artar ve sonuç deep-frozen döner (doküman
      # cap'lidir; validator'u dökümanı sınırsız büyütecek şekilde çağırmak
      # sözleşme dışıdır).
      module Validator
        module_function

        # patch_or_text: String (önce parse edilir) | GoalLedger::Patch
        # -> [:ok, new_doc, new_rev] | [:rejected, [reason, ...]]
        # Model girdisinde ASLA raise etmez (her başarısızlık veridir);
        # yalnız programcı hatası ArgumentError'a düşer.
        def validate(patch_or_text, schema:, current_doc:)
          raise ArgumentError, "schema must be a GoalLedger::Schema" unless schema.is_a?(Schema)

          verdict = patch_or_text.is_a?(Patch) ? [:ok, patch_or_text] : Patch.parse(patch_or_text)
          return verdict unless verdict[0] == :ok

          patch = verdict[1]
          current_rev = current_doc.is_a?(Hash) ? current_doc["rev"] : nil
          unless current_rev.is_a?(Integer)
            return [:rejected, [rejection(:conflict, nil, "", "the current ledger has no integer rev",
                                          "re-read the ledger — it may not be initialized yet")]]
          end

          # :conflict — küçük-model taksonomisinin %68'i (premature state
          # overwrite) burada deterministik olarak durur; ESKİ doküman
          # korunur, model güncel rev'e karşı yeniden yazmak zorundadır.
          if patch.rev != current_rev
            return [:rejected, [rejection(:conflict, nil, "",
                                          "patch rev #{patch.rev} does not match ledger rev #{current_rev}",
                                          "re-read the ledger (rev #{current_rev}) and re-emit the patch " \
                                          "against it — your view is stale")]]
          end

          working = deep_dup(current_doc)
          reasons = []
          patch.ops.each do |op|
            # Patch.parse op değerlerini deep-frozen taşır (VO sözleşmesi);
            # working copy'ye SICAK kopyası yerleşir — yoksa sonraki op'lar
            # frozen Hash'lere yazmaya çalışır (sequential-op semantiği).
            op = { **op, value: deep_dup(op[:value]) } if op[:value]
            reasons.concat(apply_op(op, schema, working))
          end
          return [:rejected, reasons] unless reasons.empty?

          working["rev"] = current_rev + 1
          [:ok, deep_freeze(working), working["rev"]]
        end

        # ---- op dispatch ----

        def apply_op(op, schema, doc)
          head = op[:tokens][0]
          section = schema.sections[head]
          return section_op(op, head, section, doc) if section

          field = schema.root_scalars[head]
          return root_scalar_op(op, head, field, doc) if field

          patchable = schema.root_scalars.keys.reject { |key| schema.root_scalars[key].managed }
          [rejection(:schema, op[:index], op[:path], "unknown ledger section '#{head}'",
                     "known sections: #{schema.sections.keys.join(', ')}; root fields: #{patchable.join(', ')}")]
        end

        def root_scalar_op(op, name, spec, doc)
          if spec.managed
            return [rejection(:schema, op[:index], op[:path], "'#{name}' is runtime-managed",
                              "send the current rev in the patch header; the runtime writes it")]
          end

          if op[:op] == :remove
            return [rejection(:schema, op[:index], op[:path], "the '#{name}' field is required",
                              "replace it instead of removing it (#{op[:path]} with a new value)")]
          end

          err = check_value(spec, op[:value], name, op)
          return [err] if err

          doc[name] = op[:value] # add == replace, RFC 6902 üye semantiği
          []
        end

        def section_op(op, name, section, doc)
          coll = doc[name]
          unless coll.is_a?(Array)
            return [rejection(:schema, op[:index], op[:path], "section '#{name}' is not a list in the current ledger",
                              "the ledger may be corrupted — re-read it before patching")]
          end

          return [section_head_rejection(op, name)] if op[:tokens].size == 1

          return element_op(op, name, section, coll, op[:tokens][1]) if section.scalar

          item_op(op, name, section.item, coll)
        end

        # Derinlik 1 (bütünsel section yazımı) — üç fiil de yapısal red.
        def section_head_rejection(op, name)
          lead = case op[:op]
                 when :replace then "wholesale section rewrite is not allowed"
                 when :add then "cannot add the section '#{name}' itself"
                 else "sections are structural"
                 end
          rejection(:schema, op[:index], op[:path], lead,
                    "address items individually (/#{name}/3, /#{name}/-) — one op per item")
        end

        # ---- skalar liste (open_questions) ----

        def element_op(op, name, section, coll, idx_tok)
          if op[:tokens].size > 2
            return [rejection(:schema, op[:index], op[:path],
                              "paths deeper than two levels are not supported in string lists like #{name}",
                              "address elements directly (/#{name}/0, /#{name}/-)")]
          end

          spec = FieldSpec.new(type: section.scalar, max_len: section.max_len)
          if idx_tok == "-"
            return [append_only_rejection(op, name)] unless op[:op] == :add

            err = check_value(spec, op[:value], name, op)
            return [err] if err

            coll << op[:value]
            return []
          end

          idx = index_token(idx_tok, name, coll, op, insertable: op[:op] == :add)
          return [idx] unless idx.is_a?(Integer)

          err = op[:op] == :remove ? nil : check_value(spec, op[:value], name, op)
          return [err] if err

          if op[:op] == :add
            coll.insert(idx, op[:value])
          elsif op[:op] == :replace
            coll[idx] = op[:value]
          else
            coll.delete_at(idx)
          end
          []
        end

        # ---- item listesi (tasks/findings/...) ----

        def item_op(op, name, spec, coll)
          return whole_item_op(op, name, spec, coll, op[:tokens][1]) if op[:tokens].size == 2
          if op[:tokens].size > 3
            return [rejection(:schema, op[:index], op[:path],
                              "paths deeper than three levels are not supported in item lists like #{name}",
                              "address items and their fields directly (e.g. /tasks/3/status)")]
          end

          field_op(op, name, spec, coll, op[:tokens][1])
        end

        def whole_item_op(op, name, spec, coll, idx_tok)
          if idx_tok == "-"
            return [append_only_rejection(op, name)] unless op[:op] == :add

            errs = validate_item_object(spec, op[:value], name, op)
            return errs unless errs.empty?

            coll << op[:value]
            return dup_id_rejections(coll, spec, name, op)
          end

          idx = index_token(idx_tok, name, coll, op, insertable: op[:op] == :add)
          return [idx] unless idx.is_a?(Integer)

          if op[:op] == :remove
            coll.delete_at(idx)
            return []
          end

          errs = validate_item_object(spec, op[:value], name, op)
          return errs unless errs.empty?

          op[:op] == :add ? coll.insert(idx, op[:value]) : coll[idx] = op[:value]
          dup_id_rejections(coll, spec, name, op)
        end

        def field_op(op, name, spec, coll, idx_tok)
          idx = index_token(idx_tok, name, coll, op, insertable: false)
          return [idx] unless idx.is_a?(Integer)

          field_name = op[:tokens][2]
          field = spec.fields[field_name]
          unless field
            return [rejection(:schema, op[:index], op[:path], "unknown field '#{field_name}' on #{name} items",
                              "allowed fields: #{spec.fields.keys.join(', ')}")]
          end

          if op[:op] == :remove
            nullable = spec.fields.select { |_, item_field| item_field.allow_null }.keys.join(", ")
            return [rejection(:schema, op[:index], op[:path], "fields are not removable",
                              "replace with null where allowed (#{nullable}) or remove the item (/#{name}/#{idx})")]
          end

          err = check_value(field, op[:value], "#{name}.#{field_name}", op)
          return [err] if err

          coll[idx][field_name] = op[:value]
          spec.id_field == field_name ? dup_id_rejections(coll, spec, name, op) : []
        end

        # ---- değer kontrolü ----

        def check_value(spec, value, where, op)
          if value.nil? && !spec.allow_null
            parent = op[:tokens].size >= 3 ? "/#{op[:tokens][0..-2].join('/')}" : op[:path]
            return rejection(:schema, op[:index], op[:path], "#{where} does not accept null",
                             "null does not delete; use remove on the item (#{parent})")
          end
          return nil if value.nil?

          type_err = check_type(spec, value, where, op)
          return type_err if type_err

          return nil unless spec.enum && !spec.enum.include?(value)

          rejection(:schema, op[:index], op[:path],
                    "#{where} must be one of #{spec.enum.join(', ')} (got '#{value}')",
                    "pick from the allowed vocabulary")
        end

        def check_type(spec, value, where, op)
          case spec.type
          when :string
            unless value.is_a?(String)
              return rejection(:schema, op[:index], op[:path],
                               "#{where}: expected string, got #{GoalLedger.json_type_name(value)}",
                               "use JSON types — strings are quoted, integers bare")
            end
            if spec.max_len && value.length > spec.max_len
              return rejection(:schema, op[:index], op[:path],
                               "#{where} is #{value.length} chars; the cap is #{spec.max_len}",
                               "shorten the value — caps are deterministic (no stripping)")
            end
          when :integer
            unless value.is_a?(Integer)
              detail = value.is_a?(Float) ? "floats are not integers — send a whole number" : "expected integer"
              return rejection(:schema, op[:index], op[:path],
                               "#{where}: #{detail}, got #{GoalLedger.json_type_name(value)}",
                               "integers are bare numbers without a decimal point")
            end
          when :boolean
            unless value.is_a?(TrueClass) || value.is_a?(FalseClass)
              return rejection(:schema, op[:index], op[:path],
                               "#{where}: expected boolean, got #{GoalLedger.json_type_name(value)}",
                               "booleans are the bare literals true and false")
            end
          when :object
            unless value.is_a?(Hash)
              return rejection(:schema, op[:index], op[:path],
                               "#{where}: expected object, got #{GoalLedger.json_type_name(value)}",
                               "objects are brace-delimited key-value maps")
            end
          end
          nil
        end

        def validate_item_object(spec, value, name, op)
          unless value.is_a?(Hash)
            return [rejection(:schema, op[:index], op[:path],
                              "supply the full #{name} item as a JSON object (got #{GoalLedger.json_type_name(value)})",
                              "or address the field directly (#{op[:path]}/<field>, e.g. #{op[:path]}/status)")]
          end

          reasons = []
          unknown = value.keys - spec.fields.keys
          unless unknown.empty?
            reasons << rejection(:schema, op[:index], op[:path],
                                 "unknown field(s) #{unknown.join(', ')} on #{name} items",
                                 "allowed fields: #{spec.fields.keys.join(', ')}")
          end
          missing = spec.fields.reject { |fname, item_field| item_field.optional || value.key?(fname) }.keys
          unless missing.empty?
            reasons << rejection(:schema, op[:index], op[:path],
                                 "missing required field(s) #{missing.join(', ')}",
                                 "supply the full item object or address the field directly (/#{name}/3/<field>)")
          end
          value.each do |fname, item_value|
            field = spec.fields[fname]
            next unless field

            err = check_value(field, item_value, "#{name}.#{fname}", op)
            reasons << err if err
          end
          reasons
        end

        # ---- ortak yardımcılar ----

        def index_token(tok, name, coll, op, insertable:)
          unless tok.is_a?(String) && tok.match?(/\A\d+\z/)
            return rejection(:schema, op[:index], op[:path], "expected an item index in #{name}, got '#{tok}'",
                             "numeric indices address existing items; '-' appends")
          end
          idx = tok.to_i
          upper = insertable ? coll.size : coll.size - 1
          return idx if idx <= upper

          message = coll.empty? ? "#{name} is empty — nothing to address yet" : "#{name} has #{coll.size} item(s); valid indices 0-#{coll.size - 1}"
          rejection(:schema, op[:index], op[:path], message, "append via /#{name}/-")
        end

        def append_only_rejection(op, name)
          rejection(:schema, op[:index], op[:path], "'-' appends; it cannot address an existing #{name} item",
                    "use a numeric index for replace/remove")
        end

        def dup_id_rejections(coll, spec, name, op)
          return [] unless spec.id_field

          ids = coll.filter_map { |item| item.is_a?(Hash) ? item[spec.id_field] : nil }
          dups = ids.tally.select { |_, count| count > 1 }.keys
          return [] if dups.empty?

          [rejection(:schema, op[:index], op[:path], "duplicate #{name} id '#{dups.first}'; ids must be unique within #{name}",
                     "pick a fresh id (e.g. a letter prefix plus the step number)")]
        end

        def rejection(kind, op_index, path, message, hint)
          GoalLedger.reason(kind, op_index: op_index, path: path, message: message, hint: hint)
        end

        def deep_dup(value)
          case value
          when Hash then value.to_a.to_h { |key, val| [key.dup, deep_dup(val)] }
          when Array then value.map { |val| deep_dup(val) }
          else value
          end
        end

        def deep_freeze(value)
          case value
          when Hash then value.each do |key, val|
            deep_freeze(key)
            deep_freeze(val)
          end.freeze
          when Array then value.each { |val| deep_freeze(val) }.freeze
          when String then value.dup.freeze
          else value
          end
        end
      end
    end
  end
end

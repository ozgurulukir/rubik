# frozen_string_literal: true

module Rubik
  module Orchestrator
    module GoalLedger
      # Deklaratif şema VO'ları — hepsi ctor sonunda dondurulur (Struct#freeze
      # shallow kaldığı için kontrol bize ait). MEKANİZMA bu dosyanın işidir;
      # Schema.goal_skeleton yalnızca bir ÖRNEKTİR — üretim şemasını feature
      # katmanı (goal-ledger planı A) sahiplenir.
      #
      # Alan tipleri JSON dünyasındadır (:string/:integer/:boolean);
      # `optional: true` alanlar whole-item şekillerde eksik kalabilir,
      # `allow_null: true` alanlara null ATANABİLİR (null asla silmez —
      # silme yalnız remove op'udur), `managed: true` root alanlarına patch
      # pointer'ı yazamaz (rev savunması).
      class FieldSpec
        attr_reader :type, :enum, :max_len, :optional, :allow_null, :managed

        def initialize(type:, enum: nil, max_len: nil, optional: false, allow_null: false, managed: false)
          @type = type
          @enum = enum&.dup&.freeze
          @max_len = max_len
          @optional = optional
          @allow_null = allow_null
          @managed = managed
          freeze
        end
      end

      # Liste-section öğe şekli: fields (ad → FieldSpec) + id_field
      # (nil olmayan değer => koleksiyon içinde uniqueluk kuralı).
      class ItemSpec
        attr_reader :fields, :id_field

        def initialize(fields:, id_field: nil)
          @fields = fields.to_a.to_h { |name, spec| [name.dup.freeze, spec] }.freeze
          @id_field = id_field&.dup&.freeze
          freeze
        end
      end

      # Section şekli: ya item'lı liste (item:) ya da düz string listesi
      # (scalar: + max_len:). İkisi birden olmaz.
      class SectionSpec
        attr_reader :item, :scalar, :max_len

        def initialize(item: nil, scalar: nil, max_len: nil)
          raise ArgumentError, "a section is either an item list or a scalar list" if item && scalar

          @item = item
          @scalar = scalar
          @max_len = max_len
          freeze
        end
      end

      class Schema
        attr_reader :root_scalars, :sections

        def initialize(root_scalars:, sections:)
          @root_scalars = root_scalars.to_a.to_h { |name, spec| [name.dup.freeze, spec] }.freeze
          @sections = sections.to_a.to_h { |name, spec| [name.dup.freeze, spec] }.freeze
          freeze
        end

        # ÖRNEK goal şeması (C'nin ship ettiği örnek): beş section + iki root
        # skalar. `verify` alanları (tasks, environment_notes) bilinçli olarak
        # optional+allow_null taşınır — re-verification planı (B) bu alanları
        # doldurur; şema mekanizması onları şimdiden taşır.
        def self.goal_skeleton
          new(
            root_scalars: {
              "rev" => FieldSpec.new(type: :integer, managed: true),
              "objective" => FieldSpec.new(type: :string, max_len: 400)
            },
            sections: {
              "tasks" => SectionSpec.new(item: ItemSpec.new(
                fields: {
                  "id" => FieldSpec.new(type: :string, max_len: 40),
                  "title" => FieldSpec.new(type: :string, max_len: 200),
                  "status" => FieldSpec.new(type: :string, enum: ["todo", "doing", "done", "blocked"]),
                  "notes" => FieldSpec.new(type: :string, max_len: 500, optional: true, allow_null: true),
                  "verify" => FieldSpec.new(type: :string, max_len: 500, optional: true, allow_null: true)
                },
                id_field: "id"
              )),
              "findings" => SectionSpec.new(item: ItemSpec.new(
                fields: {
                  "id" => FieldSpec.new(type: :string, max_len: 40),
                  "text" => FieldSpec.new(type: :string, max_len: 800),
                  "source_step" => FieldSpec.new(type: :integer)
                },
                id_field: "id"
              )),
              "decisions" => SectionSpec.new(item: ItemSpec.new(
                fields: {
                  "id" => FieldSpec.new(type: :string, max_len: 40),
                  "text" => FieldSpec.new(type: :string, max_len: 800),
                  "rationale" => FieldSpec.new(type: :string, max_len: 500)
                },
                id_field: "id"
              )),
              "open_questions" => SectionSpec.new(scalar: :string, max_len: 400),
              "environment_notes" => SectionSpec.new(item: ItemSpec.new(
                fields: {
                  "id" => FieldSpec.new(type: :string, max_len: 40),
                  "text" => FieldSpec.new(type: :string, max_len: 800),
                  "verify" => FieldSpec.new(type: :string, max_len: 500, optional: true, allow_null: true)
                },
                id_field: "id"
              ))
            }
          )
        end
      end
    end
  end
end

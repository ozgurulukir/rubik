# frozen_string_literal: true

module Rubik
  module Orchestrator
    module GoalLedger
      # Σ XML render sayfası: rubik://goal/ledger read_file gövdesi.
      # Ledger'a include edilir — SAF render'dır (durum sahibi Ledger'da
      # kalır; bu sayfa yalnız @monitor altında okur), sayfa disiplini
      # (hygiene satır cap'leri) altındaki Ledger'ı rahatlatır.
      module XmlRender
        def to_xml
          @monitor.synchronize { render_xml }
        end

        # §4.1 render: GoalState#to_xml mold'u — tüm metin xml_escape'ten
        # geçer; boş koleksiyonların etiketi HİÇ basılmaz ("yokluk, boşluk
        # değil" kuralı); optional attribute'lar (storage_id, verify) yalnız
        # set iken basılır.
        def render_xml
          esc = Rubik::Platform.method(:xml_escape)
          attrs = %(rev="#{@doc['rev']}")
          attrs += %( storage_id="#{esc.call(@storage_id)}") if @storage_id
          attrs += %( updated_at="#{@updated_at.utc.iso8601}") if @updated_at
          body = []
          body << %(  <objective>#{esc.call(@doc['objective'].to_s)}</objective>)
          tasks = @doc["tasks"].map do |task|
            text = task["title"].to_s
            text += " — notes: #{task['notes']}" if task["notes"]
            attrs_t = %(id="#{esc.call(task['id'].to_s)}" status="#{esc.call(task['status'].to_s)}")
            attrs_t += %( verify="#{esc.call(task['verify'].to_s)}") if task["verify"]
            task["title"] || task["notes"] ? %(  <task #{attrs_t}>#{esc.call(text)}</task>) : %(  <task #{attrs_t} />)
          end
          body << "<tasks>\n#{tasks.join("\n")}\n  </tasks>" unless tasks.empty?
          findings = @doc["findings"].map do |f|
            %(  <finding id="#{esc.call(f['id'].to_s)}" source_step="#{f['source_step']}">#{esc.call(f['text'].to_s)}</finding>)
          end
          body << "<findings>\n#{findings.join("\n")}\n  </findings>" unless findings.empty?
          decisions = @doc["decisions"].map do |dec|
            attrs_d = %(id="#{esc.call(dec['id'].to_s)}")
            attrs_d += %( rationale="#{esc.call(dec['rationale'].to_s)}") if dec["rationale"]
            %(  <decision #{attrs_d}>#{esc.call(dec['text'].to_s)}</decision>)
          end
          body << "<decisions>\n#{decisions.join("\n")}\n  </decisions>" unless decisions.empty?
          questions = @doc["open_questions"].map { |q| %(  <question>#{esc.call(q.to_s)}</question>) }
          body << "<open_questions>\n#{questions.join("\n")}\n  </open_questions>" unless questions.empty?
          notes = @doc["environment_notes"].map do |note|
            attrs_n = %(id="#{esc.call(note['id'].to_s)}")
            attrs_n += %( verify="#{esc.call(note['verify'].to_s)}") if note["verify"]
            %(  <note #{attrs_n}>#{esc.call(note['text'].to_s)}</note>)
          end
          body << "<environment_notes>\n#{notes.join("\n")}\n  </environment_notes>" unless notes.empty?
          <<~XML.strip
            <goal_ledger #{attrs}>
            #{body.join("\n")}
            </goal_ledger>
          XML
        end
      end
    end
  end
end

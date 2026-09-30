# frozen_string_literal: true

require "json"

module Rubik
  module Storage
    # Okuma düzlemi biçimlendiricisi: rubik://storage URI'leri read_file
    # üzerinden okunduğunda insan/ajan-okur markdown, ".json" ekinde ham
    # JSON üretilir. Yazı katmanı (Store) hash döndürür; biçim burada kalır.
    module Render
      module_function

      def entity(record, project:)
        <<~MD
          # #{record['id']}

          **Type:** #{record['type']} · **Row:** #{record['row']} · **Status:** #{record['status']} · **Version:** #{record['version']}
          **Title:** #{record['title']}
          **Created:** #{record['created_at']} · **Updated:** #{record['updated_at']}
          **Hash:** #{record['hash']}
          **Tags:** #{Array(record['tags']).join(', ')}
          #{links_line(record)}
          **URI:** rubik://storage/#{project}/#{record['type']}/#{record['id']}

          ---

          #{record['body'].to_s.empty? ? '(no body)' : record['body']}
        MD
      end

      def listing(project:, type:, summaries:, uri_hint: nil)
        header = "# #{project}/#{type}\n\n"
        header << "_Read list entries via #{uri_hint}_\n\n" if uri_hint
        header << "| row | id | status | updated | title |\n|---|---|---|---|---|\n"
        return header << "_(empty — no #{type} entities yet)_\n" if summaries.empty?

        summaries.each do |s|
          title = s[:title].to_s.gsub("|", "\\|").slice(0, 80)
          header << "| #{s[:row]} | `#{s[:id]}` | #{s[:status]} | #{s[:updated_at]} | #{title} |\n"
        end
        header
      end

      def project(project_name, summary)
        counts = summary["entity_counts"].to_h.map { |t, n| "#{t}: #{n}" }.join(", ")
        refs = summary["refs"].to_h.map { |k, v| "#{k} → #{v}" }.join("; ")
        <<~MD
          # Storage project: #{project_name}

          **Path:** #{summary['path']}
          **Entities:** #{counts.empty? ? '(none)' : counts}
          **Created:** #{summary['created_at']} · **Updated:** #{summary['updated_at']}
          **Refs:** #{refs.empty? ? '(none)' : refs}
        MD
      end

      def index(snapshot)
        out = +"# Rubik storage central index\n\n"
        out << "**Root updated:** #{snapshot['updated_at'] || '(never written)'}\n\n"
        projects = snapshot["projects"].to_h
        return out << "_(no projects registered yet)_\n" if projects.empty?

        out << "| project | entities | updated |\n|---|---|---|\n"
        projects.sort.each do |name, entry|
          total = entry["entity_counts"].to_h.values.sum
          out << "| #{name} | #{total} (#{entry['entity_counts'].to_h.map { |t, n| "#{t}=#{n}" }.join(' ')}) | #{entry['updated_at']} |\n"
        end
        out
      end

      def links_line(record)
        links = record["links"].to_h
        links.empty? ? "**Links:** (none)" : "**Links:** #{links.map { |k, v| "#{k}=#{v}" }.join(', ')}"
      end
    end
  end
end

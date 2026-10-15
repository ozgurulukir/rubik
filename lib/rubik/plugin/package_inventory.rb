# frozen_string_literal: true

require "digest"

module Rubik
  module Plugin
    # Containment + inventory policy for directory plugin packages
    # (issue #144). A package is the set of regular files under its root,
    # each identified by a package-relative POSIX path and a SHA-256 of its
    # content; that inventory is the consent snapshot recorded at `!plugin
    # add` time and the thing verification compares against. Symlinks can
    # escape the package and special files are not content, so both are
    # violations — add and verify fail closed on them.
    module PackageInventory
      class Violation < StandardError; end

      module_function

      def inventory(dir)
        files = {}
        walk(dir) do |rel, full|
          files[rel] = file_hash(full)
        end
        files
      end

      # nil when the tree is clean; a violation message otherwise (used to
      # refuse an add before anything is copied).
      def violation(dir)
        walk(dir)
        nil
      rescue Violation => e
        e.message
      end

      # Audits additions, deletions, and modifications: any drift means the
      # package no longer matches the consented inventory.
      def drift(expected, current)
        added = current.keys - expected.keys
        removed = expected.keys - current.keys
        modified = (current.keys & expected.keys).reject { |f| current[f] == expected[f] }

        parts = []
        parts << "added: #{added.sort.join(', ')}" unless added.empty?
        parts << "removed: #{removed.sort.join(', ')}" unless removed.empty?
        parts << "modified: #{modified.sort.join(', ')}" unless modified.empty?
        parts.join("; ")
      end

      def content_hash(content)
        Digest::SHA256.hexdigest(content.to_s.delete("\r"))
      end

      def file_hash(path)
        content_hash(File.binread(path))
      end

      # Recursive walk with the containment policy: only regular files and
      # directories under `dir`; symlinks and special entries raise
      # Violation so add and verify both fail closed on them.
      def walk(dir)
        base = File.expand_path(dir)
        stack = [base]
        until stack.empty?
          current = stack.pop
          Dir.children(current).sort.each do |child|
            full = "#{current}#{File::SEPARATOR}#{child}"
            rel = full.delete_prefix("#{base}#{File::SEPARATOR}").tr("\\", "/")
            raise Violation, "symlink entry is not allowed: #{rel}" if File.symlink?(full)
            raise Violation, "unsupported entry type: #{rel}" unless File.file?(full) || File.directory?(full)

            if File.directory?(full)
              stack << full
            elsif block_given?
              yield(rel, full)
            end
          end
        end
      end
    end
  end
end

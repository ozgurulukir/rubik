# frozen_string_literal: true

require "digest"
require_relative "path_validator"
require_relative "../platform"

module Rubik
  module Buffer
    # The two-phase apply transaction, extracted from Manager (issue #472):
    # per-file atomic writes with external-conflict detection — NOT a
    # multi-file transaction. On a mid-run failure the partial progress is
    # carried by ApplyFailedError: applied entries ARE on disk, the failed
    # entry stays dirty, and pending entries keep their buffer content, so
    # a retry writes only the remainder. External-modification conflicts
    # are skipped (recorded in the run report) unless policy is "overwrite".
    #
    # The transaction owns the loop and its failure semantics; workspace
    # path policy (containment, disk hashes, external-modification config)
    # is delegated to the `disk_policy` adapter, and the overlay hashes are
    # mutated in place so Manager state and the transaction stay the same
    # objects. This makes conflict/failure paths testable without the full
    # Manager dictionary API.
    class ApplyTransaction
      # A single run's outcome: paths that reached disk, externally-modified
      # paths that were skipped, and entries rejected by the path validator.
      Result = Struct.new(:applied, :conflicts, :skipped)

      # The mutable overlay state (issue #472): the Manager's live
      # buffer / dirty_files / original_hashes hashes, mutated in place.
      Overlay = Struct.new(:buffer, :dirty_files, :original_hashes)

      attr_reader :overlay

      # @param overlay [Overlay] live buffer state, mutated in place
      # @param disk_policy [#root_dir, #containment_root, #disk_hash,
      #   #external_modification_policy] workspace path policy adapter
      # @param event_bus [Rubik::EventBus, nil] apply lifecycle events
      def initialize(overlay:, disk_policy:, event_bus: nil)
        @overlay = overlay
        @disk_policy = disk_policy
        @event_bus = event_bus
      end

      # Runs the apply loop over keys already sanitized by the caller (the
      # path policy is Manager's concern). `on_finish` runs in an ensure so
      # the caller records the run report (conflicts/skipped/applied) even
      # when a mid-loop failure raises — Manager's last_conflicts /
      # last_skipped / last_applied depend on it.
      #
      # @return [Result] applied/conflicts/skipped for a completed run
      # @raise [ApplyFailedError] on the first failed write, with the
      #   structured partial-progress report attached
      def run(keys_to_apply, effective_policy, &on_finish)
        applied_paths = []
        conflicts = []
        skipped = []

        begin
          keys_to_apply.each_with_index do |rel_path, index|
            next unless overlay.dirty_files.key?(rel_path)

            unless validate_and_clean_garbage(rel_path)
              skipped << { path: rel_path, reason: :path_validator_rejected }
              next
            end

            if external_conflict?(rel_path) && effective_policy != "overwrite"
              conflicts << rel_path
              @event_bus&.emit(:buffer_apply_conflict, paths: conflicts.dup.freeze, path: rel_path)
              next
            end

            apply_single_entry(rel_path, index: index, keys_to_apply: keys_to_apply,
                                         applied_paths: applied_paths, conflicts: conflicts, skipped: skipped)
          end
        ensure
          on_finish.call(applied_paths, conflicts, skipped)
        end

        Result.new(applied_paths, conflicts, skipped)
      end

      private

      def validate_and_clean_garbage(rel_path)
        return true if PathValidator.valid?(rel_path)

        overlay.dirty_files.delete(rel_path)
        overlay.buffer.delete(rel_path)
        overlay.original_hashes.delete(rel_path)
        @event_bus&.emit(:buffer_garbage_skipped, path: rel_path)
        false
      end

      def external_conflict?(rel_path)
        baseline = overlay.original_hashes[rel_path]
        current_disk = @disk_policy.disk_hash(rel_path)

        if baseline
          current_disk != baseline
        else
          !current_disk.nil?
        end
      end

      def apply_single_entry(rel_path, index:, keys_to_apply:, applied_paths:, conflicts:, skipped:)
        full_path = File.expand_path(rel_path, @disk_policy.root_dir)

        # TOCTOU close: re-verify containment immediately before the
        # atomic write — a symlink planted between write-time sanitize
        # and apply! must not redirect the write outside the workspace.
        # Fail loud: an untrustworthy path is an attack signal or a
        # mid-flight root misconfiguration, not a content problem; the
        # entry stays dirty for a retry after remediation.
        containment_kind, = @disk_policy.containment_root(full_path)
        unless containment_kind
          @event_bus&.emit(:buffer_containment_blocked, path: rel_path)
          raise apply_failure(
            "Write blocked: '#{rel_path}' resolves outside all allowed roots at apply time " \
            "(possible symlink swap since buffering). Re-verify the workspace and retry.",
            kind: :containment_blocked, applied: applied_paths, failed: rel_path,
            pending: pending_after(keys_to_apply, index), conflicts: conflicts, skipped: skipped
          )
        end

        content = overlay.buffer[rel_path]

        begin
          Rubik::Platform.atomic_write(full_path, content)
        rescue StandardError => e
          raise apply_failure(
            "Apply failed for '#{rel_path}': #{e.class}: #{e.message}; " \
            "#{applied_paths.empty? ? 'no file was written' : "already written: #{applied_paths.join(', ')}"}; " \
            "#{pending_after(keys_to_apply, index).size} file(s) still dirty",
            kind: :write_failed, applied: applied_paths, failed: rel_path,
            pending: pending_after(keys_to_apply, index), conflicts: conflicts, skipped: skipped
          ), cause: e
        end

        overlay.original_hashes[rel_path] = Digest::SHA256.hexdigest(content)
        overlay.dirty_files.delete(rel_path)
        overlay.buffer.delete(rel_path)
        applied_paths << rel_path
      end

      # Build the structured partial-apply error with frozen report copies —
      # a reader must see the state at raise time, not later mutations.
      def apply_failure(message, kind:, applied:, failed:, pending:, conflicts:, skipped: [])
        ApplyFailedError.new(
          message, kind: kind,
                   applied: applied.dup.freeze, failed: failed,
                   pending: pending.dup.freeze, conflicts: conflicts.dup.freeze,
                   skipped: skipped.dup.freeze
        )
      end

      # This run's remaining dirty entries after the failed index — exactly
      # what a retry will still have to write (garbage-skipped entries are
      # already out of dirty_files when this runs).
      def pending_after(keys, index)
        keys[(index + 1)..].to_a.select { |k| overlay.dirty_files.key?(k) }
      end
    end
  end
end

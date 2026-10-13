# frozen_string_literal: true

require_relative "transcript_reader"

module Rubik
  module Orchestrator
    module Subagent
      # Execution-keyed read seams (issues #122/#123): resolve an execution by
      # its unique storage id and serve its canonical transcript pages. Kept
      # out of supervisor.rb to stay under the module-hygiene cap; the
      # supervisor includes it and owns the state these methods read.
      module ExecutionReads
        # Tombstones included: a reaped execution stays addressable within
        # retention. Display ids restart every process — storage ids are the
        # durable address, so lookup keys on storage_id, never on the id.
        def find_by_storage_id(storage_id)
          sid = storage_id.to_s
          return nil if sid.empty?

          @monitor.synchronize do
            (@instances.values + (@finished || {}).values).find do |inst|
              inst.respond_to?(:storage_id) && inst.storage_id.to_s == sid
            end
          end
        end

        # Was this execution ever known to the runtime? Distinguishes an
        # expired (reaped + transcript gone) address from an unknown one; the
        # result archive keeps the last bounded proof after tombstone eviction.
        def execution_tracked?(storage_id)
          sid = storage_id.to_s
          return true if find_by_storage_id(sid)

          @result_archive.respond_to?(:known?) && @result_archive.known?(sid)
        end

        # The canonical transcript read seam (issue #123): the supervisor owns
        # both planes (roster + root/storage resolution), so one call serves
        # live memory or the persisted snapshot with snapshot-stable pages.
        def read_transcript(storage_id, cursor: 0, limit: nil, snapshot: nil)
          sid = storage_id.to_s
          Rubik::Orchestrator::Subagent::TranscriptReader.read(
            storage_id: sid, instance: find_by_storage_id(sid), root_dir: @root_dir, storage: absorb_storage,
            tracked: execution_tracked?(sid), cursor: cursor, limit: limit, snapshot: snapshot
          )
        end
      end
    end
  end
end

# frozen_string_literal: true

module Rubik
  module LSP
    # Owns the four per-document state hashes of LSP::Client (issue #406):
    #
    #   open_documents     path -> open version
    #   document_contents  path -> full text of the open document
    #   diagnostic_states  path -> { state:, document_version:, published_version: }
    #   diagnostics        path -> last published diagnostics array
    #
    # ## Lock discipline — the single home of the LSP lock-order invariant
    #
    # This class creates no locks of its own. The owning Client must hold its
    # document mutex across EVERY call into this store — that is the only
    # synchronization for open_documents / document_contents. The diagnostic
    # hashes share the client's protocol mutex and its condition variable,
    # injected here as diagnostic_mutex / diagnostics_cv: this store acquires
    # the diagnostics mutex for every diagnostic read/write and broadcasts the
    # condition variable under that same hold, so waiters can never miss a
    # wakeup (Client#wait_for_diagnostics waits on the same pair).
    #
    # The resulting global acquisition order — and the only legal one — is:
    #
    #   document_mutex -> write_mutex -> diagnostics mutex
    #
    # write_mutex sits between the two because transport writes happen inside
    # document transitions and write_message's failure path takes the
    # diagnostics mutex. No call site may re-derive this order: document state
    # flows exclusively through this store.
    class DocumentStore
      # Per-path pre-transition state. A nil field means "path absent before
      # the transition", so the restore deletes instead of writing.
      Snapshot = Struct.new(:version, :content, :state, :diagnostics)

      def initialize(diagnostic_mutex, diagnostics_cv)
        @diagnostic_mutex = diagnostic_mutex
        @diagnostics_cv = diagnostics_cv
        @open_documents = {}
        @document_contents = {}
        @diagnostic_states = {}
        @diagnostics = {}
        @version_counter = 0
      end

      # Start-of-session reset (Client#start): drop every document and
      # diagnostic trace and restart the version counter at zero.
      def reset
        @open_documents.clear
        @document_contents.clear
        @version_counter = 0
        @diagnostic_mutex.synchronize do
          @diagnostic_states.clear
          @diagnostics.clear
        end
      end

      def open?(path)
        @open_documents.key?(path)
      end

      def content_for(path)
        @document_contents[path]
      end

      def next_version
        @version_counter += 1
      end

      # Forward mutation shared by didOpen (new document) and didChange (new
      # version of an open document): publish the version/content pair and
      # invalidate the diagnostic snapshot for the new version.
      def stage_version(path, content, version)
        @open_documents[path] = version
        @document_contents[path] = content
        @diagnostic_mutex.synchronize do
          @diagnostic_states[path] = pending_diagnostics(version)
        end
      end

      # Forward mutation of didClose: remove every trace of the document.
      def evict(path)
        @open_documents.delete(path)
        @document_contents.delete(path)
        @diagnostic_mutex.synchronize do
          @diagnostic_states.delete(path)
          @diagnostics.delete(path)
        end
      end

      # The ONE transactional helper for document transitions (issue #406):
      # capture the per-path snapshot, yield to the transport send, and on a
      # falsy result restore the snapshot in place — failed sends never leave
      # mutated document state behind. Returns the block's result. Must be
      # called with the caller's document mutex held.
      def commit(path)
        before = snapshot(path)
        sent = yield
        restore(path, before) unless sent
        sent
      end

      # Records a publishDiagnostics payload. Returns false when the payload
      # is stale relative to the currently open version (the caller discards
      # the message), true otherwise; waiters wake under the same
      # diagnostics-mutex hold that installs the new state.
      def record_diagnostics(path, published, version)
        current = @open_documents[path]
        return false if version.is_a?(Numeric) && current && version < current

        @diagnostic_mutex.synchronize do
          @diagnostics[path] = published
          @diagnostic_states[path] = {
            state: version.is_a?(Numeric) ? :fresh : :unversioned,
            document_version: current,
            published_version: version
          }
          @diagnostics_cv.broadcast
        end
        true
      end

      def all_diagnostics
        @diagnostic_mutex.synchronize { @diagnostics.dup }
      end

      def diagnostic_snapshot(path)
        @diagnostic_mutex.synchronize { build_snapshot(path) }
      end

      # Blocks while the document's diagnostic state is :pending, waking on
      # each publish/broadcast, then returns the final snapshot.
      def await_diagnostics(path, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @diagnostic_mutex.synchronize do
          while @diagnostic_states[path]&.dig(:state) == :pending
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            @diagnostics_cv.wait(@diagnostic_mutex, remaining)
          end
          build_snapshot(path)
        end
      end

      def all_diagnostic_snapshots
        @diagnostic_mutex.synchronize do
          @diagnostic_states.each_with_object({}) do |(path, state), result|
            result[path] = {
              state: state[:state],
              diagnostics: (@diagnostics[path] || []).dup,
              document_version: state[:document_version],
              published_version: state[:published_version]
            }
          end
        end
      end

      private

      # Reads the per-path state across all four hashes. open_documents /
      # document_contents are read directly (the caller holds the document
      # mutex); the diagnostic pair shares one diagnostics-mutex hold.
      def snapshot(path)
        state, published = @diagnostic_mutex.synchronize do
          [@diagnostic_states[path], @diagnostics[path]]
        end
        Snapshot.new(@open_documents[path], @document_contents[path], state, published)
      end

      # Writes the captured pre-transition state back. nil fields mean the
      # path was absent before, so the entry is deleted again.
      def restore(path, before)
        restore_entry(@open_documents, path, before.version)
        restore_entry(@document_contents, path, before.content)
        @diagnostic_mutex.synchronize do
          restore_entry(@diagnostic_states, path, before.state)
          restore_entry(@diagnostics, path, before.diagnostics)
        end
      end

      def restore_entry(hash, path, value)
        if value
          hash[path] = value
        else
          hash.delete(path)
        end
      end

      def build_snapshot(path)
        state = @diagnostic_states[path]
        {
          state: state ? state[:state] : :unavailable,
          diagnostics: (@diagnostics[path] || []).dup,
          document_version: state && state[:document_version],
          published_version: state && state[:published_version]
        }
      end

      def pending_diagnostics(version)
        {
          state: :pending,
          document_version: version,
          published_version: nil
        }
      end
    end
  end
end

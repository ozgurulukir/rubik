# frozen_string_literal: true

module Rubik
  module Concurrency
    # Monotonic min-heap of fiber wakeups. Entries are
    # [deadline, fiber, resume_value, generation]; only the EventLoop thread
    # touches this structure (timers are registered from VM hooks, which run
    # on the loop thread), so no locking is needed.
    #
    # Staleness: a timer for a fiber that has since re-parked (new park
    # generation) or been resumed dead is inert. The EventLoop passes a
    # stale? check at construction; entries failing it are pruned lazily by
    # every query, so a dead timer never gates idle-draining — without this
    # an interrupted 30 s sleep would hold the whole loop hostage until its
    # deadline despite the fiber being long gone.
    class Timers
      def initialize(&staleness)
        @staleness = staleness
        @heap = []
      end

      # Returns the stored entry (opaque; useful for diagnostics only).
      def add(deadline, fiber, resume_value, generation)
        entry = [deadline, fiber, resume_value, generation]
        @heap << entry
        sift_up(@heap.size - 1)
        entry
      end

      def empty?
        prune!
        @heap.empty?
      end

      def size
        prune!
        @heap.size
      end

      # Seconds until the earliest deadline (0.0 when already due), or nil
      # when no timers are pending.
      def next_gap(now)
        return nil if empty?

        gap = @heap[0][0] - now
        gap.positive? ? gap : 0.0
      end

      # Calls sink.call(fiber, resume_value, generation) for every due entry,
      # removing it. Returns the number of entries fired. The sink decides
      # whether a stale entry actually resumes its fiber.
      def fire_due!(now, &sink)
        return 0 if empty? || sink.nil?

        fired = 0
        while !empty? && @heap[0][0] <= now
          entry = @heap[0]
          last = @heap.pop
          if @heap.empty?
            @heap << last unless last.equal?(entry)
          else
            @heap[0] = last
            sift_down(0)
          end
          sink.call(entry[1], entry[2], entry[3])
          fired += 1
        end
        fired
      end

      private

      def prune!
        return unless @staleness

        @heap.reject! { |entry| @staleness.call(entry[1], entry[3]) }
      end

      def sift_up(index)
        entry = @heap[index]
        while index.positive?
          parent = (index - 1) / 2
          break if @heap[parent][0] <= entry[0]

          @heap[index] = @heap[parent]
          index = parent
        end
        @heap[index] = entry
      end

      def sift_down(index)
        size = @heap.size
        entry = @heap[index]
        loop do
          child = (2 * index) + 1
          break if child >= size

          right = child + 1
          child = right if right < size && @heap[right][0] < @heap[child][0]
          break if @heap[child][0] >= entry[0]

          @heap[index] = @heap[child]
          index = child
        end
        @heap[index] = entry
      end
    end
  end
end

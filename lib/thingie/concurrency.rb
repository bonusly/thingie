# frozen_string_literal: true

require 'async'
require 'async/semaphore'
require 'async/barrier'
require 'kernel/sync'

module Thingie
  # Runs work over Async fibers bounded by a semaphore. Shared by the review
  # and critic passes, which both need ordered results and bounded fan-out.
  module Concurrency
    # Maps `items` to block results concurrently, preserving input order.
    # Slots start at `default`; a slot whose block never completes (barrier
    # stopped early) keeps that default. Callers wanting per-item failure
    # tolerance rescue inside the block (Reviewer) or lean on the default
    # (Verifier's fail-open).
    #
    # @param items [Array] the work items
    # @param concurrency [Integer] maximum fibers in flight
    # @param default [Object, nil] pre-filled slot value for unfinished slots
    # @yieldparam item [Object] the item to process
    # @yieldreturn [Object] the slot value for that item
    # @return [Array] block results in input order
    def self.map(items, concurrency, default: nil)
      results = Array.new(items.size, default)
      barrier = nil # declared here so it's in scope for the ensure block below

      # Sync (not Async) so the call always blocks until the barrier is
      # drained, even when invoked inside an existing reactor. Async would
      # return the scheduled task immediately and race ahead to results.
      # Barrier/semaphore are created inside the reactor so they bind to it.
      Sync do
        barrier = Async::Barrier.new
        semaphore = Async::Semaphore.new(concurrency, parent: barrier)
        items.each_with_index do |item, index|
          semaphore.async(parent: barrier) { results[index] = yield(item) }
        end
        barrier.wait # drain on normal path; wait can raise and mask errors in ensure
      ensure
        barrier&.stop
      end

      results
    end
  end
end

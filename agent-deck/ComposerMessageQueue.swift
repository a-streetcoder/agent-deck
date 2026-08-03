import Foundation

/// Pure FIFO policy for in-memory composer follow-ups while a turn is active.
///
/// `PiAgentSessionStore` owns the per-session arrays; this type only encodes
/// capacity and list mutations so unit tests do not need `@MainActor` store state.
nonisolated enum ComposerMessageQueue {
    /// Maximum queued follow-ups per session before send/enqueue is blocked.
    static let maxCount = 5

    /**
     Returns whether another item may be enqueued.

     - Parameters:
       - count: Current queue length. Required; must be ≥ 0.
       - max: Capacity ceiling. Defaults to ``maxCount``.
     - Returns: `true` when `count < max`.
     */
    static func canEnqueue(count: Int, max: Int = maxCount) -> Bool {
        count < max
    }

    /**
     Appends `item` when under capacity.

     - Parameters:
       - item: Message to enqueue. Required.
       - queue: Existing FIFO list. Required.
       - max: Capacity ceiling. Defaults to ``maxCount``.
     - Returns: Updated queue, or `nil` when full (input queue unchanged conceptually).
     */
    static func enqueue<T>(_ item: T, onto queue: [T], max: Int = maxCount) -> [T]? {
        guard queue.count < max else { return nil }
        var next = queue
        next.append(item)
        return next
    }

    /**
     Inserts `item` at the front after removing any prior copy with the same id.

     Used when a drain races with a new active turn so a dequeued item is not dropped.
     Bypasses the capacity cap.

     - Parameters:
       - item: Message to place at front. Required.
       - queue: Existing list. Required.
       - id: Stable identity for dedupe. Required.
     - Returns: Updated queue.
     */
    static func requeueAtFront<T>(
        _ item: T,
        onto queue: [T],
        id: UUID,
        idOf: (T) -> UUID
    ) -> [T] {
        var next = queue.filter { idOf($0) != id }
        next.insert(item, at: 0)
        return next
    }

    /**
     Removes the first element matching `id`.

     - Parameters:
       - id: Item identity. Required.
       - queue: Existing list. Required.
       - idOf: Identity extractor. Required.
     - Returns: `(item, remaining)` or `nil` when not found.
     */
    static func withdraw<T>(
        id: UUID,
        from queue: [T],
        idOf: (T) -> UUID
    ) -> (item: T, remaining: [T])? {
        guard let index = queue.firstIndex(where: { idOf($0) == id }) else { return nil }
        var next = queue
        let item = next.remove(at: index)
        return (item, next)
    }

    /**
     Pops the oldest item (FIFO).

     - Parameter queue: Existing list. Required.
     - Returns: `(item, remaining)` or `nil` when empty.
     */
    static func dequeueFirst<T>(from queue: [T]) -> (item: T, remaining: [T])? {
        guard let first = queue.first else { return nil }
        return (first, Array(queue.dropFirst()))
    }

    /**
     Whether a drained follow-up should be re-queued because the session became active again.

     - Parameter sessionIsActive: Session status after attempting delivery. Required.
     - Returns: `true` when the item must return to the front of the queue.
     */
    static func shouldRequeueAfterDrain(sessionIsActive: Bool) -> Bool {
        sessionIsActive
    }
}

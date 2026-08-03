import XCTest
@testable import agent_deck

@MainActor
final class ComposerMessageQueueTests: XCTestCase {
    private struct Item: Equatable {
        let id: UUID
        let text: String
    }

    func testCanEnqueueRespectsCap() {
        XCTAssertTrue(ComposerMessageQueue.canEnqueue(count: 0))
        XCTAssertTrue(ComposerMessageQueue.canEnqueue(count: 4))
        XCTAssertFalse(ComposerMessageQueue.canEnqueue(count: 5))
        XCTAssertEqual(ComposerMessageQueue.maxCount, 5)
    }

    func testEnqueueUntilFull() {
        var queue: [Item] = []
        for i in 0..<5 {
            let item = Item(id: UUID(), text: "\(i)")
            let next = ComposerMessageQueue.enqueue(item, onto: queue)
            XCTAssertNotNil(next)
            queue = next!
        }
        XCTAssertNil(ComposerMessageQueue.enqueue(Item(id: UUID(), text: "overflow"), onto: queue))
        XCTAssertEqual(queue.count, 5)
    }

    func testWithdrawAndDequeueFIFO() {
        let a = Item(id: UUID(), text: "a")
        let b = Item(id: UUID(), text: "b")
        let c = Item(id: UUID(), text: "c")
        var queue = [a, b, c]
        let withdrawn = ComposerMessageQueue.withdraw(id: b.id, from: queue, idOf: \.id)
        XCTAssertEqual(withdrawn?.item, b)
        queue = withdrawn!.remaining
        XCTAssertEqual(queue.map(\.text), ["a", "c"])
        let dequeued = ComposerMessageQueue.dequeueFirst(from: queue)
        XCTAssertEqual(dequeued?.item, a)
        XCTAssertEqual(dequeued?.remaining.map(\.text), ["c"])
    }

    func testRequeueAtFrontDedupesAndBypassesCap() {
        var items = (0..<5).map { Item(id: UUID(), text: "\($0)") }
        let extra = Item(id: UUID(), text: "front")
        items = ComposerMessageQueue.requeueAtFront(extra, onto: items, id: extra.id, idOf: \.id)
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.first?.text, "front")
        // re-insert same id moves to front without duplicating
        items = ComposerMessageQueue.requeueAtFront(extra, onto: items, id: extra.id, idOf: \.id)
        XCTAssertEqual(items.filter { $0.id == extra.id }.count, 1)
        XCTAssertEqual(items.first?.id, extra.id)
    }

    func testShouldRequeueAfterDrain() {
        XCTAssertTrue(ComposerMessageQueue.shouldRequeueAfterDrain(sessionIsActive: true))
        XCTAssertFalse(ComposerMessageQueue.shouldRequeueAfterDrain(sessionIsActive: false))
    }
}

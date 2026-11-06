import XCTest
@testable import MemoCore

final class TaskDocumentTests: XCTestCase {
    func testEmptyInputCannotCreateOrEraseTask() throws {
        var doc = TaskDocument()
        XCTAssertNil(doc.add(" \n "))
        let id = try XCTUnwrap(doc.add("  写好方案  "))
        XCTAssertFalse(doc.edit(id, text: "   "))
        XCTAssertEqual(doc.activeTasks.first?.text, "写好方案")
        try doc.validate()
    }

    func testCompleteRestoreAndReorderPreserveIdentity() throws {
        var doc = TaskDocument()
        let a = doc.add("甲")!, b = doc.add("乙")!, c = doc.add("丙")!
        doc.move(c, before: a)
        XCTAssertEqual(doc.activeOrder, [c, a, b])
        doc.setCompleted(a, true)
        XCTAssertEqual(doc.activeOrder, [c, b])
        XCTAssertEqual(doc.completedTasks.map(\.id), [a])
        doc.setCompleted(a, false)
        XCTAssertEqual(doc.activeOrder, [c, b, a])
        doc.setCompleted(a, false)
        XCTAssertEqual(doc.activeOrder, [c, b, a])
        try doc.validate()
    }

    func testBatchUndoRestoresOriginalOrderRegardlessOfDeletionSequence() throws {
        for sequence in [[1, 2], [2, 1], [3, 0, 1], [0, 1, 2, 3]] {
            var doc = TaskDocument()
            let ids = (0..<4).map { doc.add("任务 \($0)")! }
            var batch: [DeletedTask] = []
            for index in sequence { batch.append(try XCTUnwrap(doc.remove(ids[index]))) }
            doc.restore(batch)
            XCTAssertEqual(doc.activeOrder, ids)
            doc.restore(batch)
            XCTAssertEqual(doc.tasks.count, 4)
            try doc.validate()
        }
    }

    func testCompletedDeletionUndoKeepsCompletionState() throws {
        var doc = TaskDocument()
        let id = doc.add("已经完成")!
        doc.setCompleted(id, true)
        let deleted = try XCTUnwrap(doc.remove(id))
        doc.restore([deleted])
        XCTAssertTrue(doc.activeOrder.isEmpty)
        XCTAssertEqual(doc.completedTasks.map(\.id), [id])
        try doc.validate()
    }

    func testInvalidReorderDoesNotLoseTasks() throws {
        var doc = TaskDocument()
        let a = doc.add("甲")!, b = doc.add("乙")!
        doc.reorder([a, a])
        doc.reorder([b])
        doc.move(a, before: UUID())
        XCTAssertEqual(doc.activeOrder, [a, b])
        try doc.validate()
    }
}

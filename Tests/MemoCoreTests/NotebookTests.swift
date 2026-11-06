import XCTest
@testable import MemoCore

final class NotebookTests: XCTestCase {
    private func repository() throws -> NotebookRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notchmemo-notebooks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return NotebookRepository(directory: directory)
    }

    func testOnlyNonemptyFullyCompletedNoteArchivesAndGetsNewIdentity() throws {
        var book = Notebook()
        let initialID = book.current.id
        XCTAssertFalse(book.archiveCompletedCurrent())
        let a = book.current.document.add("甲")!, b = book.current.document.add("乙")!
        book.current.document.setCompleted(a, true)
        XCTAssertFalse(book.archiveCompletedCurrent())
        book.current.document.setCompleted(b, true)
        let original = book.current.document
        XCTAssertTrue(book.archiveCompletedCurrent())
        XCTAssertEqual(book.history.first?.id, initialID)
        XCTAssertEqual(book.history.first?.document, original)
        XCTAssertNotEqual(book.current.id, initialID)
        XCTAssertTrue(book.current.document.tasks.isEmpty)
        XCTAssertFalse(book.archiveCompletedCurrent())
        try book.validate()
    }

    func testDatesAndSameDaySequenceRemainStableAcrossReloadAndMidnight() throws {
        let repo = try repository()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 23, minute: 59))!
        var book = Notebook()
        for offset in [0.0, 10, 120] {
            let task = book.current.document.add("任务")!
            book.current.document.setCompleted(task, true)
            XCTAssertTrue(book.archiveCompletedCurrent(now: day.addingTimeInterval(offset), calendar: calendar))
            try repo.save(book)
            book = try repo.load().notebook
        }
        XCTAssertEqual(book.history.map(\.title), ["2026-11-06", "2026-11-06 · 2", "2026-11-07"])
        XCTAssertEqual(try repo.load().notebook, book)
    }

    func testLegacyMigrationPreservesAllTasksOrderAndOriginalBackup() throws {
        let repo = try repository()
        var document = TaskDocument()
        let a = document.add("中文 📝")!, b = document.add("已完成")!, c = document.add("长任务\n第二行")!
        document.move(c, before: a)
        document.setCompleted(b, true)
        let original = try JSONEncoder().encode(document)
        try original.write(to: repo.file)
        let loaded = try repo.load()
        XCTAssertTrue(loaded.migrated)
        XCTAssertEqual(loaded.document, document)
        try repo.save(loaded.notebook)
        try repo.save(loaded.notebook)
        XCTAssertEqual(try Data(contentsOf: repo.legacyBackup), original)
        XCTAssertFalse(try repo.load().migrated)
        XCTAssertEqual(try repo.load().document, document)
    }

    func testCorruptPrimaryRecoversHistoryAndKeepsUnreadableOriginal() throws {
        let repo = try repository()
        var book = Notebook()
        let id = book.current.document.add("历史记录")!
        book.current.document.setCompleted(id, true)
        book.archiveCompletedCurrent()
        try repo.save(book)
        let broken = Data("broken".utf8)
        try broken.write(to: repo.file)
        let loaded = try repo.load()
        XCTAssertTrue(loaded.recoveredFromBackup)
        XCTAssertEqual(loaded.notebook, book)
        try repo.save(loaded.notebook)
        let files = try FileManager.default.contentsOfDirectory(at: repo.directory, includingPropertiesForKeys: nil)
        let archived = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("tasks.unreadable-") })
        XCTAssertEqual(try Data(contentsOf: archived), broken)
    }

    func testFutureNotebookCannotBeOverwrittenOrReplacedByBackup() throws {
        let repo = try repository()
        try repo.save(Notebook())
        let future = Data("{\"version\":4,\"anotherFormat\":[]}".utf8)
        try future.write(to: repo.file)
        XCTAssertThrowsError(try repo.load())
        XCTAssertThrowsError(try repo.save(Notebook()))
        XCTAssertEqual(try Data(contentsOf: repo.file), future)
    }

    func testCustomNameSurvivesArchivingReloadAndHistoryRenameWithoutChangingDate() throws {
        let repo = try repository()
        var book = Notebook()
        let noteID = book.current.id
        XCTAssertTrue(book.renameNote(noteID, name: "  项目计划 📝  "))
        let taskID = book.current.document.add("任务")!
        book.current.document.setCompleted(taskID, true)
        book.archiveCompletedCurrent()
        let dateTitle = book.history[0].title
        XCTAssertEqual(book.history[0].displayName, "项目计划 📝")
        XCTAssertEqual(book.current.displayName, "未命名便签")
        XCTAssertNil(book.current.name)
        XCTAssertTrue(book.renameNote(noteID, name: "已完成的计划"))
        XCTAssertEqual(book.history[0].title, dateTitle)
        try repo.save(book)
        XCTAssertEqual(try repo.load().notebook, book)
        XCTAssertEqual(try repo.load().notebook.history[0].name, "已完成的计划")
    }

    func testNameRejectsBlankAndUnknownNoteAndAllowsDuplicateDisplayNames() throws {
        var book = Notebook()
        let firstID = book.current.id
        XCTAssertTrue(book.renameNote(firstID, name: "工作\n计划"))
        XCTAssertEqual(book.current.name, "工作 计划")
        XCTAssertFalse(book.renameNote(firstID, name: " \n  "))
        XCTAssertEqual(book.current.name, "工作 计划")
        XCTAssertFalse(book.renameNote(UUID(), name: "不存在"))
        let task = book.current.document.add("任务")!
        book.current.document.setCompleted(task, true)
        book.archiveCompletedCurrent()
        XCTAssertTrue(book.renameNote(book.current.id, name: "工作 计划"))
        let second = book.current.document.add("任务二")!
        book.current.document.setCompleted(second, true)
        book.archiveCompletedCurrent()
        XCTAssertEqual(Set(book.history.compactMap(\.title)).count, 2)
        try book.validate()
    }

    func testPreviousNotebookFormatWithoutNamesStillLoads() throws {
        let repo = try repository()
        var book = Notebook()
        let task = book.current.document.add("旧数据的任务")!
        book.current.document.setCompleted(task, true)
        book.archiveCompletedCurrent()
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        payload["version"] = 2
        payload.removeValue(forKey: "ongoing")
        var current = payload["current"] as! [String: Any]
        current.removeValue(forKey: "name")
        payload["current"] = current
        var history = payload["history"] as! [[String: Any]]
        for index in history.indices { history[index].removeValue(forKey: "name") }
        payload["history"] = history
        try JSONSerialization.data(withJSONObject: payload).write(to: repo.file)
        let loaded = try repo.load().notebook
        XCTAssertEqual(loaded, book)
        XCTAssertEqual(loaded.history.first?.displayName, book.history.first?.title)
    }

    func testCreatingSwitchingAndArchivingKeepOtherNotesAndReuseEmptySheet() throws {
        let repo = try repository()
        var book = Notebook()
        let first = book.current.id
        let firstTask = book.current.document.add("第一张任务")!
        let second = book.createNote()
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(book.createNote(), second)
        XCTAssertEqual(book.inProgressNotes.count, 2)
        XCTAssertTrue(book.selectInProgress(first))
        XCTAssertEqual(book.current.document.activeOrder, [firstTask])
        XCTAssertEqual(book.createNote(), second)
        let secondTask = book.current.document.add("第二张任务")!
        let empty = book.createNote()
        XCTAssertTrue(book.renameNote(first, name: "工作"))
        XCTAssertTrue(book.selectInProgress(second))
        book.current.document.setCompleted(secondTask, true)
        XCTAssertTrue(book.archiveCompletedCurrent())
        XCTAssertEqual(book.current.id, empty)
        XCTAssertEqual(book.history.map(\.id), [second])
        XCTAssertEqual(book.inProgressNotes.count, 2)
        XCTAssertTrue(book.selectInProgress(first))
        XCTAssertEqual(book.current.name, "工作")
        XCTAssertFalse(book.selectInProgress(second))
        try repo.save(book)
        XCTAssertEqual(try repo.load().notebook, book)
    }

    func testVersionTwoMigrationPreservesOriginalAndAllNotes() throws {
        let repo = try repository()
        var book = Notebook()
        _ = book.current.document.add("旧便签")
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        payload["version"] = 2
        payload.removeValue(forKey: "ongoing")
        let original = try JSONSerialization.data(withJSONObject: payload)
        try original.write(to: repo.file)
        let migrated = try repo.load()
        XCTAssertTrue(migrated.migrated)
        XCTAssertEqual(migrated.notebook, book)
        book = migrated.notebook
        book.createNote()
        try repo.save(book)
        try repo.save(book)
        XCTAssertEqual(try Data(contentsOf: repo.multiNoteBackup), original)
        XCTAssertEqual(try repo.load().notebook, book)
        XCTAssertFalse(try repo.load().migrated)
    }
    func testArchivePresentationShowsNameThenDateWithoutChangingStoredSequence() {
        var note = MemoNote()
        note.name = "项目计划 📝"
        note.title = "2026-11-06 · 6"
        XCTAssertEqual(note.archiveName, "项目计划 📝")
        XCTAssertEqual(note.archiveDateLabel, "2026-11-06")
        XCTAssertEqual(note.title, "2026-11-06 · 6")
        note.name = nil
        XCTAssertEqual(note.archiveName, "未命名便签")
        XCTAssertEqual(note.archiveDateLabel, "2026-11-06")
    }

    func testArchiveDatePresentationHandlesFirstArchiveAndDateFallback() throws {
        var note = MemoNote()
        note.title = "2026-11-06"
        XCTAssertEqual(note.archiveDateLabel, "2026-11-06")
        note.title = nil
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        note.completedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12)))
        XCTAssertEqual(note.archiveDateLabel, "2026-11-06")
        note.completedAt = nil
        XCTAssertEqual(note.archiveDateLabel, "")
    }

}

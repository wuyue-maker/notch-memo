import XCTest
import AppKit
import MemoCore
@testable import NotchMemo

@MainActor
final class MemoModelTests: XCTestCase {
    private func model() throws -> MemoModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchmemo-model-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return MemoModel(directory: url)
    }

    private func add(_ texts: [String], to model: MemoModel) -> [MemoTask] {
        for text in texts { model.draft = text; model.addDraft() }
        return model.document.activeTasks
    }

    func testRapidCompletionAndCancellationKeepVisibleAndSavedOrder() throws {
        let model = try model()
        let tasks = add(["甲", "乙", "丙"], to: model)
        model.toggle(tasks[0])
        model.toggle(tasks[1])
        XCTAssertEqual(model.visibleActiveTasks.map(\.id), tasks.map(\.id))
        model.toggle(model.document.tasks.first { $0.id == tasks[1].id }!)
        model.toggle(model.document.tasks.first { $0.id == tasks[0].id }!)
        XCTAssertEqual(model.document.activeOrder, tasks.map(\.id))
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        XCTAssertEqual(try model.repository.load().document.activeOrder, tasks.map(\.id))
    }

    func testCancelledDragRestoresOrderWhileAcceptedDragPersists() throws {
        let model = try model()
        let tasks = add(["甲", "乙", "丙"], to: model)
        model.beginDrag(tasks[2].id)
        model.moveDrag(before: tasks[0].id)
        XCTAssertEqual(model.document.activeOrder, [tasks[2].id, tasks[0].id, tasks[1].id])
        model.finishDrag(accepted: false)
        XCTAssertEqual(model.document.activeOrder, tasks.map(\.id))
        model.beginDrag(tasks[2].id)
        model.moveDrag(before: tasks[0].id)
        model.finishDrag(accepted: true)
        XCTAssertEqual(try model.repository.load().document.activeOrder, [tasks[2].id, tasks[0].id, tasks[1].id])
    }

    func testDeleteBatchUndoPersistsRestoredTasks() throws {
        let model = try model()
        let tasks = add(["甲", "乙", "丙"], to: model)
        model.delete(tasks[0].id)
        model.delete(tasks[1].id)
        XCTAssertEqual(model.deletedCount, 2)
        model.undoDeletion()
        XCTAssertEqual(model.deletedCount, 0)
        XCTAssertEqual(model.document.activeOrder, tasks.map(\.id))
        XCTAssertEqual(try model.repository.load().document.activeOrder, tasks.map(\.id))
    }

    func testUnrecoverableDataBlocksMutationsAndPreservesOriginal() throws {
        let model = try model()
        try FileManager.default.createDirectory(at: model.repository.directory, withIntermediateDirectories: true)
        let broken = Data("broken".utf8)
        try broken.write(to: model.repository.file)
        model.reload()
        XCTAssertTrue(model.storageBlocked)
        model.draft = "不能覆盖原文件"
        model.addDraft()
        model.persist()
        XCTAssertTrue(model.document.tasks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: model.repository.file), broken)
    }

    func testCheckboxStillWorksAfterAbandonedDrag() throws {
        let model = try model()
        let tasks = add(["1", "中文任务", "很长的任务内容也必须可以勾选 📝"], to: model)
        XCTAssertTrue(model.beginDrag(tasks[2].id))
        model.moveDrag(before: tasks[0].id)
        model.toggle(tasks[1])
        XCTAssertNil(model.draggingID)
        XCTAssertEqual(model.document.activeOrder, [tasks[0].id, tasks[2].id])
        XCTAssertEqual(model.document.completedTasks.map(\.id), [tasks[1].id])
        XCTAssertEqual(try model.repository.load().document.completedTasks.map(\.id), [tasks[1].id])
    }

    func testMouseReleaseRecoversMissingNativeDragEndCallback() throws {
        let model = try model()
        let tasks = add(["甲", "乙"], to: model)
        XCTAssertTrue(model.beginDrag(tasks[1].id))
        model.moveDrag(before: tasks[0].id)
        model.recoverReleasedDrag(isMouseDown: true, now: 0)
        model.recoverReleasedDrag(isMouseDown: true, now: 10)
        XCTAssertEqual(model.draggingID, tasks[1].id)
        model.recoverReleasedDrag(isMouseDown: false, now: 11)
        model.recoverReleasedDrag(isMouseDown: false, now: 11.1)
        XCTAssertEqual(model.draggingID, tasks[1].id)
        model.recoverReleasedDrag(isMouseDown: false, now: 11.3)
        XCTAssertNil(model.draggingID)
        XCTAssertEqual(model.document.activeOrder, tasks.map(\.id))
        model.toggle(tasks[0])
        XCTAssertEqual(model.document.completedTasks.map(\.id), [tasks[0].id])
    }

    func testRejectedDragCannotOverwriteAnActiveSession() throws {
        let model = try model()
        let tasks = add(["甲", "乙"], to: model)
        XCTAssertFalse(model.beginDrag(UUID()))
        XCTAssertTrue(model.beginDrag(tasks[0].id))
        model.moveDrag(before: nil)
        XCTAssertFalse(model.beginDrag(tasks[1].id))
        model.finishDrag(accepted: false)
        XCTAssertEqual(model.document.activeOrder, tasks.map(\.id))
    }

    func testEachTaskCanBeCompletedAfterReorderAndCancel() throws {
        let model = try model()
        let tasks = add(["1", "短任务", "有换行\n的任务", "📝 完成检查"], to: model)
        model.beginDrag(tasks[3].id)
        model.moveDrag(before: tasks[0].id)
        model.finishDrag(accepted: true)
        for task in tasks {
            model.toggle(task)
            XCTAssertNotNil(model.document.tasks.first(where: { $0.id == task.id })?.completedAt)
        }
        XCTAssertTrue(model.document.activeOrder.isEmpty)
        XCTAssertEqual(model.document.completedTasks.count, tasks.count)
    }

    func testTaskPreviewExpandsAndCollapsesWithoutEditingOrChangingSavedText() throws {
        let model = try model()
        let text = String(repeating: "这是一条需要完整保留的长任务，单击只展开预览。", count: 8)
        let task = add([text], to: model)[0]
        let saved = try model.repository.load().document
        let previewHeight = model.cardHeight
        XCTAssertLessThan(previewHeight, model.maxCardHeight)
        XCTAssertTrue(model.expandedTaskIDs.isEmpty)
        model.toggleTaskExpansion(task.id)
        XCTAssertTrue(model.expandedTaskIDs.contains(task.id))
        XCTAssertGreaterThan(model.cardHeight, previewHeight)
        XCTAssertNil(model.editingID)
        XCTAssertFalse(model.isInteracting)
        XCTAssertEqual(try model.repository.load().document, saved)
        model.toggleTaskExpansion(task.id)
        XCTAssertEqual(model.cardHeight, previewHeight)
        XCTAssertEqual(model.document.tasks.first?.text, text)
    }

    func testShortTasksDoNotExpandAndExplicitNewlinesCountTowardPreview() throws {
        let model = try model()
        let tasks = add(["短任务", "第一行\n第二行", "第一行\n第二行\n第三行"], to: model)
        model.toggleTaskExpansion(tasks[0].id)
        model.toggleTaskExpansion(tasks[1].id)
        XCTAssertTrue(model.expandedTaskIDs.isEmpty)
        model.toggleTaskExpansion(tasks[2].id)
        XCTAssertTrue(model.expandedTaskIDs.contains(tasks[2].id))
        XCTAssertNil(model.editingID)
    }

    func testPreviewRowsHaveEqualHeightForShortLongAndMultilineTasks() throws {
        let model = try model()
        let tasks = add(["短任务", "第一行\n第二行", String(repeating: "需要折叠的长任务内容。", count: 25)], to: model)
        let heights = tasks.map { TaskTextLayout.rowHeight(for: $0, expanded: false) }
        XCTAssertEqual(Set(heights).count, 1)
        XCTAssertEqual(heights.first, 64)
        XCTAssertGreaterThan(TaskTextLayout.rowHeight(for: tasks[2], expanded: true), heights[2])
        model.toggle(tasks[0])
        let completed = try XCTUnwrap(model.document.completedTasks.first)
        XCTAssertEqual(TaskTextLayout.rowHeight(for: completed, expanded: false), heights[0])
    }

    func testEditingAutomaticallyRevealsFullTextAndCancelRestoresPreview() throws {
        let model = try model()
        let original = String(repeating: "编辑时应当完整显示任务内容。", count: 18)
        let task = add([original], to: model)[0]
        let previewHeight = model.cardHeight
        model.beginEditing(task.id)
        XCTAssertEqual(model.editingID, task.id)
        XCTAssertEqual(model.editingDraft, original)
        XCTAssertTrue(model.expandedTaskIDs.contains(task.id))
        XCTAssertGreaterThan(model.cardHeight, previewHeight)
        model.editingDraft = "这次修改应当取消"
        model.cancelEditing(task.id)
        XCTAssertNil(model.editingID)
        XCTAssertFalse(model.expandedTaskIDs.contains(task.id))
        XCTAssertEqual(model.cardHeight, previewHeight)
        XCTAssertEqual(try model.repository.load().document.tasks.first?.text, original)
    }

    func testEditorGrowsWithDraftAndSavesAllLines() throws {
        let model = try model()
        let task = add(["短任务"], to: model)[0]
        model.beginEditing(task.id)
        let initialHeight = model.cardHeight
        let draft = (1...10).map { "第\($0)行：新增的任务内容需要完整保存。" }.joined(separator: "\n")
        model.editingDraft = draft
        XCTAssertGreaterThan(model.cardHeight, initialHeight)
        XCTAssertEqual(model.document.tasks.first?.text, "短任务")
        model.finishEdit(task.id, text: model.editingDraft)
        XCTAssertNil(model.editingID)
        XCTAssertEqual(try model.repository.load().document.tasks.first?.text, draft)
        XCTAssertGreaterThan(TaskTextLayout.editorHeight(text: "第一行\n", completed: false),
                             TaskTextLayout.editorHeight(text: "第一行", completed: false))
    }

    func testEditorSeparatesSaveNewlineAndInputMethodConfirmation() {
        XCTAssertEqual(TaskEditorView.keyAction(code: 36, modifiers: [], composing: false), .save)
        XCTAssertEqual(TaskEditorView.keyAction(code: 36, modifiers: [.shift], composing: false), .newline)
        XCTAssertEqual(TaskEditorView.keyAction(code: 76, modifiers: [.shift], composing: false), .newline)
        XCTAssertEqual(TaskEditorView.keyAction(code: 53, modifiers: [], composing: false), .cancel)
        XCTAssertEqual(TaskEditorView.keyAction(code: 36, modifiers: [], composing: true), .system)
        XCTAssertEqual(TaskEditorView.keyAction(code: 53, modifiers: [], composing: true), .system)
    }

    func testLastCheckAutomaticallyArchivesAndHistoryCannotChangeCurrentNote() async throws {
        let model = try model()
        let tasks = add(["甲", "乙"], to: model)
        model.toggle(tasks[0])
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(model.notebook.history.isEmpty)
        model.toggle(tasks[1])
        XCTAssertTrue(model.notebook.history.isEmpty) // completion animation is still visible
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(model.notebook.history.count, 1)
        XCTAssertTrue(model.document.tasks.isEmpty)
        XCTAssertTrue(model.pendingCompletions.isEmpty)
        let history = try XCTUnwrap(model.notebook.history.first)
        XCTAssertEqual(Set(history.document.tasks.map(\.id)), Set(tasks.map(\.id)))
        let current = add(["新便签的任务"], to: model)
        model.showNote(history.id)
        XCTAssertTrue(model.isViewingHistory)
        XCTAssertEqual(model.visibleActiveTasks.map(\.id), tasks.map(\.id))
        model.toggle(tasks[0])
        model.delete(tasks[0].id)
        model.beginEditing(tasks[0].id)
        XCTAssertFalse(model.beginDrag(tasks[0].id))
        model.draft = "不能写进历史"
        model.addDraft()
        XCTAssertNil(model.editingID)
        XCTAssertEqual(model.notebook.history.first, history)
        model.showNote(nil)
        XCTAssertEqual(model.document.activeTasks, current)
        let reload = MemoModel(directory: model.repository.directory)
        XCTAssertEqual(reload.notebook, model.notebook)
        XCTAssertFalse(reload.isViewingHistory)
    }

    func testTitleMenuStateClosesOnNoteActions() throws {
        let model = try model()
        XCTAssertFalse(model.isTitleMenuOpen)
        model.toggleTitleMenu()
        XCTAssertTrue(model.isTitleMenuOpen)
        XCTAssertTrue(model.isInteracting)
        model.titleMenuArchivedOpen = true
        model.closeTitleMenu()
        XCTAssertFalse(model.isTitleMenuOpen)
        XCTAssertFalse(model.titleMenuArchivedOpen)

        model.toggleTitleMenu()
        model.createNote()
        XCTAssertFalse(model.isTitleMenuOpen)

        model.toggleTitleMenu()
        model.showNote(nil)
        XCTAssertFalse(model.isTitleMenuOpen)
    }

    func testLastCheckCrumplesFinishedSheetBeforeRevealingNextNote() async throws {
        let model = try model()
        model.requestPaperSnapshot = {
            NSImage(size: NSSize(width: 368, height: 388))
        }
        let task = add(["最后一项"], to: model)[0]
        model.toggle(task)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(model.isCrumpling)
        XCTAssertEqual(model.notebook.history.count, 1)
        XCTAssertEqual(model.cardHeight, 388, accuracy: 0.5)
        try await Task.sleep(nanoseconds: 2_400_000_000)
        XCTAssertFalse(model.isCrumpling)
        XCTAssertNil(model.crumpleImage)
        XCTAssertLessThan(model.cardHeight, 388)
    }

    func testCancellingLastCheckDiscardsFrozenSheet() async throws {
        let model = try model()
        model.requestPaperSnapshot = {
            NSImage(size: NSSize(width: 368, height: 388))
        }
        let task = add(["又不想完成了"], to: model)[0]
        model.toggle(task)
        model.toggle(task)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(model.isCrumpling)
        XCTAssertEqual(model.notebook.history.count, 0)
        XCTAssertEqual(model.document.activeOrder, [task.id])
    }

    func testCancellingLastCheckDoesNotArchiveAndEmptyDeletionDoesNotCreateHistory() async throws {
        let model = try model()
        let task = add(["尚未完成"], to: model)[0]
        model.toggle(task)
        model.toggle(task)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(model.notebook.history.isEmpty)
        XCTAssertEqual(model.document.activeOrder, [task.id])
        model.delete(task.id)
        model.showNote(nil)
        XCTAssertTrue(model.notebook.history.isEmpty)
        model.undoDeletion()
        XCTAssertEqual(model.document.activeOrder, [task.id])
    }

    func testRestartFinishesPersistedLastCheckAndKeepsHistoryOnNextNoteCompletion() throws {
        let model = try model()
        let task = add(["退出前已勾选"], to: model)[0]
        model.toggle(task)
        let restarted = MemoModel(directory: model.repository.directory)
        XCTAssertEqual(restarted.notebook.history.count, 1)
        XCTAssertTrue(restarted.document.tasks.isEmpty)
        let next = add(["第二张"], to: restarted)[0]
        restarted.toggle(next)
        restarted.showNote(nil)
        XCTAssertEqual(restarted.notebook.history.count, 2)
        XCTAssertTrue(restarted.document.tasks.isEmpty)
        XCTAssertEqual(Set(restarted.notebook.history.compactMap(\.title)).count, 2)
        XCTAssertEqual(try restarted.repository.load().notebook, restarted.notebook)
    }

    func testFirstTaskAutoNamesUnnamedNoteWithFirstEightCharacters() throws {
        let model = try model()
        XCTAssertNil(model.notebook.current.name)
        model.draft = "设计首页交互动画并补齐加载反馈"
        model.addDraft()
        XCTAssertEqual(model.notebook.current.name, "设计首页交互动画")
        model.draft = "第二条任务不应该再改名"
        model.addDraft()
        XCTAssertEqual(model.notebook.current.name, "设计首页交互动画")
        XCTAssertEqual(MemoModel(directory: model.repository.directory).notebook.current.name,
                       "设计首页交互动画")
    }

    func testManualNameIsNotOverwrittenByFirstTask() throws {
        let model = try model()
        let id = model.notebook.current.id
        model.beginRenamingNote()
        model.nameDraft = "我的首页"
        model.finishRenamingNote(id)
        model.draft = "第一条任务内容"
        model.addDraft()
        XCTAssertEqual(model.notebook.current.name, "我的首页")
    }

    func testNameEditingSavesCancelsAndRejectsBlankWithoutChangingTasks() throws {
        let model = try model()
        let tasks = add(["保留原有任务"], to: model)
        let id = model.notebook.current.id
        model.beginRenamingNote()
        XCTAssertTrue(model.isInteracting)
        XCTAssertEqual(model.nameDraft, "保留原有任务") // first task names the note
        model.nameDraft = "  本周工作  "
        model.finishRenamingNote(id)
        XCTAssertFalse(model.isInteracting)
        XCTAssertEqual(try model.repository.load().notebook.current.name, "本周工作")
        model.beginRenamingNote()
        model.nameDraft = "不保存的修改"
        model.cancelRenamingNote(id)
        XCTAssertEqual(model.displayedNote.displayName, "本周工作")
        model.beginRenamingNote()
        model.nameDraft = " \n "
        model.finishRenamingNote(id)
        XCTAssertEqual(model.displayedNote.displayName, "本周工作")
        XCTAssertEqual(model.document.activeTasks, tasks)
        XCTAssertEqual(MemoModel(directory: model.repository.directory).displayedNote.displayName, "本周工作")
    }

    func testSwitchingNotesCommitsNameAndHistoryRenameKeepsCurrentNoteSeparate() throws {
        let model = try model()
        let task = add(["归档"], to: model)[0]
        let oldID = model.notebook.current.id
        model.beginRenamingNote()
        model.nameDraft = "第一张"
        model.toggle(task)
        model.showNote(nil)
        XCTAssertEqual(model.notebook.history.first?.name, "第一张")
        XCTAssertEqual(model.displayedNote.displayName, "未命名便签")
        let currentID = model.notebook.current.id
        model.beginRenamingNote()
        model.nameDraft = "当前工作"
        model.showNote(oldID)
        XCTAssertEqual(model.notebook.current.name, "当前工作")
        model.beginRenamingNote()
        model.nameDraft = "历史工作"
        model.finishRenamingNote(oldID)
        XCTAssertEqual(model.selectedHistory?.name, "历史工作")
        XCTAssertEqual(model.notebook.current.id, currentID)
        XCTAssertEqual(model.notebook.current.name, "当前工作")
        model.finishRenamingNote(currentID) // a stale editor callback cannot rename another note
        XCTAssertEqual(try model.repository.load().notebook, model.notebook)
    }

    func testNewNotesKeepEditsDraftsAndTaskListsSeparateAcrossSwitchesAndRestart() throws {
        let model = try model()
        let firstTask = add(["第一张"], to: model)[0]
        let first = model.displayedNote.id
        model.beginEditing(firstTask.id)
        model.editingDraft = "第一张已编辑"
        model.createNote()
        let second = model.displayedNote.id
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(model.newTaskFocusRequest)
        model.createNote()
        XCTAssertEqual(model.displayedNote.id, second)
        XCTAssertEqual(model.inProgressNotes.count, 2)
        _ = add(["第二张"], to: model)
        model.draft = "第二张未提交的文字"
        model.showNote(first)
        XCTAssertEqual(model.document.activeTasks.map(\.text), ["第一张已编辑"])
        XCTAssertEqual(model.draft, "")
        model.draft = "第一张草稿"
        model.showNote(second)
        XCTAssertEqual(model.draft, "第二张未提交的文字")
        model.showNote(first)
        XCTAssertEqual(model.draft, "第一张草稿")
        model.createNote()
        XCTAssertEqual(model.inProgressNotes.count, 3)
        model.showNote(first)
        XCTAssertEqual(model.document.activeTasks.map(\.text), ["第一张已编辑", "第一张草稿"])
        let restarted = MemoModel(directory: model.repository.directory)
        XCTAssertEqual(restarted.notebook, model.notebook)
        XCTAssertEqual(restarted.inProgressNotes.count, 3)
    }

    func testSwitchSettlesCompletionAndCannotCarryUndoIntoAnotherNote() async throws {
        let model = try model()
        let tasks = add(["保留", "删除"], to: model)
        let first = model.displayedNote.id
        model.createNote()
        let second = model.displayedNote.id
        let secondTask = add(["完成第二张"], to: model)[0]
        model.showNote(first)
        model.delete(tasks[1].id)
        model.showNote(second)
        XCTAssertEqual(model.deletedCount, 0)
        model.undoDeletion()
        XCTAssertEqual(model.document.activeTasks.map(\.id), [secondTask.id])
        model.toggle(secondTask)
        model.showNote(first)
        XCTAssertEqual(model.document.activeTasks.map(\.id), [tasks[0].id])
        XCTAssertEqual(model.notebook.history.map(\.id), [second])
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(model.displayedNote.id, first)
        XCTAssertEqual(model.notebook.history.count, 1)
        XCTAssertEqual(try model.repository.load().notebook, model.notebook)
    }
    func testNameWidthAcceptsEightChineseCharactersAndLimitsTheNinth() {
        let text = "一二三四五六七八九十"
        XCTAssertEqual(NoteNameLayout.fittingPrefix(text), "一二三四五六七八")
        let font = NoteNameLayout.font()
        XCTAssertLessThanOrEqual(NoteNameLayout.width(NoteNameLayout.fittingPrefix(text), font: font),
                                 NoteNameLayout.maximumWidth(font: font) + 0.01)
    }

    func testNameWidthAllowsMoreEnglishCharactersAndMeasuresDifferentGlyphs() {
        let narrow = NoteNameLayout.fittingPrefix(String(repeating: "i", count: 80))
        let wide = NoteNameLayout.fittingPrefix(String(repeating: "W", count: 80))
        let mixed = NoteNameLayout.fittingPrefix("项目A123设计方案abcdefghijk")
        XCTAssertGreaterThan(narrow.count, 8)
        XCTAssertGreaterThan(narrow.count, wide.count)
        let font = NoteNameLayout.font()
        for text in [narrow, wide, mixed] {
            XCTAssertLessThanOrEqual(NoteNameLayout.width(text, font: font), NoteNameLayout.maximumWidth(font: font) + 0.01)
        }
        XCTAssertFalse(mixed.contains("…"))
    }

    func testNameWidthKeepsEmojiGraphemesWhole() {
        let family = "👩‍👩‍👧‍👦"
        let text = String(repeating: family, count: 20)
        let fitted = NoteNameLayout.fittingPrefix(text)
        XCTAssertFalse(fitted.isEmpty)
        XCTAssertTrue(fitted.allSatisfy { String($0) == family })
        XCTAssertTrue(text.hasPrefix(fitted))
        XCTAssertFalse(fitted.contains("…"))
    }

    func testNameSaveAndLegacyDisplayUseWidthWithoutOverwritingUntouchedLegacyName() throws {
        let model = try model()
        let original = String(repeating: "很长的旧名称", count: 4)
        var book = model.notebook
        book.current.name = original
        try model.repository.save(book)
        model.reload()
        XCTAssertEqual(model.notebook.current.name, original)
        XCTAssertEqual(model.displayedNote.labelName, NoteNameLayout.fittingPrefix(original))
        model.persist()
        XCTAssertEqual(try model.repository.load().notebook.current.name, original)
        model.beginRenamingNote()
        let draft = "abcdefghijklmnopqrstuvwxyzzzz"
        model.nameDraft = draft
        model.finishRenamingNote(model.notebook.current.id)
        let expected = NoteNameLayout.fittingPrefix(draft)
        XCTAssertGreaterThan(expected.count, 8)
        XCTAssertEqual(try model.repository.load().notebook.current.name, expected)
    }

}

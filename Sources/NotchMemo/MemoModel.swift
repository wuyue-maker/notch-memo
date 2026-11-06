import AppKit
import SwiftUI
import MemoCore

@MainActor
final class MemoModel: ObservableObject {
    @Published private(set) var notebook = Notebook()
    @Published private(set) var selectedHistoryID: UUID?
    var selectedHistory: MemoNote? { notebook.history.first { $0.id == selectedHistoryID } }
    var isViewingHistory: Bool { selectedHistoryID != nil }
    var displayedNote: MemoNote { selectedHistory ?? notebook.current }
    var inProgressNotes: [MemoNote] { notebook.inProgressNotes }
    @Published private(set) var newTaskFocusRequest: UUID?
    @Published private(set) var renamingNoteID: UUID?
    @Published var nameDraft = ""
    var document: TaskDocument {
        get { selectedHistory?.document ?? notebook.current.document }
        set { guard !isViewingHistory else { return }; notebook.current.document = newValue }
    }
    @Published var isPinned = false
    @Published var isPresented = false
    @Published private(set) var noteAppearanceRevision: UInt = 0
    @Published private(set) var isCrumpling = false
    @Published private(set) var crumpleImage: NSImage?
    @Published private(set) var isTitleMenuOpen = false
    @Published var titleMenuArchivedOpen = false
    @Published var completedExpanded = false
    @Published var editingID: UUID?
    @Published var editingDraft = ""
    @Published private(set) var expandedTaskIDs: Set<UUID> = []
    @Published var draft = ""
    @Published var banner: String?
    @Published private(set) var storageBlocked = false
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var deletedCount = 0
    @Published private(set) var pendingCompletions: [UUID: Int] = [:]
    @Published private(set) var draggingID: UUID?
    @Published var dropTarget: UUID?
    @Published var topInset: CGFloat = 32
    @Published var notchWidth: CGFloat = 184
    @Published var maxCardHeight: CGFloat = 490
    var activeInput: UUID?
    let newInputID = UUID()
    let repository: NotebookRepository
    var requestClose: (() -> Void)?
    var requestResize: (() -> Void)?
    var requestNewNote: (() -> Void)?
    var requestSelectNote: ((UUID) -> Void)?
    var requestPaperSnapshot: (() -> NSImage?)?
    private var noteDrafts: [UUID: String] = [:]
    private var deleted: [DeletedTask] = []
    private var undoTimer: Timer?
    private var completionJobs: [UUID: DispatchWorkItem] = [:]
    private var crumpleJob: DispatchWorkItem?
    private var crumpleCardHeight: CGFloat?
    private var snapshotJob: DispatchWorkItem?
    private var pendingPaperSnapshot: NSImage?
    private var dragOriginalOrder: [UUID]?
    private var dragReleasedAt: TimeInterval?
    private var editingWasExpanded = false

    init(directory: URL) {
        repository = NotebookRepository(directory: directory)
        reload()
    }

    var visibleActiveTasks: [MemoTask] {
        if isViewingHistory { return document.tasks }
        var ids = document.activeOrder
        for (id, index) in pendingCompletions.sorted(by: { $0.value < $1.value }) {
            ids.insert(id, at: min(index, ids.count))
        }
        let lookup = Dictionary(uniqueKeysWithValues: document.tasks.map { ($0.id, $0) })
        return ids.compactMap { lookup[$0] }
    }

    var completedTasks: [MemoTask] {
        isViewingHistory ? [] : document.completedTasks.filter { pendingCompletions[$0.id] == nil }
    }

    var cardHeight: CGFloat {
        if let crumpleCardHeight { return crumpleCardHeight }
        let rowHeights = visibleActiveTasks.reduce(CGFloat(0)) { height, task in
            height + taskRowHeight(task)
        }
        let completedHeight = completedExpanded
            ? completedTasks.reduce(CGFloat(0)) { $0 + taskRowHeight($1) } + 10 : 0
        let completedHeader: CGFloat = completedTasks.isEmpty ? 0 : 38
        let emptyHeight: CGFloat = visibleActiveTasks.isEmpty ? 128 : 0
        let statusHeight: CGFloat = banner != nil || hasUnsavedChanges ? 44 : 0
        return min(maxCardHeight, max(286, 196 + rowHeights + emptyHeight + completedHeader + completedHeight + statusHeight))
    }

    var isInteracting: Bool { activeInput != nil || editingID != nil || draggingID != nil || renamingNoteID != nil || isCrumpling || isTitleMenuOpen }

    func toggleTitleMenu() {
        withAnimation(titleMenuMotion(opening: !isTitleMenuOpen)) {
            isTitleMenuOpen.toggle()
            if !isTitleMenuOpen { titleMenuArchivedOpen = false }
        }
    }

    func closeTitleMenu() {
        guard isTitleMenuOpen || titleMenuArchivedOpen else { return }
        withAnimation(titleMenuMotion(opening: false)) {
            isTitleMenuOpen = false
            titleMenuArchivedOpen = false
        }
    }

    private func titleMenuMotion(opening: Bool) -> Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .easeOut(duration: 0.12) }
        return opening ? .spring(response: 0.38, dampingFraction: 0.86) : .easeInOut(duration: 0.20)
    }

    func beginRenamingNote() {
        guard !storageBlocked, draggingID == nil, renamingNoteID == nil else { return }
        closeTitleMenu()
        if let id = editingID { finishEdit(id, text: editingDraft) }
        nameDraft = displayedNote.labelName
        renamingNoteID = displayedNote.id
    }

    func finishRenamingNote(_ id: UUID) {
        guard renamingNoteID == id else { return }
        if !storageBlocked {
            if notebook.renameNote(id, name: NoteNameLayout.fittingPrefix(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines))) { persist() }
            else { banner = "便签名称不能为空，已保留原名称。" }
        }
        renamingNoteID = nil
        nameDraft = ""
        if activeInput == id { activeInput = nil }
    }

    func cancelRenamingNote(_ id: UUID) {
        guard renamingNoteID == id else { return }
        renamingNoteID = nil
        nameDraft = ""
        if activeInput == id { activeInput = nil }
    }

    private func taskRowHeight(_ task: MemoTask) -> CGFloat {
        if editingID == task.id {
            return max(TaskTextLayout.previewRowHeight - 20,
                       TaskTextLayout.editorHeight(text: editingDraft, completed: task.completedAt != nil)) + 20
        }
        return TaskTextLayout.rowHeight(for: task, expanded: expandedTaskIDs.contains(task.id))
    }

    func beginEditing(_ id: UUID) {
        guard !isViewingHistory, !storageBlocked, draggingID == nil,
              let task = document.tasks.first(where: { $0.id == id }) else { return }
        guard editingID != id else { return }
        if let noteID = renamingNoteID { finishRenamingNote(noteID) }
        if let previous = editingID, previous != id { finishEdit(previous, text: editingDraft) }
        editingWasExpanded = expandedTaskIDs.contains(id)
        editingDraft = task.text
        if TaskTextLayout.canExpand(task) { expandedTaskIDs.insert(id) }
        editingID = id
        requestResize?()
    }

    func cancelEditing(_ id: UUID) {
        guard editingID == id else { return }
        if !editingWasExpanded { expandedTaskIDs.remove(id) }
        editingID = nil
        editingDraft = ""
        if activeInput == id { activeInput = nil }
        requestResize?()
    }

    func toggleTaskExpansion(_ id: UUID) {
        guard draggingID == nil, let task = document.tasks.first(where: { $0.id == id }) else { return }
        if expandedTaskIDs.contains(id) { expandedTaskIDs.remove(id) }
        else if TaskTextLayout.canExpand(task) { expandedTaskIDs.insert(id) }
        requestResize?()
    }

    func reload() {
        cancelCrumple()
        closeTitleMenu()
        do {
            let result = try repository.load()
            resetNoteInteraction()
            selectedHistoryID = nil
            notebook = result.notebook
            noteDrafts = [:]
            draft = ""
            storageBlocked = false
            hasUnsavedChanges = false
            banner = result.recoveredFromBackup ? "已从备份恢复任务，原文件会保留。" : nil
            // Recover a last check saved just before quitting during its animation.
            let advanced = notebook.archiveCompletedCurrent()
            if result.migrated || advanced { persist() }
        } catch {
            storageBlocked = true
            banner = error.localizedDescription
        }
    }

    func persist() {
        guard !storageBlocked else { return }
        do {
            try repository.save(notebook)
            hasUnsavedChanges = false
            if banner?.hasPrefix("保存失败") == true { banner = nil }
        } catch {
            hasUnsavedChanges = true
            banner = "保存失败，任务仍在内存中。点击重试。"
        }
        requestResize?()
    }

    func addDraft() {
        guard !isViewingHistory, !storageBlocked else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let taskID = document.add(text) else { return }
        draft = ""
        noteDrafts.removeValue(forKey: notebook.current.id)
        autoNameFromFirstTask(taskID)
        persist()
    }

    /// An unnamed note takes a prefix of its first task fitting eight Chinese
    /// glyphs. Notes the user has named are never touched.
    private func autoNameFromFirstTask(_ taskID: UUID) {
        guard renamingNoteID == nil,
              notebook.current.document.tasks.count == 1,
              (notebook.current.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              let task = notebook.current.document.tasks.first(where: { $0.id == taskID })
        else { return }
        let candidate = NoteNameLayout.fittingPrefix(task.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        _ = notebook.renameNote(notebook.current.id, name: candidate)
    }

    func finishEdit(_ id: UUID, text: String) {
        guard !isViewingHistory, !storageBlocked else { return }
        if !document.edit(id, text: text) { banner = "任务不能为空，已保留原内容。" }
        if let task = document.tasks.first(where: { $0.id == id }), !TaskTextLayout.canExpand(task) {
            expandedTaskIDs.remove(id)
        }
        editingID = nil
        editingDraft = ""
        if activeInput == id { activeInput = nil }
        persist()
    }

    func setInput(_ id: UUID, focused: Bool) {
        if focused { activeInput = id }
        else if activeInput == id { activeInput = nil }
    }

    func toggle(_ task: MemoTask) {
        guard !isViewingHistory, !storageBlocked else { return }
        // A deliberate checkbox action must never be swallowed by a stale drag.
        if draggingID != nil { finishDrag(accepted: false) }
        guard let task = document.tasks.first(where: { $0.id == task.id }) else { return }
        if let oldIndex = pendingCompletions.removeValue(forKey: task.id) {
            completionJobs.removeValue(forKey: task.id)?.cancel()
            discardPaperSnapshot()
            document.setCompleted(task.id, false)
            var order = document.activeOrder.filter { $0 != task.id }
            let stillPendingBefore = pendingCompletions.values.filter { $0 < oldIndex }.count
            order.insert(task.id, at: min(max(0, oldIndex - stillPendingBefore), order.count))
            document.reorder(order)
        } else if task.completedAt != nil {
            discardPaperSnapshot()
            document.setCompleted(task.id, false)
        } else {
            let index = visibleActiveTasks.firstIndex(where: { $0.id == task.id }) ?? 0
            pendingCompletions[task.id] = index
            document.setCompleted(task.id, true)
            let job = DispatchWorkItem { [weak self] in
                guard let self else { return }
                withAnimation(self.motion) {
                    self.pendingCompletions.removeValue(forKey: task.id)
                    self.completionJobs.removeValue(forKey: task.id)
                    self.advanceIfCompleted()
                }
                self.requestResize?()
            }
            completionJobs[task.id] = job
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: job)
            if document.activeTasks.isEmpty { schedulePaperSnapshot() }
        }
        persist()
    }

    func delete(_ id: UUID) {
        guard !isViewingHistory, !storageBlocked, draggingID == nil else { return }
        // A newly completed row is already completed in the saved document.
        pendingCompletions.removeValue(forKey: id)
        completionJobs.removeValue(forKey: id)?.cancel()
        guard let entry = document.remove(id) else { return }
        expandedTaskIDs.remove(id)
        if editingID == id { editingID = nil }
        deleted.append(entry)
        deletedCount = deleted.count
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deleted = []
                self?.deletedCount = 0
            }
        }
        persist()
    }

    func undoDeletion() {
        guard !isViewingHistory, !storageBlocked else { return }
        undoTimer?.invalidate()
        document.restore(deleted)
        deleted = []
        deletedCount = 0
        persist()
    }

    @discardableResult
    func beginDrag(_ id: UUID) -> Bool {
        guard !isViewingHistory, !storageBlocked, pendingCompletions.isEmpty, editingID == nil, renamingNoteID == nil,
              draggingID == nil, document.activeOrder.contains(id) else { return false }
        dragOriginalOrder = document.activeOrder
        dragReleasedAt = nil
        draggingID = id
        return true
    }

    func moveDrag(before target: UUID?) {
        guard let id = draggingID else { return }
        withAnimation(motion) { document.move(id, before: target); dropTarget = target }
    }

    func finishDrag(accepted: Bool) {
        guard draggingID != nil else { return }
        if !accepted, let original = dragOriginalOrder { document.reorder(original) }
        draggingID = nil
        dragOriginalOrder = nil
        dragReleasedAt = nil
        dropTarget = nil
        if accepted { persist() }
    }

    func recoverReleasedDrag(isMouseDown: Bool, now: TimeInterval) {
        guard draggingID != nil, !isMouseDown else { dragReleasedAt = nil; return }
        guard let releasedAt = dragReleasedAt else { dragReleasedAt = now; return }
        // Let the native drop callback run first; recover only if it failed to arrive.
        if now - releasedAt >= 0.25 { finishDrag(accepted: false) }
    }

    func showNote(_ historyID: UUID?) {
        guard historyID == nil || (notebook.inProgressNotes + notebook.history).contains(where: { $0.id == historyID }) else { return }
        cancelCrumple()
        closeTitleMenu()
        let previousID = displayedNote.id
        if !isViewingHistory { noteDrafts[previousID] = draft }
        if let id = renamingNoteID { finishRenamingNote(id) }
        if let id = editingID { finishEdit(id, text: editingDraft) }
        finishDrag(accepted: false)
        // Settle the current note before changing which document the UI reads.
        completionJobs.values.forEach { $0.cancel() }
        completionJobs = [:]
        pendingCompletions = [:]
        advanceIfCompleted()
        if let id = historyID, notebook.selectInProgress(id) {
            selectedHistoryID = nil
        } else { selectedHistoryID = historyID }
        if displayedNote.id != previousID {
            resetNoteInteraction()
            draft = isViewingHistory ? "" : (noteDrafts[displayedNote.id] ?? "")
        }
        persist()
        requestResize?()
    }

    func createNote() {
        guard !storageBlocked else { return }
        cancelCrumple()
        closeTitleMenu()
        if let id = renamingNoteID { finishRenamingNote(id) }
        if let id = editingID { finishEdit(id, text: editingDraft) }
        finishDrag(accepted: false)
        // Explicitly creating a sheet commits any task currently being entered.
        if !isViewingHistory, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addDraft() }
        completionJobs.values.forEach { $0.cancel() }
        completionJobs = [:]
        pendingCompletions = [:]
        advanceIfCompleted()
        notebook.createNote()
        selectedHistoryID = nil
        resetNoteInteraction()
        draft = noteDrafts.removeValue(forKey: notebook.current.id) ?? ""
        newTaskFocusRequest = UUID()
        noteAppearanceRevision &+= 1
        persist()
    }

    private func advanceIfCompleted() {
        guard !storageBlocked, pendingCompletions.isEmpty,
              !notebook.current.document.tasks.isEmpty, notebook.current.document.activeTasks.isEmpty else { return }
        if let id = renamingNoteID { finishRenamingNote(id) }
        beginCrumple()
        guard notebook.archiveCompletedCurrent() else { finishCrumple(animated: false); return }
        resetNoteInteraction()
        selectedHistoryID = nil
        draft = noteDrafts.removeValue(forKey: notebook.current.id) ?? ""
        persist()
    }

    /// Freezes the finished sheet, then lets the archived note crumple away while
    /// the fresh note waits behind it. Storage already holds the archive at this point.
    private func beginCrumple() {
        guard !isCrumpling,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let image = pendingPaperSnapshot else { return }
        snapshotJob?.cancel()
        snapshotJob = nil
        pendingPaperSnapshot = nil
        crumpleCardHeight = image.size.height > 1 ? image.size.height : cardHeight
        crumpleImage = image
        isCrumpling = true
        crumpleJob?.cancel()
        let job = DispatchWorkItem { [weak self] in
            self?.finishCrumple(animated: true)
        }
        crumpleJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: job)
    }

    /// Freeze the finished sheet shortly after the last check, while its layout
    /// is stable. Capturing later runs into the list's move-to-completed frame.
    private func schedulePaperSnapshot() {
        snapshotJob?.cancel()
        pendingPaperSnapshot = nil
        let job = DispatchWorkItem { [weak self] in
            guard let self, !self.isViewingHistory,
                  self.document.activeTasks.isEmpty else { return }
            self.pendingPaperSnapshot = self.requestPaperSnapshot?()
        }
        snapshotJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: job)
    }

    private func discardPaperSnapshot() {
        snapshotJob?.cancel()
        snapshotJob = nil
        pendingPaperSnapshot = nil
    }

    /// Called by the crumple view when its last frame has been drawn.
    func completeCrumple() {
        crumpleJob?.cancel()
        crumpleJob = nil
        finishCrumple(animated: true)
    }

    func cancelCrumple() {
        crumpleJob?.cancel()
        crumpleJob = nil
        discardPaperSnapshot()
        guard isCrumpling || crumpleImage != nil || crumpleCardHeight != nil else { return }
        isCrumpling = false
        crumpleImage = nil
        crumpleCardHeight = nil
        requestResize?()
    }

    private func finishCrumple(animated: Bool) {
        crumpleJob = nil
        guard isCrumpling else { return }
        if animated {
            withAnimation(motion) {
                isCrumpling = false
                crumpleImage = nil
                crumpleCardHeight = nil
            }
        } else {
            isCrumpling = false
            crumpleImage = nil
            crumpleCardHeight = nil
        }
        requestResize?()
    }

    private func resetNoteInteraction() {
        completionJobs.values.forEach { $0.cancel() }
        completionJobs = [:]
        pendingCompletions = [:]
        isTitleMenuOpen = false
        titleMenuArchivedOpen = false
        discardPaperSnapshot()
        undoTimer?.invalidate()
        deleted = []
        deletedCount = 0
        expandedTaskIDs = []
        editingID = nil
        editingDraft = ""
        renamingNoteID = nil
        nameDraft = ""
        activeInput = nil
        newTaskFocusRequest = nil
        completedExpanded = false
        draggingID = nil
        dragOriginalOrder = nil
        dropTarget = nil
    }

    var motion: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.78)
    }

    var appearanceMotion: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.12) : .spring(response: 0.76, dampingFraction: 0.70)
    }

    var dismissalMotion: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.46)
    }

    var presentationMotion: Animation { isPresented ? appearanceMotion : dismissalMotion }

    func revealDataFolder() {
        NSWorkspace.shared.open(repository.directory)
    }
}

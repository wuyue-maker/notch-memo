import SwiftUI
import AppKit
import MemoCore
import UniformTypeIdentifiers

private enum Ink {
    static let text = Color(red: 0.22, green: 0.24, blue: 0.21)
    static let muted = Color(red: 0.54, green: 0.54, blue: 0.48)
    static let accent = Color(red: 0.78, green: 0.35, blue: 0.20)
    static let paper = Color(red: 0.98, green: 0.97, blue: 0.92)
    static let line = Color(red: 0.35, green: 0.32, blue: 0.23).opacity(0.10)
}

struct MemoView: View {
    @ObservedObject var model: MemoModel
    @State private var edgeTimer: Timer?
    @State private var edgeIndex = 0
    @State private var topTarget = false
    @State private var bottomTarget = false
    @State private var titleHovered = false
    @State private var addSpin: Double = 0
    @State private var lastCreationRevision: UInt = 0
    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The notch tab fades in with the sheet, then lingers briefly while the
    /// sheet curls away so it never pops out of existence.
    private var bridgeMotion: Animation {
        if reducedMotion { return .easeOut(duration: 0.12) }
        return model.isPresented
            ? .easeOut(duration: 0.20)
            : .easeIn(duration: 0.26).delay(0.10)
    }

    private var titleChevronKey: Int {
        (model.isTitleMenuOpen ? 2 : 0) + (titleHovered ? 1 : 0)
    }

    private var titleChevronMotion: Animation {
        reducedMotion ? .easeOut(duration: 0.12) : .spring(response: 0.30, dampingFraction: 0.55)
    }

    var body: some View {
        VStack(spacing: -MemoLayout.bridgeSpacing) {
            NotchBridge(notchWidth: model.notchWidth)
                .fill(.black)
                .frame(height: model.topInset + MemoLayout.bridgeExtraHeight)
                .padding(.horizontal, MemoLayout.paperMargin)
                .opacity(model.isPresented ? 1 : 0)
                .animation(bridgeMotion, value: model.isPresented)
            paper
                .frame(height: model.cardHeight)
                .background {
                    RoundedRectangle(cornerRadius: MemoLayout.paperCornerRadius, style: .continuous)
                        .fill(LinearGradient(colors: [Ink.paper, Color(red: 0.96, green: 0.94, blue: 0.87)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay { PaperGrain().clipShape(RoundedRectangle(cornerRadius: MemoLayout.paperCornerRadius)) }
                }
                .clipShape(RoundedRectangle(cornerRadius: MemoLayout.paperCornerRadius, style: .continuous))
                .overlay(alignment: .bottomTrailing) { PaperCorner().allowsHitTesting(false) }
                .overlay {
                    RoundedRectangle(cornerRadius: MemoLayout.paperCornerRadius).strokeBorder(.white.opacity(0.58), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .modifier(StickerPeelModifier(progress: model.isPresented ? 1 : 0,
                                              reducedMotion: reducedMotion))
                .scaleEffect(model.isCrumpling ? 0.985 : 1, anchor: .center)
                .opacity(model.isCrumpling ? 0 : 1)
                .overlay {
                    if model.isCrumpling, let image = model.crumpleImage {
                        PaperCrumpleView(image: image) { model.completeCrumple() }
                            .transition(.identity)
                    }
                }
        }
        .padding(.horizontal, MemoLayout.paperMargin)
        .padding(.bottom, MemoLayout.paperBottomPadding)
        // The panel hangs from the screen's top edge; pin the content there so a
        // transient window/content height mismatch cannot center the note.
        .frame(minWidth: MemoLayout.panelWidth, maxWidth: MemoLayout.panelWidth,
               maxHeight: .infinity, alignment: .top)
        // Height changes resize the AppKit panel. Animating that layout at the
        // same time made the note drop by a row height and slide back on every
        // add; let the panel snap, and animate only the content that needs it.
        .animation(nil, value: model.cardHeight)
        .foregroundStyle(Ink.text)
        .environment(\.colorScheme, .light)
        .animation(model.presentationMotion, value: model.isPresented)
        // Replaying the paper peel on every new note made the sheet tilt and
        // settle under the user's eyes; a new note now swaps in place instead.
        .onChange(of: model.noteAppearanceRevision) { _, revision in
            lastCreationRevision = revision
        }
        .onChange(of: model.cardHeight) { _, _ in model.requestResize?() }
        .onChange(of: model.draggingID) { _, value in if value == nil { stopEdgeScroll() } }
        .onDisappear { stopEdgeScroll() }
    }

    private var paper: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .top) {
                noteContent
                    .id(model.displayedNote.id)
                    .transition(noteSwitchTransition)
            }
            .animation(noteSwitchMotion, value: model.displayedNote.id)
            .transaction { transaction in
                if lastCreationRevision != model.noteAppearanceRevision {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }

            if model.isTitleMenuOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeTitleMenu() }
                    .zIndex(8)
                NoteSwitcherMenu(model: model, maxHeight: menuMaxHeight)
                    .offset(x: MemoLayout.horizontalInset, y: 57)
                    .zIndex(9)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -6))
                            .combined(with: .scale(scale: 0.98, anchor: .topLeading)),
                        removal: .opacity.combined(with: .offset(y: -4))
                            .combined(with: .scale(scale: 0.99, anchor: .topLeading))))
            }
        }
    }

    private var noteContent: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Ink.line).frame(height: 1).padding(.horizontal, MemoLayout.horizontalInset)
            if model.storageBlocked {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 27)).foregroundStyle(Ink.accent)
                    Text("先保护好已有任务").font(.system(size: 15, weight: .medium))
                    Text(model.banner ?? "暂时无法读取数据").font(.system(size: 12)).multilineTextAlignment(.center)
                    HStack {
                        Button("查看文件") { model.revealDataFolder() }
                        Button("重新读取") { model.reload() }
                    }.buttonStyle(.bordered)
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                taskList.id(model.selectedHistoryID ?? model.notebook.current.id)
                if model.isViewingHistory {
                    Button {
                        model.requestSelectNote?(model.notebook.current.id)
                    } label: {
                        Label("返回进行中便签", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Ink.accent).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).padding(.horizontal, MemoLayout.horizontalInset).padding(.top, 7)
                } else { addInput }
                footer
            }
        }
    }

    private var noteSwitchMotion: Animation {
        reducedMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    private var noteSwitchTransition: AnyTransition {
        if reducedMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: -10))
                .combined(with: .scale(scale: 0.99, anchor: .top)),
            removal: .opacity.combined(with: .offset(y: 8)))
    }

    private var menuMaxHeight: CGFloat {
        min(250, max(120, model.cardHeight - 77))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let id = model.renamingNoteID {
                    NativeInput(text: $model.nameDraft, placeholder: "便签名称", autofocus: true, font: noteTitleFont, limitText: NoteNameLayout.fittingPrefix,
                                onFocus: { model.setInput(id, focused: $0) },
                                onSubmit: { model.finishRenamingNote(id); NSApp.keyWindow?.makeFirstResponder(nil) },
                                onCancel: { model.cancelRenamingNote(id) },
                                onEnd: { model.finishRenamingNote(id) })
                        .frame(width: NoteNameLayout.maximumWidth(font: noteTitleFont) + 4, height: 28)
                        .padding(.leading, MemoLayout.iconColumn + MemoLayout.contentSpacing)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                        .accessibilityLabel("编辑便签名称")
                        .id(id)
                } else {
                    Button {
                        model.toggleTitleMenu()
                    } label: {
                        HStack(spacing: MemoLayout.contentSpacing) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(titleHovered || model.isTitleMenuOpen ? Ink.accent : Ink.muted)
                                .rotationEffect(.degrees(model.isTitleMenuOpen ? 180 : 0))
                                .frame(width: MemoLayout.iconColumn, height: 28)
                                .background {
                                    Circle()
                                        .fill(Ink.accent.opacity(model.isTitleMenuOpen ? 0.14 : (titleHovered ? 0.10 : 0)))
                                        .frame(width: MemoLayout.titleIndicatorDiameter, height: MemoLayout.titleIndicatorDiameter)
                                }
                                .animation(titleChevronMotion, value: titleChevronKey)
                            Text(model.displayedNote.labelName)
                                .font(Font(noteTitleFont)).tracking(-0.5)
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: titleMaximumWidth, alignment: .leading)
                                .clipped()
                        }
                        .contentShape(Rectangle())
                        .onHover { hovered in
                            withAnimation(titleChevronMotion) { titleHovered = hovered }
                        }
                    }
                        .buttonStyle(NoteTitleButtonStyle())
                        .fixedSize(horizontal: true, vertical: true)
                        .help(model.displayedNote.displayName + "\n打开便签列表或编辑名称")
                        .accessibilityLabel("便签名称：\(model.displayedNote.displayName)，打开便签列表")
                }
                if model.renamingNoteID == nil || model.isViewingHistory {
                    Text(model.isViewingHistory ? "已完成" : String(format: "%02d", model.document.activeTasks.count))
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Ink.accent).fixedSize()
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Button {
                if !reducedMotion {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { addSpin += 90 }
                }
                model.requestNewNote?()
            } label: {
                Image(systemName: "plus")
                    .rotationEffect(.degrees(reducedMotion ? 0 : addSpin))
            }
            .buttonStyle(MemoHeaderButtonStyle())
            .help("新建便签").accessibilityLabel("新建便签").disabled(model.storageBlocked)
            Button { model.isPinned.toggle() } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .rotationEffect(.degrees(model.isPinned ? -25 : 0))
            }
            .buttonStyle(MemoHeaderButtonStyle(active: model.isPinned))
            .help(model.isPinned ? "取消固定，恢复自动收起" : "固定展开")
                .accessibilityLabel(model.isPinned ? "取消固定" : "固定展开")
        }
        .buttonStyle(.plain)
        .padding(.leading, MemoLayout.titleLeadingInset)
        .padding(.trailing, MemoLayout.horizontalInset)
        .padding(.top, 24).padding(.bottom, 19)
    }

    private var titleMaximumWidth: CGFloat {
        NoteNameLayout.maximumWidth(font: noteTitleFont)
    }

    private var noteTitleFont: NSFont {
        NoteNameLayout.font(size: model.isViewingHistory ? 19 : 23)
    }

    private var taskList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.visibleActiveTasks.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "square.and.pencil").font(.system(size: 25, weight: .light))
                                .rotationEffect(.degrees(-9)).foregroundStyle(Ink.accent.opacity(0.75))
                            Text("记下下一件要做的事").font(.system(size: 13, weight: .medium))
                            Text("从一件小事开始。").font(.system(size: 11)).foregroundStyle(Ink.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 29)
                    }
                    ForEach(model.visibleActiveTasks) { task in
                        TaskRow(task: task, model: model).id(task.id)
                            .onDrop(of: [.text], delegate: TaskDropDelegate(target: task.id, model: model))
                    }
                    Color.clear.frame(height: model.draggingID == nil ? 1 : 22)
                        .onDrop(of: [.text], delegate: TaskDropDelegate(target: nil, model: model))
                    if !model.completedTasks.isEmpty {
                        completedSection
                    }
                }.padding(.horizontal, MemoLayout.horizontalInset).padding(.top, 10).padding(.bottom, 4)
                    .background(PaperScrollStyle())
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .top) {
                Color.clear.frame(height: model.draggingID == nil ? 0 : 16).contentShape(Rectangle())
                    .onDrop(of: [.text], isTargeted: $topTarget) { _ in acceptEdgeDrop(atEnd: false) }
            }
            .overlay(alignment: .bottom) {
                Color.clear.frame(height: model.draggingID == nil ? 0 : 16).contentShape(Rectangle())
                    .onDrop(of: [.text], isTargeted: $bottomTarget) { _ in acceptEdgeDrop(atEnd: true) }
            }
            .onChange(of: topTarget) { _, active in
                if active { startEdgeScroll(direction: -1, proxy: proxy) } else { stopEdgeScroll() }
            }
            .onChange(of: bottomTarget) { _, active in
                if active { startEdgeScroll(direction: 1, proxy: proxy) } else { stopEdgeScroll() }
            }
            .onChange(of: model.editingID) { _, id in
                guard let id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .animation(model.motion, value: model.visibleActiveTasks.map(\.id))
        .animation(model.motion, value: model.completedExpanded)
        .animation(model.motion, value: model.expandedTaskIDs)
    }

    private var completedSection: some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(model.motion) { model.completedExpanded.toggle() }
                model.requestResize?()
            } label: {
                HStack(spacing: MemoLayout.contentSpacing) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(model.completedExpanded ? 90 : 0))
                        .frame(width: MemoLayout.iconColumn)
                    Text("已完成").font(.system(size: 11, weight: .medium))
                    Text("\(model.completedTasks.count)").font(.system(size: 10, design: .monospaced))
                    Spacer()
                }.foregroundStyle(Ink.muted).padding(.horizontal, MemoLayout.rowInset).padding(.vertical, 13).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("已完成 \(model.completedTasks.count) 项")
            if model.completedExpanded {
                ForEach(model.completedTasks) { task in TaskRow(task: task, model: model).id(task.id) }
            }
        }
    }

    private var addInput: some View {
        HStack(spacing: MemoLayout.contentSpacing) {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.accent)
                .frame(width: MemoLayout.iconColumn)
            NativeInput(text: $model.draft, placeholder: "添加任务，回车记下…",
                        autofocus: model.newTaskFocusRequest != nil, focusRequest: model.newTaskFocusRequest, onFocus: {
                model.setInput(model.newInputID, focused: $0)
            }, onSubmit: { withAnimation(model.motion) { model.addDraft() } }, onCancel: {})
                .frame(height: 23).accessibilityLabel("添加任务")
                .id(model.notebook.current.id)
        }
        .padding(.horizontal, MemoLayout.rowInset).padding(.vertical, 10)
        .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
        .padding(.horizontal, MemoLayout.horizontalInset).padding(.top, 7)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let banner = model.banner {
                Button {
                    if model.hasUnsavedChanges { model.persist() } else { model.banner = nil }
                } label: {
                    HStack(alignment: .top, spacing: MemoLayout.contentSpacing) {
                        Image(systemName: model.hasUnsavedChanges ? "exclamationmark.circle" : "info.circle")
                            .frame(width: MemoLayout.iconColumn)
                        Text(banner).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.font(.system(size: 11)).foregroundStyle(Ink.accent)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                if model.deletedCount > 0 && !model.isViewingHistory {
                    HStack(spacing: 6) {
                        Text("已删除 \(model.deletedCount) 项")
                        Button("撤销") { withAnimation(model.motion) { model.undoDeletion() } }
                            .foregroundStyle(Ink.accent).buttonStyle(.plain).accessibilityLabel("撤销删除")
                    }
                } else {
                    MemoFooterCaption(
                        title: model.hasUnsavedChanges ? "等待保存" : (model.isViewingHistory ? "已归档 · \(model.document.tasks.count) 项任务" : "保存在这台 Mac"),
                        symbol: model.hasUnsavedChanges ? "circle.dotted" : "checkmark")
                }
                Spacer(minLength: 0)
                Button { model.requestClose?() } label: {
                    MemoFooterCaption(title: "收起", symbol: "chevron.up", symbolAfterText: true)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("收起便签")
                    .help(model.isPinned ? "取消固定并收起便签" : "收起便签；移开鼠标也会自动收起")
            }
            .font(.system(size: 10, weight: .regular)).foregroundStyle(Ink.muted)
            .frame(height: 20)
        }.padding(.horizontal, MemoLayout.horizontalInset).padding(.top, 12).padding(.bottom, 21)
    }

    private func acceptEdgeDrop(atEnd: Bool) -> Bool {
        guard model.draggingID != nil else { return false }
        model.moveDrag(before: atEnd ? nil : model.document.activeOrder.first)
        model.finishDrag(accepted: true)
        stopEdgeScroll()
        return true
    }

    private func startEdgeScroll(direction: Int, proxy: ScrollViewProxy) {
        stopEdgeScroll()
        guard model.draggingID != nil else { return }
        edgeIndex = model.document.activeOrder.firstIndex(of: model.dropTarget ?? model.draggingID!) ?? 0
        edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { _ in
            MainActor.assumeIsolated {
                let ids = model.document.activeOrder
                guard !ids.isEmpty, model.draggingID != nil else { stopEdgeScroll(); return }
                edgeIndex = min(ids.count - 1, max(0, edgeIndex + direction))
                withAnimation(.linear(duration: 0.16)) { proxy.scrollTo(ids[edgeIndex], anchor: direction < 0 ? .top : .bottom) }
            }
        }
        if let edgeTimer { RunLoop.main.add(edgeTimer, forMode: .eventTracking) }
    }

    private func stopEdgeScroll() { edgeTimer?.invalidate(); edgeTimer = nil }
}

private struct TaskRow: View {
    let task: MemoTask
    @ObservedObject var model: MemoModel
    @State private var hovered = false
    @State private var gripHovered = false

    private var completed: Bool { task.completedAt != nil }
    private var expanded: Bool { model.expandedTaskIDs.contains(task.id) }
    private var isEditing: Bool { model.editingID == task.id }
    private var isOpen: Bool { expanded || isEditing }
    private var canExpand: Bool { TaskTextLayout.canExpand(task) }

    var body: some View {
        HStack(alignment: .center, spacing: MemoLayout.contentSpacing) {
            Button { completeTask() } label: {
                SpringCheckbox(checked: completed)
                    .animation(model.motion, value: completed)
                    .frame(width: 18, height: 18)
                    .frame(width: MemoLayout.iconColumn, height: 28)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(model.isViewingHistory ? "已完成" : (completed ? "恢复任务" : "完成任务"))
                .disabled(model.isViewingHistory)
                .accessibilityLabel("\(model.isViewingHistory ? "已完成" : (completed ? "恢复任务" : "完成任务"))：\(task.text)")
            if model.editingID == task.id {
                TaskTextEditor(text: $model.editingDraft, completed: completed, onFocus: {
                    model.setInput(task.id, focused: $0)
                }, onSubmit: { finishEditing() }, onCancel: { model.cancelEditing(task.id) }, onEnd: { finishEditing() })
                    .frame(height: TaskTextLayout.editorHeight(text: model.editingDraft, completed: completed))
                    .accessibilityLabel("编辑任务")
            } else {
                Button { withAnimation(model.motion) { model.toggleTaskExpansion(task.id) } } label: {
                    Text(task.text).font(.system(size: 13)).lineSpacing(4)
                        .lineLimit(expanded ? nil : 2)
                        .truncationMode(.tail)
                        .strikethrough(completed && !model.isViewingHistory, color: Ink.muted.opacity(0.6))
                        .foregroundStyle(completed && !model.isViewingHistory ? Ink.muted : Ink.text)
                        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(model.isViewingHistory ? (canExpand ? (expanded ? "单击收起" : "单击展开全文") : "已完成的任务") : (canExpand ? (expanded ? "单击收起，右键编辑" : "单击展开全文，右键编辑") : "右键编辑任务"))
                    .accessibilityValue(canExpand ? (expanded ? "已展开全文" : "两行预览") : "")
            }
            if !completed {
                TaskGrip(highlighted: gripHovered).frame(width: MemoLayout.gripWidth, height: 25)
                    .background(gripHovered ? Ink.accent.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
        }
        .frame(height: expanded || model.editingID == task.id ? nil : TaskTextLayout.previewRowHeight - 20,
               alignment: .center)
        .frame(minHeight: TaskTextLayout.previewRowHeight - 20)
        .padding(.horizontal, MemoLayout.rowInset).padding(.vertical, 10)
        .background(isOpen ? .white.opacity(0.58) : (hovered ? .white.opacity(0.4) : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isOpen {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Ink.accent.opacity(isEditing ? 0.30 : 0.18), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if model.editingID != task.id && !model.isViewingHistory {
                TaskDragSurface(id: task.id,
                                canDrag: !completed && model.editingID == nil && model.pendingCompletions.isEmpty,
                                preview: { dragPreview(size: $0) },
                                onClick: { withAnimation(model.motion) { model.toggleTaskExpansion(task.id) } },
                                onCheck: { completeTask() },
                                onEdit: { startEditing() },
                                onDelete: { withAnimation(model.motion) { model.delete(task.id) } },
                                completed: completed,
                                onHandleHover: { gripHovered = $0 },
                                onBegin: { model.beginDrag(task.id) }, onEnd: { model.finishDrag(accepted: $0) })
            }
        }
        .overlay(alignment: .top) {
            if model.dropTarget == task.id, model.draggingID != task.id {
                Capsule().fill(Ink.accent).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .opacity(model.draggingID == task.id ? 0.35 : 1)
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .contextMenu {
            if !model.isViewingHistory {
                Button("编辑") { startEditing() }
                Button(completed ? "恢复任务" : "完成任务") { completeTask() }
                Divider()
                Button("删除", role: .destructive) { withAnimation(model.motion) { model.delete(task.id) } }
            }
        }
        .transition(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .opacity :
                        .asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .modifier(active: PaperFold(progress: 1), identity: PaperFold(progress: 0))))
    }

    @MainActor
    private func dragPreview(size: NSSize) -> NSImage? {
        let renderer = ImageRenderer(content: TaskDragPreview(task: task, expanded: expanded, size: size))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    private func completeTask() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        withAnimation(model.motion) { model.toggle(task) }
    }

    private func startEditing() {
        guard model.draggingID == nil, !model.storageBlocked else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.beginEditing(task.id)
    }

    private func finishEditing() {
        guard model.editingID == task.id else { return }
        model.finishEdit(task.id, text: model.editingDraft)
    }
}

private struct TaskGrip: View {
    var highlighted = false
    var body: some View {
        Canvas { context, _ in
            for x in [CGFloat(1), 5] {
                for y in [CGFloat(1), 5, 9] {
                    let dot = Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                    context.fill(dot, with: .color(highlighted ? Ink.accent : Ink.muted.opacity(0.65)))
                }
            }
        }
        .frame(width: 6, height: 10)
        .scaleEffect(highlighted && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.12 : 1)
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

private struct TaskDragPreview: View {
    let task: MemoTask
    let expanded: Bool
    let size: NSSize

    var body: some View {
        HStack(alignment: .center, spacing: MemoLayout.contentSpacing) {
            SpringCheckbox(checked: false).frame(width: 18, height: 18).frame(width: MemoLayout.iconColumn, height: 28)
            Text(task.text).font(.system(size: 13)).lineSpacing(4)
                .lineLimit(expanded ? nil : 2).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            TaskGrip().frame(width: MemoLayout.gripWidth, height: 25)
        }
        .padding(.horizontal, MemoLayout.rowInset).padding(.vertical, 10)
        .frame(width: size.width, height: size.height)
        .foregroundStyle(Ink.text)
        .background(Ink.paper, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.8), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
        .padding(8)
        .environment(\.colorScheme, .light)
    }
}

private struct PaperFold: ViewModifier {
    var progress: Double
    func body(content: Content) -> some View {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        content
            .scaleEffect(x: reduced ? 1 : 1 - 0.86 * progress,
                         y: reduced ? 1 : 1 - 0.58 * progress, anchor: .trailing)
            .rotation3DEffect(.degrees(reduced ? 0 : 64 * progress), axis: (x: 1, y: 0.25, z: 0),
                              anchor: .trailing, perspective: 0.4)
            .opacity(1 - progress)
    }
}

private struct SpringCheckbox: View {
    let checked: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(checked ? Ink.accent : .clear)
            RoundedRectangle(cornerRadius: 6).strokeBorder(checked ? Ink.accent : Ink.muted.opacity(0.42), lineWidth: 1.2)
            Path { path in
                path.move(to: CGPoint(x: 4.5, y: 9.5))
                path.addLine(to: CGPoint(x: 8, y: 13))
                path.addLine(to: CGPoint(x: 14.5, y: 6))
            }.trim(from: 0, to: checked ? 1 : 0).stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }.contentShape(Rectangle()).scaleEffect(checked ? 1.03 : 1)
    }
}

private struct NotchBridge: Shape {
    var notchWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        let left = max(0, (rect.width - notchWidth) / 2)
        let right = rect.width - left
        var path = Path()
        path.move(to: CGPoint(x: left, y: 0))
        path.addLine(to: CGPoint(x: right, y: 0))
        path.addLine(to: CGPoint(x: right, y: max(0, rect.height - 18)))
        path.addCurve(to: CGPoint(x: rect.width, y: rect.height), control1: CGPoint(x: right, y: rect.height + 1), control2: CGPoint(x: rect.width - 12, y: rect.height - 5))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.addCurve(to: CGPoint(x: left, y: max(0, rect.height - 18)), control1: CGPoint(x: 12, y: rect.height - 5), control2: CGPoint(x: left, y: rect.height + 1))
        path.closeSubpath()
        return path
    }
}

private struct PaperGrain: View {
    var body: some View {
        Canvas { context, size in
            for y in stride(from: CGFloat(1), to: size.height, by: 4) {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.brown.opacity(0.018)), lineWidth: 0.5)
            }
            for i in 0..<420 {
                let x = CGFloat((i * 73 + 17) % 367) / 367 * size.width
                let y = CGFloat((i * 113 + 29) % 521) / 521 * size.height
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.7, height: 0.7)), with: .color(.brown.opacity(0.04)))
            }
        }.allowsHitTesting(false)
    }
}

private struct PaperCorner: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 27))
            path.addQuadCurve(to: CGPoint(x: 27, y: 0), control: CGPoint(x: 22, y: 24))
            path.addLine(to: CGPoint(x: 27, y: 17))
            path.addQuadCurve(to: CGPoint(x: 17, y: 27), control: CGPoint(x: 27, y: 27))
            path.closeSubpath()
        }
        .fill(LinearGradient(colors: [Color(red: 0.85, green: 0.82, blue: 0.72), Ink.paper], startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(width: 27, height: 27)
    }
}

private struct MemoFooterCaption: View {
    let title: String
    let symbol: String
    var symbolAfterText = false

    var body: some View {
        HStack(spacing: 6) {
            if !symbolAfterText { icon }
            Text(title).lineLimit(1)
            if symbolAfterText { icon }
        }
        .font(.system(size: 10, weight: .regular))
        .foregroundStyle(Ink.muted)
        .frame(height: 20)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .regular))
            .frame(width: 12, height: 12)
    }
}

private struct MemoHeaderButtonStyle: ButtonStyle {
    var active = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active || hovered ? Ink.accent : Ink.muted)
            .frame(width: MemoLayout.headerButtonSize, height: MemoLayout.headerButtonSize)
            .background(active || hovered ? Ink.accent.opacity(0.10) : .clear, in: Circle())
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovered = isEnabled && $0 }
    }
}

private struct NoteTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct NoteSwitcherMenu: View {
    @ObservedObject var model: MemoModel
    var maxHeight: CGFloat
    @State private var archiveHovered = false

    var body: some View {
        // Keep one scroll view throughout disclosure; replacing the whole menu
        // at the height limit interrupts its layout animation.
        ScrollView(.vertical, showsIndicators: false) { menuContent }
            .scrollDisabled(contentHeight <= maxHeight - 8)
            .frame(height: min(contentHeight, maxHeight - 8), alignment: .top)
        .padding(4)
        .frame(width: menuWidth)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [Ink.paper, Color(red: 0.96, green: 0.945, blue: 0.885)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    PaperGrain()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.72), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.22), radius: 15, x: 0, y: 8)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .animation(disclosureMotion(opening: model.titleMenuArchivedOpen), value: model.titleMenuArchivedOpen)
    }

    private func disclosureMotion(opening: Bool) -> Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .easeOut(duration: 0.12) }
        return opening ? .spring(response: 0.42, dampingFraction: 0.86) : .easeInOut(duration: 0.26)
    }

    private var archivedContentHeight: CGFloat {
        model.notebook.history.isEmpty ? 23 : CGFloat(model.notebook.history.count) * 25 - 1
    }

    private var contentHeight: CGFloat {
        84 + CGFloat(model.inProgressNotes.count) * 25
            + (model.titleMenuArchivedOpen ? archivedContentHeight : 0)
    }

    private var menuWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        var labels = ["编辑便签名称"]
        labels += model.inProgressNotes.map(\.labelName)
        if model.titleMenuArchivedOpen, model.notebook.history.isEmpty {
            labels.append("暂无归档便签")
        }
        var width = (labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 60) + 58
        if model.titleMenuArchivedOpen {
            let dateFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            for note in model.notebook.history {
                let nameWidth = (note.labelName as NSString).size(withAttributes: [.font: font]).width
                let dateWidth = (note.archiveDateLabel as NSString).size(withAttributes: [.font: dateFont]).width
                width = max(width, nameWidth + dateWidth + 72)
            }
        }
        return min(248, max(180, ceil(width)))
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            NoteMenuRow(label: "编辑便签名称", icon: "pencil") {
                model.closeTitleMenu()
                model.beginRenamingNote()
            }
            .disabled(model.storageBlocked)
            .opacity(model.storageBlocked ? 0.4 : 1)

            divider
            sectionHeader("进行中", count: model.inProgressNotes.count)
            ForEach(model.inProgressNotes) { note in
                noteRow(note, label: note.labelName)
            }

            divider
            archiveHeader
            VStack(spacing: 0) {
                if model.titleMenuArchivedOpen {
                    archivedRows
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .frame(height: model.titleMenuArchivedOpen ? archivedContentHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(model.titleMenuArchivedOpen)
            .accessibilityHidden(!model.titleMenuArchivedOpen)
            Color.clear.frame(height: 2)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
    }

    private var archivedRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            if model.notebook.history.isEmpty {
                Text("暂无归档便签")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.muted)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
            } else {
                ForEach(model.notebook.history.reversed()) { note in
                    NoteMenuRow(label: note.labelName, detail: note.archiveDateLabel,
                                selected: model.displayedNote.id == note.id) {
                        model.closeTitleMenu()
                        model.requestSelectNote?(note.id)
                    }
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Ink.line)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Ink.muted)
            Text("\(count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Ink.muted.opacity(0.8))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 17)
    }

    private var archiveHeader: some View {
        Button {
            withAnimation(disclosureMotion(opening: !model.titleMenuArchivedOpen)) {
                model.titleMenuArchivedOpen.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("已归档")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Ink.muted)
                Text("\(model.notebook.history.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Ink.muted.opacity(0.8))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Ink.muted)
                    .rotationEffect(.degrees(model.titleMenuArchivedOpen ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: 23)
            .contentShape(Rectangle())
            .background(archiveHovered ? Ink.accent.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { archiveHovered = $0 }
        .accessibilityLabel("已归档 \(model.notebook.history.count) 项")
        .accessibilityValue(model.titleMenuArchivedOpen ? "已展开" : "已收起")
    }

    private func noteRow(_ note: MemoNote, label: String) -> some View {
        NoteMenuRow(label: label, selected: model.displayedNote.id == note.id) {
            model.closeTitleMenu()
            model.requestSelectNote?(note.id)
        }
    }

}

private struct NoteMenuRow: View {
    let label: String
    var detail: String? = nil
    var icon: String? = nil
    var selected = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.accent)
                        .frame(width: 12)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Ink.muted)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12)
                }
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: detail == nil ? 0 : 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Ink.muted.opacity(0.8))
                        .lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
            .background(hovered ? Ink.accent.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

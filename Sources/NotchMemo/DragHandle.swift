import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskDragSurface: NSViewRepresentable {
    let id: UUID
    let canDrag: Bool
    let preview: (NSSize) -> NSImage?
    let onClick: () -> Void
    let onCheck: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let completed: Bool
    let onHandleHover: (Bool) -> Void
    let onBegin: () -> Bool
    let onEnd: (Bool) -> Void

    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }
    func updateNSView(_ view: SurfaceView, context: Context) {
        view.taskID = id
        view.canDrag = canDrag
        view.preview = preview
        view.onClick = onClick
        view.onCheck = onCheck
        view.onEdit = onEdit
        view.onDelete = onDelete
        view.completed = completed
        view.onHandleHover = onHandleHover
        view.onBegin = onBegin
        view.onEnd = onEnd
        view.window?.invalidateCursorRects(for: view)
    }

    final class SurfaceView: NSView {
        var taskID = UUID()
        var canDrag = true
        var preview: ((NSSize) -> NSImage?)?
        var onClick: (() -> Void)?
        var onCheck: (() -> Void)?
        var onEdit: (() -> Void)?
        var onDelete: (() -> Void)?
        var completed = false
        var onHandleHover: ((Bool) -> Void)?
        private var handleHovered = false
        private var pointerTracking: NSTrackingArea?
        var onBegin: (() -> Bool)?
        var onEnd: ((Bool) -> Void)?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private var checkboxRect: NSRect {
            NSRect(x: MemoLayout.rowInset, y: bounds.midY - 14, width: MemoLayout.iconColumn, height: 28)
        }

        private var handleRect: NSRect {
            NSRect(x: bounds.maxX - 31, y: bounds.midY - 16, width: 26, height: 32)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
            if canDrag { addCursorRect(handleRect, cursor: .openHand) }
            addCursorRect(checkboxRect, cursor: .pointingHand)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTracking { removeTrackingArea(pointerTracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            pointerTracking = area
        }

        override func mouseEntered(with event: NSEvent) { updateHandleHover(at: convert(event.locationInWindow, from: nil)) }
        override func mouseMoved(with event: NSEvent) { updateHandleHover(at: convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { setHandleHover(false) }

        private func updateHandleHover(at point: NSPoint) { setHandleHover(canDrag && handleRect.contains(point)) }
        private func setHandleHover(_ value: Bool) {
            guard value != handleHovered else { return }
            handleHovered = value
            onHandleHover?(value)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // Finish an explicit editor before interacting with a different task.
            window.makeFirstResponder(nil)
            let start = convert(event.locationInWindow, from: nil)
            let checking = checkboxRect.contains(start)
            let gripping = !completed && handleRect.contains(start)
            updateHandleHover(at: start)
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                               until: .distantFuture, inMode: .eventTracking, dequeue: true) {
                let point = convert(next.locationInWindow, from: nil)
                if next.type == .leftMouseUp {
                    guard bounds.contains(point) else { return }
                    if checking {
                        if checkboxRect.contains(point) { onCheck?() }
                    } else if !gripping { onClick?() }
                    return
                }
                let distance = hypot(point.x - start.x, point.y - start.y)
                // Reordering is only allowed from the grip; dragging elsewhere
                // keeps the row's normal click behaviour instead.
                if Self.shouldStartDrag(gripping: gripping, canDrag: canDrag, distance: distance) {
                    startDrag(with: next)
                    return
                }
            }
        }

        static func shouldStartDrag(gripping: Bool, canDrag: Bool, distance: CGFloat) -> Bool {
            gripping && canDrag && distance >= 4
        }

        private func startDrag(with event: NSEvent) {
            guard let image = preview?(bounds.size), onBegin?() == true else { return }
            let item = NSDraggingItem(pasteboardWriter: taskID.uuidString as NSString)
            // Include the card's soft shadow, keeping the grab point attached to the row.
            item.setDraggingFrame(NSRect(x: -8, y: -8, width: image.size.width, height: image.size.height), contents: image)
            // Reordering can recycle this SwiftUI row. The source must outlive the row.
            let source = DragSessionSource(onEnd: onEnd)
            let session = beginDraggingSession(with: [item], event: event, source: source)
            source.retainForSession(session)
            session.animatesToStartingPositionsOnCancelOrFail = true
            if Bundle.main.object(forInfoDictionaryKey: "NotchMemoVerificationMode") as? Bool == true,
               let directory = Bundle.main.object(forInfoDictionaryKey: "NotchMemoDataDirectory") as? String,
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("last-drag-preview.png"), options: .atomic)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            for (title, action) in [("编辑", #selector(editTask)),
                                    (completed ? "恢复任务" : "完成任务", #selector(checkTask))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let delete = NSMenuItem(title: "删除", action: #selector(deleteTask), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
            return menu
        }

        @objc private func editTask() {
            // Open the editor after the context menu's tracking loop has relinquished focus.
            let edit = onEdit
            RunLoop.main.perform(inModes: [.default]) { edit?() }
        }
        @objc private func checkTask() { onCheck?() }
        @objc private func deleteTask() { onDelete?() }
    }
}

private final class DragSessionSource: NSObject, NSDraggingSource {
    private static var sessions: [Int: DragSessionSource] = [:]
    private let onEnd: ((Bool) -> Void)?
    private var ended = false

    init(onEnd: ((Bool) -> Void)?) { self.onEnd = onEnd }

    func retainForSession(_ session: NSDraggingSession) {
        if !ended { Self.sessions[session.draggingSequenceNumber] = self }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard !ended else { return }
        ended = true
        Self.sessions.removeValue(forKey: session.draggingSequenceNumber)
        onEnd?(operation.contains(.move))
    }
}

struct TaskDropDelegate: DropDelegate {
    let target: UUID?
    let model: MemoModel
    func validateDrop(info: DropInfo) -> Bool { model.draggingID != nil }
    func dropEntered(info: DropInfo) { model.moveDrag(before: target) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard model.draggingID != nil else { return false }
        model.moveDrag(before: target)
        model.finishDrag(accepted: true)
        return true
    }
}

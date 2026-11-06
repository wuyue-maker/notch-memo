import AppKit
import SwiftUI

/// A wrapping editor with the same font, line spacing and zero leading inset as task text.
struct TaskTextEditor: NSViewRepresentable {
    @Binding var text: String
    let completed: Bool
    let onFocus: (Bool) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TaskEditorView {
        let view = TaskEditorView(frame: NSRect(x: 0, y: 0,
                                                width: TaskTextLayout.textWidth(completed: completed),
                                                height: TaskTextLayout.editorHeight(text: text, completed: completed)))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = TaskTextLayout.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        view.delegate = context.coordinator
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = TaskTextLayout.font
        view.textColor = NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.21, alpha: 1)
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: TaskTextLayout.font, .paragraphStyle: paragraph,
                                 .foregroundColor: view.textColor!]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        // SwiftUI and the outer task list manage height and scrolling together.
        view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: TaskTextLayout.textWidth(completed: completed),
                                                  height: .greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: view.typingAttributes))
        view.setAccessibilityLabel("编辑任务")
        view.toolTip = "回车保存，Shift + 回车换行，Escape 取消"
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let coordinator = context.coordinator
        view.onFocus = { [weak coordinator] in coordinator?.parent.onFocus(true) }
        view.onResign = { [weak coordinator, weak view] in
            guard let view else { return }
            coordinator?.endEditing(text: view.string)
        }
        view.onSubmit = { [weak coordinator, weak view] in
            guard let view else { return }
            coordinator?.submit(view)
        }
        view.onCancel = { [weak coordinator, weak view] in
            guard let view else { return }
            coordinator?.cancel(view)
        }
        return view
    }

    func updateNSView(_ view: TaskEditorView, context: Context) {
        context.coordinator.parent = self
        if !view.hasMarkedText(), view.string != text { view.string = text }
        view.scheduleInitialFocus()
    }

    static func dismantleNSView(_ view: TaskEditorView, coordinator: Coordinator) {
        coordinator.finished = true
        view.onFocus = nil
        view.onResign = nil
        view.onSubmit = nil
        view.onCancel = nil
        view.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TaskTextEditor
        var finished = false
        init(_ parent: TaskTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !finished else { return }
            parent.text = view.string
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window?.firstResponder === view else { return }
                view.scrollRangeToVisible(view.selectedRange())
            }
        }

        func endEditing(text: String) {
            guard !finished else { return }
            finished = true
            parent.text = text
            parent.onFocus(false)
            parent.onEnd()
        }

        func submit(_ textView: NSTextView) {
            guard !finished else { return }
            parent.text = textView.string
            finished = true
            parent.onFocus(false)
            parent.onSubmit()
            textView.window?.makeFirstResponder(nil)
        }

        func cancel(_ textView: NSTextView) {
            guard !finished else { return }
            finished = true
            parent.onFocus(false)
            parent.onCancel()
            textView.window?.makeFirstResponder(nil)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText(), !finished,
                  !((textView as? TaskEditorView)?.isHandlingCompositionKey ?? false) else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                submit(textView)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancel(textView)
                return true
            }
            return false
        }
    }
}

final class TaskEditorView: NSTextView {
    var onFocus: (() -> Void)?
    var onResign: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isHandlingCompositionKey = false
    private var needsInitialFocus = true
    private var focusScheduled = false

    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleInitialFocus() }

    func scheduleInitialFocus() {
        guard needsInitialFocus, !focusScheduled, window != nil else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            guard self.needsInitialFocus, let window = self.window else { return }
            window.makeKey()
            if window.makeFirstResponder(self) {
                self.needsInitialFocus = false
                self.setSelectedRange(NSRange(location: 0, length: 0))
                self.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onResign?() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    enum KeyAction: Equatable { case system, save, newline, cancel }

    static func keyAction(code: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool) -> KeyAction {
        guard !composing else { return .system }
        if code == 53 { return .cancel }
        if code == 36 || code == 76 {
            return modifiers.contains(.shift) || modifiers.contains(.option) ? .newline : .save
        }
        return .system
    }

    override func keyDown(with event: NSEvent) {
        isHandlingCompositionKey = hasMarkedText()
        defer { isHandlingCompositionKey = false }
        switch Self.keyAction(code: event.keyCode, modifiers: event.modifierFlags, composing: isHandlingCompositionKey) {
        case .system: super.keyDown(with: event)
        case .newline: insertNewline(nil)
        case .save: onSubmit?()
        case .cancel: onCancel?()
        }
    }
}

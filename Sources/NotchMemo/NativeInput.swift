import AppKit
import SwiftUI

/// Uses AppKit's field editor so composition and candidate selection stay native.
struct NativeInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var autofocus = false
    var focusRequest: UUID?
    var font: NSFont = .systemFont(ofSize: 13)
    var limitText: ((String) -> String)?
    var onFocus: (Bool) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InputField {
        let field = InputField()
        field.delegate = context.coordinator
        field.onClickFocus = { context.coordinator.parent.onFocus(true) }
        field.isBordered = false
        field.isBezeled = false
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = NSColor(calibratedRed: 0.22, green: 0.23, blue: 0.20, alpha: 1)
        field.placeholderString = placeholder
        field.stringValue = text
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.autofocus = autofocus
        field.focusRequest = focusRequest
        field.focusWhenReady()
        return field
    }

    func updateNSView(_ field: InputField, context: Context) {
        context.coordinator.parent = self
        let isComposing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if field.stringValue != text, !isComposing {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.font = font
        field.autofocus = autofocus
        field.focusRequest = focusRequest
        field.focusWhenReady()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeInput
        private var wasCancelled = false
        init(_ parent: NativeInput) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            wasCancelled = false
            parent.onFocus(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = limitedValue(field)
        }

        private func limitedValue(_ field: NSTextField, value: String? = nil) -> String {
            let editor = field.currentEditor() as? NSTextView
            let value = value ?? field.stringValue
            guard editor?.hasMarkedText() != true, let limitText = parent.limitText else { return value }
            let limited = limitText(value)
            if limited != value {
                let selection = editor?.selectedRange() ?? NSRange(location: limited.utf16.count, length: 0)
                field.stringValue = limited
                editor?.string = limited
                editor?.setSelectedRange(NSRange(location: min(selection.location, limited.utf16.count), length: 0))
            }
            return limited
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = limitedValue(field) }
            parent.onFocus(false)
            if !wasCancelled { parent.onEnd() }
            wasCancelled = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let field = control as? NSTextField { parent.text = limitedValue(field, value: textView.string) }
                else { parent.text = parent.limitText?(textView.string) ?? textView.string }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                wasCancelled = true
                parent.onCancel()
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

final class InputField: NSTextField {
    var onClickFocus: (() -> Void)?
    var autofocus = false
    var focusRequest: UUID? {
        didSet { if focusRequest != oldValue, focusRequest != nil { didAutofocus = false } }
    }
    private var didAutofocus = false
    private var focusScheduled = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusWhenReady()
    }
    func focusWhenReady() {
        guard autofocus, !didAutofocus, !focusScheduled, window != nil else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            guard self.autofocus, !self.didAutofocus, let window = self.window else { return }
            self.didAutofocus = true
            window.makeKey()
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
        if currentEditor() != nil { onClickFocus?() }
    }
}

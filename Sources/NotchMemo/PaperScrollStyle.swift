import AppKit
import SwiftUI

/// Keep the native scrolling and dragging behavior, with paper-colored overlay chrome.
struct PaperScrollStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollStyleAnchor { ScrollStyleAnchor() }

    func updateNSView(_ view: ScrollStyleAnchor, context: Context) {
        view.scheduleInstall()
    }

    final class ScrollStyleAnchor: NSView {
        private var preferenceObserver: NSObjectProtocol?
        private var installScheduled = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
            preferenceObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.scheduleInstall() }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleInstall() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleInstall() }

        func scheduleInstall() {
            guard !installScheduled else { return }
            installScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.installScheduled = false
                self.install()
            }
        }

        private func install() {
            guard let scrollView = enclosingScrollView else { return }
            if !(scrollView.verticalScroller is PaperScroller) {
                let scroller = PaperScroller()
                scroller.controlSize = .small
                scrollView.verticalScroller = scroller
            }
            // SwiftUI's hidden indicator can still leave legacy chrome under Always Show.
            // Explicit overlay chrome prevents a white slot from reserving paper width.
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if !scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = true }
            if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
            if scrollView.drawsBackground { scrollView.drawsBackground = false }
            if scrollView.borderType != .noBorder { scrollView.borderType = .noBorder }
        }
    }
}

final class PaperScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var isOpaque: Bool { false }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Transparent track: leave the paper visible all the way to the edge.
    }

    override func drawKnob() {
        guard isEnabled, knobProportion < 1 else { return }
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let capsule = NSRect(x: knob.midX - 1.5, y: knob.minY + 2,
                             width: 3, height: max(4, knob.height - 4))
        NSColor(calibratedRed: 0.43, green: 0.40, blue: 0.32, alpha: 0.36).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

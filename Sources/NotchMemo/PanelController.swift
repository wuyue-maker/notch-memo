import AppKit
import SwiftUI
import MemoCore

final class MemoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
}

final class MemoHostingView: NSHostingView<MemoView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model: MemoModel
    let panel: MemoPanel
    private var hover = HoverMachine()
    private var safetyTimer: Timer?
    private var hoverTimer: Timer?
    private var eventMonitors: [Any] = []
    private var hotZone = NSRect.zero
    private var targetScreen: NSScreen?
    private var hideJob: DispatchWorkItem?
    private var holdUntil: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastVerificationRecord: TimeInterval = 0

    init(model: MemoModel) {
        self.model = model
        panel = MemoPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "刘海便签"
        panel.identifier = NSUserInterfaceItemIdentifier("NotchMemoPanel")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        panel.animationBehavior = .none
        panel.escape = { [weak self] in self?.hide() }
        panel.contentView = MemoHostingView(rootView: MemoView(model: model))
        model.requestClose = { [weak self] in self?.hide() }
        model.requestResize = { [weak self] in self?.resize() }
        model.requestNewNote = { [weak self] in self?.createNote() }
        model.requestSelectNote = { [weak self] id in self?.selectNote(id) }
        model.requestPaperSnapshot = { [weak self] in self?.capturePaperSnapshot() }
        updateScreen()
        observeEnvironment()
        startPointerMonitoring()
    }

    /// Hover detection is event driven: global/local mouse monitors feed the
    /// state machine as soon as the pointer moves. A low-frequency safety probe
    /// catches anything a monitor can miss (cursor warps, event taps), and a
    /// short timer only runs while a show/hide deadline is pending. That keeps
    /// a hidden note at ~3 wake-ups per second instead of a constant 12.5 Hz.
    private func startPointerMonitoring() {
        guard safetyTimer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
        installMouseMonitors()
    }

    private func stopPointerMonitoring() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
    }

    private func installMouseMonitors() {
        guard eventMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pollPointer() }
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    /// Runs only while the state machine is waiting for its 0.3s/0.6s deadline.
    private func syncHoverTimer() {
        let pending = hover.isWaitingForShow || hover.isWaitingForHide
        if pending, hoverTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollPointer() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        } else if !pending, hoverTimer != nil {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
    }

    /// Captures the paper exactly as it is on screen, before the finished note is
    /// archived and replaced. The crinkle animation runs on this frozen bitmap.
    private func capturePaperSnapshot() -> NSImage? {
        guard panel.isVisible, let view = panel.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let full = rep.cgImage else { return nil }
        let sx = CGFloat(full.width) / bounds.width
        let sy = CGFloat(full.height) / bounds.height
        let top = (model.topInset + MemoLayout.paperTopOffset) * sy
        let height = CGFloat(full.height) - top - MemoLayout.paperBottomPadding * sy
        guard height > 4 else { return nil }
        let rect = CGRect(x: MemoLayout.paperMargin * sx, y: top,
                          width: CGFloat(full.width) - 2 * MemoLayout.paperMargin * sx,
                          height: height).integral
        guard let cropped = full.cropping(to: rect) else { return nil }
        // cacheDisplay gives the paper a white backdrop outside its rounded
        // corners; mask it so the falling sheet keeps clean paper edges.
        let pixelRect = CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        bitmap.addPath(CGPath(roundedRect: pixelRect.insetBy(dx: 0.5, dy: 0.5),
                              cornerWidth: MemoLayout.paperCornerRadius * sx,
                              cornerHeight: MemoLayout.paperCornerRadius * sx,
                              transform: nil))
        bitmap.clip()
        bitmap.draw(cropped, in: pixelRect)
        guard let masked = bitmap.makeImage() else { return nil }
        return NSImage(cgImage: masked, size: NSSize(width: bounds.width - 28, height: height / sy))
    }

    func updateScreen() {
        targetScreen = builtInScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }
        let inset = screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let notchWidth: CGFloat
        if inset > 0, let left, let right, right.minX > left.maxX {
            notchWidth = right.minX - left.maxX
        } else { notchWidth = 180 }
        model.topInset = inset
        model.notchWidth = notchWidth + (inset > 0 ? 4 : 0)
        model.maxCardHeight = min(520, max(272, screen.visibleFrame.height * 0.55))
        // Only the very top edge, exactly as wide as the notch. Moving below
        // the notch must not summon the note.
        let edgeBand: CGFloat = 5
        hotZone = NSRect(x: screen.frame.midX - notchWidth / 2,
                         y: screen.frame.maxY - edgeBand,
                         width: notchWidth, height: edgeBand)
        resize()
    }

    func resize() {
        guard let screen = targetScreen else { return }
        let size = NSSize(width: MemoLayout.panelWidth,
                          height: MemoLayout.panelHeight(topInset: model.topInset,
                                                         cardHeight: model.cardHeight))
        let rect = NSRect(x: screen.frame.midX - size.width / 2,
                          y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height)
        // Persisting calls this on every edit; skip the redundant window resize.
        guard panel.frame != rect else { return }
        panel.setFrame(rect, display: panel.isVisible)
    }

    func show(fromMenu: Bool = false, pin: Bool = false) {
        guard !hover.isSuspended else { return }
        hideJob?.cancel()
        hideJob = nil
        updateScreen()
        hover.show()
        if pin { model.isPinned = true }
        if fromMenu { holdUntil = ProcessInfo.processInfo.systemUptime + 2.5 }
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        withAnimation(model.appearanceMotion) { model.isPresented = true }
    }

    func hide(force: Bool = false) {
        if !force, model.isTitleMenuOpen {
            model.closeTitleMenu()
            return
        }
        if !force, let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
            model.banner = "请先完成当前选词，再收起便签。"
            return
        }
        model.closeTitleMenu()
        panel.makeFirstResponder(nil)
        model.activeInput = nil
        model.editingID = nil
        model.finishDrag(accepted: false)
        model.isPinned = false
        hover.hide()
        withAnimation(model.dismissalMotion) { model.isPresented = false }
        // Do not swallow clicks in the empty panel area while the sheet curls away.
        panel.ignoresMouseEvents = true
        hideJob?.cancel()
        if force {
            panel.orderOut(nil)
        } else {
            let job = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideJob = job
            // Long enough for the sticker to finish curling back under the notch.
            let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
        }
    }

    private func endInputForNoteChange() -> Bool {
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
            model.banner = "请先完成当前选词，再切换或新建便签。"
            return false
        }
        panel.makeFirstResponder(nil)
        return true
    }

    func createNote() {
        guard !model.storageBlocked, endInputForNoteChange() else { return }
        show(fromMenu: true)
        model.createNote()
    }

    func selectNote(_ id: UUID?) {
        guard endInputForNoteChange() else { return }
        model.showNote(id)
        show(fromMenu: true)
    }

    private func pollPointer() {
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        model.recoverReleasedDrag(isMouseDown: NSEvent.pressedMouseButtons & 1 != 0, now: now)
        hover.isPinned = model.isPinned
        hover.isEditing = model.isInteracting || now < holdUntil
        hover.isDragging = model.draggingID != nil
        // NSRect.contains excludes the max edges; the pointer parked on the
        // very top of the screen reports y == screen.maxY, which must count.
        let onHotZone = point.x >= hotZone.minX && point.x <= hotZone.maxX
            && point.y >= hotZone.minY && point.y <= hotZone.maxY
        switch hover.step(inHotZone: onHotZone,
                          inPanel: model.isPresented && panel.frame.insetBy(dx: 4, dy: 0).contains(point), now: now) {
        case .show: show()
        case .hide: hide()
        case nil: break
        }
        if Bundle.main.object(forInfoDictionaryKey: "NotchMemoVerificationMode") as? Bool == true,
           now - lastVerificationRecord > 0.5 {
            lastVerificationRecord = now
            recordVerificationState()
        }
        syncHoverTimer()
    }

    private func recordVerificationState() {
        let values: [String: Any] = [
            "visible": panel.isVisible,
            "presented": model.isPresented,
            "onActiveSpace": panel.isOnActiveSpace,
            "occlusionVisible": panel.occlusionState.contains(.visible),
            "isKey": panel.isKeyWindow,
            "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "screen": NSStringFromRect(targetScreen?.frame ?? .zero),
            "topInset": model.topInset,
            "notchWidth": model.notchWidth,
            "hotZone": NSStringFromRect(hotZone),
            "panel": NSStringFromRect(panel.frame),
            "pointer": NSStringFromPoint(NSEvent.mouseLocation)
        ]
        let directory = model.repository.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("runtime.json"), options: .atomic)
        }
    }

    private func observeEnvironment() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScreen() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.objectWillChange.send() }
        })
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hide(force: true)
                    self.hover.isSuspended = true
                    self.stopPointerMonitoring()
                    self.model.persist()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hover.isSuspended = false
                    self?.startPointerMonitoring()
                    self?.updateScreen()
                }
            })
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        panel.makeFirstResponder(nil)
        model.activeInput = nil
        model.closeTitleMenu()
    }

    func diagnostics() -> String {
        let screen = targetScreen
        return """
        刘海便签 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
        屏幕：\(screen?.localizedName ?? "未知")
        屏幕范围：\(NSStringFromRect(screen?.frame ?? .zero))
        顶部安全区：\(model.topInset) pt
        刘海宽度：\(model.notchWidth) pt
        悬停区域：\(NSStringFromRect(hotZone))
        面板范围：\(NSStringFromRect(panel.frame))
        窗口层级：\(panel.level.rawValue)
        数据目录：\(model.repository.directory.path)
        """
    }
}

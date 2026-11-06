import Foundation

public struct HoverMachine {
    public enum Action: Equatable { case show, hide }
    public private(set) var isVisible = false
    public var isPinned = false
    public var isEditing = false
    public var isDragging = false
    public var isSuspended = false
    public var showDelay: TimeInterval = 0.3
    public var hideDelay: TimeInterval = 0.6
    private var enteredAt: TimeInterval?
    private var exitedAt: TimeInterval?
    private var suppressUntilExit = false

    public init() {}

    /// A show deadline is pending: the pointer is inside the hot zone and the
    /// dwell timer is running.
    public var isWaitingForShow: Bool {
        !isVisible && !isSuspended && !suppressUntilExit && enteredAt != nil
    }

    /// A hide deadline is pending: the pointer has left the panel.
    public var isWaitingForHide: Bool {
        isVisible && exitedAt != nil && !isPinned && !isEditing && !isDragging
    }

    public mutating func show() {
        isVisible = true
        enteredAt = nil
        exitedAt = nil
        suppressUntilExit = false
    }

    public mutating func hide(suppress: Bool = true) {
        isVisible = false
        isPinned = false
        enteredAt = nil
        exitedAt = nil
        suppressUntilExit = suppress
    }

    public mutating func step(inHotZone: Bool, inPanel: Bool, now: TimeInterval) -> Action? {
        if isSuspended {
            enteredAt = nil
            exitedAt = nil
            if isVisible { hide(); return .hide }
            return nil
        }
        if !inHotZone { suppressUntilExit = false }
        if !isVisible {
            guard inHotZone, !suppressUntilExit else { enteredAt = nil; return nil }
            if enteredAt == nil { enteredAt = now }
            if now - enteredAt! >= showDelay { show(); return .show }
            return nil
        }
        guard !isPinned, !isEditing, !isDragging, !inHotZone, !inPanel else {
            exitedAt = nil
            return nil
        }
        if exitedAt == nil { exitedAt = now }
        if now - exitedAt! >= hideDelay { hide(); return .hide }
        return nil
    }
}

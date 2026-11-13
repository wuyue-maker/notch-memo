import AppKit
import ServiceManagement

/// Why the login item cannot be offered from where this copy of the app runs.
enum LaunchAtLoginBlocker: Equatable {
    /// A bare SwiftPM executable, not an application bundle the system can record.
    case notAnApplicationBundle
    /// A disk image or an App Translocation copy: the recorded path disappears as
    /// soon as the image is ejected or the temporary copy is cleaned up.
    case temporaryLocation

    var guidance: String {
        switch self {
        case .notAnApplicationBundle:
            "当前运行的是开发版可执行文件，只有打包后的「刘海便签」才能登记开机自启。"
        case .temporaryLocation:
            "请先把「刘海便签」拖进「应用程序」文件夹，再开启开机自启。"
        }
    }
}

/// The app's own login item, as the menu reports it.
enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    /// Registered, but the user still has to allow it in System Settings.
    case awaitingApproval
}

/// The system registration, kept behind a protocol so the menu rules stay testable.
protocol LaunchAtLoginBackend {
    var state: LaunchAtLoginState { get }
    func register() throws
    func unregister() throws
}

struct SystemLaunchAtLoginBackend: LaunchAtLoginBackend {
    var state: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .awaitingApproval
        default: .disabled
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Registers the app itself to open when the user logs in. The system owns the
/// registration, so nothing about it is stored in the task file.
@MainActor
final class LaunchAtLoginService {
    enum Outcome: Equatable {
        case enabled
        case disabled
        case pendingApproval
        case blocked(String)
        case failed(String)
    }

    static let title = "开机自动启动"

    private let backend: LaunchAtLoginBackend
    private let bundlePath: String
    private let hasBundleIdentifier: Bool

    init(backend: LaunchAtLoginBackend = SystemLaunchAtLoginBackend(),
         bundlePath: String = Bundle.main.bundlePath,
         hasBundleIdentifier: Bool = Bundle.main.bundleIdentifier != nil) {
        self.backend = backend
        self.bundlePath = bundlePath
        self.hasBundleIdentifier = hasBundleIdentifier
    }

    var state: LaunchAtLoginState { backend.state }
    var isEnabled: Bool { state == .enabled }
    var blocker: LaunchAtLoginBlocker? {
        Self.blocker(bundlePath: bundlePath, hasBundleIdentifier: hasBundleIdentifier)
    }

    /// A mixed mark means registered but still waiting for the user's approval.
    var menuState: NSControl.StateValue {
        switch state {
        case .enabled: .on
        case .awaitingApproval: .mixed
        case .disabled: .off
        }
    }

    var summary: String {
        if let blocker { return "开机自启：不可用（\(blocker.guidance)）" }
        switch state {
        case .enabled: return "开机自启：已开启"
        case .awaitingApproval: return "开机自启：已登记，等待在系统设置中允许"
        case .disabled: return "开机自启：未开启"
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Outcome {
        if enabled, let blocker { return .blocked(blocker.guidance) }
        do {
            if enabled { try backend.register() } else { try backend.unregister() }
        } catch {
            return .failed(error.localizedDescription)
        }
        switch backend.state {
        case .enabled: return .enabled
        case .awaitingApproval: return enabled ? .pendingApproval : .disabled
        // The call returned without changing anything: say so instead of
        // showing a checkmark the system does not honour.
        case .disabled: return enabled ? .failed("系统没有接受这次登记，请稍后重试。") : .disabled
        }
    }

    /// One line for the `--launch-at-login` hook and the copied run information.
    func commandOutput(_ action: String) -> String {
        switch action {
        case "on", "off":
            let outcome = setEnabled(action == "on")
            return "\(Self.message(for: outcome) ?? "系统已接受这次修改。")\n\(summary)"
        default:
            return summary
        }
    }

    static func blocker(bundlePath: String, hasBundleIdentifier: Bool) -> LaunchAtLoginBlocker? {
        guard hasBundleIdentifier, bundlePath.hasSuffix(".app") else { return .notAnApplicationBundle }
        if bundlePath.hasPrefix("/Volumes/") || bundlePath.contains("/AppTranslocation/") {
            return .temporaryLocation
        }
        return nil
    }

    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .enabled, .disabled: return nil
        case .pendingApproval: return "已登记开机自启，请在「系统设置 → 通用 → 登录项与扩展」中允许刘海便签。"
        case .blocked(let guidance): return guidance
        case .failed(let reason): return "无法修改开机自启：\(reason)"
        }
    }
}

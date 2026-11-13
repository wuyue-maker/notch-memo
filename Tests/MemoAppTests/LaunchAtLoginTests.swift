import XCTest
import AppKit
@testable import NotchMemo

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    private final class FakeBackend: LaunchAtLoginBackend {
        var state: LaunchAtLoginState = .disabled
        var registerCount = 0
        var unregisterCount = 0
        var registerError: Error?
        var unregisterError: Error?
        /// What the system reports afterwards, including a registration it ignores.
        var registerResult: LaunchAtLoginState = .enabled
        var unregisterResult: LaunchAtLoginState = .disabled

        func register() throws {
            registerCount += 1
            if let registerError { throw registerError }
            state = registerResult
        }

        func unregister() throws {
            unregisterCount += 1
            if let unregisterError { throw unregisterError }
            state = unregisterResult
        }
    }

    private func service(_ backend: FakeBackend,
                         path: String = "/Applications/刘海便签.app",
                         hasIdentifier: Bool = true) -> LaunchAtLoginService {
        LaunchAtLoginService(backend: backend, bundlePath: path, hasBundleIdentifier: hasIdentifier)
    }

    func testTogglingRegistersAndUnregistersTheAppItself() {
        let backend = FakeBackend()
        let subject = service(backend)
        XCTAssertEqual(subject.menuState, .off)
        XCTAssertEqual(subject.setEnabled(true), .enabled)
        XCTAssertEqual(backend.registerCount, 1)
        XCTAssertEqual(subject.menuState, .on)
        XCTAssertTrue(subject.isEnabled)
        XCTAssertNil(LaunchAtLoginService.message(for: .enabled))
        XCTAssertEqual(subject.setEnabled(false), .disabled)
        XCTAssertEqual(backend.unregisterCount, 1)
        XCTAssertEqual(subject.menuState, .off)
    }

    func testApprovalRequestKeepsAMixedMarkAndExplainsWhereToAllowIt() throws {
        let backend = FakeBackend()
        backend.registerResult = .awaitingApproval
        let subject = service(backend)
        let outcome = subject.setEnabled(true)
        XCTAssertEqual(outcome, .pendingApproval)
        XCTAssertEqual(subject.menuState, .mixed)
        XCTAssertFalse(subject.isEnabled)
        let message = try XCTUnwrap(LaunchAtLoginService.message(for: outcome))
        XCTAssertTrue(message.contains("登录项与扩展"))
        // Clicking the mixed item asks again instead of doing nothing silently.
        _ = subject.setEnabled(!subject.isEnabled)
        XCTAssertEqual(backend.registerCount, 2)
    }

    func testAFailedRegistrationStaysOffAndCarriesTheSystemReason() throws {
        let backend = FakeBackend()
        backend.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "操作不被允许"])
        let subject = service(backend)
        guard case .failed(let reason) = subject.setEnabled(true) else { return XCTFail("应当报告失败") }
        XCTAssertTrue(reason.contains("操作不被允许"))
        XCTAssertEqual(subject.menuState, .off)
        let message = try XCTUnwrap(LaunchAtLoginService.message(for: .failed(reason)))
        XCTAssertTrue(message.hasPrefix("无法修改开机自启："))
    }

    func testASilentlyIgnoredRegistrationIsNotShownAsOn() {
        let backend = FakeBackend()
        backend.registerResult = .disabled
        let subject = service(backend)
        guard case .failed = subject.setEnabled(true) else { return XCTFail("登记没生效就不能报告已开启") }
        XCTAssertEqual(subject.menuState, .off)
    }

    func testOnlyInstalledBundlesCanHoldALoginItem() {
        XCTAssertNil(LaunchAtLoginService.blocker(bundlePath: "/Applications/刘海便签.app", hasBundleIdentifier: true))
        XCTAssertEqual(LaunchAtLoginService.blocker(bundlePath: "/Users/me/.build/release/NotchMemo", hasBundleIdentifier: true), .notAnApplicationBundle)
        XCTAssertEqual(LaunchAtLoginService.blocker(bundlePath: "/Applications/刘海便签.app", hasBundleIdentifier: false), .notAnApplicationBundle)
        XCTAssertEqual(LaunchAtLoginService.blocker(bundlePath: "/Volumes/刘海便签/刘海便签.app", hasBundleIdentifier: true), .temporaryLocation)
        XCTAssertEqual(LaunchAtLoginService.blocker(bundlePath: "/private/var/folders/xy/AppTranslocation/ABC-1/d/刘海便签.app", hasBundleIdentifier: true), .temporaryLocation)
    }

    func testATemporaryLocationNeverTouchesTheSystem() {
        let backend = FakeBackend()
        let subject = service(backend, path: "/Volumes/刘海便签/刘海便签.app")
        guard case .blocked(let guidance) = subject.setEnabled(true) else { return XCTFail("不该登记") }
        XCTAssertTrue(guidance.contains("应用程序"))
        XCTAssertEqual(backend.registerCount, 0)
        XCTAssertTrue(subject.summary.contains("不可用"))
    }

    func testCommandOutputReportsTheChangeAndTheStateThatFollows() {
        let backend = FakeBackend()
        let subject = service(backend)
        XCTAssertEqual(subject.commandOutput("status"), "开机自启：未开启")
        XCTAssertEqual(subject.commandOutput("on"), "系统已接受这次修改。\n开机自启：已开启")
        XCTAssertEqual(subject.commandOutput("off"), "系统已接受这次修改。\n开机自启：未开启")
    }
}

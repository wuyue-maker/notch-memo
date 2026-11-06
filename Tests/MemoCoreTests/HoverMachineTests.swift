import XCTest
@testable import MemoCore

final class HoverMachineTests: XCTestCase {
    func testBriefPassDoesNotOpenAndReentryRestartsDwell() {
        var machine = HoverMachine()
        XCTAssertNil(machine.step(inHotZone: true, inPanel: false, now: 0))
        XCTAssertNil(machine.step(inHotZone: false, inPanel: false, now: 0.2))
        XCTAssertNil(machine.step(inHotZone: true, inPanel: false, now: 1))
        XCTAssertNil(machine.step(inHotZone: true, inPanel: false, now: 1.2))
        XCTAssertEqual(machine.step(inHotZone: true, inPanel: false, now: 1.31), .show)
    }

    func testReturnToPanelCancelsHideTimer() {
        var machine = HoverMachine()
        machine.show()
        XCTAssertNil(machine.step(inHotZone: false, inPanel: false, now: 0))
        XCTAssertNil(machine.step(inHotZone: false, inPanel: true, now: 0.5))
        XCTAssertNil(machine.step(inHotZone: false, inPanel: false, now: 0.7))
        XCTAssertNil(machine.step(inHotZone: false, inPanel: false, now: 1.0))
        XCTAssertEqual(machine.step(inHotZone: false, inPanel: false, now: 1.31), .hide)
    }

    func testEditingDraggingAndPinningProtectPanel() {
        for protection in 0..<3 {
            var machine = HoverMachine()
            machine.show()
            machine.isPinned = protection == 0
            machine.isEditing = protection == 1
            machine.isDragging = protection == 2
            XCTAssertNil(machine.step(inHotZone: false, inPanel: false, now: 0))
            XCTAssertNil(machine.step(inHotZone: false, inPanel: false, now: 30))
            machine.isPinned = false; machine.isEditing = false; machine.isDragging = false
            XCTAssertNil(machine.step(inHotZone: false, inPanel: false, now: 31))
            XCTAssertEqual(machine.step(inHotZone: false, inPanel: false, now: 31.7), .hide)
        }
    }

    func testExplicitHideDoesNotReopenUntilPointerLeaves() {
        var machine = HoverMachine()
        machine.show(); machine.hide()
        XCTAssertNil(machine.step(inHotZone: true, inPanel: false, now: 0))
        XCTAssertNil(machine.step(inHotZone: true, inPanel: false, now: 10))
        XCTAssertNil(machine.step(inHotZone: false, inPanel: false, now: 11))
        XCTAssertNil(machine.step(inHotZone: true, inPanel: false, now: 12))
        XCTAssertEqual(machine.step(inHotZone: true, inPanel: false, now: 12.31), .show)
    }

    func testSessionSuspensionHidesEvenPinnedPanel() {
        var machine = HoverMachine()
        machine.show(); machine.isPinned = true; machine.isSuspended = true
        XCTAssertEqual(machine.step(inHotZone: true, inPanel: true, now: 0), .hide)
        XCTAssertNil(machine.step(inHotZone: true, inPanel: false, now: 1))
        XCTAssertFalse(machine.isVisible)
    }

    func testReportsPendingTransitionsForScheduling() {
        var machine = HoverMachine()
        XCTAssertFalse(machine.isWaitingForShow)
        _ = machine.step(inHotZone: true, inPanel: false, now: 0)
        XCTAssertTrue(machine.isWaitingForShow)
        _ = machine.step(inHotZone: true, inPanel: false, now: 0.3)
        XCTAssertTrue(machine.isVisible)
        XCTAssertFalse(machine.isWaitingForShow)
        _ = machine.step(inHotZone: false, inPanel: false, now: 1.0)
        XCTAssertTrue(machine.isWaitingForHide)
    }
}

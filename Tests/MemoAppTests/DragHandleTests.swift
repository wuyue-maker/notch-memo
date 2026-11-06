import XCTest
import CoreGraphics
@testable import NotchMemo

final class DragHandleTests: XCTestCase {
    func testReorderingOnlyStartsFromGrip() {
        XCTAssertTrue(TaskDragSurface.SurfaceView.shouldStartDrag(
            gripping: true, canDrag: true, distance: 5))
        XCTAssertFalse(TaskDragSurface.SurfaceView.shouldStartDrag(
            gripping: false, canDrag: true, distance: 40),
            "dragging the row text or blank space must not reorder")
    }

    func testReorderingNeedsThresholdAndPermission() {
        XCTAssertFalse(TaskDragSurface.SurfaceView.shouldStartDrag(
            gripping: true, canDrag: true, distance: 2))
        XCTAssertFalse(TaskDragSurface.SurfaceView.shouldStartDrag(
            gripping: true, canDrag: false, distance: 40))
    }
}

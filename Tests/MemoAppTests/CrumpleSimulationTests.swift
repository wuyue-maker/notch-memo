import XCTest
import simd
@testable import NotchMemo

final class CrumpleSimulationTests: XCTestCase {
    private func mesh() -> CrumpleMesh {
        // A deliberately tiny run: enough to exercise the folding constraints
        // without slowing the test suite down.
        CrumpleSimulation.build(aspect: 1.2, seed: 10, detail: 16,
                                frameCount: 8, stepsPerFrame: 1)
    }

    func testStartsFlatAndFoldsIntoBall() {
        let mesh = mesh()
        XCTAssertEqual(mesh.frames.count, 9)
        XCTAssertEqual(mesh.frames[0].count, mesh.vertexCount)
        XCTAssertEqual(mesh.vertexCount, mesh.rest.count)
        XCTAssertEqual(mesh.indices.count, mesh.triangleCount * 3)

        for (index, point) in mesh.frames[0].enumerated() {
            XCTAssertEqual(point.x, mesh.rest[index].x, accuracy: 0.0001)
            XCTAssertEqual(point.y, mesh.rest[index].y, accuracy: 0.0001)
            XCTAssertEqual(point.z, 0, accuracy: 0.0001)
        }

        func width(_ frame: [SIMD3<Float>]) -> Float {
            let xs = frame.map(\.x)
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        let start = width(mesh.frames[0])
        let end = width(mesh.frames[mesh.frames.count - 1])
        XCTAssertGreaterThan(start, 0.99)
        XCTAssertLessThan(end, start * 0.6, "the sheet should collapse to a paper ball")
    }

    func testFramesStayFiniteAndDeterministic() {
        let first = mesh()
        let second = mesh()
        for frame in first.frames {
            for point in frame {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite && point.z.isFinite)
            }
        }
        XCTAssertEqual(first.frames[first.frames.count - 1],
                       second.frames[second.frames.count - 1])
        XCTAssertEqual(first.indices, second.indices)
    }
}

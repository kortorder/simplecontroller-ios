import Foundation
import XCTest
@testable import ControllerCore

final class TouchAimMotionWindowTests: XCTestCase {
    private func circle(segments: Int, duration: Double = 2) throws -> [Bool] {
        var window = TouchAimMotionWindow()
        return try (0...segments).map { index in
            let phase = 2 * Double.pi * Double(index) / Double(segments)
            return try window.observe(x: 10 * cos(phase), y: 10 * sin(phase),
                                      at: 1_234_567 + duration * Double(index) / Double(segments))
        }
    }

    func testSmallCircleSurvivesDenseCoalescedSampling() throws {
        // At 120/240 segments every individual movement is below the old 0.75pt
        // threshold, despite the same 62.8pt circular path. Compare common times.
        let sparse = try circle(segments: 60)
        let dense = try circle(segments: 120)
        let veryDense = try circle(segments: 240)
        XCTAssertFalse(sparse[0]); XCTAssertFalse(dense[0]); XCTAssertFalse(veryDense[0])
        for index in 3...60 {
            XCTAssertTrue(sparse[index], "Sparse circle at index \(index)")
            XCTAssertEqual(dense[index * 2], sparse[index])
            XCTAssertEqual(veryDense[index * 4], sparse[index])
        }
    }

    func testSlowSmallSegmentsBecomeMotionWithinRecentWindow() throws {
        var window = TouchAimMotionWindow()
        for index in 0...200 {
            let moving = try window.observe(x: Double(index) * 0.1, y: 0, at: Double(index) * 0.01)
            if index >= 8 { XCTAssertTrue(moving) }
        }
    }

    func testLongStationaryJitterNeverAccumulatesIntoMovementAndMemoryIsBounded() throws {
        var window = TouchAimMotionWindow()
        for index in 0...20_000 {
            let angle = Double(index) * 0.7
            let moving = try window.observe(x: 100 + 0.2 * cos(angle), y: 200 + 0.2 * sin(angle),
                                            at: 12_345 + Double(index) / 1_000)
            XCTAssertFalse(moving)
            XCTAssertLessThanOrEqual(window.retainedObservationCount, 48)
        }
    }

    func testDisplacementOutsideTheTimeWindowCannotAccumulate() throws {
        var window = TouchAimMotionWindow()
        // Ten points of slow drift are still below the threshold in every 120ms
        // window. This guards against replacing segment checks with a path sum.
        for index in 0...1_000 {
            XCTAssertFalse(try window.observe(x: Double(index) * 0.01, y: 0, at: Double(index) * 0.02))
        }
        XCTAssertFalse(try window.observe(x: 1_000, y: 1_000, at: 30))
    }

    func testOutAndBackMotionIsObservedThenExpires() throws {
        var window = TouchAimMotionWindow()
        XCTAssertFalse(try window.observe(x: 0, y: 0, at: 0))
        XCTAssertTrue(try window.observe(x: 2, y: 0, at: 0.01))
        XCTAssertTrue(try window.observe(x: 0, y: 0, at: 0.02))
        XCTAssertFalse(try window.observe(x: 0, y: 0, at: 0.2))
    }

    func testDiagonalDisplacementUsesActualPointDistance() throws {
        var window = TouchAimMotionWindow()
        XCTAssertFalse(try window.observe(x: 0, y: 0, at: 0))
        XCTAssertTrue(try window.observe(x: 0.6, y: 0.6, at: 0.04))
    }

    func testResetStartsIndependentRecordingAndClock() throws {
        var window = TouchAimMotionWindow()
        _ = try window.observe(x: 0, y: 0, at: 50)
        XCTAssertTrue(try window.observe(x: 2, y: 0, at: 50.01))
        window.reset()
        XCTAssertEqual(window.retainedObservationCount, 0)
        XCTAssertFalse(try window.observe(x: 200, y: 100, at: 0))
        XCTAssertFalse(try window.observe(x: 200.1, y: 100, at: 0.01))
    }

    func testInvalidObservationsDoNotMutateHistory() throws {
        var window = TouchAimMotionWindow()
        _ = try window.observe(x: 0, y: 0, at: 10)
        let retained = window.retainedObservationCount
        XCTAssertThrowsError(try window.observe(x: 50, y: 0, at: 9))
        XCTAssertThrowsError(try window.observe(x: .nan, y: 0, at: 10.01))
        XCTAssertThrowsError(try window.observe(x: 0, y: .infinity, at: 10.01))
        XCTAssertThrowsError(try window.observe(x: 0, y: 0, at: .infinity))
        XCTAssertThrowsError(try window.observe(x: 0, y: 0, at: .greatestFiniteMagnitude))
        XCTAssertEqual(window.retainedObservationCount, retained)
        XCTAssertFalse(try window.observe(x: 0, y: 0, at: 10.02))
        XCTAssertTrue(try window.observe(x: 1, y: 0, at: 10.04))
    }
}

import Foundation
import XCTest
@testable import ControllerCore

final class TouchpadInputTests: XCTestCase {
    private func pad(_ mode: TouchpadClickMode = .none, sensitivity: Double = 1) -> ProfileControl {
        .init(kind: .touchpad, touchpadBehavior: .init(sensitivity: sensitivity, clickMode: mode))
    }
    private func profile(_ controls: [ProfileControl], turbo: Bool = false) throws -> ControllerProfile {
        let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: placements, landscape: placements, turboEnabled: turbo)
    }
    private func events(_ engine: inout ProfileInputEngine) -> [PracticeOutputEvent.Kind] { engine.drainPracticeEvents().events.map(\.kind) }
    func testPointerOnlyHasNoInitialJumpAndNoEndClick() throws {
        let p = pad(); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        XCTAssertEqual(engine.activeTouchpads, [p.id]); XCTAssertEqual(engine.practiceState.pointerOffset, .zero)
        XCTAssertTrue(events(&engine).isEmpty)
        try engine.moveTouchpad(contact: 1, delta: .init(dx: 2, dy: 4), at: 0.1)
        XCTAssertEqual(engine.practiceState.pointerOffset.dx, 0.92, accuracy: 0.000001)
        XCTAssertEqual(engine.practiceState.pointerOffset.dy, 1.72, accuracy: 0.000001)
        _ = events(&engine)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertTrue(events(&engine).isEmpty); XCTAssertTrue(engine.practiceState.heldMouseButtons.isEmpty)
        XCTAssertTrue(engine.activeTouchpads.isEmpty)
    }
    func testAllCapturedMovementSamplesArePreservedWithoutThrottleLoss() throws {
        let p = pad(); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.moveTouchpadBatch(contact: 1, deltas: [.init(dx: 2, dy: 4), .init(dx: 2, dy: 4)], at: 0.001)
        XCTAssertEqual(engine.practiceState.pointerOffset.dx, 2.24, accuracy: 0.000001)
        XCTAssertEqual(engine.practiceState.pointerOffset.dy, 4.24, accuracy: 0.000001)
        XCTAssertEqual(events(&engine).count, 2)
    }
    func testSensitivityZeroStopsMovementButHoldClickAndSlopStillWork() throws {
        let p = pad(.hold, sensitivity: 0)
        var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        XCTAssertEqual(events(&engine), [.mouseDown(.left)])
        try engine.moveTouchpad(contact: 1, delta: .init(dx: 100, dy: 100), at: 0.1)
        XCTAssertTrue(events(&engine).isEmpty); XCTAssertEqual(engine.practiceState.pointerOffset, .zero)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertEqual(events(&engine), [.mouseUp(.left)])
    }
    func testIndependentMouseOwnerSuppressesPadReleaseAndClickEdges() throws {
        let p = pad(.hold), button = ProfileControl(payload: "MOUSE_LEFT_DOWN")
        var engine = try ProfileInputEngine(profile: profile([p, button]))
        try engine.begin(contact: 1, control: button.id, at: 0); _ = events(&engine)
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.1)
        try engine.end(contact: 2, at: 0.2)
        XCTAssertTrue(events(&engine).isEmpty); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left])
        try engine.end(contact: 1, at: 0.3); XCTAssertEqual(events(&engine), [.mouseUp(.left)])
    }
    func testToggleDelaySurvivesNormalLiftAndNextTouchCancelsOrUnlocks() throws {
        let p = pad(.toggle); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.end(contact: 1, at: 0.1)
        XCTAssertEqual(engine.pendingTouchpadLocks, [p.id]); XCTAssertEqual(engine.nextDeadline, 0.75)
        try engine.tick(at: 0.749); XCTAssertTrue(engine.practiceState.heldMouseButtons.isEmpty)
        try engine.tick(at: 0.75); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left])
        XCTAssertEqual(engine.lockedTouchpads, [p.id]); _ = events(&engine)
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.8)
        XCTAssertEqual(events(&engine), [.mouseUp(.left)])
        try engine.end(contact: 2, at: 0.9)
        try engine.beginTouchpad(contact: 3, control: p.id, at: 1)
        try engine.end(contact: 3, at: 1.1)
        try engine.beginTouchpad(contact: 4, control: p.id, at: 1.8) // Overdue but unexecuted lock loses to this touch.
        XCTAssertTrue(engine.practiceState.heldMouseButtons.isEmpty); XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty)
        XCTAssertTrue(events(&engine).isEmpty)
    }
    func testDoubleTapClickThenHoldLocksAndCleanTapUnlocksWithoutClick() throws {
        let p = pad(.doubleTapLock); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.end(contact: 1, at: 0.05)
        XCTAssertEqual(events(&engine), [.mouseDown(.left), .mouseUp(.left)])
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.15)
        XCTAssertEqual(engine.nextDeadline!, 0.53, accuracy: 0.000001)
        try engine.tick(at: 0.529); XCTAssertTrue(engine.practiceState.heldMouseButtons.isEmpty)
        try engine.tick(at: 0.53); XCTAssertEqual(events(&engine), [.mouseDown(.left)])
        try engine.end(contact: 2, at: 0.6)
        XCTAssertEqual(engine.lockedTouchpads, [p.id]); XCTAssertTrue(events(&engine).isEmpty)
        try engine.beginTouchpad(contact: 3, control: p.id, at: 0.7)
        try engine.end(contact: 3, at: 0.75)
        XCTAssertEqual(events(&engine), [.mouseUp(.left)]); XCTAssertTrue(engine.lockedTouchpads.isEmpty)
    }
    func testNormalEndCancelsUnexecutedDoubleTapLockEvenAfterItsDeadline() throws {
        let p = pad(.doubleTapLock); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0); try engine.end(contact: 1, at: 0.05)
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.1); _ = events(&engine)
        try engine.endTouchpad(contact: 2, finalDeltas: [.init(dx: 1)], at: 0.6)
        XCTAssertTrue(engine.lockedTouchpads.isEmpty); XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty)
        XCTAssertTrue(engine.practiceState.heldMouseButtons.isEmpty)
        XCTAssertFalse(events(&engine).contains(.mouseDown(.left)))
        try engine.tick(at: 1); XCTAssertTrue(events(&engine).isEmpty)
    }
    func testCoalescedMoveInvalidatesWholePathBeforeDueLockAndOutBackCannotClick() throws {
        let p = pad(.doubleTapLock); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0); try engine.end(contact: 1, at: 0.05)
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.1); _ = events(&engine)
        try engine.moveTouchpadBatch(contact: 2, deltas: [.init(dx: 1), .init(dx: 25), .init(dx: -26)], at: 0.6)
        XCTAssertTrue(engine.lockedTouchpads.isEmpty); XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty)
        try engine.end(contact: 2, at: 0.61)
        XCTAssertFalse(events(&engine).contains(.mouseDown(.left)))
    }
    func testFinalCoalescedPathPreventsTapEvenWhenEndpointReturnsToOrigin() throws {
        let p = pad(.doubleTapLock); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.endTouchpad(contact: 1, finalDeltas: [.init(dx: 21), .init(dx: -21)], at: 0.1)
        XCTAssertFalse(events(&engine).contains(.mouseDown(.left)))
        XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty)
    }
    func testCleanTapExactTimeAndSlopBoundariesAndSecondGapExpiry() throws {
        let p = pad(.doubleTapLock); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.endTouchpad(contact: 1, finalDeltas: [.init(dx: 20)], at: 0.18)
        XCTAssertTrue(events(&engine).contains(.mouseDown(.left)))
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.301)
        XCTAssertNil(engine.nextDeadline)
        try engine.end(contact: 2, at: 0.5)
        XCTAssertFalse(events(&engine).contains(.mouseDown(.left)))
    }
    func testPostUnlockCooldownCannotImmediatelyRearm() throws {
        let p = pad(.doubleTapLock); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0); try engine.end(contact: 1, at: 0.05)
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.1); try engine.tick(at: 0.48); try engine.end(contact: 2, at: 0.5)
        try engine.beginTouchpad(contact: 3, control: p.id, at: 0.6); try engine.end(contact: 3, at: 0.65)
        try engine.beginTouchpad(contact: 4, control: p.id, at: 0.66); try engine.end(contact: 4, at: 0.67)
        try engine.beginTouchpad(contact: 5, control: p.id, at: 0.7)
        XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty)
    }
    func testCancelNeverClicksAndPreventsLateToggleOrDoubleHoldActivation() throws {
        for mode: TouchpadClickMode in [.hold, .toggle, .doubleTapLock] {
            let p = pad(mode); var engine = try ProfileInputEngine(profile: profile([p]))
            if mode == .doubleTapLock {
                try engine.beginTouchpad(contact: 10, control: p.id, at: 0)
                try engine.end(contact: 10, at: 0.05)
            }
            try engine.beginTouchpad(contact: 1, control: p.id, at: 0.1); _ = events(&engine)
            try engine.cancel(contact: 1, at: 1)
            XCTAssertFalse(events(&engine).contains(.mouseDown(.left)))
            try engine.tick(at: 2)
            XCTAssertTrue(engine.practiceState.heldMouseButtons.isEmpty); XCTAssertTrue(engine.lockedTouchpads.isEmpty)
        }
    }
    func testPerContactCancelPreservesOtherPadAndMouseButtonOwners() throws {
        let first = pad(.hold), second = pad(.hold), button = ProfileControl(payload: "MOUSE_RIGHT_DOWN")
        var engine = try ProfileInputEngine(profile: profile([first, second, button]))
        try engine.beginTouchpad(contact: 1, control: first.id, at: 0)
        try engine.beginTouchpad(contact: 2, control: second.id, at: 0)
        try engine.begin(contact: 3, control: button.id, at: 0); _ = events(&engine)
        try engine.cancel(contact: 1, at: 0.1)
        XCTAssertEqual(engine.activeTouchpads, [second.id]); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left, .right])
        XCTAssertTrue(events(&engine).isEmpty)
        try engine.cancel(contact: 2, at: 0.2)
        XCTAssertEqual(events(&engine), [.mouseUp(.left)]); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.right])
    }
    func testSecondFingerOnSamePadCannotMoveClickOrCancelFirstOwner() throws {
        let p = pad(.hold); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.1); _ = events(&engine)
        try engine.moveTouchpad(contact: 2, delta: .init(dx: 100), at: 0.2)
        try engine.cancel(contact: 2, at: 0.3)
        XCTAssertEqual(engine.practiceState.pointerOffset, .zero); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left])
        XCTAssertTrue(events(&engine).isEmpty)
    }
    func testCancelButtonDoesNotDetachPulseAndPreservesOtherContactOnSameButton() throws {
        let button = ProfileControl(payload: "RT:1P1,W")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.begin(contact: 2, control: button.id, at: 0.1)
        try engine.cancel(contact: 1, at: 0.2)
        XCTAssertEqual(engine.practiceState.rightTrigger, 1); XCTAssertEqual(engine.practiceState.heldKeys, [.w])
        try engine.cancel(contact: 2, at: 0.3)
        XCTAssertEqual(engine.practiceState, .neutral); XCTAssertNil(engine.nextDeadline)
    }
    func testFinalDragMotionAppearsBeforeMouseRelease() throws {
        let p = pad(.hold); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0); _ = events(&engine)
        try engine.endTouchpad(contact: 1, finalDeltas: [.init(dx: 2)], at: 0.1)
        let result = events(&engine)
        guard result.count == 2, case .pointerMoved = result[0] else { return XCTFail("Expected final motion followed by release") }
        XCTAssertEqual(result[1], .mouseUp(.left))
    }
    func testScrollToggleDirectAndAccessibilityOnlyIgnoresTurboAndResetsFilters() throws {
        let p = pad(), toggle = ProfileControl(payload: "SCROLL_MODE_TOGGLE"), other = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([p, toggle, other], turbo: true))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.moveTouchpad(contact: 1, delta: .init(dy: 4), at: 0.1)
        try engine.begin(contact: 2, control: other.id, at: 0.2)
        try engine.transfer(contact: 2, to: toggle.id, at: 0.3)
        XCTAssertFalse(engine.practiceState.scrollModeEnabled)
        try engine.end(contact: 2, at: 0.4)
        try engine.activate(toggle.id, at: 0.5)
        XCTAssertTrue(engine.practiceState.scrollModeEnabled); _ = events(&engine)
        try engine.moveTouchpad(contact: 1, delta: .init(dx: 2), at: 0.6)
        XCTAssertEqual(engine.practiceState.scrollOffset, 0); XCTAssertTrue(events(&engine).isEmpty)
        try engine.moveTouchpad(contact: 1, delta: .init(dy: 4), at: 0.7)
        XCTAssertEqual(engine.practiceState.scrollOffset, -1.72, accuracy: 0.000001)
        XCTAssertEqual(engine.practiceState.pointerOffset.dy, 1.72, accuracy: 0.000001)
        try engine.tick(at: 10); XCTAssertTrue(engine.practiceState.scrollModeEnabled)
    }
    func testScrollToggleDoesNotRepeatForConcurrentFingersOnSameButton() throws {
        let toggle = ProfileControl(payload: "SCROLL_MODE_TOGGLE")
        var engine = try ProfileInputEngine(profile: profile([toggle], turbo: true))
        try engine.begin(contact: 1, control: toggle.id, at: 0)
        try engine.begin(contact: 2, control: toggle.id, at: 0)
        XCTAssertTrue(engine.practiceState.scrollModeEnabled)
        XCTAssertEqual(events(&engine), [.scrollModeChanged(true)])
    }
    func testRecenterLeavesPadLocksAndScrollWhileReleaseAllResetsEverything() throws {
        let p = pad(.toggle), toggle = ProfileControl(payload: "SCROLL_MODE_TOGGLE")
        var engine = try ProfileInputEngine(profile: profile([p, toggle]))
        try engine.activate(toggle.id, at: 0)
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.moveTouchpad(contact: 1, delta: .init(dy: 4), at: 0.1)
        try engine.end(contact: 1, at: 0.2); try engine.tick(at: 0.75)
        engine.recenterSticks()
        XCTAssertEqual(engine.lockedTouchpads, [p.id]); XCTAssertTrue(engine.practiceState.scrollModeEnabled)
        engine.releaseAll()
        XCTAssertEqual(engine.practiceState, .neutral); XCTAssertTrue(engine.lockedTouchpads.isEmpty)
        XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty); XCTAssertNil(engine.nextDeadline)
        try engine.tick(at: 10); XCTAssertEqual(engine.practiceState, .neutral)
    }
    func testInvalidDeltaTimeAndBatchRejectBeforeMutatingAnyState() throws {
        let p = pad(.hold); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 1); _ = events(&engine)
        for delta in [PointerDelta(dx: .nan), .init(dy: .infinity), .init(dx: 4_097)] {
            XCTAssertThrowsError(try engine.moveTouchpadBatch(contact: 1, deltas: [.init(dx: 1), delta], at: 1.1))
        }
        XCTAssertThrowsError(try engine.moveTouchpadBatch(contact: 1, deltas: Array(repeating: .zero, count: 257), at: 1.1))
        XCTAssertThrowsError(try engine.endTouchpad(contact: 1, finalDeltas: [.init(dx: .nan)], at: 1.1))
        XCTAssertThrowsError(try engine.moveTouchpad(contact: 1, delta: .init(dx: 2), at: 0.9))
        XCTAssertEqual(engine.practiceState.pointerOffset, .zero); XCTAssertEqual(engine.activeTouchpads, [p.id])
        XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left]); XCTAssertTrue(events(&engine).isEmpty)
    }
    func testResponseCurveAndExtremeCumulativeTotalsStayFinite() {
        XCTAssertEqual(touchpadResponse(0.1), 0.15, accuracy: 0.000001)
        XCTAssertEqual(touchpadResponse(0.2), 0.2, accuracy: 0.000001)
        XCTAssertEqual(touchpadResponse(0.6), 0.6, accuracy: 0.000001)
        XCTAssertEqual(touchpadResponse(-2), -1.72, accuracy: 0.000001)
        let bound = PracticeOutputState.maximumMovementTotal
        XCTAssertEqual(clampedPracticeTotal(bound - 1, adding: 100), bound)
        XCTAssertEqual(clampedPracticeTotal(-bound + 1, adding: -100), -bound)
        XCTAssertEqual(clampedPracticeTotal(5, adding: 2), 7)
    }
    func testTouchpadTotalsSurviveHistoryEvictionButNeverEnterSCX1() throws {
        let p = pad(); var engine = try ProfileInputEngine(profile: profile([p]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        for index in 1...300 { try engine.moveTouchpad(contact: 1, delta: .init(dx: 2), at: Double(index) / 1_000) }
        let batch = engine.drainPracticeEvents()
        XCTAssertEqual(batch.events.count, 256); XCTAssertEqual(batch.omittedCount, 44)
        XCTAssertGreaterThan(engine.practiceState.pointerOffset.dx, 400)
        XCTAssertEqual(engine.state, .neutral)
        let wire = try BridgeCodec.encode(.init(kind: .state, session: UUID().uuidString, sequence: 1, state: engine.state))
        XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("pointer"))
    }
}

import Foundation
import XCTest
@testable import ControllerCore

final class ProfileHandoffTests: XCTestCase {
    private func profile(_ controls: [ProfileControl], _ mode: ProfileSwipeMode = .controls) throws -> ControllerProfile {
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: positions, landscape: positions, swipeMode: mode)
    }
    private func pad(_ mode: TouchpadClickMode = .none) -> ProfileControl {
        .init(kind: .touchpad, touchpadBehavior: .init(clickMode: mode))
    }
    private func events(_ engine: inout ProfileInputEngine) -> [PracticeOutputEvent.Kind] {
        engine.drainPracticeEvents().events.map(\.kind)
    }
    func testOffRejectsHandoffAndCapturesButtonThroughLegacyTransferRequests() throws {
        let a = ProfileControl(actions: [.a]), b = ProfileControl(actions: [.b])
        var engine = try ProfileInputEngine(profile: profile([a, b], .off))
        try engine.begin(contact: 1, control: a.id, at: 0)
        XCTAssertFalse(try engine.handoff(contact: 1, to: b.id, at: 0.1))
        try engine.transfer(contact: 1, to: nil, at: 0.2)
        XCTAssertEqual(engine.capturedControl(for: 1), a.id); XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 1, at: 0.3); XCTAssertTrue(engine.state.isNeutral)
    }
    func testButtonsModeUsesLegacyGapReleaseAndCannotAcquireAStick() throws {
        let a = ProfileControl(actions: [.a]), blocked = ProfileControl(actions: [.b], swipeActivationEnabled: false)
        let stick = ProfileControl(kind: .leftStick)
        var engine = try ProfileInputEngine(profile: profile([a, blocked, stick], .buttons))
        try engine.begin(contact: 1, control: a.id, at: 0)
        XCTAssertFalse(try engine.handoff(contact: 1, to: stick.id, at: 0))
        try engine.transfer(contact: 1, to: blocked.id, at: 0.1)
        XCTAssertNil(engine.capturedControl(for: 1)); XCTAssertTrue(engine.state.isNeutral)
        try engine.transfer(contact: 1, to: a.id, at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.transfer(contact: 1, to: stick.id, at: 0.3)
        XCTAssertEqual(engine.capturedControl(for: 1), a.id)
    }
    func testAcrossControlsButtonStickPadHandoffAndRetainedFinalPosition() throws {
        let a = ProfileControl(actions: [.a]), stick = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false)), p = pad()
        var engine = try ProfileInputEngine(profile: profile([a, stick, p]))
        try engine.begin(contact: 1, control: a.id, at: 0)
        XCTAssertTrue(try engine.handoff(contact: 1, to: stick.id, arrivingStickPosition: .init(x: 0.5), at: 0.1))
        XCTAssertTrue(engine.state.buttons.isEmpty); XCTAssertEqual(engine.state.leftStick.x, 0.5)
        XCTAssertTrue(try engine.handoff(contact: 1, to: p.id, departingStickPosition: .init(x: 1, y: -0.6), at: 0.2))
        XCTAssertEqual(engine.retainedSticks[stick.id], .init(x: 1, y: -0.6))
        XCTAssertEqual(engine.activeTouchpads, [p.id]); XCTAssertEqual(engine.practiceState.pointerOffset, .zero)
        try engine.moveTouchpad(contact: 1, delta: .init(dx: 2), at: 0.3)
        XCTAssertTrue(try engine.handoff(contact: 1, to: a.id, finalPadDeltas: [.init(dx: 2)], at: 0.4))
        XCTAssertEqual(engine.state.buttons, [.a]); XCTAssertEqual(engine.practiceState.pointerOffset.dx, 2.24, accuracy: 0.000001)
        XCTAssertTrue(engine.activeTouchpads.isEmpty)
    }
    func testSameChannelHandoffReplacesDepartingRetentionWithoutGhostOwner() throws {
        let first = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false))
        let next = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false))
        var engine = try ProfileInputEngine(profile: profile([first, next]))
        try engine.begin(contact: 1, control: first.id, position: .init(x: 0.8), at: 0)
        XCTAssertTrue(try engine.handoff(contact: 1, to: next.id, departingStickPosition: .init(x: 1), arrivingStickPosition: .init(x: -0.4), at: 0.1))
        XCTAssertNil(engine.retainedSticks[first.id]); XCTAssertEqual(engine.state.leftStick.x, -0.4)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertEqual(engine.retainedSticks, [next.id: .init(x: -0.4)])
    }
    func testOccupiedOrDisabledDestinationRejectsBeforeSourcePadPathMutation() throws {
        let p = pad(.hold), occupied = pad(), stick = ProfileControl(kind: .leftStick), duplicate = ProfileControl(kind: .leftStick)
        let blocked = ProfileControl(swipeActivationEnabled: false), recenter = ProfileControl(kind: .recenter)
        let scroll = ProfileControl(payload: "SCROLL_MODE_TOGGLE")
        var engine = try ProfileInputEngine(profile: profile([p, occupied, stick, duplicate, blocked, recenter, scroll]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.beginTouchpad(contact: 2, control: occupied.id, at: 0)
        try engine.begin(contact: 3, control: stick.id, position: .init(x: 0.6), at: 0)
        let before = engine.practiceState; _ = events(&engine)
        for id in [occupied.id, duplicate.id, blocked.id, recenter.id, scroll.id, UUID()] {
            XCTAssertFalse(try engine.handoff(contact: 1, to: id, finalPadDeltas: [.init(dx: 100)], at: 0.1))
            XCTAssertEqual(engine.practiceState, before); XCTAssertEqual(engine.capturedControl(for: 1), p.id)
            XCTAssertTrue(events(&engine).isEmpty)
        }
        try engine.cancel(contact: 2, at: 0.1)
        XCTAssertTrue(try engine.handoff(contact: 1, to: occupied.id, at: 0.1))
    }
    func testInvalidHandoffPathAndTimeRejectBeforeAnyMutation() throws {
        let p = pad(.hold), a = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([p, a]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 1)
        let before = engine.practiceState
        for path in [[PointerDelta(dx: .nan)], Array(repeating: .zero, count: 257)] {
            XCTAssertThrowsError(try engine.handoff(contact: 1, to: a.id, finalPadDeltas: path, at: 1))
        }
        XCTAssertThrowsError(try engine.handoff(contact: 1, to: a.id, arrivingStickPosition: .init(x: 2), at: 1))
        XCTAssertThrowsError(try engine.handoff(contact: 1, to: a.id, at: 0.9))
        XCTAssertEqual(engine.practiceState, before); XCTAssertEqual(engine.capturedControl(for: 1), p.id)
    }
    func testPendingHoldDepartureCannotLatchButIndependentContactStillCan() throws {
        let toggle = ProfileControl(actions: [.y], buttonBehavior: .init(holdToggle: true)), b = ProfileControl(actions: [.b])
        var engine = try ProfileInputEngine(profile: profile([toggle, b]))
        try engine.begin(contact: 1, control: toggle.id, at: 10)
        XCTAssertTrue(try engine.handoff(contact: 1, to: b.id, at: 10.6))
        XCTAssertTrue(engine.latchedControls.isEmpty); XCTAssertEqual(engine.state.buttons, [.b])
        engine.releaseAll()
        try engine.begin(contact: 2, control: toggle.id, at: 11)
        try engine.begin(contact: 3, control: toggle.id, at: 11.1)
        XCTAssertTrue(try engine.handoff(contact: 2, to: b.id, at: 11.6))
        XCTAssertEqual(engine.latchedControls, [toggle.id]); XCTAssertEqual(engine.state.buttons, [.y, .b])
    }
    func testEstablishedLatchSurvivesHandoffAndIncomingToggleStartsFreshDeadline() throws {
        let toggle = ProfileControl(actions: [.y], buttonBehavior: .init(holdToggle: true))
        let target = ProfileControl(actions: [.b], buttonBehavior: .init(holdToggle: true))
        var engine = try ProfileInputEngine(profile: profile([toggle, target]))
        try engine.begin(contact: 1, control: toggle.id, at: 0)
        try engine.tick(at: 0.5)
        XCTAssertTrue(try engine.handoff(contact: 1, to: target.id, at: 0.6))
        XCTAssertEqual(engine.latchedControls, [toggle.id]); XCTAssertEqual(engine.pendingHoldDeadline, 1.1)
        try engine.tick(at: 1.1)
        XCTAssertEqual(engine.latchedControls, [toggle.id, target.id])
    }
    func testSourceWaitCancelsAndStartedPulseSurvivesWithoutReleasingIndependentMouseOwner() throws {
        let source = ProfileControl(payload: "X360A,RT:1P1,WAIT_100,X360Y")
        let mouse = ProfileControl(payload: "MOUSE_LEFT_DOWN"), p = pad(.hold)
        var engine = try ProfileInputEngine(profile: profile([source, mouse, p]))
        try engine.begin(contact: 1, control: source.id, at: 0)
        try engine.begin(contact: 2, control: mouse.id, at: 0)
        XCTAssertTrue(try engine.handoff(contact: 1, to: p.id, at: 0.2))
        XCTAssertEqual(engine.state.buttons, [.rightTrigger]); XCTAssertEqual(engine.practiceState.rightTrigger, 1)
        XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left]); _ = events(&engine)
        XCTAssertTrue(try engine.handoff(contact: 1, to: mouse.id, at: 0.3))
        XCTAssertTrue(events(&engine).isEmpty)
        try engine.end(contact: 1, at: 0.4)
        XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left])
        try engine.tick(at: 1)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0); XCTAssertEqual(engine.state.buttons, [])
    }
    func testPadDepartureCancelsOverdueDoubleTapCandidateWithoutClickOrLock() throws {
        let p = pad(.doubleTapLock), a = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([p, a]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.end(contact: 1, at: 0.05)
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.1)
        XCTAssertEqual(engine.pendingTouchpadLocks, [p.id]); _ = events(&engine)
        XCTAssertTrue(try engine.handoff(contact: 2, to: a.id, finalPadDeltas: [.init(dx: 30), .init(dx: -30)], at: 0.6))
        XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty); XCTAssertTrue(engine.lockedTouchpads.isEmpty)
        XCTAssertTrue(engine.practiceState.heldMouseButtons.isEmpty)
        XCTAssertFalse(events(&engine).contains { if case .mouseDown = $0 { return true }; return false })
        try engine.tick(at: 1); XCTAssertTrue(engine.lockedTouchpads.isEmpty)
    }
    func testSwipeEntryAndLiftCannotCreateClickOrPrimeNextDirectTap() throws {
        let p = pad(.doubleTapLock), a = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([p, a]))
        // A prior genuine click cannot turn the swipe entry into a second tap.
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        try engine.end(contact: 1, at: 0.02)
        try engine.begin(contact: 2, control: a.id, at: 0.03); _ = events(&engine)
        XCTAssertTrue(try engine.handoff(contact: 2, to: p.id, at: 0.04))
        XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty)
        try engine.end(contact: 2, at: 0.05)
        XCTAssertTrue(events(&engine).isEmpty)
        try engine.beginTouchpad(contact: 3, control: p.id, at: 0.06)
        XCTAssertTrue(engine.pendingTouchpadLocks.isEmpty)
        try engine.end(contact: 3, at: 0.08)
        XCTAssertEqual(events(&engine), [.mouseDown(.left), .mouseUp(.left)])
    }
    func testSwipeEntryAndLiftCannotUnlockEstablishedDoubleTapLock() throws {
        let p = pad(.doubleTapLock), a = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([p, a]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0); try engine.end(contact: 1, at: 0.02)
        try engine.beginTouchpad(contact: 2, control: p.id, at: 0.04); try engine.tick(at: 0.42)
        XCTAssertEqual(engine.lockedTouchpads, [p.id])
        XCTAssertTrue(try engine.handoff(contact: 2, to: a.id, at: 0.43)); _ = events(&engine)
        XCTAssertTrue(try engine.handoff(contact: 2, to: p.id, at: 0.44))
        try engine.end(contact: 2, at: 0.45)
        XCTAssertEqual(engine.lockedTouchpads, [p.id]); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left])
        XCTAssertTrue(events(&engine).isEmpty)
        try engine.beginTouchpad(contact: 3, control: p.id, at: 0.5); try engine.end(contact: 3, at: 0.52)
        XCTAssertTrue(engine.lockedTouchpads.isEmpty); XCTAssertEqual(events(&engine), [.mouseUp(.left)])
    }
    func testTogglePadHandoffPreservesPendingLockAndCancelClearsEverything() throws {
        let p = pad(.toggle), a = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([p, a]))
        try engine.beginTouchpad(contact: 1, control: p.id, at: 0)
        XCTAssertTrue(try engine.handoff(contact: 1, to: a.id, at: 0.1))
        XCTAssertEqual(engine.pendingTouchpadLocks, [p.id]); try engine.tick(at: 0.75)
        XCTAssertEqual(engine.lockedTouchpads, [p.id])
        try engine.handle(.cancelAll, at: 0.8)
        XCTAssertEqual(engine.practiceState, .neutral); XCTAssertNil(engine.nextDeadline)
        try engine.tick(at: 10); XCTAssertEqual(engine.practiceState, .neutral)
    }
    func testEngineDestinationCooldownIsGlobalAndResettable() throws {
        let a = ProfileControl(actions: [.a]), b = ProfileControl(actions: [.b])
        var engine = try ProfileInputEngine(profile: profile([a, b]))
        try engine.begin(contact: 1, control: a.id, at: 0)
        XCTAssertTrue(try engine.handoff(contact: 1, to: b.id, at: 0))
        try engine.end(contact: 1, at: 0.01)
        try engine.begin(contact: 2, control: a.id, at: 0.02)
        XCTAssertFalse(try engine.handoff(contact: 2, to: b.id, at: 0.119))
        XCTAssertEqual(engine.capturedControl(for: 2), a.id)
        XCTAssertTrue(try engine.handoff(contact: 2, to: b.id, at: 0.12))
        engine.releaseAll()
        try engine.begin(contact: 3, control: a.id, at: 0.13)
        XCTAssertTrue(try engine.handoff(contact: 3, to: b.id, at: 0.13))
    }
    func testIndependentDirectionalAndAnalogSurfacesCanBeEnteredTogether() throws {
        let a = ProfileControl(), analog = ProfileControl(kind: .leftStick)
        var directional = ProfileControl(kind: .leftStick, directionalEnabled: true)
        directional.directionPayloads[.up] = .init(normalPayload: "W", boostPayload: "W", superBoostPayload: "W")
        var engine = try ProfileInputEngine(profile: profile([a, analog, directional]))
        try engine.begin(contact: 1, control: analog.id, position: .init(x: 0.6), at: 0)
        try engine.begin(contact: 2, control: a.id, at: 0)
        XCTAssertTrue(try engine.handoff(contact: 2, to: directional.id, arrivingStickPosition: .init(y: 1), at: 0.1))
        XCTAssertEqual(engine.state.leftStick.x, 0.6); XCTAssertEqual(engine.practiceState.heldKeys, [.w])
        try engine.cancel(contact: 2, at: 0.2)
        XCTAssertEqual(engine.state.leftStick.x, 0.6); XCTAssertTrue(engine.practiceState.heldKeys.isEmpty)
    }
}

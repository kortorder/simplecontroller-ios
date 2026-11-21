import Foundation
import XCTest
@testable import ControllerCore

final class StickPlusRepeatTests: XCTestCase {
    private func stick(retained: Bool = true, interval: Int? = 200, kind: ProfileControlKind = .leftStick) -> ProfileControl {
        var behavior = StickBehavior(autoCenter: !retained, stickPlusEnabled: true,
                                     boostThreshold: 0.5, superBoostThreshold: 0.95)
        behavior.directions[.up] = .init(superBoostControls: [.a])
        return .init(kind: kind, stickBehavior: behavior, stickPlusRepeatIntervalMilliseconds: interval)
    }
    private func profile(_ controls: [ProfileControl]) throws -> ControllerProfile {
        let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try .init(controls: controls, portrait: placements, landscape: placements)
    }
    private func engine(_ control: ProfileControl, other: [ProfileControl] = []) throws -> ProfileInputEngine {
        try .init(profile: profile([control] + other))
    }
    private func deadline(_ e: ProfileInputEngine, _ expected: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(e.nextDeadline ?? -1, expected, accuracy: 1e-9, file: file, line: line)
    }

    func testStrictForwardThresholdStartsImmediatePressAndOnlyDigitalActionCycles() throws {
        let c = stick(); var e = try engine(c)
        try e.begin(contact: 1, control: c.id, position: .init(y: 0.95), at: 0)
        XCTAssertTrue(e.state.buttons.isEmpty); XCTAssertNil(e.nextDeadline)
        try e.move(contact: 1, position: .init(x: 0.1, y: 0.951), at: 0.1)
        XCTAssertEqual(e.state.buttons, [.a]); deadline(e, 0.15)
        try e.tick(at: 0.15)
        XCTAssertTrue(e.state.buttons.isEmpty); deadline(e, 0.3)
        XCTAssertEqual(e.state.leftStick, .init(x: 0.1, y: 0.951))
        try e.tick(at: 0.3)
        XCTAssertEqual(e.state.buttons, [.a]); deadline(e, 0.35)
        try e.move(contact: 1, position: .init(y: 0.95), at: 0.35)
        XCTAssertTrue(e.state.buttons.isEmpty); XCTAssertNil(e.nextDeadline)
        try e.tick(at: 4); XCTAssertTrue(e.state.buttons.isEmpty)
    }
    func testMovesWithinStageDoNotRestartPressButReentryStartsFresh() throws {
        let c = stick(); var e = try engine(c)
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        try e.move(contact: 1, position: .init(y: 0.97), at: 0.03); deadline(e, 0.05)
        try e.move(contact: 1, position: .init(y: 0.96), at: 0.06)
        XCTAssertTrue(e.state.buttons.isEmpty); deadline(e, 0.21)
        try e.move(contact: 1, position: .init(y: 0.5), at: 0.07)
        XCTAssertNil(e.nextDeadline)
        try e.move(contact: 1, position: .init(y: 1), at: 0.08)
        XCTAssertEqual(e.state.buttons, [.a]); deadline(e, 0.13)
    }
    func testRetainedStickContinuesRepeatAndDeliberateLowerTouchStopsIt() throws {
        let c = stick(); var e = try engine(c)
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        try e.end(contact: 1, at: 0.02); deadline(e, 0.05)
        try e.tick(at: 0.05); XCTAssertTrue(e.state.buttons.isEmpty); XCTAssertEqual(e.state.leftStick.y, 1)
        try e.tick(at: 0.2); XCTAssertEqual(e.state.buttons, [.a])
        try e.begin(contact: 2, control: c.id, position: .init(y: 0.8), at: 0.21)
        XCTAssertTrue(e.state.buttons.isEmpty); XCTAssertNil(e.nextDeadline)
        try e.end(contact: 2, at: 0.22); try e.tick(at: 2)
        XCTAssertEqual(e.state.leftStick.y, 0.8); XCTAssertTrue(e.state.buttons.isEmpty)
    }
    func testOrdinaryLiftCancelsNonretainedRepeatBeforeOverdueWork() throws {
        let c = stick(retained: false); var e = try engine(c)
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        try e.end(contact: 1, at: 5)
        XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
        try e.tick(at: 9); XCTAssertTrue(e.state.isNeutral)
    }
    func testLateTickFirstReleasesThenWaitsFullGapWithoutCatchUp() throws {
        let c = stick(); var e = try engine(c)
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        try e.tick(at: 10)
        XCTAssertTrue(e.state.buttons.isEmpty); deadline(e, 10.15)
        try e.tick(at: 10.01); XCTAssertTrue(e.state.buttons.isEmpty); deadline(e, 10.15)
        try e.tick(at: 10.15); XCTAssertEqual(e.state.buttons, [.a]); deadline(e, 10.2)
        try e.tick(at: 20.15); XCTAssertTrue(e.state.buttons.isEmpty); deadline(e, 20.3)
        try e.tick(at: 30); XCTAssertEqual(e.state.buttons, [.a]); deadline(e, 30.05)
    }
    func testCancellationRecenterScopedReleasePageChangeAndApplyClearDeadlines() throws {
        let c = stick(), independent = ProfileControl(actions: [.b])
        for operation in 0..<6 {
            var p = try profile([c, independent]); let other = try p.addPage(name: "Other")
            var e = try ProfileInputEngine(profile: p)
            try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
            try e.end(contact: 1, at: 0.01)
            try e.begin(contact: 2, control: independent.id, at: 0.02)
            switch operation {
            case 0: e.recenterSticks()
            case 1: e.releaseControls([c.id])
            case 2: try e.handle(.cancelAll, at: 5)
            case 3: e.releaseAll()
            case 4: _ = try e.selectPage(other, at: 5)
            default: try e.apply(profile: p)
            }
            XCTAssertNil(e.nextDeadline); XCTAssertEqual(e.state.leftStick, .zero)
            XCTAssertEqual(e.state.buttons, operation < 2 ? [.b] : [])
            try e.end(contact: 1, at: 6); try e.tick(at: 10)
            XCTAssertFalse(e.state.buttons.contains(.a)); XCTAssertNil(e.nextDeadline)
        }
    }
    func testLocalReleaseAllControlCancelsRepeatImmediately() throws {
        let c = stick(), stop = ProfileControl(payload: "RELEASE_ALL")
        var e = try engine(c, other: [stop])
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        try e.begin(contact: 2, control: stop.id, at: 10)
        XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
    }
    func testIndependentButtonOwnerKeepsAThroughRepeatOffAndRecenter() throws {
        let c = stick(), hold = ProfileControl(actions: [.a]); var e = try engine(c, other: [hold])
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        try e.begin(contact: 2, control: hold.id, at: 0.02)
        try e.tick(at: 0.05); XCTAssertEqual(e.state.buttons, [.a])
        e.recenterSticks(); XCTAssertEqual(e.state.buttons, [.a]); XCTAssertNil(e.nextDeadline)
        try e.end(contact: 2, at: 0.1); XCTAssertTrue(e.state.isNeutral)
    }
    func testTwoStickOwnersHaveIndependentPhasesAndScopedRelease() throws {
        let left = stick(), right = stick(kind: .rightStick)
        var e = try engine(left, other: [right])
        try e.begin(contact: 1, control: left.id, position: .init(y: 1), at: 0)
        try e.begin(contact: 2, control: right.id, position: .init(y: 1), at: 0.03)
        try e.tick(at: 0.05); XCTAssertEqual(e.state.buttons, [.a]); deadline(e, 0.08)
        e.releaseControls([left.id]); XCTAssertEqual(e.state.buttons, [.a]); deadline(e, 0.08)
        try e.tick(at: 0.08); XCTAssertTrue(e.state.buttons.isEmpty); deadline(e, 0.23)
    }
    func testOtherAnalogOwnerPreventsGhostRepeatAndRetainedTakeoverStopsOldClock() throws {
        let first = stick(), second = stick(interval: nil)
        var e = try engine(first, other: [second])
        try e.begin(contact: 1, control: second.id, position: .init(y: 0.5), at: 0)
        try e.begin(contact: 2, control: first.id, position: .init(y: 1), at: 0.01)
        XCTAssertNil(e.nextDeadline); XCTAssertTrue(e.state.buttons.isEmpty)
        try e.end(contact: 1, at: 0.02); try e.move(contact: 2, position: .init(y: 1), at: 0.03)
        XCTAssertNil(e.nextDeadline); XCTAssertTrue(e.state.buttons.isEmpty)
        try e.end(contact: 2, at: 0.04)
        try e.begin(contact: 3, control: first.id, position: .init(y: 1), at: 0.1)
        try e.end(contact: 3, at: 0.11); XCTAssertEqual(e.state.buttons, [.a])
        try e.begin(contact: 4, control: second.id, position: .init(y: 0.5), at: 0.12)
        XCTAssertNil(e.nextDeadline); XCTAssertTrue(e.state.buttons.isEmpty)
    }
    func testRepeatIgnoresPressureKeysMouseAndFixedStickStageActions() throws {
        var c = stick(); c.directionPayloads[.up]?.superBoostPayload = "X360A,LT:0.4,W,MOUSE_LEFT_DOWN,RS:R60"
        var e = try engine(c)
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        try e.tick(at: 0.05)
        XCTAssertFalse(e.state.buttons.contains(.a)); XCTAssertEqual(e.practiceState.leftTrigger, 0.4)
        XCTAssertEqual(e.practiceState.heldKeys, [.w]); XCTAssertEqual(e.practiceState.heldMouseButtons, [.left])
        XCTAssertEqual(e.state.leftStick.y, 1); XCTAssertEqual(e.state.rightStick.x, 0.6)
        e.recenterSticks(); XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.practiceState.heldKeys.isEmpty)
    }
    func testNoDigitalStageHasNoRepeatTimer() throws {
        var c = stick(); c.directionPayloads[.up]?.superBoostPayload = "LT:0.4,W"
        var e = try engine(c); try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        XCTAssertNil(e.nextDeadline); try e.tick(at: 10); XCTAssertEqual(e.practiceState.leftTrigger, 0.4)
    }
    func testDisabledStickPlusAndDirectionalModeLeaveRepeatDormant() throws {
        for directional in [false, true] {
            var c = stick(); c.directionalEnabled = directional; c.stickBehavior.stickPlusEnabled = directional
            var e = try engine(c); try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
            XCTAssertNil(e.nextDeadline); try e.tick(at: 10)
            XCTAssertEqual(e.state.buttons, directional ? [.a] : [])
        }
    }
    func testLegacySustainedStageAndGlobalTurboRemainIndependent() throws {
        var c = stick(interval: nil), p = try profile([c]); p.turboEnabled = true
        var e = try ProfileInputEngine(profile: p); try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        try e.tick(at: 0.1); XCTAssertEqual(e.state.buttons, [.a]); XCTAssertNil(e.nextDeadline)
        c.stickPlusRepeatIntervalMilliseconds = 200; p.controls[0] = c; try e.apply(profile: p)
        try e.begin(contact: 2, control: c.id, position: .init(y: 1), at: 1)
        try e.tick(at: 1.05); XCTAssertTrue(e.state.buttons.isEmpty); deadline(e, 1.2)
    }
    func testExtendedOuterStageGetsOwnRepeatPhase() throws {
        var c = stick(); c.extendedBoost.enabled = true; c.extendedBoost.mode = .addOuterStage
        c.extendedBoost.directions[.up]?.outerPayload = "X360B"
        var e = try engine(c)
        try e.beginStick(contact: 1, control: c.id, travel: .init(y: 1), at: 0)
        try e.tick(at: 0.05); XCTAssertTrue(e.state.buttons.isEmpty)
        try e.moveStick(contact: 1, travel: .init(y: 1.3), at: 0.06)
        XCTAssertEqual(e.state.buttons, [.b]); deadline(e, 0.11)
        try e.moveStick(contact: 1, travel: .init(y: 1), at: 0.07)
        XCTAssertEqual(e.state.buttons, [.a]); deadline(e, 0.12)
    }
    func testMinimumIntervalUsesHalfPeriodAndRepeatedTicksDoNotSpin() throws {
        let c = stick(interval: 16); var e = try engine(c)
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 100_000)
        for _ in 0..<100 {
            let next = try XCTUnwrap(e.nextDeadline)
            try e.tick(at: next)
            XCTAssertGreaterThan(try XCTUnwrap(e.nextDeadline), next)
            let prior = e.state
            try e.tick(at: next); XCTAssertEqual(e.state, prior)
        }
        deadline(e, 100_000.808)
    }
    func testPerContactCancelRemovesOnlyItsRepeatAndRejectsStaleMove() throws {
        let c = stick(), independent = ProfileControl(actions: [.b]); var e = try engine(c, other: [independent])
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0)
        try e.begin(contact: 2, control: independent.id, at: 0)
        try e.cancel(contact: 1, at: 5); try e.move(contact: 1, position: .init(y: 1), at: 6)
        XCTAssertEqual(e.state.buttons, [.b]); XCTAssertEqual(e.state.leftStick, .zero); XCTAssertNil(e.nextDeadline)
    }
}

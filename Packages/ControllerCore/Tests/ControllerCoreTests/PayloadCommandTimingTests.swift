import XCTest
@testable import ControllerCore

final class PayloadCommandTimingTests: XCTestCase {
    private func profile(_ controls: [ProfileControl], turbo: Bool = false) throws -> ControllerProfile {
        let places = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.3, y: 0.6)) }
        return try .init(controls: controls, portrait: places, landscape: places, turboEnabled: turbo, turboIntervalMilliseconds: 200)
    }
    private func touch(_ radius: Double, _ elapsed: Double = 0) -> TouchAimSample {
        .init(pointer: .init(x: 40, y: 40, width: 100, height: 100),
              metrics: .init(majorRadius: radius), elapsed: elapsed)
    }
    private func touchControl(_ medium: String, high: String = "", press: Bool = false) -> ProfileControl {
        var c = ProfileControl(kind: .touchAim)
        c.touchAim.threeStage.smoothing = 1
        c.touchAim.threeStage.low.payload = ""
        c.touchAim.threeStage.medium = .init(threshold: 3, payload: medium, action: press ? .press : .hold)
        c.touchAim.threeStage.high = .init(threshold: 5, payload: high, action: .hold)
        c.touchAim.threeStage.keepLowerHolds = true
        return c
    }
    func testParallelActivationDelayAndEarlyLift() throws {
        let b = ProfileControl(payload: "LT:0.5(D100),RT:0.7(D100)(HRD200),X360A")
        var e = try ProfileInputEngine(profile: profile([b]))
        try e.begin(contact: 1, control: b.id, at: 10)
        XCTAssertEqual(e.state.buttons, [.a])
        try e.end(contact: 1, at: 10.05)
        XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
        try e.begin(contact: 2, control: b.id, at: 11)
        try e.tick(at: 11.1)
        XCTAssertEqual(e.practiceState.leftTrigger, 0.5); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        try e.end(contact: 2, at: 11.11)
        XCTAssertEqual(e.state.buttons, [.rightTrigger])
        try e.tick(at: 11.31); XCTAssertTrue(e.state.isNeutral)
    }
    func testIndependentTurboRepeatAndReleaseShotWithRealGap() throws {
        let b = ProfileControl(payload: "LT:0.5(HRD200),RT:0.7(R100),RT:0.9(SOR),X360A")
        var e = try ProfileInputEngine(profile: profile([b], turbo: true))
        try e.begin(contact: 1, control: b.id, at: 0)
        try e.tick(at: 0.05)
        XCTAssertEqual(e.practiceState.leftTrigger, 0.5); XCTAssertEqual(e.practiceState.rightTrigger, 0)
        try e.tick(at: 0.11)
        XCTAssertEqual(e.practiceState.rightTrigger, 0.7); XCTAssertFalse(e.state.buttons.contains(.a))
        try e.end(contact: 1, at: 0.12)
        XCTAssertEqual(e.practiceState.rightTrigger, 0)
        try e.tick(at: 0.155)
        XCTAssertEqual(e.practiceState.rightTrigger, 0.9)
        try e.tick(at: 0.245)
        XCTAssertEqual(e.state.buttons, [.leftTrigger])
        e.releaseAll(); XCTAssertNil(e.nextDeadline)
    }
    func testHoldToggleDelaysActivationAndTailStartsWhenUnlatched() throws {
        var b = ProfileControl(payload: "LT:0.5(HRD200),X360A(SOR)")
        b.buttonBehavior = .init(holdToggle: true, holdMilliseconds: 500)
        var e = try ProfileInputEngine(profile: profile([b]))
        try e.begin(contact: 1, control: b.id, at: 0); try e.end(contact: 1, at: 0.45)
        XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
        try e.begin(contact: 2, control: b.id, at: 1); try e.tick(at: 1.5)
        try e.end(contact: 2, at: 1.6); try e.tick(at: 2)
        XCTAssertEqual(e.state.buttons, [.leftTrigger])
        try e.begin(contact: 3, control: b.id, at: 2)
        XCTAssertEqual(e.state.buttons, [.a,.leftTrigger])
        try e.end(contact: 3, at: 2.02); try e.tick(at: 2.2)
        XCTAssertTrue(e.state.isNeutral)
    }
    func testTouchAimShrinkingContactThenLiftKeepsOriginalDeadline() throws {
        let c = touchControl("LT:0.5(HRD200)", high: "RT:0.7")
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginTouchAim(contact: 1, control: c.id, sample: touch(4), at: 0)
        try e.moveTouchAimBatch(contact: 1, samples: [touch(6,0.05)], at: 0.05)
        XCTAssertEqual(e.practiceState.leftTrigger, 0.5); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        try e.moveTouchAimBatch(contact: 1, samples: [touch(1,0.1)], at: 0.1)
        XCTAssertEqual(e.practiceState.rightTrigger, 0)
        try e.end(contact: 1, at: 0.15)
        try e.tick(at: 0.299); XCTAssertEqual(e.practiceState.leftTrigger, 0.5)
        try e.tick(at: 0.3); XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
    }
    func testLiveHrdResumesButSiblingDelayAndReleaseShotRemainIndependent() throws {
        let c = touchControl("LT:0.5(D100)(HRD200),RT:0.7(D50),X360A(SOR)")
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginTouchAim(contact: 1, control: c.id, sample: touch(4), at: 0)
        try e.tick(at: 0.12)
        try e.moveTouchAimBatch(contact: 1, samples: [touch(1,0.13)], at: 0.13)
        try e.moveTouchAimBatch(contact: 1, samples: [touch(4,0.15)], at: 0.15)
        XCTAssertEqual(e.state.buttons, [.a,.leftTrigger])
        try e.tick(at: 0.20)
        XCTAssertEqual(e.state.buttons, [.a,.leftTrigger,.rightTrigger])
        try e.tick(at: 0.22)
        XCTAssertEqual(e.state.buttons, [.leftTrigger,.rightTrigger])
        try e.cancel(contact: 1, at: 0.23); XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
    }
    func testTouchAimFinitePressWindowAndStageOwnedReleaseShot() throws {
        let c = touchControl("LT:1.0(I)(HRD200),RT:0.7(SOR)", press: true)
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginTouchAim(contact: 1, control: c.id, sample: touch(4), at: 0)
        XCTAssertEqual(e.state.buttons, [.leftTrigger])
        try e.tick(at: 0.09); XCTAssertTrue(e.state.isNeutral)
        try e.end(contact: 1, at: 0.5); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        try e.tick(at: 0.59); XCTAssertTrue(e.state.isNeutral)
    }
    func testButtonAimMixedImmediateAndInheritedRelease() throws {
        var c = ProfileControl(payload: "LT:0.5(I),RT:0.7(D100),X360A")
        c.buttonAim.enabled = true; c.buttonAim.payloadTiming = .sendOnRelease
        let p = ButtonPointerSample(x: 20, y: 20, width: 80, height: 80)
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginButton(contact: 1, control: c.id, sample: p, at: 0)
        XCTAssertEqual(e.state.buttons, [.leftTrigger])
        try e.endButton(contact: 1, finalSamples: [], at: 0.2)
        XCTAssertEqual(e.state.buttons, [.a]); try e.tick(at: 0.3)
        XCTAssertEqual(e.state.buttons, [.rightTrigger]); try e.tick(at: 0.4); XCTAssertTrue(e.state.isNeutral)
    }
    func testModifiedFixedStickKeyboardAndMouseHaveIndependentDeadlinesAndCleanup() throws {
        let b = ProfileControl(payload: "RS:R50(D100),W(R100),MOUSE_LEFT_DOWN(SOR)")
        var e = try ProfileInputEngine(profile: profile([b]))
        try e.begin(contact: 1, control: b.id, at: 0)
        XCTAssertEqual(e.practiceState.heldKeys, [.w]); XCTAssertEqual(e.state.rightStick, .zero)
        try e.tick(at: 0.05); XCTAssertTrue(e.practiceState.heldKeys.isEmpty)
        try e.tick(at: 0.1); XCTAssertEqual(e.state.rightStick.x, 0.5)
        try e.end(contact: 1, at: 0.12)
        XCTAssertEqual(e.practiceState.heldMouseButtons, [.left]); XCTAssertEqual(e.state.rightStick, .zero)
        e.releaseControls([b.id]); XCTAssertNil(e.nextDeadline); XCTAssertEqual(e.practiceState, .neutral)
    }
    func testRepeatReleaseDuringOffPhaseDoesNotPressAgainForTail() throws {
        let b = ProfileControl(payload: "X360A(R200)(HRD400)")
        var e = try ProfileInputEngine(profile: profile([b]))
        try e.begin(contact: 1, control: b.id, at: 0)
        try e.end(contact: 1, at: 0.075); XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
    }
    func testExpiredTailReentryWaitsAgainAndOtherOwnerSurvivesScopedCleanup() throws {
        let c = touchControl("LT:0.5(D50)(HRD100),RT:0.7(SOR)(D100)")
        let b = ProfileControl(payload: "LT:0.4")
        var e = try ProfileInputEngine(profile: profile([b, c]))
        try e.begin(contact: 1, control: b.id, at: 0)
        try e.beginTouchAim(contact: 2, control: c.id, sample: touch(4), at: 0)
        try e.tick(at: 0.05)
        try e.moveTouchAimBatch(contact: 2, samples: [touch(1, 0.1)], at: 0.1)
        try e.tick(at: 0.20)
        XCTAssertEqual(e.practiceState.leftTrigger, 0.4)
        try e.moveTouchAimBatch(contact: 2, samples: [touch(4, 0.21)], at: 0.21)
        XCTAssertEqual(e.practiceState.leftTrigger, 0.4)
        try e.tick(at: 0.26); XCTAssertEqual(e.practiceState.leftTrigger, 0.5)
        e.releaseControls([c.id])
        XCTAssertEqual(e.practiceState.leftTrigger, 0.4); XCTAssertEqual(e.practiceState.rightTrigger, 0)
        try e.end(contact: 1, at: 0.27); try e.tick(at: 4); XCTAssertTrue(e.state.isNeutral)
    }
    func testDelayedPressGetsFullWidthButLeavingBeforeStartPreventsPress() throws {
        let c = touchControl("LT:0.6(D150)", press: true)
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginTouchAim(contact: 1, control: c.id, sample: touch(4), at: 0)
        try e.tick(at: 0.149); XCTAssertTrue(e.state.isNeutral)
        try e.tick(at: 0.15); XCTAssertEqual(e.practiceState.leftTrigger, 0.6)
        try e.tick(at: 0.24); XCTAssertTrue(e.state.isNeutral)
        try e.end(contact: 1, at: 0.3)
        try e.beginTouchAim(contact: 2, control: c.id, sample: touch(4), at: 1)
        try e.moveTouchAimBatch(contact: 2, samples: [touch(1, 0.1)], at: 1.1)
        try e.tick(at: 1.16); XCTAssertTrue(e.state.isNeutral)
    }
    func testNativeAutoTapOwnsFiniteSourcesAndCancelsOverlongDelay() throws {
        let b = ProfileControl(payload: "X360A(SOR),RT:0.5(D80),X360Y(R20)", autoTapEnabled: true,
                               autoTapIntervalMilliseconds: 200)
        var e = try ProfileInputEngine(profile: profile([b]))
        try e.begin(contact: 1, control: b.id, at: 0); try e.end(contact: 1, at: 0.01)
        try e.tick(at: 0.04); XCTAssertEqual(e.state.buttons, [.y])
        try e.tick(at: 0.05); XCTAssertEqual(e.state.buttons, [.a])
        try e.tick(at: 0.141); XCTAssertTrue(e.state.isNeutral)
        try e.tick(at: 0.2); XCTAssertEqual(e.state.buttons, [.y])
        try e.tick(at: 0.25); XCTAssertEqual(e.state.buttons, [.a])
        try e.begin(contact: 2, control: b.id, at: 0.28); try e.end(contact: 2, at: 0.29)
        try e.tick(at: 0.34); XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
    }
    func testTurboContinuesOnItsOriginalCadenceAfterDelayedFirstPress() throws {
        let b = ProfileControl(payload: "X360A(D80),RT:0.7P0.02(R100)")
        var e = try ProfileInputEngine(profile: profile([b], turbo: true))
        try e.begin(contact: 1, control: b.id, at: 0)
        try e.tick(at: 0.08); XCTAssertEqual(e.state.buttons, [.a])
        try e.tick(at: 0.18); XCTAssertTrue(e.state.isNeutral)
        try e.tick(at: 0.2); XCTAssertEqual(e.state.buttons, [.a, .rightTrigger])
        try e.tick(at: 0.25); XCTAssertEqual(e.state.buttons, [.a])
    }
    func testStickPlusNormalDepartureKeepsTailAndReleasesArmedShot() throws {
        var stick = ProfileControl(kind: .leftStick, stickBehavior: .init(stickPlusEnabled: true))
        stick.directionPayloads[.up] = .init(normalPayload: "", boostPayload: "LT:0.6(HRD120),X360A(SOR)", superBoostPayload: "")
        var e = try ProfileInputEngine(profile: profile([stick]))
        try e.begin(contact: 1, control: stick.id, position: .init(y: 0.6), at: 0)
        XCTAssertEqual(e.practiceState.leftTrigger, 0.6)
        try e.move(contact: 1, position: .zero, at: 0.1)
        XCTAssertEqual(e.state.buttons, [.a, .leftTrigger])
        try e.end(contact: 1, at: 0.11)
        try e.tick(at: 0.19); XCTAssertEqual(e.state.buttons, [.leftTrigger])
        try e.tick(at: 0.22); XCTAssertTrue(e.state.isNeutral)
    }
    func testRingAdsRealLiftRunsTimingButFinishCancelsOutstandingShot() throws {
        var config = FloatingRingConfig(); config.startRole = .aim
        config.knobs[0].fire.adsPayload = "LT:0.5(D30)(HRD200),RT:0.7(SOR)(D50)"
        let point = FloatingPoint(x: 300, y: 300), env = FloatingRingEnvironment()
        var ring = try FloatingRingRuntime(config: config, sessionID: UUID(), touch: point,
                                            usable: .init(x: 0, y: 0, width: 700, height: 900))
        XCTAssertTrue(ring.begin(contact: 1, point: point, initial: true, time: 10, environment: env))
        ring.advance(to: 10.03, environment: env); XCTAssertEqual(ring.claims.pressure[.left], 0.5)
        _ = try ring.samples(contact: 1, samples: [.init(point: point, elapsed: 0.05)], ending: true, now: 10.05, environment: env)
        XCTAssertEqual(ring.claims.pressure[.left], 0.5); XCTAssertNil(ring.claims.pressure[.right])
        ring.advance(to: 10.1, environment: env); XCTAssertEqual(ring.claims.pressure[.right], 0.7)
        ring.finish(); ring.advance(to: 11, environment: env); XCTAssertFalse(ring.claims.hasOutput); XCTAssertNil(ring.nextDeadline)
    }
    func testMixedAlternateOverridesTimedBaseAndCancelPreservesLatch() throws {
        var c = ProfileControl(payload: "RT:0.9(I),LT:0.4(HRD200)", buttonAim: .init(enabled: true, alternate: .init(enabled: true, payload: "RT:0.2")))
        c.buttonBehavior = .init(holdToggle: true, holdMilliseconds: 500)
        let point = ButtonPointerSample(x: 30, y: 30, width: 80, height: 80)
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginButton(contact: 1, control: c.id, sample: point, at: 0)
        try e.tick(at: 0.5); try e.end(contact: 1, at: 0.51)
        try e.beginButton(contact: 2, control: c.id, sample: point, at: 1)
        XCTAssertEqual(e.practiceState.rightTrigger, 0.2); XCTAssertEqual(e.practiceState.leftTrigger, 0.4)
        try e.cancel(contact: 2, at: 1.1)
        XCTAssertEqual(e.practiceState.rightTrigger, 0.9); XCTAssertEqual(e.practiceState.leftTrigger, 0.4)
        e.releaseAll(); XCTAssertTrue(e.state.isNeutral)
    }
    func testRealTwoStateReturnArmsOnlyAfterConfirmedReturnToAim() throws {
        let settings = TouchAimSettings(mode: .manualTwoState, twoState: .init(smoothing: 1, aimPayload: "",
            shootPayload: "X360A(I),RT:0.7(SOR)", shootBehavior: .pressOnReturn))
        let c = ProfileControl(kind: .touchAim, touchAim: settings)
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginTouchAim(contact: 1, control: c.id, sample: touch(6), at: 0)
        try e.tick(at: 0.09); try e.end(contact: 1, at: 0.1)
        XCTAssertTrue(e.state.isNeutral)
        try e.beginTouchAim(contact: 2, control: c.id, sample: touch(6), at: 1)
        try e.tick(at: 1.09)
        try e.moveTouchAimBatch(contact: 2, samples: [touch(1, 0.1)], at: 1.1)
        try e.tick(at: 1.22); XCTAssertEqual(e.state.buttons, [.a])
        try e.end(contact: 2, at: 1.30); XCTAssertEqual(e.state.buttons, [.rightTrigger])
        try e.tick(at: 1.39); XCTAssertTrue(e.state.isNeutral)
    }
    func testLaterTimedCommandOverridesEarlierTriggerAndOtherControlsRemainIndependent() throws {
        let b = ProfileControl(payload: "RT:0.9,RT:0.2(D100)"), other = ProfileControl(payload: "RT:0.5")
        var e = try ProfileInputEngine(profile: profile([b, other]))
        try e.begin(contact: 1, control: b.id, at: 0); XCTAssertEqual(e.practiceState.rightTrigger, 0.9)
        try e.tick(at: 0.1); XCTAssertEqual(e.practiceState.rightTrigger, 0.2)
        try e.begin(contact: 2, control: other.id, at: 0.12); XCTAssertEqual(e.practiceState.rightTrigger, 0.5)
        try e.end(contact: 1, at: 0.15); XCTAssertEqual(e.practiceState.rightTrigger, 0.5)
    }
    func testMalformedOrConflictingTimingAndInvalidRepeatPulseRejectEntireProgram() throws {
        for bad in ["W(I)(SOR)","LT:1.0(R1)","W(R10)(SOR)","RT:0.7P0.1(R100)","W(D1)(D2)","W(HRD-1)","W(D600001)","WAIT_100(D10)","RELEASE_ALL(SOR)","W(D0","X360A(I)BAD", "X360B(I),RT:0", "X360A(D10),MOUSE_LEFT_UP", "X360B(HRD20),WAIT_80"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse(bad), bad)
        }
        let imported = try ControllerPayloadProgram.parse("X360A_HOLD(HRD200) KEY_DOWN:W(SOR)")
        XCTAssertEqual(imported.steps, [.digital(.a), .keyDown(.w)])
        XCTAssertEqual(imported.source, "X360A(HRD200), W(SOR)")
        let p = try ControllerPayloadProgram.parse("lt:0.5(hrd200)(i),RT:0.7P0.03(R100)(D100)")
        XCTAssertEqual(p.minimumAndroidModifierVersion, 16)
        XCTAssertEqual(try ControllerPayloadProgram.parse(p.source), p)
    }
}

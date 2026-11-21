import XCTest
@testable import ControllerCore

final class FloatingRingRuntimeTests: XCTestCase {
    private let touch = FloatingPoint(x: 300, y: 300)
    private let canvas = FloatingRect(x: 0, y: 0, width: 700, height: 900)
    private let environment = FloatingRingEnvironment()
    private func runtime(_ config: FloatingRingConfig = .init()) throws -> FloatingRingRuntime {
        try .init(config: config, sessionID: UUID(), touch: touch, usable: canvas)
    }
    private func sample(_ r: FloatingRingRuntime, _ x: Double, _ y: Double, _ elapsed: Double) -> FloatingRingSample {
        .init(point: .init(x: r.placement.origin.x + r.geometry.center.x + x,
                           y: r.placement.origin.y + r.geometry.center.y + y), elapsed: elapsed)
    }
    private func start(_ r: inout FloatingRingRuntime, at time: Double = 0) {
        XCTAssertTrue(r.begin(contact: 1, point: touch, initial: true, time: time, environment: environment))
    }
    private func move(_ r: inout FloatingRingRuntime, _ x: Double, _ y: Double, _ elapsed: Double, ending: Bool = false, now: Double? = nil) throws {
        let s = sample(r,x,y,elapsed)
        _ = try r.samples(contact: 1, samples: [s], ending: ending, now: now ?? elapsed, environment: environment)
    }
    private func aiming(_ mode: RingFireMode = .none) -> FloatingRingConfig {
        var c = FloatingRingConfig(); c.startRole = .aim; c.knobs[0].fire.mode = mode
        c.knobs[0].fire.firePayload = "X360A"; return c
    }
    func testCompactAndAdjacentBoundariesUseTheStartingRole() throws {
        var c = FloatingRingConfig()
        c.compactAimBoosts = true; c.adjacentMovementBoosts = true
        c.boost1.enabled = true; c.boost2.enabled = true
        c.boost1.payload = "X360A"; c.boost2.payload = "X360B"; c.aim.participateInBoosts = true
        var r = try runtime(c); start(&r)
        try move(&r,88,0,0.01); XCTAssertTrue(r.claims.actions.isEmpty)
        try move(&r,89,0,0.02); XCTAssertEqual(r.claims.actions,[.a])
        try move(&r,128,0,0.03); XCTAssertEqual(r.claims.actions,[.a,.b])
        c.startRole = .aim; r = try runtime(c); start(&r)
        try move(&r,48,0,0.01); XCTAssertTrue(r.claims.actions.isEmpty)
        try move(&r,49,0,0.02); XCTAssertEqual(r.claims.actions,[.a])
        try move(&r,88,0,0.03); XCTAssertEqual(r.claims.actions,[.a,.b])
    }

    func testBankLayoutCanKeepMovementHeldWhileAimingWithOtherBindings() throws {
        var c = FloatingRingConfig(); c.aim.participateInBoosts = true
        var banks = c.seededBoostBanks(); banks.enabled = true
        banks.movement.boost1.enabled = true; banks.movement.boost1.payload = "X360A"
        banks.movement.boost1.retainOnLift = true; banks.movement.boost1.latchOnExit = true
        banks.movement.geometry = .init(enabled: true, boost1Distance: 90, boost1Thickness: 8, boost2Thickness: 7, directStartDistance: 94)
        banks.aim.geometry = .init(enabled: true, boost1Distance: 49, boost1Thickness: 4, boost2Thickness: 3, directStartDistance: 95)
        banks.aim.boost1.enabled = true; banks.aim.boost1.payload = "X360Y"
        c.boostBanks = banks
        var r = try runtime(c); start(&r)
        XCTAssertEqual(r.geometry.directBand(.two, bank: .aim), 99...102)
        try move(&r,91,0,0.01); try move(&r,91,0,0.02,ending:true)
        XCTAssertEqual(r.claims.actions,[.a])
        XCTAssertTrue(r.begin(contact:1,point:sample(r,0,0,0).point,initial:false,time:0.03,environment:environment))
        try move(&r,51,0,0.01,now:0.04); XCTAssertEqual(r.claims.actions,[.a,.y])
        XCTAssertTrue(r.state.boostBankStatus.contains { $0.contains("Movement B1") })
        XCTAssertTrue(r.state.boostBankStatus.contains { $0.contains("Aim B1") })
        r.cancel(); XCTAssertEqual(r.claims.actions,[.a])
        r.finish(); XCTAssertTrue(r.claims.actions.isEmpty)
    }

    func testDirectAimStartsNeutralWithFineAndSkipsDelayOnlyOnFreshTouch() throws {
        var c = aiming(.hold)
        c.startRole = .boostTwo; c.directBoostStartsAim = true
        c.aim.fine.enabled = true; c.aim.tuning.output = .rightStick; c.aim.tuning.origin = .controlCenter
        c.knobs[0].fire.adsPayload = "LT:0.5"; c.knobs[0].fire.firePayload = "RT:0.7"
        c.boost2.enabled = true; c.boost2.payload = "X360B"; c.boost2.directTapEnabled = true
        c.boost2.activationDelayMilliseconds = 300; c.boost2.skipDelayOnDirectTouch = true
        var r = try runtime(c); start(&r)
        XCTAssertTrue(r.state.aiming && r.state.fine); XCTAssertEqual(r.aimAnalog?.position,.zero)
        XCTAssertTrue(r.claims.pressure.isEmpty); XCTAssertEqual(r.claims.actions,[.b])
        try move(&r,0,0,0.01,ending:true); XCTAssertFalse(r.state.fine)
        c.startRole = .movement; r = try runtime(c); start(&r)
        try move(&r,163,0,0.01); XCTAssertTrue(r.state.pending); XCTAssertTrue(r.claims.actions.isEmpty)
        r.advance(to:0.31,environment:environment); XCTAssertEqual(r.claims.actions,[.b])
    }

    func testFireTimerStartsAtFirstBoostAndWaitsForAimWhenRequired() throws {
        var c = aiming(.hold); c.aim.participateInBoosts = true; c.compactAimBoosts = true
        c.boost1.enabled = true; c.boost2.enabled = true
        c.knobs[0].fire.returnFire = .init(enabled:true,qualifyingStages:[.one,.two],delayMilliseconds:300)
        c.knobs[0].fire.returnFire.startOnBoostEntry = true; c.knobs[0].fire.continueFireOutside = false
        var r = try runtime(c); start(&r); try move(&r,50,0,0.1); try move(&r,91,0,0.2)
        XCTAssertEqual(try XCTUnwrap(r.nextDeadline),0.4,accuracy:0.0001)
        r.advance(to:0.4,environment:environment); XCTAssertFalse(r.state.pending); XCTAssertTrue(r.claims.actions.isEmpty)
        try move(&r,47,0,0.41); XCTAssertEqual(r.claims.actions,[.a])
        try move(&r,50,0,0.5); XCTAssertTrue(r.state.pending)
        r.finish(); r.advance(to:1,environment:environment); XCTAssertTrue(r.claims.actions.isEmpty)
    }

    func testIgnoringFinishSwipeAllowsAnIntentionalFreshFinishTap() throws {
        var r = try FloatingRingRuntime(config:.init(),sessionID:UUID(),touch:touch,usable:canvas,finishIgnoresSwipes:true)
        start(&r)
        let path = [FloatingRingSample(point:r.placement.finish.center,elapsed:0.1)]
        _ = try r.samples(contact:1,samples:path,ending:true,now:0.1,environment:environment)
        XCTAssertFalse(r.finished)
        XCTAssertTrue(r.begin(contact:2,point:r.placement.finish.center,initial:false,time:0.2,environment:environment))
        XCTAssertTrue(r.finished)
    }

    func testRecenterMovementKeepsBoostAndRebasesWithoutRetainingNeutral() throws {
        var c = FloatingRingConfig(); c.movement.autoCenter = false
        c.boost1.enabled = true; c.boost1.payload = "X360A"; c.boost1.retainOnLift = true
        var r = try runtime(c); start(&r); try move(&r,130,0,0.1)
        r.recenterMovement(); XCTAssertNil(r.movementAnalog); XCTAssertEqual(r.claims.actions,[.a])
        try move(&r,140,0,0.2); XCTAssertEqual(try XCTUnwrap(r.movementAnalog).position.x,10/88,accuracy:0.00001)
        r.recenterMovement(); try move(&r,140,0,0.3,ending:true)
        XCTAssertNil(r.movementAnalog); XCTAssertEqual(r.claims.actions,[.a])
    }

    func testMovementRetainsOnlyOnNormalLiftAndFinishClearsIt() throws {
        var c = FloatingRingConfig(); c.movement.autoCenter = false
        var r = try runtime(c); start(&r); try move(&r,88,0,0.1,ending:true)
        XCTAssertEqual(r.movementAnalog?.position,.init(x:1)); XCTAssertTrue(r.state.retained)
        XCTAssertNil(r.contact); r.finish(); XCTAssertNil(r.movementAnalog); XCTAssertTrue(r.state.finished)
        XCTAssertFalse(r.state.visible)
    }
    func testMouseSuppressionPersistsOnLiftUntilExplicitActionOrFinish() throws {
        var config = aiming(); config.aim.suppressCameraFollow = true
        var r = try runtime(config); start(&r); XCTAssertTrue(r.state.suppressed)
        try move(&r, 0, 0, 0.1, ending: true); XCTAssertTrue(r.state.suppressed)
        r.localAction(.endSuppression); XCTAssertFalse(r.state.suppressed)
        XCTAssertTrue(r.begin(contact: 2, point: touch, initial: false, time: 0.2, environment: environment))
        XCTAssertTrue(r.state.suppressed); r.finish(); XCTAssertFalse(r.state.suppressed)
    }
    func testMovementCancelAndOccupiedStickDoNotCreateRetainedOutput() throws {
        var c = FloatingRingConfig(); c.movement.autoCenter = false
        var r = try runtime(c); start(&r); try move(&r,88,0,0.1); r.cancel()
        XCTAssertNil(r.movementAnalog)
        XCTAssertTrue(r.begin(contact:2,point:sample(r,80,0,0).point,initial:false,time:0.2,environment:.init(occupiedChannels:[.leftStick])))
        XCTAssertNil(r.movementAnalog)
        XCTAssertNotNil(r.issue)
    }
    func testBoostsAreCumulativeAndRadialWithDistanceHysteresis() throws {
        var c = FloatingRingConfig(); c.boost1.enabled = true; c.boost1.payload = "X360A"
        c.boost2.enabled = true; c.boost2.payload = "X360B"
        var r = try runtime(c); start(&r)
        try move(&r,120,0,0.1); XCTAssertEqual(r.claims.actions,[.a])
        try move(&r,160,0,0.2); XCTAssertEqual(r.claims.actions,[.a,.b])
        try move(&r,159,0,0.3); XCTAssertEqual(r.claims.actions,[.a,.b])
        try move(&r,157,0,0.4); XCTAssertEqual(r.claims.actions,[.a])
        try move(&r,117,0,0.5); XCTAssertTrue(r.claims.actions.isEmpty)
    }
    func testDirectionChangesUseTwelvePointHysteresis() throws {
        var c = FloatingRingConfig(); c.boost1.enabled = true
        c.boost1.directionalPayloads = .init(right:"X360A",down:"X360B")
        var r = try runtime(c); start(&r)
        try move(&r,100,100,0.1); XCTAssertEqual(r.claims.actions,[.a])
        try move(&r,100,111,0.2); XCTAssertEqual(r.claims.actions,[.a])
        try move(&r,100,112,0.3); XCTAssertEqual(r.claims.actions,[.b])
    }
    func testDelayedBoostSeesCompleteCoalescedExitBeforeOverdueTimer() throws {
        var c = FloatingRingConfig(); c.boost2.enabled = true; c.boost2.payload = "X360A"; c.boost2.activationDelayMilliseconds = 50
        var r = try runtime(c); start(&r)
        let path = [sample(r,180,0,0.1),sample(r,0,0,0.2)]
        _ = try r.samples(contact:1,samples:path,ending:false,now:1,environment:environment)
        r.advance(to:1,environment:environment)
        XCTAssertFalse(r.state.pending); XCTAssertTrue(r.claims.actions.isEmpty)
    }
    func testDelayedBoostCanExplicitlyLatchAfterExitButNeverAfterLift() throws {
        var c = FloatingRingConfig(); c.boost2.enabled = true; c.boost2.payload = "X360A"
        c.boost2.activationDelayMilliseconds = 500; c.boost2.cancelDelayOnExit = false; c.boost2.latchOnExit = true
        var r = try runtime(c); start(&r); try move(&r,180,0,0.1); try move(&r,0,0,0.2)
        r.advance(to:0.6,environment:environment); XCTAssertEqual(r.claims.actions,[.a]); XCTAssertEqual(r.state.latchedBoosts,[.two])
        var lifted = try runtime(c); start(&lifted); try move(&lifted,180,0,0.1); try move(&lifted,0,0,0.2,ending:true)
        lifted.advance(to:1,environment:environment); XCTAssertTrue(lifted.claims.actions.isEmpty)
    }
    func testTerminalSampleCannotActivateNewBoost() throws {
        var c = FloatingRingConfig(); c.boost1.enabled = true; c.boost1.payload = "X360A"; c.boost1.action = .tap
        var r = try runtime(c); start(&r); try move(&r,130,0,0.1,ending:true)
        XCTAssertTrue(r.claims.actions.isEmpty); XCTAssertNil(r.nextDeadline)
    }
    func testFinishPreflightCancelsEntirePathBeforeAnyAction() throws {
        var c = FloatingRingConfig(); c.boost1.enabled = true; c.boost1.payload = "X360A"; c.boost1.action = .tap
        var r = try runtime(c); start(&r)
        let path = [sample(r,130,0,0.1),FloatingRingSample(point:r.placement.finish.center,elapsed:0.2),sample(r,0,0,0.3)]
        _ = try r.samples(contact:1,samples:path,ending:false,now:0.3,environment:environment)
        XCTAssertTrue(r.finished); XCTAssertTrue(r.claims.actions.isEmpty); XCTAssertNil(r.nextDeadline)
    }
    func testMalformedCoalescedPacketIsAtomicAndOtherContactCannotControlRing() throws {
        var r = try runtime(); start(&r); let before = r.state
        var invalid = sample(r,88,0,0.2); invalid.point.x = .nan
        XCTAssertThrowsError(try r.samples(contact:1,samples:[sample(r,88,0,0.1),invalid],ending:false,now:0.2,environment:environment))
        XCTAssertEqual(r.state,before)
        _ = try r.samples(contact:9,samples:[sample(r,88,0,0.1)],ending:true,now:0.1,environment:environment)
        XCTAssertEqual(r.contact,1); XCTAssertEqual(r.movementAnalog?.position,.zero)
    }
    func testNormalReleaseShotIsFiniteAndCancelNeverShoots() throws {
        var r = try runtime(aiming(.releaseShot)); start(&r)
        XCTAssertTrue(r.state.armed); XCTAssertTrue(r.claims.actions.isEmpty)
        XCTAssertTrue(r.state.aiming) // Mouse aim has no analog position but still needs live UI feedback.
        try move(&r,0,0,0.1,ending:true); XCTAssertEqual(r.claims.actions,[.a]); XCTAssertNil(r.contact)
        XCTAssertFalse(r.state.aiming)
        r.advance(to:0.135,environment:environment); XCTAssertTrue(r.claims.actions.isEmpty)
        var cancel = try runtime(aiming(.releaseShot)); start(&cancel); cancel.cancel(); cancel.advance(to:1,environment:environment)
        XCTAssertTrue(cancel.claims.actions.isEmpty); XCTAssertNil(cancel.nextDeadline)
    }
    func testReleaseShotBoundaryExitAndExplicitRearm() throws {
        var c = aiming(.releaseShot); c.knobs[0].fire.cancelReleaseShotOnBoundaryExit = true
        var r = try runtime(c); start(&r); try move(&r,60,0,0.1); try move(&r,0,0,0.2,ending:true)
        XCTAssertTrue(r.claims.actions.isEmpty)
        c.knobs[0].fire.rearmReleaseShotOnBoundaryReturn = true
        r = try runtime(c); start(&r); try move(&r,60,0,0.1); try move(&r,0,0,0.2); try move(&r,0,0,0.3,ending:true)
        XCTAssertEqual(r.claims.actions,[.a])
    }
    func testReturnFireRequiresVisitedBoostAndCancelsPendingOnLift() throws {
        var c = aiming(.hold); c.aim.participateInBoosts = true; c.boost1.enabled = true
        c.knobs[0].fire.returnFire.enabled = true; c.knobs[0].fire.returnFire.delayMilliseconds = 200
        var r = try runtime(c); start(&r); XCTAssertTrue(r.claims.actions.isEmpty)
        try move(&r,130,0,0.1); try move(&r,0,0,0.2); XCTAssertTrue(r.state.pending)
        try move(&r,0,0,0.3,ending:true); r.advance(to:1,environment:environment)
        XCTAssertTrue(r.claims.actions.isEmpty)
        r = try runtime(c); start(&r); try move(&r,130,0,0.1); try move(&r,0,0,0.2)
        r.advance(to:0.4,environment:environment); XCTAssertEqual(r.claims.actions,[.a])
    }
    func testDirectBoostToAimDoesNotInventADSOrFire() throws {
        var c = aiming(.hold); c.startRole = .boostOne; c.boost1.enabled = true; c.boost1.directTapEnabled = true
        c.boost1.payload = "X360B"; c.directBoostToAim = true; c.knobs[0].fire.adsPayload = "LT:1"
        var r = try runtime(c); start(&r); XCTAssertEqual(r.claims.actions,[.b])
        try move(&r,0,0,0.1); XCTAssertTrue(r.claims.actions.isEmpty); XCTAssertNil(r.claims.pressure[.left])
        try move(&r,10,0,0.2); XCTAssertTrue(r.claims.actions.isEmpty)
    }
    func testDirectBoostTwoFastInwardCrossVisitsLowerLatch() throws {
        var c = FloatingRingConfig(); c.startRole = .boostTwo; c.directBoostTwoToOne = true
        c.boost2.enabled = true; c.boost2.directTapEnabled = true; c.boost2.payload = "X360B"
        c.boost1.enabled = true; c.boost1.payload = "X360A"; c.boost1.latchOnExit = true; c.boost1.retainOnLift = true
        var r = try runtime(c); start(&r); XCTAssertEqual(r.claims.actions,[.b])
        try move(&r,0,0,0.1); XCTAssertEqual(r.claims.actions,[.a]); XCTAssertEqual(r.state.latchedBoosts,[.one])
    }
    func testFineAimCanPersistOnlyWithQualifyingLatchedADS() throws {
        var c = aiming(); c.aim.participateInBoosts = true; c.aim.fine.enabled = true
        c.boost1.enabled = true; c.boost1.payload = "LT:1"; c.boost1.latchOnExit = true; c.boost1.retainOnLift = true
        var r = try runtime(c); start(&r); try move(&r,130,0,0.1); try move(&r,0,0,0.2)
        XCTAssertTrue(r.state.fine); try move(&r,0,0,0.3,ending:true); XCTAssertTrue(r.state.ads)
        r.localAction(.releaseADS); XCTAssertFalse(r.state.fine); XCTAssertNil(r.claims.pressure[.left])
    }
    func testAimBoundaryCentersAndReanchorsControlCenterWithoutJump() throws {
        var c = aiming(); c.aim.tuning.output = .rightStick; c.aim.tuning.origin = .controlCenter; c.aim.continueOutside = false
        var r = try runtime(c); start(&r); try move(&r,24,0,0.1)
        XCTAssertEqual(r.aimAnalog?.position.x ?? 0,0.5,accuracy:1e-10)
        try move(&r,60,0,0.2); XCTAssertEqual(r.aimAnalog?.position,.zero)
        try move(&r,30,0,0.3); XCTAssertEqual(r.aimAnalog?.position,.zero)
        try move(&r,42,0,0.4); XCTAssertEqual(r.aimAnalog?.position.x ?? 0,0.25,accuracy:1e-10)
    }
    func testRetainedAimIsNotMovedByLaterMovementGesture() throws {
        var c = aiming(); c.aim.tuning.output = .rightStick; c.aim.tuning.autoCenter = false; c.aim.tuning.deadzone = 0
        var r = try runtime(c); start(&r); try move(&r,30,0,0.1,ending:true)
        let retained = r.aimAnalog?.position
        let movementPoint = sample(r,80,0,0).point
        XCTAssertTrue(r.begin(contact:2,point:movementPoint,initial:false,time:0.2,environment:environment))
        _ = try r.samples(contact:2,samples:[sample(r,-80,0,0.1)],ending:false,now:0.3,environment:environment)
        XCTAssertEqual(r.aimAnalog?.position,retained); XCTAssertTrue(r.aimAnalog?.retained == true)
        r.cancel(); XCTAssertEqual(r.aimAnalog?.position,retained)
    }
    func testCancelNewGesturePreservesOlderRetainedHold() throws {
        var c = aiming(.hold); c.knobs[0].fire.retainFireOnLift = true
        var r = try runtime(c); start(&r); try move(&r,0,0,0.1,ending:true)
        XCTAssertEqual(r.claims.actions,[.a]); XCTAssertTrue(r.state.retained)
        XCTAssertTrue(r.begin(contact:2,point:touch,initial:false,time:0.2,environment:environment)); r.cancel()
        XCTAssertEqual(r.claims.actions,[.a]); XCTAssertTrue(r.state.retained)
        r.localAction(.stopFire); XCTAssertTrue(r.claims.actions.isEmpty)
    }
    func testBlockedFiniteOutputDoesNotSpringAliveAfterOtherOwnerLeaves() throws {
        var r = try runtime(aiming(.tap))
        XCTAssertTrue(r.begin(contact:1,point:touch,initial:true,time:0,environment:.init(blockedPayloadKeys:[.digital(.a)])))
        XCTAssertTrue(r.claims.actions.isEmpty); XCTAssertEqual(r.state.overridden,[.fire])
        r.advance(to:1,environment:environment); XCTAssertTrue(r.claims.actions.isEmpty)
        r.cancel(); XCTAssertTrue(r.begin(contact:2,point:touch,initial:false,time:2,environment:environment))
        XCTAssertEqual(r.claims.actions,[.a])
    }
    func testFiniteOutputKeepsReservationInGapAndLateTicksDoNotCatchUp() {
        var output = FloatingRingOutput()
        XCTAssertTrue(output.pulse("X360A",pressMilliseconds:35,gapMilliseconds:35,gesture:1,now:0,permitted:true))
        XCTAssertEqual(output.claims.actions,[.a]); XCTAssertEqual(output.exclusiveKeys,[.digital(.a)])
        XCTAssertTrue(output.advance(to:10,permits:{_ in true})); XCTAssertTrue(output.claims.actions.isEmpty)
        XCTAssertEqual(output.deadline,10.035); XCTAssertTrue(output.hasReservation)
        XCTAssertTrue(output.advance(to:10.034,permits:{_ in true})); XCTAssertTrue(output.hasReservation)
        XCTAssertTrue(output.advance(to:10.035,permits:{_ in true})); XCTAssertFalse(output.hasReservation)
    }
    func testFiniteRetriggerQueueIsBoundedToOneAndCanBeCanceledByGesture() {
        var output = FloatingRingOutput()
        _ = output.pulse("X360A",pressMilliseconds:10,gapMilliseconds:10,gesture:1,now:0,permitted:true)
        _ = output.pulse("X360B",pressMilliseconds:20,gapMilliseconds:20,gesture:2,now:0,permitted:true)
        _ = output.pulse("X360X",pressMilliseconds:30,gapMilliseconds:30,gesture:3,now:0,permitted:true)
        XCTAssertEqual(output.queued?.payload,"X360B")
        _ = output.advance(to:0.01,permits:{_ in true}); _ = output.advance(to:0.02,permits:{_ in true})
        XCTAssertEqual(output.claims.actions,[.b]); XCTAssertEqual(output.activeGesture,2)
        _ = output.pulse("X360X",pressMilliseconds:30,gapMilliseconds:30,gesture:3,now:0.03,permitted:true)
        output.restoreRetained(false,cancelQueuedFrom:3); XCTAssertNil(output.queued)
    }
    func testRepeatReservesOffGapsAndStopHasNoFutureWork() {
        var output = FloatingRingOutput()
        _ = output.repeatOutput("RT:0.5",pressMilliseconds:10,gapMilliseconds:20,gesture:1,now:0,permitted:true)
        _ = output.advance(to:0.01,permits:{_ in true})
        XCTAssertTrue(output.claims.pressure.isEmpty); XCTAssertEqual(output.exclusiveKeys,[.trigger(.right)])
        output.retainOrRelease(true); XCTAssertTrue(output.retained)
        _ = output.advance(to:0.03,permits:{_ in true}); XCTAssertEqual(output.claims.pressure[.right],0.5)
        output.stop(); _ = output.advance(to:100,permits:{_ in true})
        XCTAssertTrue(output.claims.pressure.isEmpty); XCTAssertNil(output.deadline); XCTAssertFalse(output.hasReservation)
    }
}

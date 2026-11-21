import XCTest
@testable import ControllerCore

final class SustainedFixedStickTests: XCTestCase {
    private func profile(_ controls: [ProfileControl], ring: FloatingRingConfig? = nil, turbo: Bool = false) throws -> ControllerProfile {
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        var value = try ControllerProfile(controls: controls, portrait: positions, landscape: positions,
                                          turboEnabled: turbo, turboIntervalMilliseconds: 100)
        if let ring {
            value.pages[0].floatingRingZones = [.init(portraitGeometry: .init(canvasWidth: 700, canvasHeight: 900,
                zone: .init(x: 0, y: 0, width: 700, height: 900)), config: ring)]
        }
        try value.validate(); return value
    }
    private func point(_ x: Double = 50, _ y: Double = 50) -> ButtonPointerSample { .init(x: x, y: y, width: 100, height: 100) }
    private func touch(_ radius: Double = 1, _ elapsed: Double = 0) -> TouchAimSample {
        .init(pointer: point(), metrics: .init(majorRadius: radius), elapsed: elapsed)
    }
    private func aim(_ payload: String) -> ProfileControl { .init(payload: payload, buttonAim: .init(enabled: true)) }
    private func stick(directional: Bool = false, retained: Bool = false) -> ProfileControl {
        var c = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: !retained, stickPlusEnabled: !directional))
        c.directionalEnabled = directional
        c.directionPayloads[.up] = .init(normalPayload: "RS:R30", boostPayload: "RS:U60", superBoostPayload: "RS:L90")
        return c
    }
    private let canvas = FloatingRect(x: 0, y: 0, width: 700, height: 900)
    private func beginRing(_ e: inout ProfileInputEngine, at time: Double = 0) throws -> (UUID, UUID) {
        let id = e.profile.pages[0].floatingRingZones[0].id, session = UUID()
        XCTAssertTrue(try e.beginFloatingRing(contact: 1, zoneID: id, sessionID: session,
            point: .init(x: 300, y: 300), usable: canvas, at: time))
        return (id, session)
    }
    private func ringSample(_ e: ProfileInputEngine, _ id: UUID, _ x: Double, elapsed: Double) -> FloatingRingSample {
        let state = e.floatingRingStates[id]!
        return .init(point: .init(x: state.placement.origin.x + state.geometry.center.x + x,
                                  y: state.placement.origin.y + state.geometry.center.y), elapsed: elapsed)
    }
    func testStickPlusStageTransitionsKeepPhysicalStickAndReleaseOnlyOwnMacro() throws {
        let c = stick(); var e = try ProfileInputEngine(profile: profile([c]))
        try e.begin(contact: 1, control: c.id, position: .init(y: 0.3), at: 0)
        XCTAssertEqual(e.state.leftStick.y, 0.3); XCTAssertEqual(e.state.rightStick, .init(x: 0.3))
        try e.move(contact: 1, position: .init(y: 0.6), at: 0.1); XCTAssertEqual(e.state.rightStick, .init(y: 0.6))
        try e.move(contact: 1, position: .init(y: 0.9), at: 0.2); XCTAssertEqual(e.state.rightStick, .init(x: -0.9))
        try e.end(contact: 1, at: 0.3); XCTAssertEqual(e.state, .neutral)
    }
    func testDirectionalRetainedMacroYieldsAndCannotReviveAfterManualEnds() throws {
        let c = stick(directional: true, retained: true), manual = ProfileControl(kind: .rightStick)
        var e = try ProfileInputEngine(profile: profile([c, manual]))
        try e.begin(contact: 1, control: c.id, position: .init(y: 0.3), at: 0); try e.end(contact: 1, at: 0.01)
        XCTAssertEqual(e.state.rightStick, .init(x: 0.3)); XCTAssertEqual(e.state.leftStick, .zero)
        try e.begin(contact: 2, control: manual.id, position: .init(y: -0.5), at: 0.02)
        XCTAssertEqual(e.state.rightStick, .init(y: -0.5))
        try e.end(contact: 2, at: 0.03); try e.tick(at: 1); XCTAssertEqual(e.state.rightStick, .zero)
        try e.begin(contact: 3, control: c.id, position: .init(y: 0.6), at: 2); XCTAssertEqual(e.state.rightStick, .init(y: 0.6))
    }
    func testRejectedStickStageNeedsExplicitNewStageNotAnotherTimerPass() throws {
        let c = stick(directional: true), manual = ProfileControl(kind: .rightStick)
        var e = try ProfileInputEngine(profile: profile([c, manual]))
        try e.begin(contact: 2, control: manual.id, position: .init(x: -1), at: 0)
        try e.begin(contact: 1, control: c.id, position: .init(y: 0.3), at: 0.01)
        try e.end(contact: 2, at: 0.02); try e.tick(at: 1); XCTAssertEqual(e.state.rightStick, .zero)
        try e.move(contact: 1, position: .init(y: 0.4), at: 1.1); XCTAssertEqual(e.state.rightStick, .zero)
        try e.move(contact: 1, position: .init(y: 0.6), at: 1.2); XCTAssertEqual(e.state.rightStick, .init(y: 0.6))
    }
    func testTwoDirectionalSurfacesShareFirstLiveOwnership() throws {
        let a = stick(directional: true), b = stick(directional: true)
        var e = try ProfileInputEngine(profile: profile([a, b]))
        try e.begin(contact: 1, control: a.id, position: .init(y: 0.3), at: 0)
        try e.begin(contact: 2, control: b.id, position: .init(y: 0.6), at: 0.01)
        XCTAssertEqual(e.state.rightStick, .init(x: 0.3)); try e.end(contact: 1, at: 0.02)
        try e.tick(at: 1); XCTAssertEqual(e.state.rightStick, .zero)
        try e.move(contact: 2, position: .init(y: 0.9), at: 1.1); XCTAssertEqual(e.state.rightStick, .init(x: -0.9))
    }
    func testAdvancedMixedPayloadKeepsDigitalWhenVectorBlockedAndDoesNotRevive() throws {
        let c = aim("RS:R50,X360A"), manual = ProfileControl(kind: .rightStick)
        var e = try ProfileInputEngine(profile: profile([c, manual]))
        try e.begin(contact: 2, control: manual.id, position: .init(y: -1), at: 0)
        try e.beginButton(contact: 1, control: c.id, sample: point(), at: 0.01)
        XCTAssertEqual(e.state.rightStick, .init(y: -1)); XCTAssertEqual(e.state.buttons, [.a])
        XCTAssertNotNil(e.fixedStickIssues[c.id])
        try e.end(contact: 2, at: 0.02); try e.tick(at: 1); XCTAssertEqual(e.state.rightStick, .zero)
        try e.endButton(contact: 1, finalSamples: [], at: 1.1)
        try e.beginButton(contact: 3, control: c.id, sample: point(), at: 1.2)
        XCTAssertEqual(e.state.rightStick, .init(x: 0.5)); XCTAssertTrue(e.outputControls.contains(c.id))
        XCTAssertNil(e.fixedStickIssues[c.id])
    }
    func testDirectionalButtonLocalStagesRestoreBaseWithinOwnContinuousChannel() throws {
        var c = ProfileControl(payload: "LS:U20", buttonDirectional: .init(enabled: true))
        c.buttonDirectional.directions[.right] = .init(firstDistance: 48, secondDistance: 96, firstPayload: "LS:R40", secondPayload: "LS:D60")
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginButton(contact: 1, control: c.id, sample: point(), at: 0); XCTAssertEqual(e.state.leftStick, .init(y: 0.2))
        try e.moveButtonBatch(contact: 1, samples: [point(100)], at: 0.1); XCTAssertEqual(e.state.leftStick, .init(x: 0.4))
        try e.moveButtonBatch(contact: 1, samples: [point(150)], at: 0.2); XCTAssertEqual(e.state.leftStick, .init(y: -0.6))
        try e.moveButtonBatch(contact: 1, samples: [point(100)], at: 0.3); XCTAssertEqual(e.state.leftStick, .init(x: 0.4))
        try e.moveButtonBatch(contact: 1, samples: [point()], at: 0.4); XCTAssertEqual(e.state.leftStick, .init(y: 0.2))
        try e.cancel(contact: 1, at: 1); XCTAssertEqual(e.state, .neutral)
    }
    func testAimCannotUseMacroToStealItsOwnLivePhysicalChannel() throws {
        var c = aim("RS:L,X360A"); c.buttonAim.tuning.output = .rightStick; c.buttonAim.tuning.origin = .controlCenter
        var e = try ProfileInputEngine(profile: profile([c])); try e.beginButton(contact: 1, control: c.id, sample: point(75), at: 0)
        XCTAssertEqual(e.state.rightStick.x, 0.5); XCTAssertEqual(e.state.buttons, [.a])
        e.recenterSticks(); try e.moveButtonBatch(contact: 1, samples: [point(90)], at: 0.1)
        XCTAssertEqual(e.state.rightStick, .zero); XCTAssertEqual(e.state.buttons, [.a])
    }
    func testAdvancedReleaseMacroIsFiniteAndCancelNeverCreatesIt() throws {
        var c = aim("LS:U50"); c.buttonAim.payloadTiming = .sendOnRelease
        var e = try ProfileInputEngine(profile: profile([c])); try e.beginButton(contact: 1, control: c.id, sample: point(), at: 0)
        try e.endButton(contact: 1, finalSamples: [], at: 0.1); XCTAssertEqual(e.state.leftStick, .init(y: 0.5))
        try e.tick(at: 0.19); XCTAssertEqual(e.state.leftStick, .zero)
        try e.beginButton(contact: 2, control: c.id, sample: point(), at: 1); try e.cancel(contact: 2, at: 2)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertNil(e.nextDeadline)
    }
    func testRecenterPreventsPendingAdvancedMacroButPreservesDigitalPayload() throws {
        var c = aim("LS:U50,X360B"); c.buttonAim.payloadTiming = .sendOnRelease; c.buttonAim.releaseDelayMilliseconds = 200
        var e = try ProfileInputEngine(profile: profile([c])); try e.beginButton(contact: 1, control: c.id, sample: point(), at: 0)
        try e.endButton(contact: 1, finalSamples: [], at: 0.1); e.recenterSticks(); try e.tick(at: 0.3)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.buttons, [.b])
    }
    func testAdvancedTurboReservesNeutralOffGapAndDoesNotReviveAfterCancel() throws {
        let c = aim("LS:U50"), manual = ProfileControl(kind: .leftStick)
        var e = try ProfileInputEngine(profile: profile([c, manual], turbo: true))
        try e.beginButton(contact: 1, control: c.id, sample: point(), at: 0); XCTAssertEqual(e.state.leftStick, .init(y: 0.5))
        try e.tick(at: 0.095); XCTAssertEqual(e.state.leftStick, .zero)
        try e.begin(contact: 2, control: manual.id, position: .init(x: 1), at: 0.096); XCTAssertFalse(e.isCapturedInputOwner(for: 2))
        try e.tick(at: 0.1); XCTAssertEqual(e.state.leftStick, .init(y: 0.5))
        try e.cancel(contact: 1, at: 0.11); try e.move(contact: 2, position: .init(x: 1), at: 1); XCTAssertEqual(e.state.leftStick, .zero)
    }
    func testTouchAimShootOverridesAndRestoresOwnAimMacro() throws {
        var c = ProfileControl(kind: .touchAim); c.touchAim.mode = .manualTwoState
        c.touchAim.twoState = .init(smoothing: 1, aimPayload: "RS:R25", shootPayload: "RS:U75", keepAimWhileShooting: true)
        var e = try ProfileInputEngine(profile: profile([c])); try e.beginTouchAim(contact: 1, control: c.id, sample: touch(), at: 0)
        XCTAssertEqual(e.state.rightStick, .init(x: 0.25))
        try e.moveTouchAimBatch(contact: 1, samples: [touch(6, 0.1)], at: 0.1); try e.tick(at: 0.19)
        XCTAssertEqual(e.state.rightStick, .init(y: 0.75))
        try e.moveTouchAimBatch(contact: 1, samples: [touch(1, 0.2)], at: 0.2); try e.tick(at: 0.32)
        XCTAssertEqual(e.state.rightStick, .init(x: 0.25)); try e.end(contact: 1, at: 0.4); XCTAssertEqual(e.state.rightStick, .zero)
    }
    func testTouchAimPressExpiresAndSetupGateNeverClaimsMacro() throws {
        var c = ProfileControl(kind: .touchAim); c.touchAim.threeStage.smoothing = 1; c.touchAim.threeStage.low.payload = "LS:U50"
        var e = try ProfileInputEngine(profile: profile([c])); try e.beginTouchAim(contact: 1, control: c.id, sample: touch(2), at: 0)
        XCTAssertEqual(e.state.leftStick, .init(y: 0.5)); try e.tick(at: 0.09); XCTAssertEqual(e.state.leftStick, .zero)
        c.touchAim.requiresLocalSetup = true; e = try ProfileInputEngine(profile: profile([c]))
        try e.beginTouchAim(contact: 1, control: c.id, sample: touch(2), at: 0); try e.tick(at: 1); XCTAssertEqual(e.state.leftStick, .zero)
    }
    func testRecenterSuppressesTouchAimFutureStagesUntilNewTouch() throws {
        var c = ProfileControl(kind: .touchAim); c.touchAim.threeStage.smoothing = 1
        c.touchAim.threeStage.medium.payload = ""
        c.touchAim.threeStage.high.payload = "LS:U75,X360A"
        var e = try ProfileInputEngine(profile: profile([c])); try e.beginTouchAim(contact: 1, control: c.id, sample: touch(), at: 0)
        e.recenterSticks(); try e.moveTouchAimBatch(contact: 1, samples: [touch(6, 0.1)], at: 0.1)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.buttons, [.a])
        try e.cancel(contact: 1, at: 0.2); try e.beginTouchAim(contact: 2, control: c.id, sample: touch(6), at: 0.3)
        XCTAssertEqual(e.state.leftStick, .init(y: 0.75))
    }
    func testRingBoostMacroSharesStateAndFinishPreservesIndependentButton() throws {
        var ring = FloatingRingConfig(); ring.boost1.enabled = true; ring.boost1.payload = "RS:U50,X360A"
        let independent = ProfileControl(actions: [.b]); var e = try ProfileInputEngine(profile: profile([independent], ring: ring))
        try e.begin(contact: 2, control: independent.id, at: 0); let (id, session) = try beginRing(&e)
        try e.moveFloatingRing(contact: 1, sessionID: session, samples: [ringSample(e, id, 130, elapsed: 0.1)], at: 0.1)
        XCTAssertEqual(e.state.leftStick, .init(x: 1)); XCTAssertEqual(e.state.rightStick, .init(y: 0.5)); XCTAssertEqual(e.state.buttons, [.a, .b])
        try e.floatingRingAction(zoneID: id, sessionID: session, action: .finish, at: 0.2)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.rightStick, .zero); XCTAssertEqual(e.state.buttons, [.b])
    }
    func testRingMixedPayloadDoesNotDropDigitalWhenMacroChannelIsOccupied() throws {
        var ring = FloatingRingConfig(); ring.boost1.enabled = true; ring.boost1.payload = "RS:U50,X360A"
        let manual = ProfileControl(kind: .rightStick); var e = try ProfileInputEngine(profile: profile([manual], ring: ring))
        try e.begin(contact: 2, control: manual.id, position: .init(x: -1), at: 0); let (id, session) = try beginRing(&e)
        try e.moveFloatingRing(contact: 1, sessionID: session, samples: [ringSample(e, id, 130, elapsed: 0.1)], at: 0.1)
        XCTAssertEqual(e.state.rightStick, .init(x: -1)); XCTAssertEqual(e.state.buttons, [.a])
        try e.end(contact: 2, at: 0.2); try e.tick(at: 1); XCTAssertEqual(e.state.rightStick, .zero)
    }
    func testRingRetainedADSVectorYieldsAndDoesNotReturn() throws {
        var ring = FloatingRingConfig(); ring.startRole = .aim; ring.knobs[0].fire.adsPayload = "RS:R50"; ring.knobs[0].fire.retainADSOnLift = true
        let manual = ProfileControl(kind: .rightStick); var e = try ProfileInputEngine(profile: profile([manual], ring: ring))
        let (_, session) = try beginRing(&e); try e.endFloatingRing(contact: 1, sessionID: session, at: 0.1)
        XCTAssertEqual(e.state.rightStick, .init(x: 0.5)); try e.begin(contact: 2, control: manual.id, position: .init(y: -1), at: 0.2)
        XCTAssertEqual(e.state.rightStick, .init(y: -1)); try e.end(contact: 2, at: 0.3); try e.tick(at: 1); XCTAssertEqual(e.state.rightStick, .zero)
    }
    func testRingRepeatReservesOffGapAndReleaseShotCancelNeverAcquires() throws {
        var ring = FloatingRingConfig(); ring.startRole = .aim; ring.knobs[0].fire.mode = .repeat; ring.knobs[0].fire.firePayload = "RS:R50"
        let manual = ProfileControl(kind: .rightStick); var e = try ProfileInputEngine(profile: profile([manual], ring: ring))
        let (_, session) = try beginRing(&e); XCTAssertEqual(e.state.rightStick, .init(x: 0.5))
        try e.tick(at: 0.035); XCTAssertEqual(e.state.rightStick, .zero)
        try e.begin(contact: 2, control: manual.id, position: .init(y: 1), at: 0.04); XCTAssertFalse(e.isCapturedInputOwner(for: 2))
        try e.tick(at: 0.07); XCTAssertEqual(e.state.rightStick, .init(x: 0.5)); try e.cancelFloatingRing(contact: 1, sessionID: session, at: 0.08)
        try e.tick(at: 1); XCTAssertEqual(e.state.rightStick, .zero)
        ring.knobs[0].fire.mode = .releaseShot; e = try ProfileInputEngine(profile: profile([], ring: ring))
        let (_, shot) = try beginRing(&e); try e.cancelFloatingRing(contact: 1, sessionID: shot, at: 1)
        XCTAssertEqual(e.state.rightStick, .zero); XCTAssertNil(e.nextDeadline)
    }
    func testRingFullExitPathCancelsOverdueMacroBeforeItCanAcquire() throws {
        var ring = FloatingRingConfig(); ring.boost2.enabled = true; ring.boost2.payload = "RS:U"; ring.boost2.activationDelayMilliseconds = 50
        var e = try ProfileInputEngine(profile: profile([], ring: ring)); let (id, session) = try beginRing(&e)
        let path = [ringSample(e, id, 180, elapsed: 0.1), ringSample(e, id, 0, elapsed: 0.2)]
        try e.moveFloatingRing(contact: 1, sessionID: session, samples: path, at: 1)
        XCTAssertEqual(e.state.rightStick, .zero); XCTAssertNil(e.nextDeadline)
    }
    func testBackupContainsConfigurationAndApplyClearsAllSurfaceMacros() throws {
        let a = aim("LS:R50"), c = stick(directional: true)
        let p = try profile([a, c]), library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p])
        let data = try ControllerProfileLibraryCodec.encode(library)
        let decoded = try ControllerProfileLibraryCodec.decode(data)
        XCTAssertEqual(decoded, library)
        var e = try ProfileInputEngine(profile: p); try e.beginButton(contact: 1, control: a.id, sample: point(), at: 0)
        XCTAssertEqual(e.state.leftStick, .init(x: 0.5)); try e.apply(profile: decoded.profiles[0]); try e.tick(at: 1)
        XCTAssertEqual(e.state, .neutral); XCTAssertNil(e.nextDeadline)
    }
    func testScopedReleaseDoesNotClearUnrelatedMacroOrButton() throws {
        let a = aim("LS:R50"), b = aim("RS:U25,X360B")
        var e = try ProfileInputEngine(profile: profile([a, b])); try e.beginButton(contact: 1, control: a.id, sample: point(), at: 0)
        try e.beginButton(contact: 2, control: b.id, sample: point(), at: 0.1); e.releaseControls([a.id])
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.rightStick, .init(y: 0.25)); XCTAssertEqual(e.state.buttons, [.b])
        e.releaseAll(); try e.tick(at: 1); XCTAssertEqual(e.state, .neutral)
    }
    func testLiveZeroOverrideKeepsOwnershipUntilItReturnsToRetainedBase() throws {
        let control = UUID()
        let base = SustainedMacroLease(id: UUID(), control: control, program: try .parse("LS:R50"), priority: 0, started: 0, retained: true)
        let zero = SustainedMacroLease(id: UUID(), control: control, program: try .parse("LS:U0"), priority: 1, started: 1)
        var coordinator = SustainedMacroCoordinator(), ledger = FixedStickClaimLedger()
        _ = coordinator.reconcile([base], ledger: &ledger, occupied: [])
        XCTAssertEqual(ledger.retainedChannels, [.leftStick])
        _ = coordinator.reconcile([base, zero], ledger: &ledger, occupied: [])
        XCTAssertEqual(ledger.claims[.left]?.position, .zero); XCTAssertEqual(ledger.occupiedChannels, [.leftStick])
        XCTAssertEqual(ledger.request(owner: UUID(), macro: try .init(channel: .left, direction: .down), retained: false, occupied: []), .rejected)
        _ = coordinator.reconcile([base], ledger: &ledger, occupied: [])
        XCTAssertEqual(ledger.claims[.left]?.position, .init(x: 0.5)); XCTAssertEqual(ledger.retainedChannels, [.leftStick])
    }
}

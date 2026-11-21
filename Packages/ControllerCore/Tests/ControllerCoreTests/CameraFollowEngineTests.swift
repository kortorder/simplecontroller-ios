import XCTest
@testable import ControllerCore

final class CameraFollowEngineTests: XCTestCase {
    private func profile(_ controls: [ProfileControl], ring: FloatingRingConfig? = nil) throws -> ControllerProfile {
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        var p = try ControllerProfile(controls: controls, portrait: positions, landscape: positions)
        if let ring { p.pages[0].floatingRingZones = [.init(portraitGeometry: .init(canvasWidth: 700, canvasHeight: 900, zone: .init(x: 0, y: 0, width: 700, height: 900)), config: ring)] }
        try p.validate(); return p
    }
    private func ready(_ controls: [ProfileControl], left id: UUID) throws -> ProfileInputEngine {
        var e = try ProfileInputEngine(profile: profile(controls), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0)
        try e.begin(contact: 1, control: id, position: .init(x: 1), at: 0)
        try e.tick(at: 0.2); try e.tick(at: 0.38)
        return e
    }
    private func point(_ x: Double = 50, _ y: Double = 50) -> ButtonPointerSample { .init(x: x, y: y, width: 100, height: 100) }
    func testPermissionDefaultsOffAndCommandsCannotArmForLaterMode() throws {
        let left = ProfileControl(kind: .leftStick), command = ProfileControl(payload: "CAMERA_FOLLOW")
        var e = try ProfileInputEngine(profile: profile([left, command]))
        try e.begin(contact: 1, control: left.id, position: .init(x: 1), at: 0)
        try e.activate(command.id, at: 0); try e.setCameraFollowEnabled(true, at: 0)
        try e.tick(at: 1)
        XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled); XCTAssertEqual(e.practiceState.gamepad, e.state)
        try e.setCameraFollowPracticeAllowed(true, at: 1); try e.tick(at: 2)
        XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
    }
    func testEffectivePracticeProjectionNeverChangesPhysicalStateOrBridgeEncoding() throws {
        let left = ProfileControl(kind: .leftStick), button = ProfileControl(actions: [.b])
        var e = try ready([left, button], left: left.id)
        try e.begin(contact: 2, control: button.id, at: 0.38)
        XCTAssertEqual(e.state.leftStick, .init(x: 1)); XCTAssertEqual(e.state.rightStick, .zero)
        XCTAssertEqual(e.practiceState.gamepad.rightStick.x, 0.45, accuracy: 1e-12)
        XCTAssertEqual(e.state.buttons, [.b]); XCTAssertEqual(e.practiceState.gamepad.buttons, [.b])
        XCTAssertEqual(e.cameraFollowSnapshot.source, .cameraFollow)
        let packet = BridgePacket(kind: .state, session: UUID().uuidString, sequence: 1, state: e.state)
        XCTAssertEqual(try BridgeCodec.decode(BridgeCodec.encode(packet)).state?.rightStick, .zero)
        XCTAssertNil(e.nextDeadline)
    }
    func testDuplicateFingerAndGlobalModesDoNotRepeatCameraCommand() throws {
        let c = ProfileControl(payload: "CAMERA_FOLLOW", cameraFollowStrengthPercent: 75)
        var p = try profile([c]); p.globalHoldEnabled = true; p.turboEnabled = true
        var e = try ProfileInputEngine(profile: p, allowCameraFollowPractice: true)
        try e.begin(contact: 1, control: c.id, at: 0)
        try e.begin(contact: 2, control: c.id, at: 0.01); try e.tick(at: 1)
        XCTAssertTrue(e.cameraFollowSnapshot.requestedEnabled); XCTAssertEqual(e.cameraFollowSnapshot.strengthPercent, 75)
        XCTAssertTrue(e.latchedControls.isEmpty); XCTAssertNil(e.nextDeadline)
        try e.end(contact: 1, at: 1); try e.end(contact: 2, at: 1)
        try e.activate(c.id, at: 1.1); XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled)
    }
    func testRepeatedPracticePermissionDoesNotResetFollowButModeChangeDisarms() throws {
        let left = ProfileControl(kind: .leftStick)
        var e = try ready([left], left: left.id)
        try e.setCameraFollowPracticeAllowed(true, at: 0.39)
        XCTAssertTrue(e.cameraFollowSnapshot.requestedEnabled); XCTAssertGreaterThan(e.practiceState.gamepad.rightStick.x, 0)
        try e.setCameraFollowPracticeAllowed(false, at: 0.4)
        XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled); XCTAssertEqual(e.practiceState.gamepad, e.state)
        XCTAssertEqual(e.state.leftStick.x, 1)
        try e.setCameraFollowPracticeAllowed(true, at: 0.5); try e.tick(at: 1)
        XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
    }
    func testWinningRetainedExcludedMovementNeverArmsAndFreshWinnerRestartsDelay() throws {
        let excluded = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false), excludeFromCameraFollow: true)
        let allowed = ProfileControl(kind: .leftStick)
        var e = try ready([excluded, allowed], left: excluded.id)
        try e.end(contact: 1, at: 0.4); try e.tick(at: 1)
        XCTAssertEqual(e.state.leftStick.x, 1); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
        try e.begin(contact: 2, control: allowed.id, position: .init(x: 1), at: 1)
        try e.tick(at: 1.19); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
        try e.tick(at: 1.21); try e.tick(at: 1.4)
        XCTAssertGreaterThan(e.practiceState.gamepad.rightStick.x, 0)
    }
    func testExcludedFixedMacroUsesActualOwnerAndRetainsOrdinaryGamepadOutput() throws {
        let macro = ProfileControl(payload: "LS:R75", excludeFromCameraFollow: true)
        var e = try ProfileInputEngine(profile: profile([macro]), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0); try e.begin(contact: 1, control: macro.id, at: 0)
        try e.tick(at: 0.2); try e.tick(at: 1)
        XCTAssertEqual(e.state.leftStick.x, 0.75); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
    }
    func testNeutralManualRightContactAndRetainedSmallPositionBothOwnTheirChannel() throws {
        let left = ProfileControl(kind: .leftStick), right = ProfileControl(kind: .rightStick, stickBehavior: .init(autoCenter: false))
        var e = try ready([left, right], left: left.id)
        try e.begin(contact: 2, control: right.id, at: 0.4)
        XCTAssertTrue(e.cameraFollowSnapshot.manualRightContactActive); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
        try e.move(contact: 2, position: .init(x: 0.02), at: 0.5); try e.end(contact: 2, at: 0.6); try e.tick(at: 2)
        XCTAssertEqual(e.practiceState.gamepad.rightStick, .init(x: 0.02)); XCTAssertEqual(e.state.rightStick, .init(x: 0.02))
        e.recenterSticks(); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
        XCTAssertTrue(e.cameraFollowSnapshot.requestedEnabled)
    }
    func testSustainedMacroOffGapCannotBeFilledByCameraFollow() throws {
        let left = ProfileControl(kind: .leftStick)
        let macro = ProfileControl(payload: "RS:U50", buttonAim: .init(enabled: true))
        var p = try profile([left, macro]); p.turboEnabled = true; p.turboIntervalMilliseconds = 100
        var e = try ProfileInputEngine(profile: p, allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0); try e.begin(contact: 1, control: left.id, position: .init(x: 1), at: 0)
        try e.beginButton(contact: 2, control: macro.id, sample: point(), at: 0)
        try e.tick(at: 0.295)
        XCTAssertEqual(e.state.rightStick, .zero); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
        XCTAssertTrue(e.cameraFollowSnapshot.manualRightContactActive)
        try e.tick(at: 0.3); XCTAssertEqual(e.practiceState.gamepad.rightStick, .init(y: 0.5))
    }
    func testMouseClickSuppressionSurvivesLiftAndDisableEnableButReleaseAllClearsIt() throws {
        let left = ProfileControl(kind: .leftStick)
        let click = ProfileControl(payload: "MOUSE_LEFT_DOWN,MOUSE_LEFT_UP", mouseSuppressCameraFollow: true)
        var e = try ready([left, click], left: left.id)
        try e.begin(contact: 2, control: click.id, at: 0.4); try e.end(contact: 2, at: 0.41)
        XCTAssertTrue(e.practiceState.heldMouseButtons.isEmpty); XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
        XCTAssertTrue(e.cameraFollowSnapshot.requestedEnabled); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
        try e.setCameraFollowEnabled(false, at: 0.5); try e.setCameraFollowEnabled(true, at: 0.6)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed); XCTAssertFalse(e.cameraFollowSnapshot.effectiveEnabled)
        e.releaseAll(); XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed); XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled)
    }
    func testScopedMouseCleanupPreservesOtherSuppressionAndIndependentButton() throws {
        let a = ProfileControl(payload: "MOUSE_LEFT_DOWN", mouseSuppressCameraFollow: true)
        let b = ProfileControl(payload: "MOUSE_RIGHT_DOWN", mouseSuppressCameraFollow: true)
        let c = ProfileControl(actions: [.b])
        var e = try ProfileInputEngine(profile: profile([a,b,c]), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0)
        try e.begin(contact: 1, control: a.id, at: 0); try e.begin(contact: 2, control: b.id, at: 0); try e.begin(contact: 3, control: c.id, at: 0)
        e.releaseControls([a.id]); XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
        XCTAssertEqual(e.practiceState.heldMouseButtons, [.right]); XCTAssertEqual(e.state.buttons, [.b])
        e.releaseControls([b.id]); XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed); XCTAssertEqual(e.state.buttons, [.b])
    }
    func testPotentialMouseSettingsAndNonOptedMouseDoNotSuppress() throws {
        let left = ProfileControl(kind: .leftStick)
        var inactive = ProfileControl(payload: "X360A", mouseSuppressCameraFollow: true)
        inactive.buttonDirectional = .init(enabled: true)
        inactive.buttonDirectional.directions[.right] = .init(firstDistance: 48, secondDistance: 96, firstPayload: "MOUSE_LEFT_DOWN")
        let plain = ProfileControl(payload: "MOUSE_RIGHT_DOWN")
        var e = try ready([left, inactive, plain], left: left.id)
        try e.beginButton(contact: 2, control: inactive.id, sample: point(), at: 0.4)
        try e.begin(contact: 3, control: plain.id, at: 0.4)
        XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed); XCTAssertGreaterThan(e.practiceState.gamepad.rightStick.x, 0)
        try e.moveButtonBatch(contact: 2, samples: [point(100)], at: 0.5)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
    }
    func testTouchpadFirstActualMovementSuppressesAndNormalLiftStaysSuppressed() throws {
        let left = ProfileControl(kind: .leftStick), pad = ProfileControl(kind: .touchpad, mouseSuppressCameraFollow: true)
        var e = try ready([left, pad], left: left.id)
        try e.beginTouchpad(contact: 2, control: pad.id, at: 0.4); XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
        try e.moveTouchpadBatch(contact: 2, deltas: [.init(dx: 2, dy: 0)], at: 0.41)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
        try e.endTouchpad(contact: 2, at: 0.42); try e.tick(at: 1); XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
        e.releaseControls([pad.id]); XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
    }
    func testZeroSensitivityPadDoesNotSuppressWithoutClickOutput() throws {
        let pad = ProfileControl(kind: .touchpad, touchpadBehavior: .init(sensitivity: 0), mouseSuppressCameraFollow: true)
        var e = try ProfileInputEngine(profile: profile([pad]), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0); try e.beginTouchpad(contact: 1, control: pad.id, at: 0)
        try e.endTouchpad(contact: 1, finalDeltas: [.init(dx: 100, dy: 100)], at: 0.1)
        XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
    }
    func testRecenterImmediatelyRemovesGeneratedMotionButKeepsIndependentButtons() throws {
        let left = ProfileControl(kind: .leftStick), button = ProfileControl(actions: [.b])
        var e = try ready([left,button], left: left.id); try e.begin(contact: 2, control: button.id, at: 0.4)
        e.recenterSticks(); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
        XCTAssertEqual(e.state.buttons, [.b]); XCTAssertTrue(e.cameraFollowSnapshot.requestedEnabled)
        try e.tick(at: 5); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
    }
    func testInvalidInputAndTimeCannotAlterCameraStateAndCancellationIsTerminal() throws {
        let left = ProfileControl(kind: .leftStick)
        var e = try ready([left], left: left.id); let snapshot = e.cameraFollowSnapshot
        XCTAssertThrowsError(try e.move(contact: 1, position: .init(x: .nan), at: 1))
        XCTAssertThrowsError(try e.setCameraFollowEnabled(false, strengthPercent: .infinity, at: 1))
        XCTAssertThrowsError(try e.setCameraFollowPracticeAllowed(false, at: 0))
        XCTAssertEqual(e.cameraFollowSnapshot, snapshot)
        try e.handle(.cancelAll, at: 1); try e.tick(at: 10)
        XCTAssertEqual(e.state, .neutral); XCTAssertEqual(e.practiceState.gamepad, .neutral)
        XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled); XCTAssertNil(e.nextDeadline)
    }
    func testPageAndProfileChangesDisarmWithoutSavingLiveCameraState() throws {
        let left = ProfileControl(kind: .leftStick)
        var p = try profile([left]); let page = try p.addPage(name: "Other")
        var e = try ProfileInputEngine(profile: p, allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0); try e.begin(contact: 1, control: left.id, position: .init(x: 1), at: 0)
        try e.tick(at: 0.2); try e.tick(at: 0.4); _ = try e.selectPage(page, at: 0.5)
        XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled); XCTAssertTrue(e.state.isNeutral)
        try e.setCameraFollowEnabled(true, at: 0.6); try e.apply(profile: p)
        XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled); XCTAssertEqual(e.profile, p)
    }
    func testCameraActionCannotActivateFromSwipeButDirectActionStillWorks() throws {
        let source = ProfileControl(actions: [.a]), c = ProfileControl(payload: "CAMERA_FOLLOW")
        var p = try profile([source,c]); p.swipeMode = .controls
        var e = try ProfileInputEngine(profile: p, allowCameraFollowPractice: true)
        try e.begin(contact: 1, control: source.id, at: 0)
        XCTAssertFalse(try e.handoff(contact: 1, to: c.id, at: 0.1)); XCTAssertFalse(e.cameraFollowSnapshot.requestedEnabled)
        try e.begin(contact: 2, control: c.id, at: 0.2); XCTAssertTrue(e.cameraFollowSnapshot.requestedEnabled)
        XCTAssertEqual(e.state.buttons, [.a])
    }
    func testEndSuppressionKeepsMouseHeldAndBlocksReacquisitionUntilNewDirectDown() throws {
        let a = ProfileControl(payload: "MOUSE_LEFT_DOWN", mouseSuppressCameraFollow: true)
        let other = ProfileControl(actions: [.b])
        var e = try ProfileInputEngine(profile: profile([a,other]), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0)
        try e.begin(contact: 1, control: a.id, at: 0); try e.begin(contact: 2, control: other.id, at: 0)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
        e.endCameraSuppression(for: a.id)
        XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed); XCTAssertEqual(e.practiceState.heldMouseButtons, [.left])
        try e.tick(at: 1); XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed); XCTAssertEqual(e.state.buttons, [.b])
        try e.end(contact: 1, at: 1.1); try e.begin(contact: 3, control: a.id, at: 1.2)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
    }
    func testCleanPadTapSuppressesEvenWithoutPersistentMouseClaimOrMovement() throws {
        let pad = ProfileControl(kind: .touchpad, touchpadBehavior: .init(clickMode: .doubleTapLock), mouseSuppressCameraFollow: true)
        var e = try ProfileInputEngine(profile: profile([pad]), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0); try e.beginTouchpad(contact: 1, control: pad.id, at: 0)
        XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
        try e.endTouchpad(contact: 1, at: 0.1)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed); XCTAssertTrue(e.practiceState.heldMouseButtons.isEmpty)
    }

    func testButtonAimAndTouchAimMouseMovementAreAttributedToTheirActualOwner() throws {
        var aim = ProfileControl(buttonAim: .init(enabled: true), mouseSuppressCameraFollow: true)
        aim.buttonAim.tuning.output = .mouse
        var sensor = ProfileControl(kind: .touchAim, mouseSuppressCameraFollow: true)
        sensor.touchAim.aim.output = .mouse; sensor.touchAim.requiresLocalSetup = true
        var e = try ProfileInputEngine(profile: profile([aim,sensor]), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0)
        try e.beginButton(contact: 1, control: aim.id, sample: point(), at: 0)
        XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
        try e.moveButtonBatch(contact: 1, samples: [point(70)], at: 0.1)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
        e.releaseControls([aim.id]); XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
        try e.beginTouchAim(contact: 2, control: sensor.id, sample: .init(pointer: point(), metrics: .init(), elapsed: 0), at: 0.2)
        XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
        try e.moveTouchAimBatch(contact: 2, samples: [.init(pointer: point(70), metrics: .init(), elapsed: 0.1)], at: 0.3)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed); XCTAssertTrue(e.state.buttons.isEmpty)
        try e.end(contact: 2, at: 0.4); XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
    }
    func testRingMovementExclusionIsPreservedWhileRingPayloadMacroCanParticipate() throws {
        var config = FloatingRingConfig(); config.movement.excludeFromCameraFollow = true
        var e = try ProfileInputEngine(profile: profile([], ring: config), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0)
        let id = e.profile.pages[0].floatingRingZones[0].id, session = UUID()
        XCTAssertTrue(try e.beginFloatingRing(contact: 1, zoneID: id, sessionID: session, point: .init(x: 300,y: 300), usable: .init(x: 0,y: 0,width: 700,height: 900), at: 0))
        let ring = try XCTUnwrap(e.floatingRingStates[id])
        try e.moveFloatingRing(contact: 1, sessionID: session, samples: [.init(point: .init(x: ring.placement.origin.x + ring.geometry.center.x + 100, y: ring.placement.origin.y + ring.geometry.center.y), elapsed: 0.1)], at: 0.1)
        try e.tick(at: 0.4); try e.tick(at: 1)
        XCTAssertGreaterThan(e.state.leftStick.x, 0); XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero)
        config.startRole = .aim; config.knobs[0].fire.adsPayload = "LS:R50"
        e = try ProfileInputEngine(profile: profile([], ring: config), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0)
        let macroID = e.profile.pages[0].floatingRingZones[0].id
        XCTAssertTrue(try e.beginFloatingRing(contact: 1, zoneID: macroID, sessionID: UUID(), point: .init(x: 300,y: 300), usable: .init(x: 0,y: 0,width: 700,height: 900), at: 0))
        try e.tick(at: 0.2); try e.tick(at: 0.5)
        XCTAssertEqual(e.state.leftStick.x, 0.5); XCTAssertGreaterThan(e.practiceState.gamepad.rightStick.x, 0)
    }
    func testRingMouseSuppressionSurvivesLiftAndExplicitEndOnlyClearsThatOwner() throws {
        let left = ProfileControl(kind: .leftStick), button = ProfileControl(actions: [.b])
        var config = FloatingRingConfig(); config.startRole = .aim; config.aim.tuning.output = .mouse; config.aim.suppressCameraFollow = true
        var e = try ProfileInputEngine(profile: profile([left,button], ring: config), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0); try e.begin(contact: 1, control: left.id, position: .init(x: 1), at: 0)
        try e.begin(contact: 3, control: button.id, at: 0)
        let id = e.profile.pages[0].floatingRingZones[0].id, session = UUID()
        XCTAssertTrue(try e.beginFloatingRing(contact: 2, zoneID: id, sessionID: session, point: .init(x: 300,y: 300), usable: .init(x: 0,y: 0,width: 700,height: 900), at: 0.1))
        try e.endFloatingRing(contact: 2, sessionID: session, at: 0.2)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
        try e.floatingRingAction(zoneID: id, sessionID: session, action: .endSuppression, at: 0.3)
        XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed); XCTAssertEqual(e.state.buttons, [.b])
        try e.tick(at: 0.51); try e.tick(at: 0.7); XCTAssertGreaterThan(e.practiceState.gamepad.rightStick.x, 0)
    }

    func testEndingMacroDoesNotInventManualReleaseOverrideAndSwipeDoesNotRearmSuppression() throws {
        let left = ProfileControl(kind: .leftStick), macro = ProfileControl(payload: "RS:R50")
        let mouse = ProfileControl(payload: "MOUSE_LEFT_DOWN", mouseSuppressCameraFollow: true)
        let start = ProfileControl(actions: [.a])
        var p = try profile([left,macro,mouse,start]); p.swipeMode = .controls
        var e = try ProfileInputEngine(profile: p, allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0); try e.begin(contact: 1, control: left.id, position: .init(x: 1), at: 0)
        try e.begin(contact: 2, control: macro.id, at: 0); try e.end(contact: 2, at: 0.1)
        try e.tick(at: 0.31); try e.tick(at: 0.5)
        XCTAssertGreaterThan(e.practiceState.gamepad.rightStick.x, 0)
        try e.begin(contact: 3, control: mouse.id, at: 0.6); e.endCameraSuppression(for: mouse.id)
        try e.end(contact: 3, at: 0.7); try e.begin(contact: 4, control: start.id, at: 0.7)
        XCTAssertTrue(try e.handoff(contact: 4, to: mouse.id, at: 0.8))
        XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
        XCTAssertEqual(e.practiceState.heldMouseButtons, [.left])
        try e.end(contact: 4, at: 0.9); try e.begin(contact: 5, control: mouse.id, at: 1)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
    }

}

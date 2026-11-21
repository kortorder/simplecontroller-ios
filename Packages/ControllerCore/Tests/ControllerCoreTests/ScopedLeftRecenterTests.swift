import XCTest
@testable import ControllerCore

final class ScopedLeftRecenterTests: XCTestCase {
    private func profile(_ controls: [ProfileControl], turbo: Bool = false) throws -> ControllerProfile {
        let places = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try .init(controls: controls, portrait: places, landscape: places, turboEnabled: turbo)
    }
    private func pickup() -> ProfileControl {
        var c = ProfileControl(payload: "X360LB(D50)(U150)", macroModeEnabled: true)
        c.centerLeftStickBeforePress = true
        return c
    }
    private func point(_ x: Double = 50, _ y: Double = 50) -> ButtonPointerSample {
        .init(x: x, y: y, width: 100, height: 100)
    }
    private func touch(_ radius: Double = 6, elapsed: Double = 0, x: Double = 50) -> TouchAimSample {
        .init(pointer: point(x), metrics: .init(majorRadius: radius), elapsed: elapsed)
    }
    private func sprint() -> ProfileControl {
        var c = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false, stickPlusEnabled: true),
                               stickPlusRepeatIntervalMilliseconds: 200)
        c.directionPayloads[.up]?.superBoostPayload = "X360A"
        return c
    }
    func testPickupStopsRetainedSprintBeforeOneDelayedLBAndKeepsRightStickAndTriggers() throws {
        let move = sprint(), right = ProfileControl(kind: .rightStick, stickBehavior: .init(autoCenter: false))
        let hold = ProfileControl(payload: "LT:0.5,RT:0.7,X360Y"), pick = pickup()
        var e = try ProfileInputEngine(profile: profile([move, right, hold, pick]))
        try e.begin(contact: 1, control: move.id, position: .init(y: 1), at: 0)
        try e.end(contact: 1, at: 0.01)
        try e.begin(contact: 2, control: right.id, position: .init(x: 0.6), at: 0.02)
        try e.end(contact: 2, at: 0.03)
        try e.begin(contact: 3, control: hold.id, at: 0.03)
        try e.begin(contact: 4, control: pick.id, at: 0.04)
        XCTAssertEqual(e.state.leftStick, .zero)
        XCTAssertFalse(e.state.buttons.contains(.a)); XCTAssertFalse(e.state.buttons.contains(.leftBumper))
        XCTAssertEqual(e.state.rightStick, .init(x: 0.6)); XCTAssertEqual(e.practiceState.leftTrigger, 0.5)
        XCTAssertEqual(e.practiceState.rightTrigger, 0.7); XCTAssertTrue(e.state.buttons.contains(.y))
        try e.end(contact: 4, at: 0.05)
        try e.tick(at: 0.089); XCTAssertFalse(e.state.buttons.contains(.leftBumper))
        try e.tick(at: 0.09); XCTAssertTrue(e.state.buttons.contains(.leftBumper))
        try e.tick(at: 0.24); XCTAssertFalse(e.state.buttons.contains(.leftBumper))
        try e.tick(at: 5); XCTAssertFalse(e.state.buttons.contains(.a)); XCTAssertEqual(e.state.leftStick, .zero)
        XCTAssertEqual(e.state.rightStick, .init(x: 0.6)); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        XCTAssertNil(e.nextDeadline)
        try e.begin(contact: 5, control: move.id, position: .init(y: 1), at: 6)
        XCTAssertEqual(e.state.leftStick.y, 1); XCTAssertTrue(e.state.buttons.contains(.a))
    }
    func testCapturedLeftStickCannotResumeAfterCenterButUnrelatedSharedAHoldSurvives() throws {
        let left = sprint(), hold = ProfileControl(actions: [.a]), pick = pickup()
        var e = try ProfileInputEngine(profile: profile([left, hold, pick]))
        try e.begin(contact: 1, control: left.id, position: .init(y: 1), at: 0)
        try e.begin(contact: 2, control: hold.id, at: 0)
        try e.activate(pick.id, at: 0.01)
        try e.move(contact: 1, position: .init(x: 1), at: 0.02)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertTrue(e.state.buttons.contains(.a))
        try e.end(contact: 1, at: 0.03); try e.tick(at: 0.06); try e.tick(at: 0.21); try e.tick(at: 0.5)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertTrue(e.state.buttons.contains(.a))
        try e.end(contact: 2, at: 0.6); XCTAssertTrue(e.state.isNeutral)
    }
    func testExistingFixedVectorsAndDelayedLeftMacroStopWithoutDroppingRightOrDigital() throws {
        for source in ["LS:UP80,RS:R60,X360Y,LT:0.4", "LS:UP80(D300),RS:R60,X360Y,LT:0.4"] {
            let c = ProfileControl(payload: source)
            var e = try ProfileInputEngine(profile: profile([c]))
            try e.begin(contact: 1, control: c.id, at: 0)
            e.recenterLeftStick()
            try e.tick(at: 0.4)
            XCTAssertEqual(e.state.leftStick, .zero, source); XCTAssertEqual(e.state.rightStick, .init(x: 0.6), source)
            XCTAssertTrue(e.state.buttons.contains(.y)); XCTAssertEqual(e.practiceState.leftTrigger, 0.4)
            try e.end(contact: 1, at: 0.5)
            try e.begin(contact: 2, control: c.id, at: 1); try e.tick(at: 1.4)
            XCTAssertEqual(e.state.leftStick.y, 0.8, "A deliberate new activation can move again")
        }
    }
    func testAutoTapLeftMacroDoesNotReappearOnLaterCycleButRightCycleContinues() throws {
        var c = ProfileControl(payload: "LS:UP80,RS:R60,X360Y")
        c.autoTapEnabled = true; c.autoTapIntervalMilliseconds = 200
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.begin(contact: 1, control: c.id, at: 0)
        e.recenterLeftStick()
        for time in [0.2, 0.4, 1.0] {
            try e.tick(at: time)
            XCTAssertEqual(e.state.leftStick, .zero)
            XCTAssertEqual(e.state.rightStick, .init(x: 0.6)); XCTAssertTrue(e.state.buttons.contains(.y))
        }
    }
    func testButtonAimStopsLeftAnalogAndDirectionalSprintWhileKeepingItsOwnTriggers() throws {
        var c = ProfileControl(payload: "LT:0.5,RT:0.7", buttonDirectional: .init(enabled: true),
                               buttonAim: .init(enabled: true, tuning: .init(output: .leftStick, autoCenter: false)))
        c.buttonDirectional.directions[.right] = .init(firstDistance: 48, secondDistance: 96, firstPayload: "X360A", secondPayload: "X360X")
        let right = ProfileControl(kind: .rightStick)
        var e = try ProfileInputEngine(profile: profile([c, right]))
        try e.beginButton(contact: 1, control: c.id, sample: point(), at: 0)
        try e.moveButtonBatch(contact: 1, samples: [point(100)], at: 0.01)
        try e.begin(contact: 2, control: right.id, position: .init(y: 0.6), at: 0.02)
        XCTAssertTrue(e.state.buttons.contains(.a)); XCTAssertNotEqual(e.state.leftStick, .zero)
        e.recenterLeftStick()
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertFalse(e.state.buttons.contains(.a))
        XCTAssertEqual(e.state.rightStick.y, 0.6); XCTAssertEqual(e.practiceState.leftTrigger, 0.5); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        try e.moveButtonBatch(contact: 1, samples: [point(150)], at: 0.1)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertFalse(e.state.buttons.contains(.x)); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
    }
    func testRightButtonAimKeepsMovementAndMixedRightMacroWhileLeftMacroStops() throws {
        let c = ProfileControl(payload: "LS:UP80,LT:0.5,RT:0.7", buttonAim: .init(enabled: true, tuning: .init(output: .rightStick)))
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginButton(contact: 1, control: c.id, sample: point(), at: 0)
        try e.moveButtonBatch(contact: 1, samples: [point(80)], at: 0.1)
        let right = e.state.rightStick
        e.recenterLeftStick(); XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.rightStick, right)
        try e.moveButtonBatch(contact: 1, samples: [point(90)], at: 0.2)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertNotEqual(e.state.rightStick, right)
        XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
    }
    func testTouchAimLeftStopsButOwnPressureAndSeparateRightTouchRemain() throws {
        var left = ProfileControl(kind: .touchAim), right = ProfileControl(kind: .touchAim)
        left.touchAim.aim.output = .leftStick; left.touchAim.threeStage.smoothing = 1
        left.touchAim.threeStage.high.payload = "LT:0.5,RT:0.7"
        right.touchAim.aim.output = .rightStick; right.touchAim.threeStage.smoothing = 1
        right.touchAim.threeStage.low.payload = ""; right.touchAim.threeStage.medium.payload = ""; right.touchAim.threeStage.high.payload = ""
        var e = try ProfileInputEngine(profile: profile([left, right]))
        try e.beginTouchAim(contact: 1, control: left.id, sample: touch(), at: 0)
        try e.beginTouchAim(contact: 2, control: right.id, sample: touch(), at: 0)
        try e.moveTouchAimBatch(contact: 1, samples: [touch(elapsed: 0.1, x: 80)], at: 0.1)
        try e.moveTouchAimBatch(contact: 2, samples: [touch(elapsed: 0.1, x: 70)], at: 0.1)
        let rs = e.state.rightStick
        e.recenterLeftStick()
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.rightStick, rs)
        XCTAssertEqual(e.practiceState.leftTrigger, 0.5); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        try e.moveTouchAimBatch(contact: 1, samples: [touch(elapsed: 0.2, x: 90)], at: 0.2)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.rightStick, rs)
    }
    func testTouchAimStageChangeAndLiftCannotReviveSuppressedLeftReleaseTail() throws {
        var c = ProfileControl(kind: .touchAim)
        c.touchAim.aim.output = .mouse; c.touchAim.threeStage.smoothing = 1
        c.touchAim.threeStage.low.payload = ""; c.touchAim.threeStage.medium.payload = ""
        c.touchAim.threeStage.high.payload = "LS:UP80(HRD500),RS:R60(HRD500),RT:0.7(HRD500)"
        var e = try ProfileInputEngine(profile: profile([c]))
        try e.beginTouchAim(contact: 1, control: c.id, sample: touch(1), at: 0)
        e.recenterLeftStick()
        try e.moveTouchAimBatch(contact: 1, samples: [touch(6, elapsed: 0.1)], at: 0.1)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.rightStick.x, 0.6)
        try e.end(contact: 1, at: 0.2)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.rightStick.x, 0.6)
        XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        try e.tick(at: 0.5); XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        try e.tick(at: 0.7); XCTAssertTrue(e.state.isNeutral)
        try e.beginTouchAim(contact: 2, control: c.id, sample: touch(6), at: 1)
        XCTAssertEqual(e.state.leftStick.y, 0.8)
    }
    func testRingRetainedMovementAndSprintLatchStopWhileAimAndFireStay() throws {
        var c = FloatingRingConfig(); c.movement.autoCenter = false; c.aim.participateInBoosts = true
        c.aim.tuning.output = .rightStick
        c.knobs[0].fire.mode = .hold; c.knobs[0].fire.adsPayload = "LT:0.5"; c.knobs[0].fire.firePayload = "RT:0.7"
        var banks = c.seededBoostBanks(); banks.enabled = true
        banks.movement.boost1.enabled = true; banks.movement.boost1.payload = "X360A"
        banks.movement.boost1.retainOnLift = true; banks.movement.boost1.latchOnExit = true
        banks.movement.geometry = .init(enabled: true, boost1Distance: 90, boost1Thickness: 8, boost2Thickness: 7, directStartDistance: 94)
        c.boostBanks = banks
        let origin = FloatingPoint(x: 300, y: 300), env = FloatingRingEnvironment()
        var r = try FloatingRingRuntime(config: c, sessionID: UUID(), touch: origin, usable: .init(x: 0, y: 0, width: 700, height: 900))
        func sample(_ x: Double, _ elapsed: Double) -> FloatingRingSample {
            .init(point: .init(x: r.placement.origin.x + r.geometry.center.x + x, y: r.placement.origin.y + r.geometry.center.y), elapsed: elapsed)
        }
        XCTAssertTrue(r.begin(contact: 1, point: origin, initial: true, time: 0, environment: env))
        _ = try r.samples(contact: 1, samples: [sample(91, 0.005)], ending: false, now: 0.005, environment: env)
        _ = try r.samples(contact: 1, samples: [sample(91, 0.01)], ending: true, now: 0.01, environment: env)
        XCTAssertTrue(r.claims.actions.contains(.a)); XCTAssertNotNil(r.movementAnalog)
        XCTAssertTrue(r.begin(contact: 2, point: sample(0, 0).point, initial: false, time: 0.02, environment: env))
        _ = try r.samples(contact: 2, samples: [sample(20, 0.01)], ending: false, now: 0.03, environment: env)
        let rs = r.aimAnalog?.position
        XCTAssertNotNil(rs)
        let pressure = r.claims.pressure
        r.recenter(channel: .left)
        XCTAssertNil(r.movementAnalog); XCTAssertFalse(r.claims.actions.contains(.a)); XCTAssertEqual(r.aimAnalog?.position, rs)
        XCTAssertEqual(r.claims.pressure, pressure)
        r.advance(to: 2, environment: env); XCTAssertFalse(r.claims.actions.contains(.a))
    }
    func testSharedRingBoostRemembersMovementOrAimOwnerAfterChangingRole() throws {
        for startedAsMovement in [true, false] {
            var c = FloatingRingConfig(); c.movement.autoCenter = false
            c.adjacentMovementBoosts = true; c.compactAimBoosts = true; c.aim.participateInBoosts = true
            c.aim.tuning.output = .rightStick
            c.boost1.enabled = true; c.boost1.payload = "X360A"
            c.boost1.retainOnLift = true; c.boost1.latchOnExit = true
            c.startRole = startedAsMovement ? .movement : .aim
            let origin = FloatingPoint(x: 300, y: 300), env = FloatingRingEnvironment()
            var r = try FloatingRingRuntime(config: c, sessionID: UUID(), touch: origin,
                                            usable: .init(x: 0, y: 0, width: 700, height: 900))
            func sample(_ x: Double, _ elapsed: Double) -> FloatingRingSample {
                .init(point: .init(x: r.placement.origin.x + r.geometry.center.x + x,
                                   y: r.placement.origin.y + r.geometry.center.y), elapsed: elapsed)
            }
            XCTAssertTrue(r.begin(contact: 1, point: origin, initial: true, time: 0, environment: env))
            let distance = startedAsMovement ? 91.0 : 51.0
            _ = try r.samples(contact: 1, samples: [sample(distance, 0.01)], ending: false, now: 0.01, environment: env)
            _ = try r.samples(contact: 1, samples: [sample(distance, 0.02)], ending: true, now: 0.02, environment: env)
            XCTAssertTrue(r.claims.actions.contains(.a))
            XCTAssertTrue(r.begin(contact: 2, point: sample(0, 0).point, initial: false, time: 0.03, environment: env))
            _ = try r.samples(contact: 2, samples: [sample(20, 0.01)], ending: false, now: 0.04, environment: env)
            let right = r.aimAnalog?.position; XCTAssertNotNil(right)
            r.recenter(channel: .left)
            XCTAssertNil(r.movementAnalog); XCTAssertEqual(r.aimAnalog?.position, right)
            XCTAssertEqual(r.claims.actions.contains(.a), !startedAsMovement)
        }
    }
    func testAcceptedSwipePickupCentersMovementInBothSwipeModes() throws {
        for mode in [ProfileSwipeMode.controls, .buttons] {
            let left = sprint(), start = ProfileControl(actions: [.y]), pick = pickup()
            var p = try profile([left, start, pick]); p.swipeMode = mode
            var e = try ProfileInputEngine(profile: p)
            try e.begin(contact: 1, control: left.id, position: .init(y: 1), at: 0)
            try e.end(contact: 1, at: 0.01)
            try e.begin(contact: 2, control: start.id, at: 0.02)
            try e.transfer(contact: 2, to: pick.id, at: 0.03)
            XCTAssertEqual(e.state.leftStick, .zero, mode.rawValue)
            XCTAssertFalse(e.state.buttons.contains(.a)); XCTAssertFalse(e.state.buttons.contains(.leftBumper))
            try e.tick(at: 0.08); XCTAssertTrue(e.state.buttons.contains(.leftBumper))
            try e.end(contact: 2, at: 0.09); try e.tick(at: 0.23)
            XCTAssertTrue(e.state.isNeutral)
        }
    }
    func testNewPickupCentersAfterPriorMacroExpiresWithoutIntermediateTick() throws {
        let left = sprint(), pick = pickup()
        var e = try ProfileInputEngine(profile: profile([left, pick]))
        try e.begin(contact: 1, control: pick.id, at: 0)
        try e.end(contact: 1, at: 0.01)
        try e.tick(at: 0.05)
        try e.begin(contact: 2, control: left.id, position: .init(y: 1), at: 0.1)
        try e.end(contact: 2, at: 0.11)
        XCTAssertEqual(e.state.leftStick.y, 1)
        try e.begin(contact: 3, control: pick.id, at: 1)
        XCTAssertEqual(e.state.leftStick, .zero)
        XCTAssertFalse(e.state.buttons.contains(.leftBumper))
        try e.tick(at: 1.05); XCTAssertTrue(e.state.buttons.contains(.leftBumper))
    }
    func testCameraAssistanceStopsImmediatelyWithoutDisablingPreferenceOrManualRight() throws {
        let left = ProfileControl(kind: .leftStick), right = ProfileControl(kind: .rightStick)
        var e = try ProfileInputEngine(profile: profile([left, right]), allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0)
        try e.begin(contact: 1, control: left.id, position: .init(x: 1), at: 0)
        try e.tick(at: 0.2); try e.tick(at: 0.38)
        XCTAssertGreaterThan(e.practiceState.gamepad.rightStick.x, 0)
        e.recenterLeftStick()
        XCTAssertEqual(e.practiceState.gamepad.rightStick, .zero); XCTAssertTrue(e.cameraFollowSnapshot.requestedEnabled)
        try e.begin(contact: 2, control: right.id, position: .init(y: 0.6), at: 0.4)
        e.recenterLeftStick(); XCTAssertEqual(e.practiceState.gamepad.rightStick.y, 0.6)
    }
}

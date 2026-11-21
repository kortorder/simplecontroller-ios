import XCTest
@testable import ControllerCore

final class FloatingRingSettingsTests: XCTestCase {
    func testAuditedDefaultsAndDetachedRoundTrip() throws {
        let value = FloatingRingConfig()
        try value.validate()
        XCTAssertEqual(value.movement.output, .leftStick)
        XCTAssertEqual(value.aim.tuning.mouseResponse, .linearRelative)
        XCTAssertEqual(value.aim.tuning.fullDisplacement, 220)
        XCTAssertEqual(value.boost1.distance, 120); XCTAssertEqual(value.boost2.distance, 160)
        XCTAssertFalse(value.boost1.enabled); XCTAssertFalse(value.boost2.enabled)
        let data = try JSONEncoder().encode(value)
        var copy = try JSONDecoder().decode(FloatingRingConfig.self, from: data)
        XCTAssertEqual(copy, value); copy.knobs[0].fire.mode = .releaseShot
        XCTAssertEqual(value.knobs[0].fire.mode, .none)
    }
    func testSeparatedActionsAndGeometrySurvivePresetAndProfileRoundTrips() throws {
        var c = FloatingRingConfig(); c.directBoostStartsAim = true; c.compactAimBoosts = true
        c.knobs[0].fire.returnFire.startOnBoostEntry = true
        var banks = c.seededBoostBanks(); banks.enabled = true
        banks.aim.boost2.skipDelayOnDirectTouch = true; banks.aim.boost2.payload = "X360B"
        banks.movement.boost2.payload = "X360Y"
        banks.aim.geometry = .init(enabled:true,boost1Distance:49,boost1Thickness:8,boost2Thickness:14,directStartDistance:92)
        c.boostBanks = banks
        let copy = try JSONDecoder().decode(FloatingRingConfig.self,from:JSONEncoder().encode(c))
        XCTAssertEqual(copy,c); XCTAssertEqual(copy.requiredAndroidRingFormat,13)
        let preset = try FloatingBoostPreset.capture(c,includeAimActions:true,bank:.aim)
        XCTAssertEqual(preset.boost2.payload,"X360B"); XCTAssertTrue(preset.boost2.skipDelayOnDirectTouch)
        var target = copy
        try preset.applyBoostSettings(to:&target,bank:.movement)
        XCTAssertEqual(target.boostBanks?.aim,banks.aim)
        XCTAssertEqual(target.boostBanks?.movement.geometry,banks.movement.geometry)
        XCTAssertEqual(target.boostBanks?.movement.boost2.payload,"X360B")
        XCTAssertEqual(target.boost2,c.boost2)
    }

    func testUnknownOrMissingNestedFieldsRejected() throws {
        let encoded = try JSONEncoder().encode(FloatingRingConfig())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var aim = try XCTUnwrap(object["aim"] as? [String: Any]); aim["futureFeature"] = true; object["aim"] = aim
        XCTAssertThrowsError(try JSONDecoder().decode(FloatingRingConfig.self, from: JSONSerialization.data(withJSONObject: object)))
        aim.removeValue(forKey: "futureFeature"); aim.removeValue(forKey: "continueOutside"); object["aim"] = aim
        XCTAssertThrowsError(try JSONDecoder().decode(FloatingRingConfig.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testDuplicateQualifyingStagesRejected() throws {
        let json = #"{"enabled":false,"sensitivity":0.4,"qualifyingStages":["one","one"],"persistWhileAdsLatched":true}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RingFineAimSettings.self, from: Data(json.utf8)))
    }
    func testSustainedPayloadsAndDirectionFallback() throws {
        var boost = RingBoostSettings(payload: "X360A, RT:0.4, W, MOUSE_LEFT_DOWN")
        boost.directionalPayloads.up = "X360B"
        try boost.validate()
        XCTAssertEqual(boost.payload(for: .up), "X360B")
        XCTAssertEqual(boost.payload(for: .left), boost.payload)
        boost.directionalPayloads.left = "  "
        XCTAssertEqual(boost.payload(for: .left), boost.payload)
    }
    func testRingOwnsTimingAndRejectsNonreversiblePayloads() {
        for payload in ["WAIT_10", "RT:0.5P10", "MOUSE_LEFT_UP", "SCROLL_MODE_TOGGLE", String(repeating: "A", count: 1001)] {
            XCTAssertThrowsError(try RingBoostSettings(payload: payload).validate(), payload)
        }
    }
    func testMovementAndAimOutputRestrictions() {
        XCTAssertThrowsError(try RingMovementSettings(output: .mouse).validate())
        XCTAssertThrowsError(try RingMovementSettings(initialX: 1, initialY: 1).validate())
        XCTAssertThrowsError(try RingMovementSettings(sensitivity: .nan).validate())
        XCTAssertThrowsError(try RingAimSettings(tuning: .init(output: .leftStick)).validate())
        XCTAssertThrowsError(try RingAimSettings(tuning: .init(output: .dpad)).validate())
        XCTAssertNoThrow(try RingAimSettings(tuning: .init(output: .rightStick)).validate())
        XCTAssertEqual(RingMovementSettings(initialY: -0.5).initialPosition.y, 0.5)
    }
    func testKnobsMustFitAndDestinationsExist() throws {
        var c = FloatingRingConfig(); c.knobs[0].x = 0.8
        XCTAssertThrowsError(try c.validate())
        c.knobs[0].targetDiameter = 16; try c.validate()
        c.knobs.append(c.knobs[0]); XCTAssertThrowsError(try c.validate())
        c.knobs.removeLast(); c.startKnobID = "missing"; XCTAssertThrowsError(try c.validate())
    }
    func testDisabledTemplateKeepsItsStartingRole() throws {
        var c = FloatingRingConfig(); c.movement.enabled = false; c.aim.enabled = false
        c.startRole = .boostTwo; try c.validate()
        c.aim.enabled = true; XCTAssertThrowsError(try c.validate())
        c.startRole = .aim; try c.validate()
        c.knobs[0].enabled = false; XCTAssertThrowsError(try c.validate())
    }
    func testBoostDistanceAndDelayRulesPreserveInactiveSettings() throws {
        var c = FloatingRingConfig(); c.boost1.activationDelayMilliseconds = 1
        XCTAssertThrowsError(try c.validate())
        c.boost1.activationDelayMilliseconds = 0; c.boost1.directOuterDistance = 161
        XCTAssertThrowsError(try c.validate())
        var b = RingBoostSettings(activationDelayMilliseconds: 10, cancelDelayOnExit: false)
        XCTAssertThrowsError(try b.validate()); b.latchOnExit = true; try b.validate()
        b.action = .repeat; XCTAssertThrowsError(try b.validate()); b.repeatAfterExit = true; try b.validate()
        b.action = .tap; b.repeatAfterExit = false; try b.validate()
        XCTAssertTrue(b.latchOnExit)
    }
    func testSharedBoostTapRepeatEdgesRejectedButHoldAllowed() throws {
        var c = FloatingRingConfig(); c.boost1.enabled = true; c.boost2.enabled = true
        c.boost1.payload = "X360A"; c.boost2.directionalPayloads.up = "X360A"
        try c.validate(); c.boost2.action = .repeat; XCTAssertThrowsError(try c.validate())
        c.boost2.action = .hold; c.boost1.action = .tap; XCTAssertThrowsError(try c.validate())
    }
    func testADSFireLogicalPressureChannelConflict() {
        var c = FloatingRingConfig(); c.knobs[0].fire.mode = .hold
        c.knobs[0].fire.adsPayload = "RT:0.4"; c.knobs[0].fire.firePayload = "RT:0.5"
        XCTAssertThrowsError(try c.validate())
    }
    func testFiniteBoostCannotShareADSOrFire() throws {
        var c = FloatingRingConfig(); c.boost1.enabled = true; c.boost1.payload = "X360A"
        c.knobs[0].fire.adsPayload = "X360A"; try c.validate()
        c.boost1.action = .tap; XCTAssertThrowsError(try c.validate())
        c.knobs[0].fire.adsPayload = ""; c.knobs[0].fire.firePayload = "X360A"; c.knobs[0].fire.mode = .hold
        XCTAssertThrowsError(try c.validate()); c.boost1.action = .hold; try c.validate()
        c.knobs[0].fire.mode = .releaseShot; XCTAssertThrowsError(try c.validate())
    }
    func testCompetingDelayedFireSourceRejected() {
        var c = FloatingRingConfig(); c.boost2.enabled = true; c.boost2.activationDelayMilliseconds = 10
        c.boost2.payload = "RT:1"; c.knobs[0].fire.mode = .hold; c.knobs[0].fire.returnFire.enabled = true
        XCTAssertThrowsError(try c.validate())
    }
    func testGeometryKnownBoundsAndBoostAnnuliDoNotExpandIt() throws {
        var c = FloatingRingConfig(); c.boost2.enabled = true; c.boost2.directTapEnabled = true
        let g = try FloatingRingGeometry(config: c)
        XCTAssertEqual(g.width, 176); XCTAssertEqual(g.height, 224)
        XCTAssertEqual(g.center, .init(x: 88, y: 136)); XCTAssertEqual(g.finish, .init(x: 128, y: 0, width: 48, height: 48))
        XCTAssertNil(g.place(at: .init(x: 80, y: 80), usable: .init(x: 0, y: 0, width: 175, height: 300)))
        XCTAssertNil(g.place(at: .init(x: 80, y: 80), usable: .init(x: 0, y: 0, width: 200, height: 223)))
    }
    func testClampedPlacementPreservesExactSummonVector() throws {
        let g = try FloatingRingGeometry(config: .init(movement: .init(initialY: -1)))
        let placement = try XCTUnwrap(g.place(at: .init(x: 1, y: 1), usable: .init(x: 0, y: 0, width: 400, height: 800)))
        XCTAssertEqual(placement.origin, .init(x: 0, y: 0))
        XCTAssertEqual(placement.local(.init(x: 1, y: 1), applyGrabOffset: true), g.startAnchor())
        XCTAssertEqual(g.movementVector(at: g.startAnchor()), .init(x: 0, y: 1))
        XCTAssertEqual(g.config.movement.initialY, -1)
    }
    func testKnobTargetsSelectOnlyActualCirclesWithBackgroundDefault() throws {
        var c = FloatingRingConfig()
        c.knobs = [.init(id: "left", x: -0.5, targetDiameter: 12), .init(id: "right", x: 0.5, targetDiameter: 12)]
        c.startKnobID = "left"; c.directBoostAimKnobID = "right"
        let g = try FloatingRingGeometry(config: c), right = g.knobCenter(c.knobs[1])
        XCTAssertEqual(g.knob(at: right)?.id, "right")
        XCTAssertEqual(g.knob(at: .init(x: right.x, y: right.y + 10))?.id, "left")
        XCTAssertNil(g.knob(at: .init(x: g.center.x, y: g.center.y + 49)))
    }
    func testRoleHitPriorityAndFiniteDirectAnnulus() throws {
        var c = FloatingRingConfig(); c.boost1.enabled = true; c.boost1.directTapEnabled = true
        let g = try FloatingRingGeometry(config: c)
        XCTAssertNil(g.role(at: g.finish.center)); XCTAssertEqual(g.role(at: g.center), .aim)
        XCTAssertEqual(g.role(at: .init(x: g.center.x + 80, y: g.center.y)), .movement)
        XCTAssertEqual(g.role(at: .init(x: g.center.x + 120, y: g.center.y)), .boostOne)
        XCTAssertEqual(g.role(at: .init(x: g.center.x + 144, y: g.center.y)), .boostOne)
        XCTAssertNil(g.role(at: .init(x: g.center.x + 145, y: g.center.y)))
    }
    func testMovementNormalizesRadiallyAndConvertsY() throws {
        let g = try FloatingRingGeometry(config: .init())
        let v = g.movementVector(at: .init(x: g.center.x + 88, y: g.center.y - 88))
        XCTAssertEqual(v.x, 1 / sqrt(2), accuracy: 1e-12); XCTAssertEqual(v.y, 1 / sqrt(2), accuracy: 1e-12)
        XCTAssertEqual(g.movementVector(at: g.center), .zero)
    }
    func testDirectionalHysteresisAndSameAxisReversal() throws {
        let g = try FloatingRingGeometry(config: .init())
        func p(_ x: Double, _ y: Double) -> FloatingPoint { .init(x: g.center.x + x, y: g.center.y + y) }
        XCTAssertEqual(g.boostDirection(at: p(100, 100)), .right)
        XCTAssertEqual(g.boostDirection(at: p(100, 111), previous: .right), .right)
        XCTAssertEqual(g.boostDirection(at: p(100, 112), previous: .right), .down)
        XCTAssertEqual(g.boostDirection(at: p(-120, 0), previous: .right), .left)
    }
    func testUnreachableDirectionsAreFeedbackNotSilentClamping() throws {
        var c = FloatingRingConfig(); c.boost2.enabled = true
        let g = try FloatingRingGeometry(config: c)
        XCTAssertEqual(g.unreachableDirections(.two, origin: .init(x: 0, y: 0), usable: .init(x: 0, y: 0, width: 300, height: 600)), [.up, .left])
        XCTAssertEqual(g.unreachableDirections(.one, origin: .init(x: 0, y: 0), usable: .init(x: 0, y: 0, width: 300, height: 600)), [])
    }
}

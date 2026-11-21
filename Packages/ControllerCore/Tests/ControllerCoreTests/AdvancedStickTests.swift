import Foundation
import XCTest
@testable import ControllerCore

final class AdvancedStickTests: XCTestCase {
    private func profile(_ controls: [ProfileControl]) throws -> ControllerProfile {
        let places = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: places, landscape: places, swipeMode: .controls)
    }
    private func stick(_ response: StickResponseSettings = .init(), extended: ExtendedBoostSettings = .init(), retained: Bool = false) -> ProfileControl {
        var behavior = StickBehavior(autoCenter: !retained, stickPlusEnabled: true)
        for direction in StickDirection.allCases {
            behavior.directions[direction] = .init(normalControls: [.a], boostControls: [.b], superBoostControls: [.x])
        }
        return .init(kind: .leftStick, stickBehavior: behavior, stickResponse: response, extendedBoost: extended)
    }
    private func outer(_ payload: String? = "X360Y", threshold: Double = 1.25) -> ExtendedBoostSettings {
        var settings = ExtendedBoostSettings(enabled: true, mode: .addOuterStage)
        for direction in StickDirection.allCases { settings.directions[direction]?.outerPayload = payload; settings.directions[direction]?.outerThreshold = threshold }
        return settings
    }
    func testLinearSensitivityScalesThenClampsAnalogOutput() throws {
        let settings = StickResponseSettings(sensitivity: 2)
        XCTAssertEqual(try settings.apply(.init(x: 0.2, y: -0.8)), .init(x: 0.4, y: -1))
        XCTAssertEqual(try StickResponseSettings(sensitivity: 0).apply(.init(x: 1, y: -1)), .zero)
        XCTAssertEqual(try StickResponseSettings().apply(.init(x: -0.3, y: 0.7)), .init(x: -0.3, y: 0.7))
    }
    func testPerAxisPowerCurvePreservesSignsAndEndpoints() throws {
        XCTAssertEqual(try StickResponseSettings(mode: .perAxis, sensitivity: 0.5).apply(.init(x: -0.5, y: 1)), .init(x: -0.25, y: 1))
        let result = try StickResponseSettings(mode: .perAxis, sensitivity: 2).apply(.init(x: 0.25, y: -0.25))
        XCTAssertEqual(result, .init(x: 0.5, y: -0.5))
        for sensitivity in [0.1, 1, 5] { XCTAssertEqual(try StickResponseSettings(mode: .perAxis, sensitivity: sensitivity).apply(.init(x: -1, y: 1)), .init(x: -1, y: 1)) }
    }
    func testRadialCurvePreservesDirectionAndClampsDistanceToCircle() throws {
        let settings = StickResponseSettings(mode: .radial, sensitivity: 2)
        let result = try settings.apply(.init(x: 0.3, y: -0.4))
        XCTAssertEqual(hypot(result.x, result.y), sqrt(0.5), accuracy: 1e-12)
        XCTAssertEqual(result.x / result.y, -0.75, accuracy: 1e-12)
        let diagonal = try settings.apply(.init(x: 1, y: 1))
        XCTAssertEqual(diagonal.x, 1 / sqrt(2), accuracy: 1e-12)
        XCTAssertEqual(hypot(diagonal.x, diagonal.y), 1, accuracy: 1e-12)
        XCTAssertEqual(try settings.apply(.zero), .zero)
    }
    func testEveryResponseRemainsFiniteAndNormalizedAcrossExtremes() throws {
        let positions = [StickPosition.zero, .init(x: 1, y: -1), .init(x: Double.leastNonzeroMagnitude), .init(x: 0.999999999, y: 0.00001), .init(x: -0.7, y: 0.4)]
        for mode in StickResponseMode.allCases {
            for sensitivity in [0, Double.leastNonzeroMagnitude, 0.01, 1, 5] {
                for position in positions { XCTAssertTrue(try StickResponseSettings(mode: mode, sensitivity: sensitivity).apply(position).isValid) }
            }
        }
    }
    func testSettingsAndTravelRejectNonfiniteAndOutOfBoundsValues() throws {
        for value in [-0.01, 5.01, .nan, .infinity] { XCTAssertThrowsError(try StickResponseSettings(sensitivity: value).validate()) }
        for value in [65.0, -65, .nan, .infinity] { XCTAssertFalse(StickTravel(x: value).isValid); XCTAssertFalse(StickTravel(y: value).isValid) }
        XCTAssertTrue(StickTravel(x: 64, y: -64).isValid)
        XCTAssertEqual(StickTravel(x: 4, y: -3).clampedPosition, .init(x: 1, y: -1))
        XCTAssertThrowsError(try StickResponseSettings().apply(.init(x: 2)))
    }
    func testLinearThresholdsFollowSensitivityWhileCurvedThresholdsFollowPhysicalTravel() throws {
        for mode in StickResponseMode.allCases {
            let control = stick(.init(mode: mode, sensitivity: 2))
            var engine = try ProfileInputEngine(profile: profile([control]))
            try engine.beginStick(contact: 1, control: control.id, travel: .init(y: 0.3), at: 0)
            XCTAssertEqual(engine.state.buttons, mode == .linear ? [.b] : [.a])
            XCTAssertEqual(engine.state.leftStick.y, mode == .linear ? 0.6 : sqrt(0.3), accuracy: 1e-12)
            XCTAssertEqual(engine.stickPositions[control.id]?.y, 0.3)
        }
    }
    func testExtendedThresholdsUseRawPhysicalDistanceRegardlessOfResponseAndSensitivity() throws {
        var extended = ExtendedBoostSettings(enabled: true)
        extended.directions[.up] = .init(regularThreshold: 1.2, superThreshold: 2, outerThreshold: 3)
        for mode in StickResponseMode.allCases {
            let control = stick(.init(mode: mode, sensitivity: 0), extended: extended)
            var engine = try ProfileInputEngine(profile: profile([control]))
            try engine.beginStick(contact: 1, control: control.id, travel: .init(y: 1.3), at: 0)
            XCTAssertEqual(engine.state.buttons, [.b]); XCTAssertEqual(engine.state.leftStick, .zero)
            try engine.moveStick(contact: 1, travel: .init(y: 2), at: 0.1); XCTAssertEqual(engine.state.buttons, [.b])
            try engine.moveStick(contact: 1, travel: .init(y: 2.0001), at: 0.2); XCTAssertEqual(engine.state.buttons, [.x])
        }
    }
    func testPerDirectionExtendedThresholdsAndDiagonalsAreIndependent() throws {
        var extended = ExtendedBoostSettings(enabled: true)
        extended.directions[.up] = .init(regularThreshold: 0.4, superThreshold: 0.8)
        extended.directions[.right] = .init(regularThreshold: 1.2, superThreshold: 2)
        let control = stick(extended: extended)
        var engine = try ProfileInputEngine(profile: profile([control]))
        try engine.beginStick(contact: 1, control: control.id, travel: .init(x: 0.6, y: 0.6), at: 0)
        XCTAssertEqual(engine.state.buttons, [.a, .b])
        try engine.moveStick(contact: 1, travel: .init(x: 1.3, y: 0.9), at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.b, .x]); XCTAssertEqual(engine.state.leftStick, .init(x: 1, y: 0.9))
    }
    func testOuterStageIsExclusiveStrictAndCanBeReachedPastMaximumThreshold() throws {
        let control = stick(extended: outer(threshold: 5))
        var engine = try ProfileInputEngine(profile: profile([control]))
        try engine.beginStick(contact: 1, control: control.id, travel: .init(y: 5), at: 0)
        XCTAssertEqual(engine.state.buttons, [.x]); XCTAssertEqual(engine.state.leftStick.y, 1)
        try engine.moveStick(contact: 1, travel: .init(y: 5.01), at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.y])
        try engine.moveStick(contact: 1, travel: .init(y: 0.6), at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.b])
    }
    func testBlankOrNilOuterPayloadFallsBackToSuperWithoutAddingLowerStages() throws {
        for payload in [nil, "", " \n\t"] as [String?] {
            let control = stick(extended: outer(payload))
            var engine = try ProfileInputEngine(profile: profile([control]))
            try engine.beginStick(contact: 1, control: control.id, travel: .init(y: 2), at: 0)
            XCTAssertEqual(engine.state.buttons, [.x])
            XCTAssertEqual(try control.outerProgram(direction: .up), try control.stageProgram(direction: .up, stage: .superBoost))
        }
    }
    func testRawRetentionKeepsOuterStageButKnobAndWireAxesRemainClamped() throws {
        let control = stick(extended: outer(), retained: true)
        var engine = try ProfileInputEngine(profile: profile([control]))
        try engine.handle(.beginStick(contact: 1, control: control.id, travel: .init(y: 2.2)), at: 0)
        try engine.end(contact: 1, at: 0.1); try engine.tick(at: 2)
        XCTAssertEqual(engine.state.buttons, [.y]); XCTAssertEqual(engine.state.leftStick.y, 1)
        XCTAssertEqual(engine.retainedSticks[control.id]?.y, 1); XCTAssertEqual(engine.stickPositions[control.id]?.y, 1)
        XCTAssertTrue(engine.state.isValid)
        engine.recenterSticks(); XCTAssertTrue(engine.state.isNeutral); XCTAssertTrue(engine.retainedSticks.isEmpty)
        try engine.tick(at: 3); XCTAssertTrue(engine.state.isNeutral)
    }
    func testRawHandoffRetainsDepartingOuterStageAndTracksNewStickResponse() throws {
        let left = stick(extended: outer(), retained: true)
        var right = ProfileControl(kind: .rightStick, stickResponse: .init(mode: .perAxis, sensitivity: 2))
        right.stickBehavior.autoCenter = false
        var engine = try ProfileInputEngine(profile: profile([left, right]))
        try engine.beginStick(contact: 1, control: left.id, travel: .init(y: 0.3), at: 0)
        XCTAssertTrue(try engine.handoffTravel(contact: 1, to: right.id, departingTravel: .init(y: 2), arrivingTravel: .init(x: -0.25), at: 0.1))
        XCTAssertEqual(engine.state.buttons, [.y]); XCTAssertEqual(engine.state.leftStick.y, 1)
        XCTAssertEqual(engine.state.rightStick.x, -0.5, accuracy: 1e-12)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertEqual(engine.retainedSticks[right.id]?.x, -0.25)
    }
    func testSameChannelReplacementClearsRawRetentionAndOldOuterClaims() throws {
        let old = stick(extended: outer(), retained: true), next = stick()
        var engine = try ProfileInputEngine(profile: profile([old, next]))
        try engine.beginStick(contact: 1, control: old.id, travel: .init(y: 3), at: 0); try engine.end(contact: 1, at: 0.1)
        try engine.beginStick(contact: 2, control: next.id, travel: .init(y: 0.3), at: 0.2)
        XCTAssertNil(engine.retainedSticks[old.id]); XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 2, at: 0.3); XCTAssertTrue(engine.state.isNeutral)
    }
    func testOuterDesktopClaimsRespectIndependentOwnersAndRecenter() throws {
        let control = stick(extended: outer("SHIFT,MOUSE_LEFT_DOWN"))
        let held = ProfileControl(payload: "SHIFT,MOUSE_LEFT_DOWN")
        var engine = try ProfileInputEngine(profile: profile([control, held]))
        try engine.begin(contact: 1, control: held.id, at: 0)
        try engine.beginStick(contact: 2, control: control.id, travel: .init(y: 2), at: 0)
        _ = engine.drainPracticeEvents()
        engine.recenterSticks()
        XCTAssertEqual(engine.practiceState.heldKeys, [.leftShift]); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left])
        XCTAssertTrue(engine.drainPracticeEvents().events.isEmpty)
        try engine.end(contact: 1, at: 0.1); XCTAssertEqual(engine.practiceState, .neutral)
    }
    func testDirectionalOuterHasNoAnalogAndContributesToCapabilityMetadata() throws {
        var control = stick(extended: outer("RT:0.4,W")); control.directionalEnabled = true; control.stickBehavior.stickPlusEnabled = false
        XCTAssertTrue(control.outputTargets.contains(.rightTrigger)); XCTAssertTrue(control.hasKeyboardOrMouseOutputs)
        var engine = try ProfileInputEngine(profile: profile([control]))
        try engine.beginStick(contact: 1, control: control.id, travel: .init(y: 2), at: 0)
        XCTAssertEqual(engine.state.leftStick, .zero); XCTAssertEqual(engine.practiceState.rightTrigger, 0.4)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w])
    }
    func testInvalidTravelIsRejectedBeforeOverdueHoldOrAnyStateMutation() throws {
        let control = stick(extended: outer()), hold = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        var engine = try ProfileInputEngine(profile: profile([control, hold]))
        try engine.begin(contact: 1, control: hold.id, at: 0)
        try engine.beginStick(contact: 2, control: control.id, travel: .init(y: 0.3), at: 0)
        let state = engine.state
        for travel in [StickTravel(x: .nan), .init(y: .infinity), .init(x: 65)] {
            XCTAssertThrowsError(try engine.moveStick(contact: 2, travel: travel, at: 1))
            XCTAssertThrowsError(try engine.handoffTravel(contact: 2, to: hold.id, departingTravel: travel, at: 1))
            XCTAssertThrowsError(try engine.beginStick(contact: 3, control: control.id, travel: travel, at: 1))
            XCTAssertEqual(engine.state, state); XCTAssertTrue(engine.latchedControls.isEmpty)
        }
        try engine.tick(at: 0.5); XCTAssertEqual(engine.latchedControls, [hold.id])
    }
    func testRawTravelStillHonorsHiddenPageAndAnalogChannelOwnership() throws {
        let first = stick(extended: outer()), other = stick(extended: outer("X360B"))
        var saved = try profile([first, other]); let page = try saved.addPage(name: "Other")
        try saved.moveControl(other.id, toPage: page)
        var engine = try ProfileInputEngine(profile: saved)
        XCTAssertThrowsError(try engine.beginStick(contact: 2, control: other.id, travel: .init(y: 4), at: 0))
        try engine.beginStick(contact: 1, control: first.id, travel: .init(y: 2), at: 0)
        XCTAssertFalse(try engine.handoffTravel(contact: 1, to: other.id, arrivingTravel: .init(y: 3), at: 0))
        XCTAssertTrue(try engine.selectPage(page, at: 0.1)); XCTAssertTrue(engine.state.isNeutral)
        try engine.beginStick(contact: 2, control: other.id, travel: .init(y: 4), at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.b])
    }
    func testNormalizedLegacyMethodsStillRejectBeyondEdgeWhileRawMethodsAcceptIt() throws {
        let control = stick(extended: outer())
        var engine = try ProfileInputEngine(profile: profile([control]))
        XCTAssertThrowsError(try engine.begin(contact: 1, control: control.id, position: .init(y: 2), at: 0))
        try engine.beginStick(contact: 1, control: control.id, travel: .init(y: 2), at: 0)
        XCTAssertThrowsError(try engine.move(contact: 1, position: .init(y: 2), at: 0.1))
        try engine.handle(.moveStick(contact: 1, travel: .init(y: -2)), at: 0.1)
        XCTAssertEqual(engine.state.leftStick.y, -1); XCTAssertEqual(engine.state.buttons, [.y])
        try engine.cancel(contact: 1, at: 0.2); XCTAssertTrue(engine.state.isNeutral)
    }
}

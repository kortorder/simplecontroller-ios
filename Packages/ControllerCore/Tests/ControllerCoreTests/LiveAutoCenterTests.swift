import Foundation
import XCTest
@testable import ControllerCore

final class LiveAutoCenterTests: XCTestCase {
    private func profile(_ controls: [ProfileControl]) throws -> ControllerProfile {
        let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try .init(controls: controls, portrait: placements, landscape: placements)
    }
    private func stick(_ kind: ProfileControlKind = .leftStick, autoCenter: Bool = false) -> ProfileControl {
        .init(kind: kind, stickBehavior: .init(autoCenter: autoCenter))
    }
    private func action(_ payload: String = "AUTO_CENTER_TOGGLE") -> ProfileControl { .init(payload: payload) }
    private func press(_ e: inout ProfileInputEngine, _ c: ProfileControl, at t: Double) throws {
        try e.begin(contact: 90, control: c.id, at: t); try e.end(contact: 90, at: t + 0.001)
    }
    private func edgeStick(hysteresis: Double? = nil) -> ProfileControl {
        var c = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: true, stickPlusEnabled: true, boostThreshold: 0.95, superBoostThreshold: 0.99), stickPlusEdgeRearmHysteresis: hysteresis)
        c.directionPayloads[.up]?.boostPayload = "X360LS"
        c.directionPayloads[.up]?.superBoostPayload = "X360LS,X360A(U100)"
        c.directionPayloads[.right]?.superBoostPayload = "AUTO_CENTER_TOGGLE"
        c.directionPayloads[.left]?.superBoostPayload = "X360LB(U100)"
        c.directionPayloads[.down]?.superBoostPayload = "X360B(U100)"
        return c
    }

    func testLocalPayloadCanonicalFormAndSafetyValidation() throws {
        XCTAssertEqual(try ControllerPayloadProgram.parse("auto_center").source, "AUTO_CENTER_TOGGLE")
        for (text, command) in [("AUTO_CENTER_ON", AutoCenterCommand.enable), ("AUTO_CENTER_OFF", .disable), ("AUTO_CENTER_TOGGLE", .toggle)] {
            let p = try ControllerPayloadProgram.parse(text)
            XCTAssertEqual(p.autoCenterCommand, command); XCTAssertTrue(p.outputTargets.isEmpty)
            XCTAssertNoThrow(try p.validateSustained()); XCTAssertThrowsError(try p.validateMacroMode())
            XCTAssertNoThrow(try action(text).validate())
        }
        for text in ["AUTO_CENTER_TOGGLE,X360A", "X360A,AUTO_CENTER_ON", "AUTO_CENTER_OFF(D100)", "AUTO_CENTER_TOGGLE(U100)", "AUTO_CENTER_NEVER"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse(text))
        }
        var c = action(); c.buttonBehavior.holdToggle = true; XCTAssertThrowsError(try c.validate())
        c = action(); c.autoTapEnabled = true; XCTAssertThrowsError(try c.validate())
        c = action(); c.buttonAim.enabled = true; XCTAssertThrowsError(try c.validate())
        c = action(); c.doubleTapRepeatEnabled = true; XCTAssertThrowsError(try c.validate())
        c = action(); c.macroModeEnabled = true; XCTAssertThrowsError(try c.validate())
    }
    func testToggleCentersOnlyReleasedStickAndKeepsIndependentPayloadOwners() throws {
        let left = stick(), right = stick(.rightStick), toggle = action(), hold = ProfileControl(payload: "X360A,LT:0.5,RT:0.7")
        let p = try profile([left, right, toggle, hold]); var e = try ProfileInputEngine(profile: p)
        try e.begin(contact: 1, control: left.id, position: .init(y: 0.7), at: 0)
        try e.end(contact: 1, at: 0.01)
        try e.begin(contact: 2, control: right.id, position: .init(x: 0.6), at: 0.02)
        try e.begin(contact: 3, control: hold.id, at: 0.03)
        try press(&e, toggle, at: 0.04)
        XCTAssertEqual(e.autoCenterOverride, true); XCTAssertEqual(e.state.leftStick, .zero)
        XCTAssertEqual(e.state.rightStick.x, 0.6); XCTAssertEqual(e.state.buttons, [.a, .leftTrigger, .rightTrigger])
        XCTAssertEqual(e.practiceState.leftTrigger, 0.5); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        try e.end(contact: 2, at: 0.05); XCTAssertEqual(e.state.rightStick, .zero)
        try press(&e, toggle, at: 0.06)
        XCTAssertEqual(e.autoCenterOverride, false); XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.rightStick, .zero)
        XCTAssertEqual(e.profile, p)
        try e.begin(contact: 4, control: right.id, position: .init(x: -0.4), at: 0.07)
        try e.end(contact: 4, at: 0.08); XCTAssertEqual(e.state.rightStick.x, -0.4)
    }
    func testGlobalHoldTurboSecondContactAndTimerNeverRepeatLocalToggle() throws {
        let left = stick(), toggle = action(); var p = try profile([left, toggle]); p.turboEnabled = true; p.globalHoldEnabled = true
        var e = try ProfileInputEngine(profile: p)
        try e.begin(contact: 1, control: toggle.id, at: 0); XCTAssertEqual(e.autoCenterOverride, true)
        try e.begin(contact: 2, control: toggle.id, at: 0.1); try e.tick(at: 5)
        XCTAssertEqual(e.autoCenterOverride, true); XCTAssertTrue(e.state.isNeutral)
        try e.end(contact: 1, at: 5.1); try e.end(contact: 2, at: 5.2)
        try e.begin(contact: 3, control: toggle.id, at: 5.3); XCTAssertEqual(e.autoCenterOverride, false)
        try e.end(contact: 3, at: 6); XCTAssertTrue(e.latchedControls.isEmpty)
    }
    func testMixedPolicyIncludesAlternateAnalogAndTurnsOnFirst() throws {
        var pad = ProfileControl(payload: "X360A", buttonAim: .init(enabled: true, tuning: .init(output: .rightStick, autoCenter: true), alternate: .init(enabled: true, payload: "X360B")))
        pad.buttonAim.alternate.tuning = .init(output: .leftStick, autoCenter: false)
        let toggle = action(); var e = try ProfileInputEngine(profile: profile([pad, toggle]))
        XCTAssertTrue(e.autoCenterSettingsMixed); XCTAssertFalse(e.allSticksAutoCenterEnabled)
        try press(&e, toggle, at: 0)
        XCTAssertFalse(e.autoCenterSettingsMixed); XCTAssertTrue(e.allSticksAutoCenterEnabled)
        XCTAssertEqual(e.effectiveAutoCenter(for: pad.id), true)
    }
    func testPolicySurvivesReleaseAndPageChangeButProfileReloadRestoresSavedPolicy() throws {
        let left = stick(), toggle = action(); var p = try profile([left, toggle]); let page = try p.addPage(name: "Other")
        var e = try ProfileInputEngine(profile: p)
        try press(&e, toggle, at: 0); e.releaseAll(); XCTAssertEqual(e.autoCenterOverride, true)
        _ = try e.selectPage(page, at: 1); XCTAssertEqual(e.autoCenterOverride, true)
        try e.handle(.cancelAll, at: 2); XCTAssertEqual(e.autoCenterOverride, true)
        try e.apply(profile: p); XCTAssertNil(e.autoCenterOverride); XCTAssertEqual(e.effectiveAutoCenter(for: left.id), false)
    }
    func testButtonAimRetainedMovementCentersWithoutReleasingIndependentTrigger() throws {
        let pad = ProfileControl(payload: "LT:0.5", buttonAim: .init(enabled: true, tuning: .init(output: .rightStick, autoCenter: false)))
        let on = action("AUTO_CENTER_ON"), off = action("AUTO_CENTER_OFF"), fire = ProfileControl(payload: "RT:0.7")
        var e = try ProfileInputEngine(profile: profile([pad, on, off, fire]))
        let center = ButtonPointerSample(x: 50, y: 50, width: 100, height: 100)
        let moved = ButtonPointerSample(x: 160, y: 50, width: 100, height: 100)
        try e.beginButton(contact: 1, control: pad.id, sample: center, at: 0)
        try e.moveButtonBatch(contact: 1, samples: [moved], at: 0.1)
        let vector = e.state.rightStick; XCTAssertGreaterThan(vector.x, 0)
        try e.end(contact: 1, at: 0.2); XCTAssertEqual(e.state.rightStick, vector)
        try e.begin(contact: 2, control: fire.id, at: 0.3); try press(&e, on, at: 0.4)
        XCTAssertEqual(e.state.rightStick, .zero); XCTAssertEqual(e.practiceState.rightTrigger, 0.7)
        try press(&e, off, at: 0.5); XCTAssertEqual(e.state.rightStick, .zero)
        try e.beginButton(contact: 3, control: pad.id, sample: center, at: 0.6)
        try e.moveButtonBatch(contact: 3, samples: [moved], at: 0.7)
        try press(&e, on, at: 0.8)
        XCTAssertGreaterThan(e.state.rightStick.x, 0); XCTAssertEqual(e.practiceState.leftTrigger, 0.5)
        try e.end(contact: 3, at: 0.9); XCTAssertEqual(e.state.rightStick, .zero)
    }
    func testOnDuringDeferredTouchCentersOldAimVectorWhenThatTouchLifts() throws {
        let pad = ProfileControl(payload: "LT:0.5", buttonAim: .init(enabled: true, tuning: .init(output: .rightStick, autoCenter: false)))
        let on = action("AUTO_CENTER_ON"); var e = try ProfileInputEngine(profile: profile([pad, on]))
        let center = ButtonPointerSample(x: 50, y: 50, width: 100, height: 100)
        try e.beginButton(contact: 1, control: pad.id, sample: center, at: 0)
        try e.moveButtonBatch(contact: 1, samples: [.init(x: 160, y: 50, width: 100, height: 100)], at: 0.1)
        try e.end(contact: 1, at: 0.2); let retained = e.state.rightStick
        XCTAssertGreaterThan(retained.x, 0)
        try e.beginButton(contact: 2, control: pad.id, sample: center, at: 0.3)
        try press(&e, on, at: 0.4); XCTAssertEqual(e.state.rightStick, retained)
        try e.end(contact: 2, at: 0.5); XCTAssertEqual(e.state.rightStick, .zero)
    }
    func testRightEdgeToggleRequiresDeliberateInwardTravelAndNeverReplaysOnTick() throws {
        let c = edgeStick(); var e = try ProfileInputEngine(profile: profile([c]))
        try e.begin(contact: 1, control: c.id, position: .init(x: 0.98), at: 0); XCTAssertNil(e.autoCenterOverride)
        try e.move(contact: 1, position: .init(x: 0.99), at: 0.01); XCTAssertEqual(e.autoCenterOverride, false)
        try e.move(contact: 1, position: .init(x: 0.985), at: 0.02)
        try e.move(contact: 1, position: .init(x: 1), at: 0.03); try e.tick(at: 1)
        XCTAssertEqual(e.autoCenterOverride, false)
        try e.move(contact: 1, position: .init(x: 0.94), at: 1.1)
        try e.move(contact: 1, position: .init(x: 1), at: 1.2); XCTAssertEqual(e.autoCenterOverride, true)
        XCTAssertEqual(e.state.leftStick.x, 1)
        try e.end(contact: 1, at: 1.3); XCTAssertEqual(e.state.leftStick, .zero)
        try e.tick(at: 10); XCTAssertEqual(e.autoCenterOverride, true); XCTAssertNil(e.nextDeadline)
    }
    func testFiniteEdgeHysteresisPreservesSprintAndNeedsInwardRearm() throws {
        let c = edgeStick(hysteresis: 0.04); var e = try ProfileInputEngine(profile: profile([c]))
        try e.begin(contact: 1, control: c.id, position: .init(y: 0.97), at: 0); XCTAssertEqual(e.state.buttons, [.leftStick])
        try e.move(contact: 1, position: .init(y: 0.99), at: 0.01); XCTAssertEqual(e.state.buttons, [.leftStick, .a])
        try e.tick(at: 0.12); XCTAssertEqual(e.state.buttons, [.leftStick])
        try e.move(contact: 1, position: .init(y: 0.985), at: 0.13)
        try e.move(contact: 1, position: .init(y: 1), at: 0.14); XCTAssertEqual(e.state.buttons, [.leftStick])
        try e.move(contact: 1, position: .init(y: 0.94), at: 0.15); XCTAssertTrue(e.state.buttons.isEmpty)
        try e.move(contact: 1, position: .init(y: 1), at: 0.16); XCTAssertEqual(e.state.buttons, [.leftStick, .a])
        e.releaseAll(); try e.tick(at: 1); XCTAssertTrue(e.state.isNeutral)
        try e.begin(contact: 2, control: c.id, position: .init(y: 1), at: 2); XCTAssertEqual(e.state.buttons, [.leftStick, .a])
    }
    func testLegacyFiniteStageStillReactivatesImmediatelyWithoutOptionalHysteresis() throws {
        let c = edgeStick(); var e = try ProfileInputEngine(profile: profile([c]))
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0); try e.tick(at: 0.1)
        XCTAssertEqual(e.state.buttons, [.leftStick])
        try e.move(contact: 1, position: .init(y: 0.985), at: 0.11)
        try e.move(contact: 1, position: .init(y: 1), at: 0.12)
        XCTAssertEqual(e.state.buttons, [.leftStick, .a])
    }
    func testOnCancelsRetainedTimedStageButPreservesAnotherButtonOwner() throws {
        var c = edgeStick(hysteresis: 0.04); c.stickBehavior.autoCenter = false
        let on = action("AUTO_CENTER_ON"), independent = ProfileControl(actions: [.a]); var e = try ProfileInputEngine(profile: profile([c, on, independent]))
        try e.begin(contact: 1, control: c.id, position: .init(y: 1), at: 0); try e.end(contact: 1, at: 0.01)
        try e.begin(contact: 2, control: independent.id, at: 0.02); try press(&e, on, at: 0.03)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.buttons, [.a])
        try e.tick(at: 2); XCTAssertEqual(e.state.buttons, [.a]); XCTAssertNil(e.nextDeadline)
        try e.end(contact: 2, at: 3); XCTAssertTrue(e.state.isNeutral)
    }
    func testOptionalHysteresisValidationAndPresetRoundTrip() throws {
        let c = edgeStick(hysteresis: 0.04); let preset = try StickDirectionalPreset.capture(c)
        let data = try JSONEncoder().encode(preset); let decoded = try JSONDecoder().decode(StickDirectionalPreset.self, from: data)
        var copy = stick(); try decoded.apply(to: &copy, scope: .settingsAndMode)
        XCTAssertEqual(copy.stickPlusEdgeRearmHysteresis, 0.04); XCTAssertEqual(copy.directionPayloads, c.directionPayloads)
        XCTAssertEqual(SettingsPresetValue.stickDirectional(preset).requiredWireVersion, 4)
        for value in [-0.01, 0.26, Double.infinity, Double.nan] {
            var bad = c; bad.stickPlusEdgeRearmHysteresis = value; XCTAssertThrowsError(try bad.validate())
        }
        var button = ProfileControl(actions: [.a]); button.stickPlusEdgeRearmHysteresis = 0.04; XCTAssertThrowsError(try button.validate())
        let legacy = stick(); let encoded = try JSONEncoder().encode(legacy)
        XCTAssertNil((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["stickPlusEdgeRearmHysteresis"])
    }
    func testVersion24RoundTripAndPreviousVersionRejectsNewBehavior() throws {
        for c in [action(), edgeStick(hysteresis: 0.04)] {
            let p = try profile([c]); let library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p])
            let data = try ControllerProfileLibraryCodec.encode(library)
            XCTAssertEqual(try ControllerProfileLibraryCodec.decode(data), library)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); json["version"] = 23
            XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: json)))
        }
        let p = try profile([stick(), ProfileControl(actions: [.a])]); let library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any]); json["version"] = 23
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: json)), library)
    }
    func test128ControlsFitAndLegacy64LimitRemainsVersionGuarded() throws {
        XCTAssertEqual(ControllerProfile.maximumControls, 128)
        for count in [64, 65, 128] {
            let p = try profile((0..<count).map { ProfileControl(name: "Button \($0)", actions: [.a]) })
            let library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p]); let data = try ControllerProfileLibraryCodec.encode(library)
            XCTAssertEqual(try ControllerProfileLibraryCodec.decode(data), library)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); json["version"] = 23
            let old = try JSONSerialization.data(withJSONObject: json)
            if count == 64 { XCTAssertNoThrow(try ControllerProfileLibraryCodec.decode(old)) }
            else { XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(old)) }
        }
        XCTAssertThrowsError(try profile((0..<129).map { _ in ProfileControl(actions: [.a]) }))
    }
}

import Foundation
import XCTest
@testable import ControllerCore

final class DesktopPayloadTests: XCTestCase {
    func testFiniteKeyVocabularyAndModifiersCanonicalize() throws {
        let program = try ControllerPayloadProgram.parse("w, SHIFT, Control, right alt, SPACE BAR, ESCAPE, PAGE UP, f12, 0")
        XCTAssertEqual(program.source, "W, LSHIFT, LCTRL, RALT, SPACE, ESC, PAGEUP, F12, 0")
        XCTAssertEqual(try ControllerPayloadProgram.parse(program.source), program)
        XCTAssertTrue(program.hasKeyboardOrMouse); XCTAssertTrue(program.hasAnyOutput)
        XCTAssertTrue(program.outputTargets.isEmpty)
        for key in KeyboardKey.allCases { XCTAssertEqual(try ControllerPayloadProgram.parse(key.rawValue).steps, [.keyDown(key)]) }
    }
    func testMouseCanonicalAndSuppliedAlternateNamesIncludeExplicitUp() throws {
        let program = try ControllerPayloadProgram.parse("LEFT_MOUSE_DOWN, LEFT_MOUSE_UP, MOUSE_RIGHT, MIDDLE_MOUSE_UP")
        XCTAssertEqual(program.source, "MOUSE_LEFT_DOWN, MOUSE_LEFT_UP, MOUSE_RIGHT_DOWN, MOUSE_MIDDLE_UP")
        XCTAssertEqual(program.steps, [.mouseDown(.left), .mouseUp(.left), .mouseDown(.right), .mouseUp(.middle)])
        XCTAssertTrue(try ControllerPayloadProgram.parse("MOUSE_LEFT_UP").hasAnyOutput)
    }
    func testRawKeyCommandsUnknownKeysAndScrollingRemainRejected() {
        for source in ["KEY_DOWN:W", "KEY_UP:W", "F13", "SCROLL:1", "SCROLL_MODE_TOGGLE,W", "MOUSE_X1_DOWN", "COMMAND", "X360A_RELEASE"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse(source), source)
        }
    }
    func testStageValidationAllowsHeldCommandsButRejectsEdgesTimingAndPulse() throws {
        XCTAssertNoThrow(try ControllerPayloadProgram.parse("W, SHIFT, MOUSE_RIGHT_DOWN, LT:0.3, X360A").validateSustained())
        for source in ["WAIT_0", "RT:1P0.3", "MOUSE_LEFT_UP"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse(source).validateSustained())
        }
        var stick = ProfileControl(kind: .leftStick, directionalEnabled: true)
        stick.directionPayloads[.right]?.boostPayload = "WAIT_100, W"
        XCTAssertThrowsError(try stick.stageProgram(direction: .right, stage: .boost)) {
            XCTAssertTrue($0.localizedDescription.contains("Right Boost"))
        }
        XCTAssertThrowsError(try stick.validate())
    }
    func testCapabilitiesDistinguishDesktopOnlyMixedEmptyAndMouseUpOnly() throws {
        let only = ProfileControl(payload: "W, MOUSE_LEFT_DOWN")
        XCTAssertTrue(only.hasKeyboardOrMouseOutputs); XCTAssertTrue(only.hasAnyOutput); XCTAssertEqual(only.outputTargets, [])
        let mixed = ProfileControl(payload: "X360A, W")
        XCTAssertTrue(mixed.hasKeyboardOrMouseOutputs); XCTAssertEqual(mixed.outputTargets, [.a])
        let up = ProfileControl(payload: "MOUSE_RIGHT_UP")
        XCTAssertTrue(up.hasAnyOutput); XCTAssertTrue(up.hasKeyboardOrMouseOutputs)
        XCTAssertFalse(ProfileControl(payload: "WAIT_100").hasAnyOutput)
        XCTAssertFalse(ProfileControl().hasAnyOutput)
    }
    func testDirectionOverridesKeepLegacySetsAndEmptyOverrideDoesNotFallBack() throws {
        var stick = ProfileControl(kind: .leftStick, directionalEnabled: true)
        stick.stickBehavior.directions[.up]?.normalControls = [.a]
        XCTAssertEqual(try stick.stageProgram(direction: .up, stage: .normal).outputTargets, [.a])
        stick.directionPayloads[.up]?.normalPayload = "W"
        XCTAssertEqual(try stick.stageProgram(direction: .up, stage: .normal).steps, [.keyDown(.w)])
        XCTAssertEqual(stick.stickBehavior.directions[.up]?.normalControls, [.a])
        stick.directionPayloads[.up]?.normalPayload = ""
        XCTAssertEqual(try stick.stageProgram(direction: .up, stage: .normal).steps, [])
    }
}

final class DesktopInputEngineTests: XCTestCase {
    private func profile(_ controls: [ProfileControl], turbo: Bool = false) throws -> ControllerProfile {
        let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: placements, landscape: placements, turboEnabled: turbo)
    }
    private func kinds(_ engine: inout ProfileInputEngine) -> [PracticeOutputEvent.Kind] { engine.drainPracticeEvents().events.map(\.kind) }
    func testImmediateMouseClickKeepsBothOrderedEdgesWithNeutralFinalState() throws {
        let button = ProfileControl(payload: "LEFT_MOUSE_DOWN, LEFT_MOUSE_UP")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        XCTAssertEqual(kinds(&engine), [.mouseDown(.left), .mouseUp(.left)])
        XCTAssertTrue(engine.practiceState.heldMouseButtons.isEmpty)
        XCTAssertTrue(kinds(&engine).isEmpty)
    }
    func testMouseUpOnlyRemovesCurrentRunAndCannotReleaseAnotherOwner() throws {
        let held = ProfileControl(payload: "MOUSE_LEFT_DOWN"), click = ProfileControl(payload: "MOUSE_LEFT_DOWN, MOUSE_LEFT_UP")
        let up = ProfileControl(payload: "MOUSE_LEFT_UP")
        var engine = try ProfileInputEngine(profile: profile([held, click, up]))
        try engine.begin(contact: 1, control: held.id, at: 0); _ = kinds(&engine)
        try engine.begin(contact: 2, control: click.id, at: 0.1)
        try engine.begin(contact: 3, control: up.id, at: 0.2)
        XCTAssertTrue(kinds(&engine).isEmpty); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left])
        try engine.end(contact: 1, at: 0.3)
        XCTAssertEqual(kinds(&engine), [.mouseUp(.left)])
    }
    func testRepeatedSameRunDownAndSharedKeysRemainIdempotent() throws {
        let first = ProfileControl(payload: "W, W, MOUSE_RIGHT_DOWN, MOUSE_RIGHT_DOWN"), second = ProfileControl(payload: "W")
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.begin(contact: 1, control: first.id, at: 0)
        XCTAssertEqual(kinds(&engine), [.keyDown(.w), .mouseDown(.right)])
        try engine.begin(contact: 2, control: second.id, at: 0.1)
        XCTAssertTrue(kinds(&engine).isEmpty)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertEqual(kinds(&engine), [.mouseUp(.right)]); XCTAssertEqual(engine.practiceState.heldKeys, [.w])
        try engine.end(contact: 2, at: 0.3); XCTAssertEqual(kinds(&engine), [.keyUp(.w)])
    }
    func testWaitProducesOrderedDelayedClickAndNormalLiftCancelsUnstartedStep() throws {
        let button = ProfileControl(payload: "WAIT_100, MOUSE_LEFT_DOWN, MOUSE_LEFT_UP, WAIT_100, W")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        XCTAssertTrue(kinds(&engine).isEmpty)
        try engine.tick(at: 0.1); XCTAssertEqual(kinds(&engine), [.mouseDown(.left), .mouseUp(.left)])
        try engine.end(contact: 1, at: 0.3)
        XCTAssertTrue(kinds(&engine).isEmpty); XCTAssertTrue(engine.practiceState.heldKeys.isEmpty)
    }
    func testAccessibilityExpiryCancelsContinuationAtItsExactReleaseBoundary() throws {
        let button = ProfileControl(payload: "WAIT_150, MOUSE_LEFT_DOWN, MOUSE_LEFT_UP")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.activate(button.id, at: 0)
        try engine.tick(at: 0.15)
        XCTAssertTrue(kinds(&engine).isEmpty)
        XCTAssertEqual(engine.practiceState, .neutral)
        XCTAssertNil(engine.nextDeadline)
    }
    func testDueStepsAcrossRunsUseDeadlineThenActivationOrder() throws {
        let first = ProfileControl(payload: "WAIT_200, MOUSE_LEFT_DOWN, MOUSE_LEFT_UP")
        let second = ProfileControl(payload: "WAIT_100, MOUSE_RIGHT_DOWN, MOUSE_RIGHT_UP")
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.begin(contact: 1, control: first.id, at: 0)
        try engine.begin(contact: 2, control: second.id, at: 0)
        try engine.tick(at: 0.3)
        XCTAssertEqual(kinds(&engine), [.mouseDown(.right), .mouseUp(.right), .mouseDown(.left), .mouseUp(.left)])
    }
    func testCancelDiscardsUnreadOldEdgesAndPendingWorkThenReportsReleaseAndReset() throws {
        let button = ProfileControl(payload: "W, MOUSE_LEFT_DOWN, WAIT_100, MOUSE_RIGHT_DOWN")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.handle(.cancelAll, at: 0.5)
        XCTAssertEqual(kinds(&engine), [.keyUp(.w), .mouseUp(.left), .reset])
        XCTAssertEqual(engine.practiceState, .neutral)
        try engine.tick(at: 1); XCTAssertTrue(kinds(&engine).isEmpty)
    }
    func testApplyNewProfileCannotLeakUnreadClicksOrDelayedKeys() throws {
        let old = ProfileControl(payload: "MOUSE_LEFT_DOWN,MOUSE_LEFT_UP,WAIT_100,W")
        var engine = try ProfileInputEngine(profile: profile([old]))
        try engine.begin(contact: 1, control: old.id, at: 0)
        try engine.apply(profile: profile([ProfileControl(payload: "A")]))
        XCTAssertEqual(kinds(&engine), [.reset])
        try engine.tick(at: 1); XCTAssertTrue(kinds(&engine).isEmpty)
    }
    func testHoldToggleKeepsDesktopClaimsUntilSecondTap() throws {
        let button = ProfileControl(buttonBehavior: .init(holdToggle: true), payload: "SHIFT,W,MOUSE_RIGHT_DOWN")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.tick(at: 0.5)
        XCTAssertEqual(engine.practiceState.heldKeys, [.leftShift, .w]); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.right])
        try engine.end(contact: 1, at: 0.6); _ = kinds(&engine)
        try engine.begin(contact: 2, control: button.id, at: 0.7)
        XCTAssertEqual(Set(kinds(&engine).map { String(describing: $0) }), Set([PracticeOutputEvent.Kind.keyUp(.leftShift), .keyUp(.w), .mouseUp(.right)].map { String(describing: $0) }))
        XCTAssertEqual(engine.practiceState, .neutral)
    }
    func testAutoTapRepeatsExplicitClickOncePerObservedOnCycleAndNoCatchupBurst() throws {
        let click = ProfileControl(payload: "MOUSE_LEFT_DOWN,MOUSE_LEFT_UP", autoTapEnabled: true)
        var engine = try ProfileInputEngine(profile: profile([click]))
        try engine.activate(click.id, at: 0)
        XCTAssertEqual(kinds(&engine), [.mouseDown(.left), .mouseUp(.left)])
        try engine.tick(at: 0.02); XCTAssertTrue(kinds(&engine).isEmpty)
        try engine.tick(at: 0.05); XCTAssertTrue(kinds(&engine).isEmpty)
        try engine.tick(at: 0.1); XCTAssertEqual(kinds(&engine), [.mouseDown(.left), .mouseUp(.left)])
        try engine.tick(at: 100.075); XCTAssertTrue(kinds(&engine).isEmpty)
        try engine.tick(at: 100.1); XCTAssertEqual(kinds(&engine), [.mouseDown(.left), .mouseUp(.left)])
        try engine.tick(at: 100.1); XCTAssertTrue(kinds(&engine).isEmpty)
    }
    func testTurboKeyboardReleaseGapAndClickReplayPreserveIndependentOwner() throws {
        let turbo = ProfileControl(payload: "W,MOUSE_LEFT_DOWN,MOUSE_LEFT_UP")
        let steady = ProfileControl(payload: "WAIT_0,W")
        var engine = try ProfileInputEngine(profile: profile([turbo, steady], turbo: true))
        try engine.begin(contact: 1, control: steady.id, at: 0)
        try engine.begin(contact: 2, control: turbo.id, at: 0); _ = kinds(&engine)
        try engine.tick(at: 0.011); XCTAssertTrue(kinds(&engine).isEmpty)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w])
        try engine.tick(at: 0.016)
        XCTAssertEqual(kinds(&engine), [.mouseDown(.left), .mouseUp(.left)])
    }
    func testBoundedEventQueueReportsOmissionsAndDrainKeepsSequenceMonotonic() throws {
        let click = ProfileControl(payload: "MOUSE_LEFT_DOWN,MOUSE_LEFT_UP")
        var engine = try ProfileInputEngine(profile: profile([click]))
        for index in 0..<130 {
            try engine.begin(contact: index, control: click.id, at: Double(index))
            try engine.end(contact: index, at: Double(index) + 0.1)
        }
        let batch = engine.drainPracticeEvents()
        XCTAssertEqual(batch.events.count, 256); XCTAssertEqual(batch.omittedCount, 4)
        XCTAssertEqual(batch.events.first?.sequence, 5); XCTAssertEqual(batch.events.last?.sequence, 260)
        XCTAssertEqual(engine.drainPracticeEvents(), .init(events: []))
        engine.releaseAll()
        let reset = engine.drainPracticeEvents()
        XCTAssertEqual(reset.events.first?.sequence, 261); XCTAssertEqual(reset.events.map(\.kind), [.reset])
    }
    func testDesktopClaimsNeverChangeSCX1ProjectionOtherThanExplicitControllerActions() throws {
        let mixed = ProfileControl(payload: "W,MOUSE_LEFT_DOWN,X360A,LT:0.4")
        var engine = try ProfileInputEngine(profile: profile([mixed]))
        try engine.begin(contact: 1, control: mixed.id, at: 0)
        XCTAssertEqual(engine.state.buttons, [.a, .leftTrigger])
        XCTAssertEqual(engine.practiceState.heldKeys, [.w]); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.left])
        let packet = BridgePacket(kind: .state, session: UUID().uuidString, sequence: 1, state: engine.state)
        let data = try BridgeCodec.encode(packet)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("heldKeys"))
    }
}

final class DirectionalInputEngineTests: XCTestCase {
    private func directional(retained: Bool = false) -> ProfileControl {
        var control = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: !retained), directionalEnabled: true)
        control.directionPayloads[.up] = .init(normalPayload: "W", boostPayload: "W,SHIFT", superBoostPayload: "W,SPACE")
        control.directionPayloads[.right] = .init(normalPayload: "D", boostPayload: "D,SHIFT", superBoostPayload: "D,SPACE")
        return control
    }
    private func profile(_ controls: [ProfileControl]) throws -> ControllerProfile {
        let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: placements, landscape: placements)
    }
    func testPureDirectionalEmitsNoAnalogAndHonorsExactStageBoundaries() throws {
        let stick = directional()
        var engine = try ProfileInputEngine(profile: profile([stick]))
        try engine.begin(contact: 1, control: stick.id, position: .init(y: 0.1), at: 0)
        XCTAssertEqual(engine.practiceState.heldKeys, [])
        try engine.move(contact: 1, position: .init(y: 0.5), at: 0.1)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w])
        try engine.move(contact: 1, position: .init(y: 0.75), at: 0.2)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w, .leftShift])
        try engine.move(contact: 1, position: .init(y: 0.751), at: 0.3)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w, .space])
        XCTAssertEqual(engine.state.leftStick, .zero); XCTAssertEqual(engine.state.rightStick, .zero)
    }
    func testStageTransitionKeepsCommonKeyWithoutFalseReleaseAndDiagonalClaimsUnion() throws {
        let stick = directional()
        var engine = try ProfileInputEngine(profile: profile([stick]))
        try engine.begin(contact: 1, control: stick.id, position: .init(y: 0.4), at: 0)
        _ = engine.drainPracticeEvents()
        try engine.move(contact: 1, position: .init(x: 0.6, y: 0.6), at: 0.1)
        XCTAssertEqual(Set(engine.drainPracticeEvents().events.map { String(describing: $0.kind) }), Set([PracticeOutputEvent.Kind.keyDown(.d), .keyDown(.leftShift)].map { String(describing: $0) }))
        try engine.move(contact: 1, position: .init(x: 0, y: 0.6), at: 0.2)
        XCTAssertEqual(engine.drainPracticeEvents().events.map(\.kind), [.keyUp(.d)])
        XCTAssertEqual(engine.practiceState.heldKeys, [.w, .leftShift])
    }
    func testDirectionalAndAnalogOnSameStoredChannelCoexistAndRetainIndependently() throws {
        let digital = directional(retained: true)
        let analog = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false))
        var engine = try ProfileInputEngine(profile: profile([digital, analog]))
        try engine.begin(contact: 1, control: analog.id, position: .init(x: 0.7), at: 0)
        try engine.begin(contact: 2, control: digital.id, position: .init(y: 0.4), at: 0.1)
        XCTAssertEqual(engine.state.leftStick.x, 0.7); XCTAssertEqual(engine.practiceState.heldKeys, [.w])
        try engine.end(contact: 1, at: 0.2); try engine.end(contact: 2, at: 0.3)
        XCTAssertEqual(Set(engine.retainedSticks.keys), [digital.id, analog.id])
        try engine.begin(contact: 3, control: analog.id, position: .init(x: -0.4), at: 0.4)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w]); XCTAssertEqual(engine.state.leftStick.x, -0.4)
    }
    func testTwoDirectionalInstancesContributeIndependentlyAndDuplicateFingerCannotTakeOver() throws {
        let first = directional(retained: true)
        var second = directional(retained: true); second.directionPayloads[.up]?.normalPayload = "A"
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.begin(contact: 1, control: first.id, position: .init(y: 0.4), at: 0)
        try engine.begin(contact: 2, control: second.id, position: .init(y: 0.4), at: 0)
        try engine.begin(contact: 3, control: second.id, position: .init(x: 0.4), at: 0)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w, .a])
        try engine.end(contact: 1, at: 0.1); try engine.end(contact: 2, at: 0.1)
        try engine.move(contact: 3, position: .init(x: 1), at: 0.2)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w, .a])
        XCTAssertEqual(Set(engine.retainedSticks.keys), [first.id, second.id])
    }
    func testRecenterClearsLiveAndRetainedDirectionalClaimsButKeepsIndependentButton() throws {
        let live = directional(), retained = directional(retained: true)
        let button = ProfileControl(payload: "W,MOUSE_RIGHT_DOWN")
        var engine = try ProfileInputEngine(profile: profile([live, retained, button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.begin(contact: 2, control: retained.id, position: .init(x: 0.4), at: 0)
        try engine.end(contact: 2, at: 0.1)
        try engine.begin(contact: 3, control: live.id, position: .init(y: 0.6), at: 0.1)
        engine.recenterSticks()
        XCTAssertEqual(engine.practiceState.heldKeys, [.w]); XCTAssertEqual(engine.practiceState.heldMouseButtons, [.right])
        XCTAssertTrue(engine.stickPositions.isEmpty); XCTAssertTrue(engine.retainedSticks.isEmpty)
        try engine.move(contact: 3, position: .init(y: 1), at: 0.2)
        XCTAssertEqual(engine.practiceState.heldKeys, [.w])
    }
    func testStickPlusKeepsAnalogWhileCustomDesktopStagesReplaceOnlyTheirOwnClaims() throws {
        var stick = directional(); stick.directionalEnabled = false; stick.stickBehavior.stickPlusEnabled = true
        let button = ProfileControl(payload: "SHIFT")
        var engine = try ProfileInputEngine(profile: profile([stick, button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.begin(contact: 2, control: stick.id, position: .init(y: 0.6), at: 0)
        try engine.move(contact: 2, position: .init(y: 1), at: 0.1)
        XCTAssertEqual(engine.state.leftStick.y, 1); XCTAssertEqual(engine.practiceState.heldKeys, [.w, .space, .leftShift])
    }
    func testDirectionalFallbackControllerMappingsRemainControllerOnlyWithZeroAnalog() throws {
        var stick = ProfileControl(kind: .rightStick, directionalEnabled: true)
        stick.stickBehavior.directions[.up]?.normalControls = [.a, .rightTrigger]
        var engine = try ProfileInputEngine(profile: profile([stick]))
        try engine.begin(contact: 1, control: stick.id, position: .init(y: 0.4), at: 0)
        XCTAssertEqual(engine.state.buttons, [.a, .rightTrigger]); XCTAssertEqual(engine.practiceState.rightTrigger, 1)
        XCTAssertEqual(engine.state.rightStick, .zero); XCTAssertFalse(stick.hasKeyboardOrMouseOutputs)
        XCTAssertEqual(stick.outputTargets, [.a, .rightTrigger])
    }
}

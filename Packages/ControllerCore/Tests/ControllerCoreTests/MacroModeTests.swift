import XCTest
@testable import ControllerCore

final class MacroModeTests: XCTestCase {
    private func profile(_ controls: [ProfileControl], turbo: Bool = false, hold: Bool = false) throws -> ControllerProfile {
        let places = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.3, y: 0.6)) }
        return try .init(controls: controls, portrait: places, landscape: places,
                         turboEnabled: turbo, turboIntervalMilliseconds: 200, globalHoldEnabled: hold)
    }
    private func macro(_ source: String) -> ProfileControl {
        ProfileControl(payload: source, macroModeEnabled: true)
    }
    func testDefaultTwoHundredCompletesAfterLiftAndNeverRepeatsWhileHeld() throws {
        let button = macro("X360A,X360B,X360X")
        var engine = try ProfileInputEngine(profile: profile([button], turbo: true, hold: true))
        try engine.begin(contact: 1, control: button.id, at: 0)
        XCTAssertEqual(engine.state.buttons, [.a, .b, .x])
        try engine.end(contact: 1, at: 0.01)
        XCTAssertEqual(engine.nextDeadline!, 0.2, accuracy: 0.00001)
        try engine.tick(at: 0.199)
        XCTAssertEqual(engine.state.buttons, [.a, .b, .x])
        try engine.tick(at: 0.2)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
        try engine.begin(contact: 2, control: button.id, at: 1)
        try engine.tick(at: 1.2)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 2)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.end(contact: 2, at: 2)
        try engine.begin(contact: 3, control: button.id, at: 3)
        XCTAssertEqual(engine.state.buttons, [.a, .b, .x])
    }
    func testTimedSequenceHasSeparateRepeatedPresses() throws {
        let button = macro("X360A(U100),X360A(D500)(U100),X360B(D800)(U100)")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.02)
        XCTAssertEqual(engine.state.buttons, [.a])
        for (time, expected) in [(0.1, Set<PadButton>()), (0.5, [.a]), (0.6, []), (0.8, [.b]), (0.9, [])] {
            try engine.tick(at: time)
            XCTAssertEqual(engine.state.buttons, expected)
        }
        XCTAssertNil(engine.nextDeadline)
    }
    func testKeyboardCombinationHasIndependentReleaseTimes() throws {
        let button = macro("CTRL(U300),ALT(U300),TAB(U100)")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        XCTAssertEqual(engine.practiceState.heldKeys, [.leftControl, .leftAlt, .tab])
        try engine.end(contact: 1, at: 0.01)
        try engine.tick(at: 0.1)
        XCTAssertEqual(engine.practiceState.heldKeys, [.leftControl, .leftAlt])
        try engine.tick(at: 0.3)
        XCTAssertTrue(engine.practiceState.heldKeys.isEmpty)
    }
    func testEqualDelaysRemainSimultaneousAndTriggerPulseKeepsAuthoredLength() throws {
        let button = macro("X360A(D300),X360B(D300),RT:0.7P0.4")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.01)
        try engine.tick(at: 0.299)
        XCTAssertEqual(engine.state.buttons, [.rightTrigger])
        try engine.tick(at: 0.3)
        XCTAssertEqual(engine.state.buttons, [.a, .b, .rightTrigger])
        try engine.tick(at: 0.4)
        XCTAssertEqual(engine.state.buttons, [.a, .b])
        try engine.tick(at: 0.5)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testExtraTapDoesNotQueueOrRestartAndOnlyOwnerReleasesSor() throws {
        let button = macro("X360A(U100),X360B(SOR)(D100)")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.begin(contact: 2, control: button.id, at: 0.02)
        try engine.end(contact: 2, at: 0.03)
        try engine.tick(at: 0.2)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.end(contact: 1, at: 0.3)
        try engine.tick(at: 0.4)
        XCTAssertEqual(engine.state.buttons, [.b])
        try engine.begin(contact: 3, control: button.id, at: 0.45)
        try engine.end(contact: 3, at: 0.46)
        try engine.tick(at: 0.6)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
        try engine.tick(at: 1)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testIgnoredPointerCancelPreservesRunButOwnerCancelStopsEverything() throws {
        let button = macro("X360A,X360B(D500)")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.begin(contact: 2, control: button.id, at: 0.01)
        try engine.cancel(contact: 2, at: 0.02)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.cancel(contact: 1, at: 0.03)
        try engine.tick(at: 1)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
        try engine.begin(contact: 3, control: button.id, at: 2)
        try engine.end(contact: 3, at: 2.01)
        try engine.tick(at: 2.5)
        XCTAssertEqual(engine.state.buttons, [.b])
    }
    func testScopedCleanupPreservesOtherOwnerAndReleaseAllStopsDelayedMacro() throws {
        let button = macro("X360A(U500),X360B(D600),X360X(SOR)")
        let other = ProfileControl(payload: "X360A")
        var engine = try ProfileInputEngine(profile: profile([button, other]))
        try engine.begin(contact: 1, control: other.id, at: 0)
        try engine.begin(contact: 2, control: button.id, at: 0)
        engine.releaseControls([button.id])
        try engine.tick(at: 0.8)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.begin(contact: 3, control: button.id, at: 1)
        try engine.end(contact: 3, at: 1.01)
        engine.releaseAll()
        try engine.tick(at: 2)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
    }
    func testAccessibilityActivationCompletesOneMacroIncludingReleaseAction() throws {
        let button = macro("X360A,X360B(SOR)(D100)")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.activate(button.id, at: 0)
        try engine.tick(at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.a, .b])
        try engine.tick(at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.b])
        try engine.tick(at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testOrdinaryReleaseShotKeepsExistingNinetyMillisecondDefault() throws {
        let button = ProfileControl(payload: "X360A(SOR)")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.tick(at: 0.19)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testNormalUHonorsEarlyLiftAndCapsHrd() throws {
        let button = ProfileControl(payload: "X360A(U100),X360B(U100)(HRD200),X360X(D300)(U100)")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.02)
        XCTAssertEqual(engine.state.buttons, [.b])
        try engine.tick(at: 0.1)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 0.4)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
    }
    func testRepeatUHasRequestedDutyCycleAndTurboKeepsLongPress() throws {
        let repeatButton = ProfileControl(payload: "RT:0.7(R100)(U20)")
        var engine = try ProfileInputEngine(profile: profile([repeatButton]))
        try engine.begin(contact: 1, control: repeatButton.id, at: 0)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0.7)
        try engine.tick(at: 0.02)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0)
        try engine.tick(at: 0.1)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0.7)
        try engine.end(contact: 1, at: 0.11)
        XCTAssertTrue(engine.state.isNeutral)
        let turbo = ProfileControl(payload: "X360A(U300)")
        engine = try ProfileInputEngine(profile: profile([turbo], turbo: true))
        try engine.begin(contact: 2, control: turbo.id, at: 0)
        try engine.tick(at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.tick(at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 0.4)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.tick(at: 0.65)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.tick(at: 0.7)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testOverlappingClaimsNeverReleaseAnIndependentHold() throws {
        let button = macro("X360A(U300),X360A(D100)(U300)")
        let other = ProfileControl(payload: "X360A")
        var engine = try ProfileInputEngine(profile: profile([button, other]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.01)
        try engine.begin(contact: 2, control: other.id, at: 0.2)
        try engine.tick(at: 0.4)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 2, at: 0.5)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testLateActivationGetsItsWholePressDuration() throws {
        for isMacro in [false, true] {
            let button = ProfileControl(payload: "X360A(D100)(U200)", macroModeEnabled: isMacro)
            var engine = try ProfileInputEngine(profile: profile([button]))
            try engine.begin(contact: 1, control: button.id, at: 0)
            if isMacro { try engine.end(contact: 1, at: 0.01) }
            try engine.tick(at: 0.25)
            XCTAssertEqual(engine.state.buttons, [.a])
            XCTAssertEqual(engine.nextDeadline!, 0.45, accuracy: 0.00001)
            try engine.tick(at: 0.44)
            XCTAssertEqual(engine.state.buttons, [.a])
            try engine.tick(at: 0.45)
            XCTAssertTrue(engine.state.isNeutral)
        }
    }
    func testLateReleaseShotGetsFullDurationAndDoesNotExtendHrd() throws {
        let button = macro("X360A(SOR)(D100)(U200)(HRD500)")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.1)
        try engine.tick(at: 0.5)
        XCTAssertEqual(engine.state.buttons, [.a])
        XCTAssertEqual(engine.nextDeadline!, 0.7, accuracy: 0.00001)
        try engine.tick(at: 0.7)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
    }
    func testLateRepeatingUUsesFullOnAndOffWindowsWithoutCatchup() throws {
        for turbo in [false, true] {
            let payload = turbo ? "X360A(D100)(U100)" : "X360A(D100)(R300)(U100)"
            let button = ProfileControl(payload: payload)
            var engine = try ProfileInputEngine(profile: profile([button], turbo: turbo))
            try engine.begin(contact: 1, control: button.id, at: 0)
            try engine.tick(at: 0.15)
            XCTAssertEqual(engine.state.buttons, [.a])
            if !turbo { XCTAssertEqual(engine.nextDeadline!, 0.25, accuracy: 0.00001) }
            try engine.tick(at: 0.2)
            XCTAssertEqual(engine.state.buttons, [.a])
            try engine.tick(at: 0.25)
            XCTAssertTrue(engine.state.isNeutral)
            try engine.tick(at: 0.9)
            XCTAssertEqual(engine.state.buttons, [.a])
            try engine.tick(at: 1.8)
            XCTAssertTrue(engine.state.isNeutral)
            try engine.end(contact: 1, at: 1.81)
            XCTAssertNil(engine.nextDeadline)
        }
    }
    func testTurboPressEqualToCadenceKeepsFutureTimerAndRestarts() throws {
        for duration in [200, 400] {
            let button = ProfileControl(payload: "X360A(U\(duration))")
            var engine = try ProfileInputEngine(profile: profile([button], turbo: true))
            let end = Double(duration) / 1000
            try engine.begin(contact: 1, control: button.id, at: 0)
            try engine.tick(at: end)
            XCTAssertTrue(engine.state.isNeutral)
            var next = try XCTUnwrap(engine.nextDeadline)
            XCTAssertGreaterThan(next, end)
            try engine.tick(at: next)
            // The ordinary Turbo run can have a bookkeeping edge before the
            // modified command's next ON window. Follow its real timer path.
            if engine.state.isNeutral {
                let following = try XCTUnwrap(engine.nextDeadline)
                XCTAssertGreaterThan(following, next)
                next = following
                try engine.tick(at: next)
            }
            XCTAssertEqual(engine.state.buttons, [.a])
            try engine.end(contact: 1, at: next + 0.01)
            XCTAssertTrue(engine.state.isNeutral)
        }
    }
    func testOrdinaryLiftCancelsUnobservedDelayedPressBeforeReleaseTail() throws {
        let button = ProfileControl(payload: "X360A(D100)(U100)(HRD200)")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
    }
    func testInvalidMacroAndReleaseSettingsFailBeforeAnyOutput() throws {
        for payload in ["", "X360A(R100)", "WAIT_100,X360A", "RELEASE_ALL", "MOUSE_LEFT_UP", "SCROLL_MODE_TOGGLE", "LT:0.0"] {
            XCTAssertThrowsError(try macro(payload).validate(), payload)
        }
        for payload in ["X360A(U0)", "X360A(U600001)", "X360A(U1.5)", "X360A(U100)(U200)", "X360A(U100)(R100)", "RT:1P0.5(U100)"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse(payload), payload)
        }
        var button = macro("X360A")
        button.buttonBehavior.holdToggle = true
        XCTAssertThrowsError(try button.validate())
        button.buttonBehavior.holdToggle = false
        button.autoTapEnabled = true
        XCTAssertThrowsError(try button.validate())
    }
}

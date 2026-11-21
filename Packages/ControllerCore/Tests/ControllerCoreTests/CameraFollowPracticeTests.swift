import XCTest
@testable import ControllerCore

final class CameraFollowPracticeTests: XCTestCase {
    func testActivationAtNonzeroUptimeUsesTheSameAbsoluteDeadlineAsScheduler() throws {
        var machine = try CameraFollowPracticeMachine(at: 10)
        try machine.setEnabled(true, at: 10)
        try machine.updateInputs(.init(leftStick: .init(x: 1)), at: 10)
        let activation = try XCTUnwrap(machine.nextDeadline)
        XCTAssertEqual(activation, 10.2)
        try machine.tick(at: activation)
        XCTAssertEqual(machine.snapshot.generatedRightStick, .zero)
        let ramp = try XCTUnwrap(machine.nextDeadline)
        XCTAssertGreaterThan(ramp, activation)
        try machine.tick(at: ramp)
        XCTAssertGreaterThan(machine.snapshot.generatedRightStick.x, 0)
    }
    private func active(x: Double = 0.8, y: Double = 0) throws -> CameraFollowPracticeMachine {
        var machine = try CameraFollowPracticeMachine()
        try machine.setEnabled(true, at: 0)
        try machine.updateInputs(.init(leftStick: .init(x: x, y: y)), at: 0)
        try machine.tick(at: 0.2); try machine.tick(at: 0.3)
        return machine
    }
    func testDisabledPreservesManualInputWithoutAssistance() throws {
        var m = try CameraFollowPracticeMachine()
        try m.updateInputs(.init(leftStick: .init(x: 1), manualRightStick: .init(x: 0.7, y: -0.4)), at: 0)
        try m.tick(at: 1)
        XCTAssertEqual(m.snapshot.rightStick, .init(x: 0.7, y: -0.4)); XCTAssertEqual(m.snapshot.source, .manual)
        XCTAssertEqual(m.snapshot.generatedRightStick, .zero); XCTAssertNil(m.nextDeadline)
    }
    func testMovementDeadzoneIsStrictAndBriefMovementCannotActivate() throws {
        var m = try CameraFollowPracticeMachine(); try m.setEnabled(true, at: 0)
        try m.updateInputs(.init(leftStick: .init(x: 0.2)), at: 0); try m.tick(at: 1)
        XCTAssertEqual(m.snapshot.rightStick, .zero); XCTAssertNil(m.nextDeadline)
        try m.updateInputs(.init(leftStick: .init(x: 0.8)), at: 1)
        try m.tick(at: 1.199); XCTAssertEqual(m.snapshot.rightStick, .zero)
        try m.updateInputs(.neutral, at: 1.199); try m.tick(at: 3)
        XCTAssertEqual(m.snapshot.rightStick, .zero)
    }
    func testActivationDelayDoesNotAccumulateRampTime() throws {
        var m = try CameraFollowPracticeMachine(); try m.setEnabled(true, at: 0)
        try m.updateInputs(.init(leftStick: .init(x: 1)), at: 0)
        XCTAssertEqual(m.nextDeadline, 0.2)
        try m.tick(at: 0.2); XCTAssertEqual(m.snapshot.rightStick, .zero)
        XCTAssertEqual(try XCTUnwrap(m.nextDeadline), 0.21, accuracy: 1e-12)
        try m.tick(at: 0.21); XCTAssertEqual(m.snapshot.rightStick.x, 0.025, accuracy: 1e-12)
        try m.tick(at: 0.38); XCTAssertEqual(m.snapshot.rightStick.x, 0.45, accuracy: 1e-12)
        XCTAssertNil(m.nextDeadline)
    }
    func testHorizontalResponseAndCeilingMatchOriginalReceiverDefaults() throws {
        var m = try active(x: 0.4); XCTAssertEqual(m.snapshot.rightStick.x, 0.22, accuracy: 1e-12)
        XCTAssertEqual(m.snapshot.rightStick.y, 0)
        XCTAssertEqual(m.snapshot.source, .cameraFollow)
        try m.updateInputs(.init(leftStick: .init(x: -1)), at: 0.3); try m.tick(at: 1)
        XCTAssertEqual(m.snapshot.rightStick, .init(x: -0.45))
    }
    func testCenteringRampsOutButExclusionClearsImmediately() throws {
        var m = try active(); let first = m.snapshot.rightStick.x
        try m.updateInputs(.neutral, at: 0.3); try m.tick(at: 0.31)
        XCTAssertGreaterThan(m.snapshot.rightStick.x, 0); XCTAssertLessThan(m.snapshot.rightStick.x, first)
        try m.tick(at: 0.5); XCTAssertEqual(m.snapshot.rightStick, .zero)
        m = try active(); try m.updateInputs(.init(leftStick: .init(x: 1), leftAllowsFollow: false), at: 0.31)
        XCTAssertEqual(m.snapshot.generatedRightStick, .zero); XCTAssertEqual(m.inputs.leftStick.x, 1)
        XCTAssertTrue(m.snapshot.requestedEnabled); XCTAssertNil(m.nextDeadline)
    }
    func testExcludedWinnerRestartsActivationWhenParticipatingSourceTakesOver() throws {
        var m = try active(); try m.updateInputs(.init(leftStick: .init(x: 1), leftAllowsFollow: false), at: 0.31)
        try m.updateInputs(.init(leftStick: .init(x: 1)), at: 0.5)
        try m.tick(at: 0.699); XCTAssertEqual(m.snapshot.rightStick, .zero)
        try m.tick(at: 0.71); XCTAssertEqual(m.snapshot.rightStick, .zero)
        try m.tick(at: 0.72); XCTAssertGreaterThan(m.snapshot.rightStick.x, 0)
    }
    func testManualRightPriorityAndExactReleaseTimeout() throws {
        var m = try active(); var input = m.inputs; input.manualRightStick = .init(x: 0.7, y: 0.2)
        try m.updateInputs(input, at: 0.31)
        XCTAssertEqual(m.snapshot.rightStick, input.manualRightStick); XCTAssertEqual(m.snapshot.source, .manual)
        input.manualRightStick = .zero; try m.updateInputs(input, at: 0.4)
        try m.tick(at: 1.149); XCTAssertEqual(m.snapshot.source, .manualOverride)
        try m.tick(at: 1.15); XCTAssertEqual(m.snapshot.rightStick, .zero)
        try m.tick(at: 1.25); XCTAssertGreaterThan(m.snapshot.rightStick.x, 0)
    }
    func testMacroRightHasPriorityOverManualAndFollowWithoutMutatingInputs() throws {
        var m = try active(); var input = m.inputs
        input.manualRightStick = .init(x: 0.6, y: 0.2); input.macroRightStick = .init(x: -1, y: 0.5)
        try m.updateInputs(input, at: 0.31)
        XCTAssertEqual(m.snapshot.rightStick, input.macroRightStick); XCTAssertEqual(m.snapshot.source, .macro)
        input.macroRightStick = .zero; try m.updateInputs(input, at: 0.32)
        XCTAssertEqual(m.snapshot.rightStick, input.manualRightStick); XCTAssertEqual(m.snapshot.source, .manual)
    }
    func testManualContactSuppressesEvenAtNeutralAndRestartsDelayOnLift() throws {
        var m = try active(); var input = m.inputs; input.manualRightContactActive = true
        try m.updateInputs(input, at: 0.31)
        XCTAssertTrue(m.snapshot.requestedEnabled); XCTAssertFalse(m.snapshot.effectiveEnabled)
        XCTAssertEqual(m.snapshot.source, .suppressed); XCTAssertEqual(m.snapshot.rightStick, .zero)
        input.manualRightContactActive = false; try m.updateInputs(input, at: 1)
        try m.tick(at: 1.199); XCTAssertEqual(m.snapshot.rightStick, .zero)
        try m.tick(at: 1.21); try m.tick(at: 1.22); XCTAssertGreaterThan(m.snapshot.rightStick.x, 0)
    }
    func testMouseAndManualSuppressionMustBothClearBeforeFollowResumes() throws {
        var m = try active(); var input = m.inputs
        input.mouseSuppressed = true; input.manualRightContactActive = true; try m.updateInputs(input, at: 0.31)
        input.manualRightContactActive = false; try m.updateInputs(input, at: 0.4); try m.tick(at: 2)
        XCTAssertFalse(m.snapshot.effectiveEnabled); XCTAssertEqual(m.snapshot.rightStick, .zero)
        input.mouseSuppressed = false; try m.updateInputs(input, at: 2)
        XCTAssertTrue(m.snapshot.effectiveEnabled); XCTAssertEqual(m.nextDeadline, 2.2)
    }
    func testLiveStrengthScalesGainCeilingAndReductionImmediately() throws {
        var m = try active(x: 1); try m.tick(at: 0.5)
        try m.setStrengthPercent(125, at: 0.5)
        XCTAssertEqual(m.snapshot.rightStick.x, 0.5625, accuracy: 1e-12)
        try m.setStrengthPercent(75, at: 0.5)
        XCTAssertEqual(m.snapshot.rightStick.x, 0.3375, accuracy: 1e-12)
        try m.updateInputs(.init(leftStick: .init(x: 0.4)), at: 0.5)
        try m.setStrengthPercent(125, at: 0.5); try m.tick(at: 1)
        XCTAssertEqual(m.snapshot.rightStick.x, 0.275, accuracy: 1e-12)
    }
    func testZeroStrengthKeepsToggleAndManualRightInput() throws {
        var m = try active(); try m.setStrengthPercent(0, at: 0.3)
        XCTAssertTrue(m.snapshot.requestedEnabled); XCTAssertEqual(m.snapshot.generatedRightStick, .zero)
        XCTAssertNil(m.nextDeadline)
        var input = m.inputs; input.manualRightStick = .init(x: 0.8); try m.updateInputs(input, at: 0.4)
        XCTAssertEqual(m.snapshot.rightStick.x, 0.8)
    }
    func testToggleOffAndDuplicateExplicitEnableDoNotLeaveOrRestartRamp() throws {
        var m = try active(); let before = m.snapshot.generatedRightStick
        try m.setEnabled(true, at: 0.3); XCTAssertEqual(m.snapshot.generatedRightStick, before)
        try m.toggle(at: 0.31); XCTAssertFalse(m.snapshot.requestedEnabled); XCTAssertEqual(m.snapshot.generatedRightStick, .zero)
        try m.setEnabled(false, at: 0.5); XCTAssertEqual(m.snapshot.rightStick, .zero)
    }
    func testClearInputsPreservesSourceToggleButNativeResetDisarms() throws {
        var m = try active(); try m.clearInputs(at: 0.4)
        XCTAssertTrue(m.snapshot.requestedEnabled); XCTAssertEqual(m.snapshot.rightStick, .zero); XCTAssertNil(m.nextDeadline)
        try m.setStrengthPercent(125, at: 0.4); try m.reset(at: 0.5)
        XCTAssertFalse(m.snapshot.requestedEnabled); XCTAssertEqual(m.snapshot.strengthPercent, 125)
        try m.updateInputs(.init(leftStick: .init(x: 1)), at: 0.6); try m.tick(at: 4)
        XCTAssertEqual(m.snapshot.rightStick, .zero)
    }
    func testLateFirstTickCannotReplayAccumulatedActivationRamp() throws {
        var m = try CameraFollowPracticeMachine(); try m.setEnabled(true, at: 0)
        try m.updateInputs(.init(leftStick: .init(x: 1)), at: 0); try m.tick(at: 100)
        XCTAssertEqual(m.snapshot.rightStick, .zero)
        XCTAssertEqual(try XCTUnwrap(m.nextDeadline), 100.01, accuracy: 1e-12)
        try m.tick(at: 100.01); XCTAssertEqual(m.snapshot.rightStick.x, 0.025, accuracy: 1e-10)
        try m.tick(at: 1e100); XCTAssertEqual(m.snapshot.rightStick.x, 0.45)
    }
    func testInvalidInputStrengthOrClockRejectsBeforeMutation() throws {
        var m = try active(); let before = m.snapshot
        XCTAssertThrowsError(try m.updateInputs(.init(leftStick: .init(x: .nan)), at: 10))
        XCTAssertThrowsError(try m.updateInputs(.init(macroRightStick: .init(y: 1.01)), at: 10))
        XCTAssertThrowsError(try m.setStrengthPercent(.infinity, at: 10))
        XCTAssertThrowsError(try m.setStrengthPercent(201, at: 10))
        XCTAssertThrowsError(try m.tick(at: 0.1)); XCTAssertThrowsError(try m.tick(at: .nan))
        XCTAssertEqual(m.snapshot, before)
        XCTAssertNoThrow(try m.tick(at: 0.31))
    }
    func testAlternateTuningDirectionAndSidewaysGateRemainBounded() throws {
        var m = try CameraFollowPracticeMachine(tuning: .init(rampInMilliseconds: 0, rampOutMilliseconds: 0,
                                                              invertDirection: true, allowSidewaysSteering: false))
        try m.setEnabled(true, at: 0); try m.updateInputs(.init(leftStick: .init(x: 1)), at: 0)
        try m.tick(at: 1); XCTAssertEqual(m.snapshot.rightStick, .zero)
        try m.updateInputs(.init(leftStick: .init(x: 1, y: 0.5)), at: 1)
        XCTAssertEqual(m.snapshot.rightStick, .init(x: -0.45))
        XCTAssertThrowsError(try CameraFollowPracticeMachine(tuning: .init(gain: .nan)))
        XCTAssertThrowsError(try CameraFollowPracticeMachine(tuning: .init(rampInMilliseconds: -1)))
    }
}

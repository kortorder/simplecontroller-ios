import Foundation
import XCTest
@testable import ControllerCore

final class ProfilePayloadEngineTests: XCTestCase {
    private func profile(_ controls: [ProfileControl], turbo: Bool = false, interval: Int = 16) throws -> ControllerProfile {
        let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: placements, landscape: placements,
                                     turboEnabled: turbo, turboIntervalMilliseconds: interval)
    }
    func testWaitDelaysFollowingStepsWhileEarlierHeldActionsRemain() throws {
        let button = ProfileControl(payload: "X360A, WAIT_1000, X360B, WAIT_500, RT:0.7")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 10)
        XCTAssertEqual(engine.state.buttons, [.a]); XCTAssertEqual(engine.nextDeadline, 11)
        try engine.tick(at: 10.999); XCTAssertEqual(engine.state.buttons, [.a])
        try engine.tick(at: 11); XCTAssertEqual(engine.state.buttons, [.a, .b])
        XCTAssertEqual(engine.nextDeadline, 11.5)
        try engine.tick(at: 11.5); XCTAssertEqual(engine.practiceState.rightTrigger, 0.7)
        try engine.end(contact: 1, at: 11.6)
        XCTAssertTrue(engine.state.isNeutral); XCTAssertNil(engine.nextDeadline)
    }
    func testNormalLiftWinsOverDueButUnprocessedWaitContinuation() throws {
        let button = ProfileControl(payload: "WAIT_100, RT:1P1")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.5)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 1)
        XCTAssertTrue(engine.state.isNeutral); XCTAssertNil(engine.nextDeadline)
    }
    func testStartedOrdinaryPulseSurvivesLiftButOtherActionsRelease() throws {
        let button = ProfileControl(payload: "X360A, RT:0.8P0.3")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.05)
        XCTAssertEqual(engine.state.buttons, [.rightTrigger])
        XCTAssertEqual(engine.practiceState.rightTrigger, 0.8)
        XCTAssertTrue(engine.activeControls.isEmpty); XCTAssertEqual(engine.outputControls, [button.id])
        XCTAssertEqual(engine.nextDeadline, 0.3)
        try engine.tick(at: 0.3)
        XCTAssertEqual(engine.practiceState, .neutral); XCTAssertTrue(engine.outputControls.isEmpty)
    }
    func testReleaseAllAndCancelAndApplyClearDetachedPulseAndPendingWait() throws {
        let button = ProfileControl(payload: "RT:1P1, WAIT_100, X360A")
        let profile = try profile([button])
        var engine = try ProfileInputEngine(profile: profile)
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.05)
        engine.releaseAll(); try engine.tick(at: 0.5)
        XCTAssertEqual(engine.practiceState, .neutral)
        try engine.begin(contact: 2, control: button.id, at: 1)
        try engine.handle(.cancelAll, at: 1.2)
        XCTAssertEqual(engine.practiceState, .neutral); XCTAssertNil(engine.nextDeadline)
        try engine.begin(contact: 3, control: button.id, at: 2)
        try engine.end(contact: 3, at: 2.05)
        try engine.apply(profile: profile); try engine.tick(at: 3)
        XCTAssertEqual(engine.practiceState, .neutral)
    }
    func testSharedPressureUsesMaximumAndRestoresLowerOwnerAfterPulseExpires() throws {
        let low = ProfileControl(payload: "RT:0.3"), high = ProfileControl(payload: "RT:0.9P0.3")
        var engine = try ProfileInputEngine(profile: profile([low, high]))
        try engine.begin(contact: 1, control: low.id, at: 0)
        try engine.begin(contact: 2, control: high.id, at: 0.1)
        try engine.end(contact: 2, at: 0.15)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0.9)
        try engine.tick(at: 0.4)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0.3)
        XCTAssertEqual(engine.outputControls, [low.id])
        try engine.end(contact: 1, at: 0.5)
        XCTAssertEqual(engine.practiceState, .neutral)
    }
    func testLaterPressureOnSameRunReplacesEarlierButNotAnotherOwner() throws {
        let changing = ProfileControl(payload: "LT:0.9, WAIT_100, LT:0.2"), other = ProfileControl(payload: "LT:0.4")
        var engine = try ProfileInputEngine(profile: profile([changing, other]))
        try engine.begin(contact: 1, control: changing.id, at: 0)
        try engine.begin(contact: 2, control: other.id, at: 0)
        try engine.tick(at: 0.1)
        XCTAssertEqual(engine.practiceState.leftTrigger, 0.4)
        try engine.end(contact: 2, at: 0.2)
        XCTAssertEqual(engine.practiceState.leftTrigger, 0.2)
    }
    func testZeroPressureCancelsEarlierPulseInSameRunButPreservesIndependentOwner() throws {
        let sequence = ProfileControl(payload: "RT:1P1, WAIT_100, RT:0"), other = ProfileControl(payload: "RT:0.3")
        var engine = try ProfileInputEngine(profile: profile([sequence, other]))
        try engine.begin(contact: 1, control: sequence.id, at: 0)
        try engine.begin(contact: 2, control: other.id, at: 0)
        XCTAssertEqual(engine.practiceState.rightTrigger, 1)
        try engine.tick(at: 0.1)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0.3)
        XCTAssertEqual(engine.outputControls, [other.id])
        try engine.end(contact: 2, at: 0.2)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0)
    }
    func testNewPulseReplacesSameRunContinuousPressureWithoutRestoringItAfterExpiration() throws {
        let sequence = ProfileControl(payload: "RT:0.8, WAIT_100, RT:0.4P0.2")
        let other = ProfileControl(payload: "RT:0.2")
        var engine = try ProfileInputEngine(profile: profile([sequence, other]))
        try engine.begin(contact: 1, control: sequence.id, at: 0)
        try engine.begin(contact: 2, control: other.id, at: 0)
        try engine.tick(at: 0.1)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0.4)
        try engine.tick(at: 0.301)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0.2)
        XCTAssertEqual(engine.outputControls, [other.id])
    }
    func testCurrentRunZeroCannotCancelEarlierDetachedPulseOfSameInstance() throws {
        let sequence = ProfileControl(payload: "RT:1P1, WAIT_100, RT:0")
        var engine = try ProfileInputEngine(profile: profile([sequence]))
        try engine.begin(contact: 1, control: sequence.id, at: 0)
        try engine.end(contact: 1, at: 0.05)
        try engine.begin(contact: 2, control: sequence.id, at: 0.1)
        try engine.tick(at: 0.2)
        XCTAssertEqual(engine.practiceState.rightTrigger, 1)
        try engine.tick(at: 1)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0)
    }
    func testSameChannelPulseReplacementDoesNotAffectOppositeChannel() throws {
        let sequence = ProfileControl(payload: "LT:0.6P1, RT:1P1, WAIT_100, RT:0.2P0.2")
        var engine = try ProfileInputEngine(profile: profile([sequence]))
        try engine.begin(contact: 1, control: sequence.id, at: 0)
        try engine.tick(at: 0.1)
        XCTAssertEqual(engine.practiceState.leftTrigger, 0.6); XCTAssertEqual(engine.practiceState.rightTrigger, 0.2)
        try engine.tick(at: 0.31)
        XCTAssertEqual(engine.practiceState.leftTrigger, 0.6); XCTAssertEqual(engine.practiceState.rightTrigger, 0)
    }
    func testDigitalTriggersProduceFullPressureAndChannelsStayIndependent() throws {
        let legacy = ProfileControl(actions: [.leftTrigger]), right = ProfileControl(payload: "RT:0.25")
        var engine = try ProfileInputEngine(profile: profile([legacy, right]))
        try engine.begin(contact: 1, control: legacy.id, at: 0)
        try engine.begin(contact: 2, control: right.id, at: 0)
        XCTAssertEqual(engine.practiceState.leftTrigger, 1); XCTAssertEqual(engine.practiceState.rightTrigger, 0.25)
        XCTAssertEqual(engine.state.buttons, [.leftTrigger, .rightTrigger])
    }
    func testLatchedPulseRepeatsHalfOnHalfOffAndWaitRunsOnlyOnce() throws {
        let button = ProfileControl(buttonBehavior: .init(holdToggle: true), payload: "WAIT_100, RT:1P0.3")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.activate(button.id, at: 0)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0); XCTAssertEqual(engine.nextDeadline, 0.1)
        try engine.tick(at: 0.1); XCTAssertEqual(engine.practiceState.rightTrigger, 1)
        try engine.tick(at: 0.25); XCTAssertEqual(engine.practiceState.rightTrigger, 0)
        XCTAssertEqual(engine.latchedControls, [button.id]); XCTAssertTrue(engine.outputControls.isEmpty)
        try engine.tick(at: 0.4); XCTAssertEqual(engine.practiceState.rightTrigger, 1)
        try engine.begin(contact: 1, control: button.id, at: 0.45)
        try engine.tick(at: 10)
        XCTAssertTrue(engine.state.isNeutral); XCTAssertNil(engine.nextDeadline)
    }
    func testHoldMaturationUsesDeadlineForSequenceStartEvenWithLateTick() throws {
        let button = ProfileControl(buttonBehavior: .init(holdToggle: true), payload: "WAIT_100, X360A")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.tick(at: 0.59); XCTAssertTrue(engine.state.isNeutral)
        XCTAssertEqual(engine.nextDeadline!, 0.6, accuracy: 0.000001)
        try engine.tick(at: 0.6); XCTAssertEqual(engine.state.buttons, [.a])
    }
    func testWaitProgramCancellationAndNewRunCannotRevivePreviousSteps() throws {
        let button = ProfileControl(payload: "WAIT_100, X360A")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.05)
        try engine.begin(contact: 2, control: button.id, at: 0.08)
        try engine.tick(at: 0.1); XCTAssertTrue(engine.state.isNeutral)
        XCTAssertEqual(engine.nextDeadline!, 0.18, accuracy: 0.000001)
        try engine.tick(at: 0.18); XCTAssertEqual(engine.state.buttons, [.a])
    }
    func testMultipleContactsOnSameInstanceDoNotRestartWaitProgram() throws {
        let button = ProfileControl(payload: "WAIT_100, X360A")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.begin(contact: 2, control: button.id, at: 0.05)
        try engine.end(contact: 1, at: 0.08)
        try engine.tick(at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 2, at: 0.2); XCTAssertTrue(engine.state.isNeutral)
    }
    func testTurboStartsImmediatelyBypassesHoldAndHasFiveMillisecondOwnGap() throws {
        let button = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        var engine = try ProfileInputEngine(profile: profile([button], turbo: true, interval: 16))
        try engine.begin(contact: 1, control: button.id, at: 0)
        XCTAssertEqual(engine.state.buttons, [.a]); XCTAssertTrue(engine.latchedControls.isEmpty)
        XCTAssertEqual(engine.nextDeadline!, 0.011, accuracy: 0.000001)
        try engine.tick(at: 0.011); XCTAssertTrue(engine.state.isNeutral)
        XCTAssertEqual(engine.activeControls, [button.id]); XCTAssertTrue(engine.outputControls.isEmpty)
        try engine.tick(at: 0.016); XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 1, at: 0.02); XCTAssertTrue(engine.state.isNeutral)
    }
    func testTurboCapsPressAtOneHundredMillisecondsForSlowInterval() throws {
        let button = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([button], turbo: true, interval: 200))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.tick(at: 0.1); XCTAssertTrue(engine.state.isNeutral)
        XCTAssertEqual(engine.nextDeadline!, 0.2, accuracy: 0.000001)
        try engine.tick(at: 0.2); XCTAssertEqual(engine.state.buttons, [.a])
    }
    func testTurboOffPhaseCannotReleaseAnIndependentSteadyOwner() throws {
        let steady = ProfileControl(payload: "X360A, WAIT_0"), turbo = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([steady, turbo], turbo: true))
        try engine.begin(contact: 1, control: steady.id, at: 0)
        try engine.begin(contact: 2, control: turbo.id, at: 0)
        try engine.tick(at: 0.012)
        XCTAssertEqual(engine.state.buttons, [.a]); XCTAssertEqual(engine.outputControls, [steady.id])
    }
    func testGlobalTurboSkipsWaitAndPulseProgramsWithoutBypassingTheirHold() throws {
        let button = ProfileControl(buttonBehavior: .init(holdToggle: true), payload: "RT:1P0.3")
        var engine = try ProfileInputEngine(profile: profile([button], turbo: true))
        try engine.begin(contact: 1, control: button.id, at: 0)
        XCTAssertTrue(engine.state.isNeutral); XCTAssertEqual(engine.pendingHoldDeadline, 0.5)
        try engine.tick(at: 0.5); XCTAssertEqual(engine.practiceState.rightTrigger, 1)
        try engine.tick(at: 0.65); XCTAssertEqual(engine.practiceState.rightTrigger, 0)
    }
    func testAutoTapTogglesImmediatelyPersistsAfterLiftAndUsesOwnPulseWidth() throws {
        let button = ProfileControl(actions: [.a], autoTapEnabled: true, autoTapIntervalMilliseconds: 100)
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.01)
        XCTAssertEqual(engine.state.buttons, [.a]); XCTAssertEqual(engine.latchedControls, [button.id])
        try engine.tick(at: 0.05); XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 0.1); XCTAssertEqual(engine.state.buttons, [.a])
        try engine.begin(contact: 2, control: button.id, at: 0.11)
        XCTAssertTrue(engine.state.isNeutral); XCTAssertTrue(engine.latchedControls.isEmpty)
        try engine.tick(at: 1); XCTAssertNil(engine.nextDeadline)
    }
    func testAutoTapIntervalAndGlobalTurboRemainDistinct() throws {
        let button = ProfileControl(payload: "LT:0.6", autoTapEnabled: true, autoTapIntervalMilliseconds: 200)
        var engine = try ProfileInputEngine(profile: profile([button], turbo: true, interval: 10))
        try engine.activate(button.id, at: 0)
        XCTAssertEqual(engine.nextDeadline!, 0.05, accuracy: 0.000001)
        try engine.tick(at: 0.049); XCTAssertEqual(engine.practiceState.leftTrigger, 0.6)
        try engine.tick(at: 0.05); XCTAssertEqual(engine.practiceState.leftTrigger, 0)
        XCTAssertEqual(engine.nextDeadline!, 0.2, accuracy: 0.000001)
    }
    func testLateClockComputesCurrentPhaseWithoutRestartingOrBacklog() throws {
        let button = ProfileControl(actions: [.a], autoTapEnabled: true, autoTapIntervalMilliseconds: 100)
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.activate(button.id, at: 0)
        try engine.tick(at: 86_400.075)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertEqual(engine.nextDeadline!, 86_400.1, accuracy: 0.000001)
        try engine.tick(at: 86_400.1); XCTAssertEqual(engine.state.buttons, [.a])
        engine.releaseAll(); try engine.tick(at: 86_401)
        XCTAssertTrue(engine.state.isNeutral); XCTAssertNil(engine.nextDeadline)
    }
    func testRepeatedQuickPulseTapsExtendOnlyTheirClaimAndStillRestoreOtherOwner() throws {
        let pulse = ProfileControl(payload: "RT:0.8P0.3"), held = ProfileControl(payload: "RT:0.2")
        var engine = try ProfileInputEngine(profile: profile([pulse, held]))
        try engine.begin(contact: 100, control: held.id, at: 0)
        for index in 0..<10 {
            let time = Double(index) * 0.02
            try engine.begin(contact: index, control: pulse.id, at: time)
            try engine.end(contact: index, at: time + 0.01)
        }
        try engine.tick(at: 0.47); XCTAssertEqual(engine.practiceState.rightTrigger, 0.8)
        try engine.tick(at: 0.48); XCTAssertEqual(engine.practiceState.rightTrigger, 0.2)
    }
    func testInvalidAndBackwardTimeLeaveTimedRunUnchanged() throws {
        let button = ProfileControl(payload: "WAIT_100, X360A")
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 1)
        for time in [0.9, .nan, .infinity] { XCTAssertThrowsError(try engine.tick(at: time)) }
        XCTAssertEqual(engine.nextDeadline, 1.1); XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 1.1); XCTAssertEqual(engine.state.buttons, [.a])
    }
}

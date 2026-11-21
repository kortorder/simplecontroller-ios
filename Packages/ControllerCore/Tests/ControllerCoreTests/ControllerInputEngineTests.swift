import Foundation
import XCTest
@testable import ControllerCore

final class ControllerInputEngineTests: XCTestCase {
    private func configured(hold: ControllerControlID? = nil, retained: Bool = false,
                            plus: Bool = false) throws -> ControllerBehaviors {
        var configuration = ControllerBehaviors.default
        if let hold { try configuration.setButton(.init(holdToggle: true), for: hold) }
        var stick = StickBehavior(autoCenter: !retained, stickPlusEnabled: plus, superBoostThreshold: 0.95)
        stick.directions[.up] = .init(boostControls: [.a], superBoostControls: [.b])
        stick.directions[.right] = .init(boostControls: [.x, .dpadRight], superBoostControls: [.y])
        try configuration.setStick(stick, for: .leftStick)
        try configuration.setStick(stick, for: .rightStick)
        return configuration
    }
    func testStartsNeutralAndMomentaryOwnersReleaseIndependently() throws {
        var engine = ControllerInputEngine()
        XCTAssertTrue(engine.state.isNeutral)
        try engine.begin(contact: 1, control: .a, at: 0)
        try engine.begin(contact: 2, control: .a, at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 1, at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 2, at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testConfiguredHoldShortTapProducesNoOutput() throws {
        var engine = ControllerInputEngine(configuration: try configured(hold: .a))
        try engine.begin(contact: 1, control: .a, at: 0)
        XCTAssertEqual(engine.pendingHoldDeadline, 0.5)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.end(contact: 1, at: 0.499)
        try engine.tick(at: 2)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
    }
    func testHoldLatchesAtExactThresholdAndSurvivesLift() throws {
        var engine = ControllerInputEngine(configuration: try configured(hold: .a))
        try engine.begin(contact: 1, control: .a, at: 0)
        try engine.tick(at: 0.499)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 0.5)
        XCTAssertEqual(engine.latchedControls, [.a])
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 1, at: 0.6)
        XCTAssertEqual(engine.state.buttons, [.a])
        XCTAssertNil(engine.nextDeadline)
    }
    func testEndAtThresholdLatchesEvenIfTimerWasDelayed() throws {
        var engine = ControllerInputEngine(configuration: try configured(hold: .a))
        try engine.begin(contact: 1, control: .a, at: 0)
        try engine.end(contact: 1, at: 0.5)
        XCTAssertEqual(engine.state.buttons, [.a])
    }
    func testNextTouchImmediatelyClearsAndCannotRelatchOnHoldOrLift() throws {
        var engine = ControllerInputEngine(configuration: try configured(hold: .a))
        try engine.activate(.a, at: 0)
        try engine.begin(contact: 1, control: .a, at: 0.1)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 5)
        try engine.end(contact: 1, at: 5.1)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.begin(contact: 2, control: .a, at: 5.2)
        try engine.tick(at: 5.7)
        XCTAssertEqual(engine.state.buttons, [.a])
    }
    func testConcurrentHoldFingersCannotRelatchAfterClearingTap() throws {
        var engine = ControllerInputEngine(configuration: try configured(hold: .a))
        try engine.begin(contact: 1, control: .a, at: 0)
        try engine.begin(contact: 2, control: .a, at: 0.1)
        try engine.tick(at: 0.5)
        try engine.begin(contact: 3, control: .a, at: 0.51)
        try engine.end(contact: 3, at: 0.52)
        try engine.tick(at: 3)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertTrue(engine.latchedControls.isEmpty)
        try engine.end(contact: 1, at: 3)
        try engine.end(contact: 2, at: 3)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testSecondFingerMustCompleteItsOwnHoldAfterFirstLeavesEarly() throws {
        var engine = ControllerInputEngine(configuration: try configured(hold: .a))
        try engine.begin(contact: 1, control: .a, at: 0)
        try engine.begin(contact: 2, control: .a, at: 0.4)
        try engine.end(contact: 1, at: 0.45)
        try engine.tick(at: 0.5)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.tick(at: 0.9)
        XCTAssertEqual(engine.state.buttons, [.a])
    }
    func testButtonSwipeTransfersOwnershipAndSupportsLeavingAndReentering() throws {
        var engine = ControllerInputEngine()
        try engine.begin(contact: 1, control: .a, at: 0)
        try engine.transfer(contact: 1, to: .b, at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.b])
        try engine.transfer(contact: 1, to: nil, at: 0.2)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.transfer(contact: 1, to: .a, at: 0.3)
        XCTAssertEqual(engine.state.buttons, [.a])
    }
    func testSwipeIntoHoldStartsFreshDeadlineAndLeavingCancelsPendingHold() throws {
        var engine = ControllerInputEngine(configuration: try configured(hold: .a))
        try engine.begin(contact: 1, control: .b, at: 0)
        try engine.transfer(contact: 1, to: .a, at: 0.2)
        XCTAssertEqual(engine.pendingHoldDeadline, 0.7)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.transfer(contact: 1, to: nil, at: 0.6)
        try engine.tick(at: 1)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testBothSticksAreIndependentAndDefaultToCenterOnLift() throws {
        var engine = ControllerInputEngine()
        try engine.begin(contact: 1, control: .leftStick, position: .init(x: 0.7), at: 0)
        try engine.begin(contact: 2, control: .rightStick, position: .init(y: -0.4), at: 0.1)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertEqual(engine.state.leftStick, .zero)
        XCTAssertEqual(engine.state.rightStick.y, -0.4)
        try engine.end(contact: 2, at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertTrue(engine.retainedSticks.isEmpty)
    }
    func testDisabledAutoCenterRetainsOnlyNormalEndAndRegrabReplacesPosition() throws {
        var engine = ControllerInputEngine(configuration: try configured(retained: true))
        try engine.begin(contact: 1, control: .leftStick, position: .init(x: 0.8), at: 0)
        try engine.end(contact: 1, at: 0.1)
        XCTAssertEqual(engine.retainedSticks[.leftStick]?.x, 0.8)
        XCTAssertEqual(engine.state.leftStick.x, 0.8)
        try engine.begin(contact: 2, control: .leftStick, position: .zero, at: 0.2)
        XCTAssertTrue(engine.retainedSticks.isEmpty)
        XCTAssertEqual(engine.state.leftStick, .zero)
        engine.releaseAll()
        try engine.end(contact: 2, at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testSecondFingerCannotTakeOverOrReleaseOccupiedStick() throws {
        var engine = ControllerInputEngine()
        try engine.begin(contact: 1, control: .leftStick, position: .init(x: 0.8), at: 0)
        try engine.begin(contact: 2, control: .leftStick, position: .init(x: -1), at: 0.1)
        try engine.move(contact: 2, position: .init(x: -1), at: 0.2)
        try engine.end(contact: 2, at: 0.3)
        XCTAssertEqual(engine.state.leftStick.x, 0.8)
    }
    func testBoostAndSuperThresholdBoundariesAreExclusive() throws {
        var engine = ControllerInputEngine(configuration: try configured(plus: true))
        try engine.begin(contact: 1, control: .leftStick, position: .init(y: 0.499), at: 0)
        XCTAssertTrue(engine.state.buttons.isEmpty)
        try engine.move(contact: 1, position: .init(y: 0.5), at: 0.1)
        XCTAssertTrue(engine.state.buttons.isEmpty)
        try engine.move(contact: 1, position: .init(y: 0.5001), at: 0.15)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.move(contact: 1, position: .init(y: 0.95), at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.move(contact: 1, position: .init(y: 0.9501), at: 0.25)
        XCTAssertEqual(engine.state.buttons, [.b])
        try engine.move(contact: 1, position: .init(y: 0.9), at: 0.3)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.move(contact: 1, position: .zero, at: 0.4)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testDiagonalStagesUseEachDirectionalAxisNotTotalMagnitude() throws {
        var engine = ControllerInputEngine(configuration: try configured(plus: true))
        try engine.begin(contact: 1, control: .leftStick, position: .init(x: 0.4, y: 0.4), at: 0)
        XCTAssertTrue(engine.state.buttons.isEmpty)
        try engine.move(contact: 1, position: .init(x: 0.6, y: 0.96), at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.b, .x])
        XCTAssertEqual(engine.state.dpad, .right)
    }
    func testNeutralDoesNotActivateZeroThresholdAndDirectionSignIsRespected() throws {
        var configuration = try configured(plus: true)
        var stick = configuration.stick(for: .leftStick)
        stick.boostThreshold = 0
        stick.directions[.down] = .init(boostControls: [.menu])
        try configuration.setStick(stick, for: .leftStick)
        var engine = ControllerInputEngine(configuration: configuration)
        try engine.begin(contact: 1, control: .leftStick, position: .zero, at: 0)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.move(contact: 1, position: .init(y: -0.2), at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.menu])
    }
    func testNormalStageDirectionalDeadzoneAndEmptySuperDoNotFallback() throws {
        var configuration = ControllerBehaviors.default
        var stick = StickBehavior(stickPlusEnabled: true)
        stick.directions[.up] = .init(normalControls: [.menu], boostControls: [.leftStickClick], superBoostControls: [])
        try configuration.setStick(stick, for: .leftStick)
        var engine = ControllerInputEngine(configuration: configuration)
        try engine.begin(contact: 1, control: .leftStick, position: .init(y: 0.1), at: 0)
        XCTAssertTrue(engine.state.buttons.isEmpty)
        try engine.move(contact: 1, position: .init(y: 0.1001), at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.menu])
        try engine.move(contact: 1, position: .init(y: 0.5), at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.menu])
        try engine.move(contact: 1, position: .init(y: 0.51), at: 0.3)
        XCTAssertEqual(engine.state.buttons, [.leftStick])
        try engine.move(contact: 1, position: .init(y: 1), at: 0.4)
        XCTAssertTrue(engine.state.buttons.isEmpty)
    }

    func testRetainedStickKeepsItsBoostUntilRecenter() throws {
        var engine = ControllerInputEngine(configuration: try configured(retained: true, plus: true))
        try engine.begin(contact: 1, control: .leftStick, position: .init(y: 1), at: 0)
        try engine.end(contact: 1, at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.b])
        engine.recenterSticks()
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertTrue(engine.retainedSticks.isEmpty)
    }
    func testRecenterKeepsIndependentMomentaryAndLatchedButtonOwners() throws {
        var engine = ControllerInputEngine(configuration: try configured(hold: .b, plus: true))
        try engine.begin(contact: 1, control: .a, at: 0)
        try engine.activate(.b, at: 0.1)
        try engine.begin(contact: 2, control: .leftStick, position: .init(y: 1), at: 0.2)
        engine.recenterSticks()
        XCTAssertEqual(engine.state.buttons, [.a, .b])
        XCTAssertEqual(engine.state.leftStick, .zero)
        try engine.end(contact: 1, at: 0.3)
        XCTAssertEqual(engine.state.buttons, [.b])
    }
    func testMappedOutputDoesNotStealOrdinaryButtonOwnership() throws {
        var engine = ControllerInputEngine(configuration: try configured(plus: true))
        try engine.begin(contact: 1, control: .a, at: 0)
        try engine.begin(contact: 2, control: .leftStick, position: .init(y: 0.7), at: 0.1)
        try engine.end(contact: 2, at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 1, at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testBothSticksShareBoostOwnershipUntilBothRelease() throws {
        var engine = ControllerInputEngine(configuration: try configured(plus: true))
        try engine.begin(contact: 1, control: .leftStick, position: .init(y: 0.7), at: 0)
        try engine.begin(contact: 2, control: .rightStick, position: .init(y: 0.7), at: 0.1)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 2, at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testMappedDpadAggregatesWithPhysicalDpadAndCancelsOpposites() throws {
        var engine = ControllerInputEngine(configuration: try configured(plus: true))
        try engine.begin(contact: 1, control: .leftStick, position: .init(x: 0.6), at: 0)
        try engine.begin(contact: 2, control: .dpadLeft, at: 0.1)
        XCTAssertEqual(engine.state.dpad, .neutral)
        try engine.end(contact: 2, at: 0.2)
        XCTAssertEqual(engine.state.dpad, .right)
    }
    func testReleaseAllClearsLatchesRetainedSticksPendingHoldsAndPulses() throws {
        var configuration = try configured(hold: .a, retained: true, plus: true)
        try configuration.setButton(.init(holdToggle: true), for: .x)
        var engine = ControllerInputEngine(configuration: configuration)
        try engine.activate(.a, at: 0)
        try engine.begin(contact: 1, control: .leftStick, position: .init(y: 1), at: 0)
        try engine.end(contact: 1, at: 0)
        try engine.begin(contact: 2, control: .x, at: 0)
        try engine.activate(.menu, at: 0)
        engine.releaseAll()
        try engine.tick(at: 5)
        try engine.end(contact: 2, at: 5)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertTrue(engine.latchedControls.isEmpty)
        XCTAssertTrue(engine.retainedSticks.isEmpty)
        XCTAssertNil(engine.nextDeadline)
    }
    func testConfigurationApplyClearsExistingRuntimeAndUsesNewBehavior() throws {
        var engine = ControllerInputEngine()
        try engine.begin(contact: 1, control: .a, at: 0)
        engine.apply(configuration: try configured(hold: .a))
        XCTAssertTrue(engine.state.isNeutral)
        try engine.begin(contact: 2, control: .a, at: 0.1)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertEqual(engine.pendingHoldDeadline, 0.6)
    }
    func testAccessibilityPulseExpiresWithoutReleasingPhysicalOwner() throws {
        var engine = ControllerInputEngine()
        try engine.begin(contact: 1, control: .a, at: 0)
        try engine.handle(.accessibilityActivate(.a), at: 0.1)
        XCTAssertEqual(engine.nextDeadline, 0.25)
        try engine.tick(at: 0.25)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.end(contact: 1, at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
    }
    func testAccessibilityHoldToggleActivatesAndClearsImmediately() throws {
        var engine = ControllerInputEngine(configuration: try configured(hold: .a))
        try engine.handle(.accessibilityActivate(.a), at: 0)
        XCTAssertEqual(engine.latchedControls, [.a])
        XCTAssertNil(engine.nextDeadline)
        try engine.handle(.accessibilityActivate(.a), at: 0.1)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testInvalidTimePositionAndDuplicateContactCannotMutateState() throws {
        var engine = ControllerInputEngine()
        try engine.begin(contact: 1, control: .leftStick, position: .init(x: 0.7), at: 1)
        let original = engine.state
        for time in [0.9, -.infinity, .infinity, .nan] {
            XCTAssertThrowsError(try engine.tick(at: time))
            XCTAssertEqual(engine.state, original)
        }
        for position in [StickPosition(x: .nan), .init(y: .infinity), .init(x: 1.1)] {
            XCTAssertThrowsError(try engine.move(contact: 1, position: position, at: 1.1))
            XCTAssertEqual(engine.state, original)
        }
        XCTAssertThrowsError(try engine.begin(contact: 1, control: .a, at: 1.1))
        XCTAssertEqual(engine.state, original)
    }
    func testCancelEventPreventsDelayedEndFromRetainingStick() throws {
        var engine = ControllerInputEngine(configuration: try configured(retained: true, plus: true))
        try engine.handle(.begin(contact: 1, control: .leftStick, position: .init(y: 1)), at: 0)
        try engine.handle(.cancelAll, at: 0.1)
        try engine.handle(.end(contact: 1), at: 0.2)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertTrue(engine.retainedSticks.isEmpty)
    }
}

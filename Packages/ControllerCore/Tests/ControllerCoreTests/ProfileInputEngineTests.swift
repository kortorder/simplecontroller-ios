import Foundation
import XCTest
@testable import ControllerCore

final class ProfileInputEngineTests: XCTestCase {
    private func profile(_ controls: [ProfileControl]) throws -> ControllerProfile {
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: positions, landscape: positions, swipeMode: .buttons)
    }
    private func stick(kind: ProfileControlKind = .leftStick, retained: Bool = false,
                       boost: ControllerControlID? = nil) -> ProfileControl {
        var behavior = StickBehavior(autoCenter: !retained, stickPlusEnabled: boost != nil)
        if let boost { behavior.directions[.up] = .init(normalControls: [.menu], boostControls: [boost], superBoostControls: [.b]) }
        return ProfileControl(kind: kind, stickBehavior: behavior)
    }
    func testTwoButtonsMappedToSameActionReleaseIndependently() throws {
        let first = ProfileControl(actions: [.a]), second = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.begin(contact: 1, control: first.id, at: 0)
        XCTAssertEqual(engine.activeControls, [first.id])
        try engine.begin(contact: 2, control: second.id, at: 0.1)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.a])
        XCTAssertEqual(engine.activeControls, [second.id])
        try engine.end(contact: 2, at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testOneButtonMapsMultipleActionsAndDpadWithOppositeCancellation() throws {
        let chord = ProfileControl(actions: [.a, .x, .dpadUp, .dpadRight])
        let opposite = ProfileControl(actions: [.dpadLeft])
        var engine = try ProfileInputEngine(profile: profile([chord, opposite]))
        try engine.begin(contact: 1, control: chord.id, at: 0)
        XCTAssertEqual(engine.state.buttons, [.a, .x])
        XCTAssertEqual(engine.state.dpad, .upRight)
        try engine.begin(contact: 2, control: opposite.id, at: 0.1)
        XCTAssertEqual(engine.state.dpad, .up)
    }
    func testLatchesArePerInstanceEvenWhenMappedOutputIsIdentical() throws {
        let first = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        let second = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.activate(first.id, at: 0)
        try engine.activate(second.id, at: 0.1)
        try engine.begin(contact: 1, control: first.id, at: 0.2)
        XCTAssertEqual(engine.latchedControls, [second.id])
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.tick(at: 2)
        try engine.end(contact: 1, at: 2)
        XCTAssertEqual(engine.latchedControls, [second.id])
    }
    func testHoldShortTapAndLateEndBoundaryMatchExistingBehavior() throws {
        let button = ProfileControl(actions: [.b], buttonBehavior: .init(holdToggle: true))
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.end(contact: 1, at: 0.49)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.begin(contact: 2, control: button.id, at: 1)
        try engine.end(contact: 2, at: 1.5)
        XCTAssertEqual(engine.latchedControls, [button.id])
        XCTAssertEqual(engine.state.buttons, [.b])
    }
    func testConcurrentFingersOnOneToggleCannotRelatchAfterClear() throws {
        let button = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.begin(contact: 2, control: button.id, at: 0.1)
        try engine.tick(at: 0.5)
        try engine.begin(contact: 3, control: button.id, at: 0.51)
        try engine.end(contact: 3, at: 0.52)
        try engine.tick(at: 4)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertTrue(engine.latchedControls.isEmpty)
    }
    func testSwipeBetweenInstancesStartsIndependentHoldDeadline() throws {
        let first = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        let second = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.begin(contact: 1, control: first.id, at: 0)
        try engine.transfer(contact: 1, to: second.id, at: 0.4)
        try engine.tick(at: 0.5)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertEqual(engine.pendingHoldDeadline, 0.9)
        try engine.tick(at: 0.9)
        XCTAssertEqual(engine.latchedControls, [second.id])
    }
    func testDuplicateStickSurfacesFirstLiveContactOwnsAnalogChannel() throws {
        let first = stick(), second = stick()
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.begin(contact: 1, control: first.id, position: .init(x: 0.8), at: 0)
        try engine.begin(contact: 2, control: second.id, position: .init(x: -1), at: 0.1)
        try engine.move(contact: 2, position: .init(x: -1), at: 0.2)
        XCTAssertEqual(engine.state.leftStick.x, 0.8)
        XCTAssertEqual(engine.activeControls, [first.id])
        XCTAssertNil(engine.stickPositions[second.id])
        try engine.end(contact: 2, at: 0.3)
        XCTAssertEqual(engine.state.leftStick.x, 0.8)
        try engine.end(contact: 1, at: 0.4)
        XCTAssertTrue(engine.state.isNeutral)
    }
    func testIgnoredHeldFingerCannotTakeOverAfterOriginalOwnerLifts() throws {
        let first = stick(), second = stick()
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.begin(contact: 1, control: first.id, position: .init(x: 1), at: 0)
        try engine.begin(contact: 2, control: second.id, position: .init(x: -1), at: 0.1)
        try engine.end(contact: 1, at: 0.2)
        try engine.move(contact: 2, position: .init(x: -1), at: 0.3)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.begin(contact: 3, control: second.id, position: .init(x: -0.7), at: 0.4)
        XCTAssertEqual(engine.state.leftStick.x, -0.7)
        try engine.end(contact: 2, at: 0.5)
        XCTAssertEqual(engine.state.leftStick.x, -0.7)
    }
    func testNewSurfaceReplacesRetainedOwnerAndItsBoostMapping() throws {
        let first = stick(retained: true, boost: .a), second = stick(retained: true, boost: .x)
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.begin(contact: 1, control: first.id, position: .init(y: 0.6), at: 0)
        try engine.end(contact: 1, at: 0.1)
        XCTAssertEqual(engine.retainedSticks[first.id]?.y, 0.6)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.begin(contact: 2, control: second.id, position: .init(y: 0.6), at: 0.2)
        XCTAssertNil(engine.retainedSticks[first.id])
        XCTAssertEqual(engine.state.buttons, [.x])
        try engine.end(contact: 2, at: 0.3)
        XCTAssertEqual(Set(engine.retainedSticks.keys), [second.id])
        XCTAssertEqual(engine.activeControls, [second.id])
    }
    func testLeftAndRightChannelsRemainIndependent() throws {
        let left = stick(), right = stick(kind: .rightStick)
        var engine = try ProfileInputEngine(profile: profile([left, right]))
        try engine.begin(contact: 1, control: left.id, position: .init(x: -0.7), at: 0)
        try engine.begin(contact: 2, control: right.id, position: .init(y: 0.9), at: 0.1)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertEqual(engine.state.leftStick, .zero)
        XCTAssertEqual(engine.state.rightStick.y, 0.9)
    }
    func testExclusiveStickStagesKeepIndependentButtonOwner() throws {
        let axis = stick(boost: .a), held = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([axis, held]))
        try engine.begin(contact: 1, control: held.id, at: 0)
        try engine.begin(contact: 2, control: axis.id, position: .init(y: 0.5), at: 0)
        XCTAssertEqual(engine.state.buttons, [.a, .menu])
        try engine.move(contact: 2, position: .init(y: 0.6), at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.a])
        try engine.move(contact: 2, position: .init(y: 0.76), at: 0.2)
        XCTAssertEqual(engine.state.buttons, [.a, .b])
        try engine.end(contact: 1, at: 0.3)
        XCTAssertEqual(engine.state.buttons, [.b])
    }
    func testRecenterTouchActsOnceAndKeepsIndependentButtons() throws {
        let axis = stick(retained: true), button = ProfileControl(actions: [.a])
        let latch = ProfileControl(actions: [.b], buttonBehavior: .init(holdToggle: true))
        let recenter = ProfileControl(kind: .recenter)
        var engine = try ProfileInputEngine(profile: profile([axis, button, latch, recenter]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.activate(latch.id, at: 0)
        try engine.begin(contact: 2, control: axis.id, position: .init(x: 1), at: 0)
        try engine.begin(contact: 3, control: recenter.id, at: 0.1)
        XCTAssertEqual(engine.state.leftStick, .zero)
        XCTAssertEqual(engine.state.buttons, [.a, .b])
        try engine.begin(contact: 4, control: axis.id, position: .init(x: 0.6), at: 0.2)
        try engine.move(contact: 3, position: .zero, at: 0.3)
        XCTAssertEqual(engine.state.leftStick.x, 0.6)
        try engine.end(contact: 2, at: 0.4)
        XCTAssertEqual(engine.state.leftStick.x, 0.6)
    }
    func testAccessibilityRecenterClearsRetainedStateWithoutGameAction() throws {
        let axis = stick(retained: true, boost: .a), recenter = ProfileControl(kind: .recenter)
        var engine = try ProfileInputEngine(profile: profile([axis, recenter]))
        try engine.begin(contact: 1, control: axis.id, position: .init(y: 0.6), at: 0)
        try engine.end(contact: 1, at: 0.1)
        try engine.handle(.accessibilityActivate(recenter.id), at: 0.2)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertTrue(engine.retainedSticks.isEmpty)
        XCTAssertEqual(engine.activeControls, [recenter.id])
        try engine.tick(at: 0.36)
        XCTAssertTrue(engine.activeControls.isEmpty)
    }
    func testSwipeOntoRecenterDoesNotTriggerDestructiveSideEffect() throws {
        let axis = stick(retained: true), button = ProfileControl(actions: [.a]), recenter = ProfileControl(kind: .recenter)
        var engine = try ProfileInputEngine(profile: profile([axis, button, recenter]))
        try engine.begin(contact: 1, control: axis.id, position: .init(x: 0.8), at: 0)
        try engine.end(contact: 1, at: 0)
        try engine.begin(contact: 2, control: button.id, at: 0.1)
        try engine.transfer(contact: 2, to: recenter.id, at: 0.2)
        XCTAssertEqual(engine.state.leftStick.x, 0.8)
        XCTAssertTrue(engine.state.buttons.isEmpty)
    }
    func testRecenterKeepsPendingHoldDeadline() throws {
        let button = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        let axis = stick()
        var engine = try ProfileInputEngine(profile: profile([button, axis]))
        try engine.begin(contact: 1, control: button.id, at: 0)
        try engine.begin(contact: 2, control: axis.id, position: .init(y: 1), at: 0.1)
        engine.recenterSticks()
        XCTAssertEqual(engine.pendingHoldDeadline, 0.5)
        try engine.tick(at: 0.5)
        XCTAssertEqual(engine.latchedControls, [button.id])
    }
    func testCancelClearsRetainedLatchedAndPendingStateAndLateEndCannotRevive() throws {
        let axis = stick(retained: true), button = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        var engine = try ProfileInputEngine(profile: profile([axis, button]))
        try engine.activate(button.id, at: 0)
        try engine.begin(contact: 1, control: axis.id, position: .init(y: 1), at: 0)
        try engine.handle(.cancelAll, at: 0.1)
        try engine.end(contact: 1, at: 0.2)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertTrue(engine.latchedControls.isEmpty)
        XCTAssertTrue(engine.retainedSticks.isEmpty)
        XCTAssertTrue(engine.activeControls.isEmpty)
        XCTAssertTrue(engine.stickPositions.isEmpty)
        XCTAssertNil(engine.nextDeadline)
    }
    func testApplyChangedMappingClearsRuntimeAndUsesNewActions() throws {
        let button = ProfileControl(actions: [.a])
        var original = try profile([button])
        var engine = try ProfileInputEngine(profile: original)
        try engine.begin(contact: 1, control: button.id, at: 0)
        original.controls[0].actions = [.b]
        try engine.apply(profile: original)
        XCTAssertTrue(engine.state.isNeutral)
        try engine.begin(contact: 2, control: button.id, at: 0.1)
        XCTAssertEqual(engine.state.buttons, [.b])
    }
    func testInvalidApplyRejectsBeforeChangingLiveRuntime() throws {
        let button = ProfileControl(actions: [.a])
        let original = try profile([button])
        var engine = try ProfileInputEngine(profile: original)
        try engine.begin(contact: 1, control: button.id, at: 0)
        var invalid = original; invalid.controls[0].diameter = -1
        XCTAssertThrowsError(try engine.apply(profile: invalid))
        XCTAssertEqual(engine.profile, original)
        XCTAssertEqual(engine.state.buttons, [.a])
        XCTAssertThrowsError(try ProfileInputEngine(profile: invalid))
    }
    func testInvalidInputAndUnknownControlsDoNotMutateState() throws {
        let button = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([button]))
        try engine.begin(contact: 1, control: button.id, at: 1)
        for time in [0.9, .nan, .infinity] { XCTAssertThrowsError(try engine.tick(at: time)) }
        XCTAssertThrowsError(try engine.move(contact: 1, position: .init(x: .nan), at: 1.1))
        XCTAssertThrowsError(try engine.begin(contact: 2, control: UUID(), at: 1.1))
        XCTAssertThrowsError(try engine.transfer(contact: 1, to: UUID(), at: 1.1))
        XCTAssertThrowsError(try engine.begin(contact: 1, control: button.id, at: 1.1))
        XCTAssertEqual(engine.state.buttons, [.a])
        XCTAssertEqual(engine.activeControls, [button.id])
    }
    func testAccessibilityPulsesWithSharedOutputHaveIndependentDeadlines() throws {
        let first = ProfileControl(actions: [.a]), second = ProfileControl(actions: [.a])
        var engine = try ProfileInputEngine(profile: profile([first, second]))
        try engine.activate(first.id, at: 0)
        try engine.activate(second.id, at: 0.1)
        try engine.tick(at: 0.15)
        XCTAssertEqual(engine.state.buttons, [.a])
        XCTAssertEqual(engine.activeControls, [second.id])
        try engine.tick(at: 0.25)
        XCTAssertTrue(engine.state.isNeutral)
        XCTAssertNil(engine.nextDeadline)
    }
}

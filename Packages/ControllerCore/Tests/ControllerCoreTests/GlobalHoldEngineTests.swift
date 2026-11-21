import XCTest
@testable import ControllerCore

final class GlobalHoldEngineTests: XCTestCase {
    private func engine(_ controls: [ProfileControl], enabled: Bool = true, turbo: Bool = false) throws -> ProfileInputEngine {
        var profile = try ControllerProfile(turboEnabled:turbo, globalHoldEnabled:enabled)
        for control in controls { try profile.addControl(control,toPage:profile.homePageID) }
        return try .init(profile:profile)
    }
    func testImmediateFireLiftRetainsAndNextTouchUnlatchesWithoutWaiting() throws {
        let a = ProfileControl(actions:[.a]); var e = try engine([a])
        try e.begin(contact:1,control:a.id,at:0)
        XCTAssertEqual(e.state.buttons,[.a]); XCTAssertEqual(e.latchedControls,[a.id]); XCTAssertNil(e.pendingHoldDeadline)
        try e.end(contact:1,at:0.01); XCTAssertEqual(e.state.buttons,[.a])
        try e.begin(contact:2,control:a.id,at:0.02)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty); XCTAssertFalse(e.activeControls.contains(a.id))
        try e.end(contact:2,at:0.03); try e.tick(at:20); XCTAssertTrue(e.state.isNeutral)
    }
    func testTwoFingersShareActivationAndFinalCancellationClearsOnlyItsOwner() throws {
        let a = ProfileControl(actions:[.a]), b = ProfileControl(actions:[.a,.b]); var e = try engine([a,b])
        try e.begin(contact:1,control:a.id,at:0); try e.begin(contact:2,control:a.id,at:0.01)
        XCTAssertEqual(e.latchedControls,[a.id])
        try e.begin(contact:3,control:b.id,at:0.02)
        try e.cancel(contact:1,at:0.03); XCTAssertEqual(e.state.buttons,[.a,.b]); XCTAssertTrue(e.latchedControls.contains(a.id))
        try e.cancel(contact:2,at:0.04); XCTAssertEqual(e.state.buttons,[.a,.b]); XCTAssertEqual(e.latchedControls,[b.id])
        try e.cancel(contact:3,at:0.05); XCTAssertTrue(e.state.isNeutral)
    }
    func testIndependentSameOutputLatchReleaseDoesNotReleaseOtherInstance() throws {
        let a = ProfileControl(actions:[.a]), b = ProfileControl(actions:[.a]); var e = try engine([a,b])
        try e.activate(a.id,at:0); try e.activate(b.id,at:0.01)
        try e.activate(a.id,at:0.02); XCTAssertEqual(e.state.buttons,[.a]); XCTAssertEqual(e.latchedControls,[b.id])
        try e.activate(b.id,at:0.03); XCTAssertTrue(e.state.isNeutral)
    }
    func testExplicitHoldToggleStillNeedsThreshold() throws {
        let a = ProfileControl(actions:[.a],buttonBehavior:.init(holdToggle:true,holdMilliseconds:500)); var e = try engine([a])
        try e.begin(contact:1,control:a.id,at:0); XCTAssertTrue(e.state.isNeutral)
        try e.end(contact:1,at:0.1); try e.tick(at:1); XCTAssertTrue(e.state.isNeutral)
        try e.begin(contact:2,control:a.id,at:2); try e.tick(at:2.5)
        XCTAssertEqual(e.state.buttons,[.a]); XCTAssertEqual(e.latchedControls,[a.id])
    }
    func testTurboOverridesGlobalHoldAndNormalLiftStopsIt() throws {
        let a = ProfileControl(actions:[.a]); var e = try engine([a],turbo:true)
        try e.begin(contact:1,control:a.id,at:0); XCTAssertTrue(e.latchedControls.isEmpty)
        try e.end(contact:1,at:0.1); try e.tick(at:10); XCTAssertTrue(e.state.isNeutral)
    }
    func testAutoTapRetainsItsOwnToggleAndOffPhase() throws {
        let a = ProfileControl(actions:[.a],autoTapEnabled:true,autoTapIntervalMilliseconds:100); var e = try engine([a])
        try e.begin(contact:1,control:a.id,at:0); try e.end(contact:1,at:0.01)
        try e.tick(at:0.06); XCTAssertTrue(e.state.isNeutral)
        try e.tick(at:0.1); XCTAssertEqual(e.state.buttons,[.a])
        try e.activate(a.id,at:0.11); try e.tick(at:5); XCTAssertTrue(e.state.isNeutral)
    }
    func testUnlatchBeforeOverdueWaitNeverFiresFutureAction() throws {
        let a = ProfileControl(payload:"X360A,WAIT_1000,X360B"); var e = try engine([a])
        try e.begin(contact:1,control:a.id,at:0); try e.end(contact:1,at:0.01)
        _ = e.drainPracticeEvents()
        try e.begin(contact:2,control:a.id,at:3)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
        try e.end(contact:2,at:3.01); try e.tick(at:100); XCTAssertTrue(e.state.isNeutral)
    }
    func testLatchedWaitContinuesAfterLiftButReleaseAllCancelsEveryDeadline() throws {
        let a = ProfileControl(payload:"X360A,WAIT_100,X360B"); var e = try engine([a])
        try e.begin(contact:1,control:a.id,at:0); try e.end(contact:1,at:0.01)
        try e.tick(at:0.1); XCTAssertEqual(e.state.buttons,[.a,.b])
        e.releaseAll(); XCTAssertNil(e.nextDeadline)
        try e.tick(at:10); XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
    }
    func testScrollToggleStaysImmediateLocalActionAndDoesNotLatch() throws {
        let a = ProfileControl(payload:"SCROLL_MODE_TOGGLE"); var e = try engine([a])
        try e.begin(contact:1,control:a.id,at:0); try e.end(contact:1,at:0.01)
        XCTAssertTrue(e.practiceState.scrollModeEnabled); XCTAssertTrue(e.latchedControls.isEmpty)
        try e.activate(a.id,at:0.02); XCTAssertFalse(e.practiceState.scrollModeEnabled)
    }
    func testApplyingProfileWithGlobalHoldDisabledClearsItsOldOwners() throws {
        let a = ProfileControl(actions:[.a]); var e = try engine([a])
        try e.activate(a.id,at:0); var profile = e.profile; profile.globalHoldEnabled = false
        try e.apply(profile:profile); XCTAssertTrue(e.state.isNeutral)
        try e.begin(contact:1,control:a.id,at:1); try e.end(contact:1,at:1.1)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
    }
}

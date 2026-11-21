import XCTest
@testable import ControllerCore

final class FixedStickEngineTests: XCTestCase {
    private func engine(_ controls: [ProfileControl], hold: Bool = false, turbo: Bool = false) throws -> ProfileInputEngine {
        var p = try ControllerProfile(turboEnabled: turbo, turboIntervalMilliseconds: 100, swipeMode: .controls, globalHoldEnabled: hold)
        for c in controls { try p.addControl(c, toPage: p.homePageID) }
        return try .init(profile: p)
    }
    private let pointer = ButtonPointerSample(x: 150, y: 100, width: 200, height: 200)
    func testParserCanonicalAliasesTargetsAndStrictInvalidCommands() throws {
        let p = try ControllerPayloadProgram.parse("ls:u25, RS:bl100, LS:right0, X360A")
        XCTAssertEqual(p.source, "LS:UP25, RS:BL100, LS:RIGHT0, X360A")
        XCTAssertEqual(p.outputTargets, [.leftStick, .rightStick, .a])
        for bad in ["LS:CENTER", "RS:DOWNLEFT", "LS:U-5", "RS:R0.5", "LS:U1000"] { XCTAssertThrowsError(try ControllerPayloadProgram.parse(bad), bad) }
        XCTAssertNoThrow(try p.validateSustained())
        XCTAssertNoThrow(try advancedButtonProgram("LS:UP"))
        XCTAssertNoThrow(try ringProgram("LS:UP"))
    }
    func testTwoChannelsNormalLiftAndIndependentZeroCommands() throws {
        let a = ProfileControl(payload: "LS:UR50, RS:BL25, X360A"), zero = ProfileControl(payload: "LS:U0, RS:R0")
        var e = try engine([a, zero]); try e.begin(contact: 1, control: a.id, at: 0)
        XCTAssertEqual(e.state.leftStick, .init(x: 0.5, y: 0.5)); XCTAssertEqual(e.state.rightStick, .init(x: -0.25, y: -0.25))
        try e.begin(contact: 2, control: zero.id, at: 0.1); XCTAssertEqual(e.state.leftStick, .init(x: 0.5, y: 0.5))
        try e.end(contact: 1, at: 0.2); XCTAssertTrue(e.state.isNeutral)
    }
    func testSameRunLaterDirectionAndZeroReplaceOnlyOwnedChannel() throws {
        let a = ProfileControl(payload: "LS:U50, WAIT_100, LS:R25, WAIT_100, LS:L0, X360B")
        var e = try engine([a]); try e.begin(contact: 1, control: a.id, at: 0)
        XCTAssertEqual(e.state.leftStick, .init(y: 0.5)); try e.tick(at: 0.1); XCTAssertEqual(e.state.leftStick, .init(x: 0.25))
        try e.tick(at: 0.2); XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.buttons, [.b])
    }
    func testFirstMacroWinsAndLosingWaitCannotSpringAlive() throws {
        let a = ProfileControl(payload: "LS:L"), b = ProfileControl(payload: "LS:R, X360B, WAIT_100, LS:UP")
        var e = try engine([a, b]); try e.begin(contact: 1, control: a.id, at: 0); try e.begin(contact: 2, control: b.id, at: 0.01)
        XCTAssertEqual(e.state.leftStick, .init(x: -1)); XCTAssertEqual(e.state.buttons, [.b])
        try e.end(contact: 1, at: 0.02); try e.tick(at: 1); XCTAssertEqual(e.state.leftStick, .zero)
        try e.end(contact: 2, at: 1.1); try e.begin(contact: 3, control: b.id, at: 1.2); XCTAssertEqual(e.state.leftStick, .init(x: 1))
    }
    func testLiveManualWinsAndLosingMacroNeedsNewActivation() throws {
        let stick = ProfileControl(kind: .leftStick), macro = ProfileControl(payload: "LS:R, X360A, WAIT_100, LS:U")
        var e = try engine([stick, macro]); try e.begin(contact: 1, control: stick.id, position: .init(x: -0.4), at: 0)
        try e.begin(contact: 2, control: macro.id, at: 0.01); XCTAssertEqual(e.state.leftStick, .init(x: -0.4)); XCTAssertEqual(e.state.buttons, [.a])
        try e.end(contact: 1, at: 0.02); try e.tick(at: 0.2); XCTAssertEqual(e.state.leftStick, .zero)
        try e.end(contact: 2, at: 0.3); try e.begin(contact: 3, control: macro.id, at: 0.4); XCTAssertEqual(e.state.leftStick, .init(x: 1))
    }
    func testLiveMacroBlocksManualAndDoesNotAdoptItsRejectedContactLater() throws {
        let stick = ProfileControl(kind: .leftStick), macro = ProfileControl(payload: "LS:R")
        var e = try engine([stick, macro]); try e.begin(contact: 1, control: macro.id, at: 0)
        try e.begin(contact: 2, control: stick.id, position: .init(x: -1), at: 0.01); XCTAssertFalse(e.isCapturedInputOwner(for: 2))
        try e.end(contact: 1, at: 0.02); try e.move(contact: 2, position: .init(y: 1), at: 0.03); XCTAssertEqual(e.state.leftStick, .zero)
    }
    func testMacroTakesRetainedManualAndLatchedMacroYieldsToNewManual() throws {
        let stick = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false)), macro = ProfileControl(payload: "LS:R")
        var e = try engine([stick, macro], hold: true)
        try e.begin(contact: 1, control: stick.id, position: .init(x: -1), at: 0); try e.end(contact: 1, at: 0.01)
        try e.begin(contact: 2, control: macro.id, at: 0.02); XCTAssertTrue(e.retainedSticks.isEmpty); XCTAssertEqual(e.state.leftStick, .init(x: 1))
        try e.end(contact: 2, at: 0.03); try e.begin(contact: 3, control: stick.id, position: .init(y: 0.5), at: 0.04)
        XCTAssertEqual(e.state.leftStick, .init(y: 0.5)); e.recenterSticks(); try e.tick(at: 10); XCTAssertEqual(e.state.leftStick, .zero)
    }
    func testRetainedMacroReplacedByAnotherMacroCannotReturnWhenNewOwnerEnds() throws {
        let a = ProfileControl(payload: "LS:L"), b = ProfileControl(payload: "LS:R")
        var e = try engine([a, b], hold: true); try e.begin(contact: 1, control: a.id, at: 0); try e.end(contact: 1, at: 0.01)
        try e.begin(contact: 2, control: b.id, at: 0.02); XCTAssertEqual(e.state.leftStick, .init(x: 1))
        try e.cancel(contact: 2, at: 0.03); try e.tick(at: 1); XCTAssertEqual(e.state.leftStick, .zero)
        XCTAssertTrue(e.latchedControls.contains(a.id))
    }
    func testButtonAimAndMacroHonorFirstLiveOwnerInBothOrders() throws {
        let aim = ProfileControl(payload: "X360A", buttonAim: .init(enabled: true, tuning: .init(output: .leftStick, origin: .controlCenter))), macro = ProfileControl(payload: "LS:L, X360B")
        var e = try engine([aim, macro]); try e.beginButton(contact: 1, control: aim.id, sample: pointer, at: 0)
        try e.begin(contact: 2, control: macro.id, at: 0.01); XCTAssertEqual(e.state.leftStick.x, 0.5)
        try e.endButton(contact: 1, finalSamples: [], at: 0.02); try e.tick(at: 1); XCTAssertEqual(e.state.leftStick, .zero)
        e.releaseAll(); try e.begin(contact: 3, control: macro.id, at: 2)
        try e.beginButton(contact: 4, control: aim.id, sample: pointer, at: 2.01); XCTAssertFalse(e.isCapturedInputOwner(for: 4)); XCTAssertEqual(e.state.leftStick, .init(x: -1))
    }
    func testTouchAimAndMacroHonorFirstLiveOwnerInBothOrders() throws {
        var aim = ProfileControl(kind: .touchAim); aim.touchAim.aim.output = .leftStick; aim.touchAim.aim.origin = .controlCenter; aim.touchAim.requiresLocalSetup = true
        let macro = ProfileControl(payload: "LS:L")
        let sample = TouchAimSample(pointer: pointer, metrics: .init(), elapsed: 0)
        var e = try engine([aim, macro]); try e.beginTouchAim(contact: 1, control: aim.id, sample: sample, at: 0)
        try e.moveTouchAimBatch(contact: 1, samples: [.init(pointer: pointer, metrics: .init(), elapsed: 0.005)], at: 0.005)
        try e.begin(contact: 2, control: macro.id, at: 0.01); XCTAssertEqual(e.state.leftStick.x, 0.5)
        try e.end(contact: 1, at: 0.02); try e.tick(at: 1); XCTAssertEqual(e.state.leftStick, .zero)
        e.releaseAll(); try e.begin(contact: 3, control: macro.id, at: 2)
        try e.beginTouchAim(contact: 4, control: aim.id, sample: sample, at: 2.01); XCTAssertFalse(e.isCapturedInputOwner(for: 4)); XCTAssertEqual(e.state.leftStick, .init(x: -1))
    }
    func testTurboOffReleasesAnalogAndManualTakeoverPreventsLaterMacroRevival() throws {
        let macro = ProfileControl(payload: "LS:R"), stick = ProfileControl(kind: .leftStick)
        var e = try engine([macro, stick], turbo: true); try e.begin(contact: 1, control: macro.id, at: 0)
        try e.tick(at: 0.095); XCTAssertEqual(e.state.leftStick, .zero)
        try e.begin(contact: 2, control: stick.id, position: .init(y: 1), at: 0.096); try e.tick(at: 0.1); XCTAssertEqual(e.state.leftStick, .init(y: 1))
        try e.end(contact: 2, at: 0.11); try e.tick(at: 10); XCTAssertEqual(e.state.leftStick, .zero)
    }
    func testAutoTapOffAndRecenterCannotRestartFixedOutput() throws {
        let macro = ProfileControl(payload: "LS:R, X360A", autoTapEnabled: true, autoTapIntervalMilliseconds: 100)
        var e = try engine([macro]); try e.begin(contact: 1, control: macro.id, at: 0); try e.end(contact: 1, at: 0.01)
        try e.tick(at: 0.05); XCTAssertEqual(e.state.leftStick, .zero)
        try e.tick(at: 0.1); XCTAssertEqual(e.state.leftStick, .init(x: 1)); e.recenterSticks()
        try e.tick(at: 1); XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.buttons, [.a])
        try e.activate(macro.id, at: 1.01); try e.activate(macro.id, at: 1.02); XCTAssertEqual(e.state.leftStick, .init(x: 1))
    }
    func testCancellationScopedReleaseProfileChangeAndEarlyLiftClearClaims() throws {
        let a = ProfileControl(payload: "LS:R, WAIT_100, RS:U"), b = ProfileControl(payload: "X360B")
        var e = try engine([a, b]); try e.begin(contact: 1, control: a.id, at: 0); try e.begin(contact: 2, control: b.id, at: 0.01)
        try e.cancel(contact: 1, at: 1); XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.rightStick, .zero); XCTAssertEqual(e.state.buttons, [.b])
        try e.begin(contact: 3, control: a.id, at: 2); e.releaseControls([a.id]); try e.tick(at: 3); XCTAssertEqual(e.state.leftStick, .zero)
        try e.begin(contact: 4, control: a.id, at: 4); try e.end(contact: 4, at: 5); XCTAssertEqual(e.state.rightStick, .zero)
        try e.begin(contact: 5, control: a.id, at: 6); try e.apply(profile: e.profile); try e.tick(at: 10); XCTAssertTrue(e.state.isNeutral)
    }
    func testReleaseAllStandaloneValidationDirectOnlyAndBypassesOverdueWork() throws {
        let release = ProfileControl(payload: "RELEASE_ALL"), a = ProfileControl(payload: "W, WAIT_100, SPACE, LS:U")
        XCTAssertTrue(try release.payloadProgram().isReleaseAll); XCTAssertFalse(release.acceptsSwipeEntry)
        XCTAssertThrowsError(try ControllerPayloadProgram.parse("X360A, RELEASE_ALL"))
        XCTAssertThrowsError(try ProfileControl(payload: "RELEASE_ALL", autoTapEnabled: true).validate())
        XCTAssertThrowsError(try ProfileControl(buttonBehavior: .init(holdToggle: true), payload: "RELEASE_ALL").validate())
        var e = try engine([release, a], hold: true); try e.begin(contact: 1, control: a.id, at: 0)
        _ = e.drainPracticeEvents(); try e.begin(contact: 2, control: release.id, at: 10)
        XCTAssertEqual(e.practiceState, .neutral); XCTAssertNil(e.nextDeadline); XCTAssertTrue(e.latchedControls.isEmpty)
        XCTAssertFalse(e.drainPracticeEvents().events.contains { $0.kind == .keyDown(.space) })
        try e.tick(at: 20); XCTAssertEqual(e.state, .neutral)
        try e.begin(contact: 3, control: a.id, at: 21); try e.activate(release.id, at: 22); XCTAssertEqual(e.practiceState, .neutral)
    }
    func testControlsSwipeCanReleaseOwnOrdinaryMacroIntoManualButNotLatchedClaim() throws {
        let macro = ProfileControl(payload: "LS:R"), stick = ProfileControl(kind: .leftStick)
        var e = try engine([macro, stick]); try e.begin(contact: 1, control: macro.id, at: 0)
        XCTAssertTrue(try e.handoff(contact: 1, to: stick.id, arrivingStickPosition: .init(y: 0.5), at: 0.1))
        XCTAssertEqual(e.state.leftStick, .init(y: 0.5)); try e.end(contact: 1, at: 0.2); XCTAssertEqual(e.state.leftStick, .zero)
        e = try engine([macro, stick], hold: true); try e.begin(contact: 1, control: macro.id, at: 0)
        XCTAssertFalse(try e.handoff(contact: 1, to: stick.id, at: 0.1)); XCTAssertEqual(e.state.leftStick, .init(x: 1))
    }
    func testRingAndMacroShareFirstLiveOwnershipAndRetainedTakeover() throws {
        let macro = ProfileControl(payload: "LS:L, X360B")
        var p = try engine([macro]).profile
        let zone = FloatingRingZone(portraitGeometry: .init(canvasWidth: 700, canvasHeight: 900, zone: .init(x: 0, y: 0, width: 700, height: 900)))
        p.pages[0].floatingRingZones = [zone]
        var e = try ProfileInputEngine(profile: p)
        let bounds = FloatingRect(x: 0, y: 0, width: 700, height: 900), session = UUID()
        XCTAssertTrue(try e.beginFloatingRing(contact: 1, zoneID: zone.id, sessionID: session, point: .init(x: 300, y: 300), usable: bounds, at: 0))
        try e.begin(contact: 2, control: macro.id, at: 0.1); XCTAssertEqual(e.state.leftStick, .zero); XCTAssertEqual(e.state.buttons, [.b])
        try e.cancelFloatingRing(contact: 1, sessionID: session, at: 0.2); try e.tick(at: 1); XCTAssertEqual(e.state.leftStick, .zero)
        e.releaseAll(); try e.begin(contact: 3, control: macro.id, at: 2)
        XCTAssertTrue(try e.beginFloatingRing(contact: 4, zoneID: zone.id, sessionID: UUID(), point: .init(x: 300, y: 300), usable: bounds, at: 2.1))
        XCTAssertEqual(e.state.leftStick, .init(x: -1)); XCTAssertNotNil(e.floatingRingStates[zone.id]?.issue)
        // A deliberately retained macro can be replaced by a new ring, with no later resurrection.
        p.globalHoldEnabled = true; try e.apply(profile: p)
        try e.begin(contact: 5, control: macro.id, at: 3); try e.end(contact: 5, at: 3.1)
        let next = UUID(); XCTAssertTrue(try e.beginFloatingRing(contact: 6, zoneID: zone.id, sessionID: next, point: .init(x: 300, y: 300), usable: bounds, at: 3.2))
        XCTAssertEqual(e.state.leftStick, .zero); try e.cancelFloatingRing(contact: 6, sessionID: next, at: 3.3)
        try e.tick(at: 10); XCTAssertEqual(e.state.leftStick, .zero)
    }

}

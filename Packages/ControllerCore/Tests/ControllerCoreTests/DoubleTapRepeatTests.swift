import Foundation
import XCTest
@testable import ControllerCore

final class DoubleTapRepeatTests: XCTestCase {
    private func button(hold: Bool = true) -> ProfileControl {
        .init(actions: [.a], buttonBehavior: .init(holdToggle: hold, holdMilliseconds: 500),
              autoTapIntervalMilliseconds: 100, doubleTapRepeatEnabled: true)
    }
    private func profile(_ controls: [ProfileControl], turbo: Bool = false, globalHold: Bool = false) throws -> ControllerProfile {
        let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: placements, landscape: placements,
                                     turboEnabled: turbo, swipeMode: .controls, globalHoldEnabled: globalHold)
    }
    private func tap(_ e: inout ProfileInputEngine, _ b: ProfileControl, at time: Double, contact: Int = 1) throws {
        try e.begin(contact: contact, control: b.id, at: time)
        try e.end(contact: contact, at: time + 0.05)
    }
    private func repeatOn(_ e: inout ProfileInputEngine, _ b: ProfileControl) throws {
        try tap(&e, b, at: 0); try tap(&e, b, at: 0.15, contact: 2)
    }
    func testSingleTapIsMomentaryAndDoesNotStartAnyRepeat() throws {
        let b = button(); var e = try ProfileInputEngine(profile: profile([b]))
        try e.begin(contact: 1, control: b.id, at: 0)
        XCTAssertEqual(e.state.buttons, [.a])
        try e.end(contact: 1, at: 0.1)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
        try e.tick(at: 5); XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
    }
    func testHoldLatchKeepsSteadyPressAndNextTouchOnlyStops() throws {
        let b = button(); var e = try ProfileInputEngine(profile: profile([b]))
        try e.begin(contact: 1, control: b.id, at: 0)
        try e.tick(at: 0.499); XCTAssertFalse(e.latchedControls.contains(b.id))
        try e.tick(at: 0.5); XCTAssertTrue(e.latchedControls.contains(b.id))
        try e.end(contact: 1, at: 0.6)
        try e.tick(at: 2); XCTAssertEqual(e.state.buttons, [.a]); XCTAssertNil(e.nextDeadline)
        try e.begin(contact: 2, control: b.id, at: 3)
        XCTAssertTrue(e.state.isNeutral)
        try e.tick(at: 4); try e.end(contact: 2, at: 4.1)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
    }
    func testDoubleTapStartsRepeatWithRealInitialGapAndFiftyFiftyCycle() throws {
        let b = button(); var e = try ProfileInputEngine(profile: profile([b]))
        try repeatOn(&e, b)
        XCTAssertTrue(e.latchedControls.contains(b.id)); XCTAssertTrue(e.state.isNeutral)
        XCTAssertEqual(e.nextDeadline!, 0.25, accuracy: 1e-8)
        try e.tick(at: 0.249); XCTAssertTrue(e.state.isNeutral)
        try e.tick(at: 0.25); XCTAssertEqual(e.state.buttons, [.a])
        try e.tick(at: 0.299); XCTAssertEqual(e.state.buttons, [.a])
        try e.tick(at: 0.3); XCTAssertTrue(e.state.isNeutral)
        try e.tick(at: 0.35); XCTAssertEqual(e.state.buttons, [.a])
        try e.tick(at: 0.4); XCTAssertTrue(e.state.isNeutral)
        try e.tick(at: 0.45); XCTAssertEqual(e.state.buttons, [.a])
    }
    func testTapStopsRepeatAndCannotBecomeHoldOrAnotherDoubleTap() throws {
        let b = button(); var e = try ProfileInputEngine(profile: profile([b]))
        try repeatOn(&e, b); try e.tick(at: 0.25)
        try e.begin(contact: 3, control: b.id, at: 0.26)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
        try e.tick(at: 1); try e.end(contact: 3, at: 1.1)
        XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline)
        try tap(&e, b, at: 1.2, contact: 4)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
    }
    func testLongSecondTouchChoosesSteadyHoldInsteadOfRepeat() throws {
        let b = button(); var e = try ProfileInputEngine(profile: profile([b]))
        try tap(&e, b, at: 0)
        try e.begin(contact: 2, control: b.id, at: 0.15)
        try e.tick(at: 0.65); try e.end(contact: 2, at: 0.7)
        try e.tick(at: 1)
        XCTAssertEqual(e.state.buttons, [.a]); XCTAssertTrue(e.latchedControls.contains(b.id)); XCTAssertNil(e.nextDeadline)
    }
    func testSlowSecondTapAndOverlongTapDoNotStartRepeat() throws {
        let b = button(hold: false)
        for (start, duration) in [(0.351, 0.05), (0.15, 0.251)] {
            var e = try ProfileInputEngine(profile: profile([b]))
            try tap(&e, b, at: 0)
            try e.begin(contact: 2, control: b.id, at: start)
            try e.end(contact: 2, at: start + duration)
            XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty); XCTAssertNil(e.nextDeadline)
        }
    }
    func testGlobalHoldAndTurboDoNotChangeOptInGestures() throws {
        let b = button(); var e = try ProfileInputEngine(profile: profile([b], turbo: true, globalHold: true))
        try e.begin(contact: 1, control: b.id, at: 0)
        try e.tick(at: 0.1); XCTAssertEqual(e.state.buttons, [.a])
        try e.end(contact: 1, at: 0.15); XCTAssertTrue(e.state.isNeutral)
        try tap(&e, b, at: 0.2, contact: 2)
        XCTAssertTrue(e.latchedControls.contains(b.id))
        try e.tick(at: 0.3); XCTAssertEqual(e.state.buttons, [.a])
        try e.tick(at: 0.35); XCTAssertTrue(e.state.isNeutral)
    }
    func testSimultaneousFingersCannotCountAsDoubleTap() throws {
        let b = button(); var e = try ProfileInputEngine(profile: profile([b]))
        try e.begin(contact: 1, control: b.id, at: 0)
        try e.begin(contact: 2, control: b.id, at: 0.01)
        try e.end(contact: 1, at: 0.05); try e.end(contact: 2, at: 0.06)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
        try tap(&e, b, at: 0.15, contact: 3)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
    }
    func testRepeatOffGapsAndStopPreserveIndependentOwner() throws {
        let b = button(), other = ProfileControl(actions: [.a])
        var e = try ProfileInputEngine(profile: profile([b, other]))
        try e.begin(contact: 9, control: other.id, at: 0)
        try repeatOn(&e, b)
        XCTAssertEqual(e.state.buttons, [.a])
        try e.tick(at: 0.3); XCTAssertEqual(e.state.buttons, [.a])
        try e.begin(contact: 3, control: b.id, at: 0.31)
        XCTAssertEqual(e.state.buttons, [.a])
        try e.end(contact: 3, at: 0.32); try e.end(contact: 9, at: 0.33)
        XCTAssertTrue(e.state.isNeutral)
    }
    func testSlidingIntoButtonDoesNotCountAsSecondTap() throws {
        let b = button(), other = ProfileControl(actions: [.b])
        var e = try ProfileInputEngine(profile: profile([b, other]))
        try tap(&e, b, at: 0)
        try e.begin(contact: 2, control: other.id, at: 0.1)
        XCTAssertTrue(try e.handoff(contact: 2, to: b.id, at: 0.15))
        XCTAssertEqual(e.state.buttons, [.a])
        try e.end(contact: 2, at: 0.2)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
        try tap(&e, b, at: 0.25, contact: 3)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
    }
    func testTerminalCleanupCancelsRepeatAndFirstTapMemory() throws {
        let b = button()
        for scoped in [false, true] {
            var e = try ProfileInputEngine(profile: profile([b]))
            try repeatOn(&e, b)
            if scoped { e.releaseControls([b.id]) } else { e.releaseAll() }
            try e.tick(at: 2)
            XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline); XCTAssertTrue(e.latchedControls.isEmpty)
            try tap(&e, b, at: 3)
            if scoped { e.releaseControls([b.id]) } else { e.releaseAll() }
            try tap(&e, b, at: 3.15, contact: 2)
            XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
        }
    }
    func testCancellationCannotMatureOverdueHoldOrDoubleTap() throws {
        let b = button(); var e = try ProfileInputEngine(profile: profile([b]))
        try tap(&e, b, at: 0)
        try e.begin(contact: 2, control: b.id, at: 0.15)
        try e.cancel(contact: 2, at: 5)
        XCTAssertTrue(e.state.isNeutral); XCTAssertNil(e.nextDeadline); XCTAssertTrue(e.latchedControls.isEmpty)
        try tap(&e, b, at: 6, contact: 3)
        XCTAssertTrue(e.state.isNeutral); XCTAssertTrue(e.latchedControls.isEmpty)
    }
    func testOriginalHoldToggleStillDelaysOutputAndAutoTapStillStartsOnOneTap() throws {
        var old = button(); old.doubleTapRepeatEnabled = false
        var e = try ProfileInputEngine(profile: profile([old]))
        try e.begin(contact: 1, control: old.id, at: 0); XCTAssertTrue(e.state.isNeutral)
        try e.end(contact: 1, at: 0.1); XCTAssertTrue(e.state.isNeutral)
        var auto = ProfileControl(actions: [.b], autoTapEnabled: true)
        auto.autoTapIntervalMilliseconds = 100
        e = try ProfileInputEngine(profile: profile([auto]))
        try tap(&e, auto, at: 0)
        XCTAssertTrue(e.latchedControls.contains(auto.id))
        try e.tick(at: 0.1); XCTAssertEqual(e.state.buttons, [.b])
    }
    func testInvalidCombinationsAreRejectedWithoutChangingOldFormats() throws {
        var b = button(); b.autoTapEnabled = true; XCTAssertThrowsError(try b.validate())
        b = button(); b.macroModeEnabled = true; XCTAssertThrowsError(try b.validate())
        b = button(); b.buttonAim.enabled = true; XCTAssertThrowsError(try b.validate())
        for payload in ["X360A(U100)", "X360A,WAIT_100", "RT:1.0P0.1", "RELEASE_ALL", "LS:R50"] {
            b = button(); b.payload = payload; XCTAssertThrowsError(try b.validate(), payload)
        }
    }
    func testFormat23RoundTripOmissionAndVersion22Migration() throws {
        let b = button(); let p = try profile([b])
        let library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p])
        let encoded = try ControllerProfileLibraryCodec.encode(library)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(encoded), library)
        XCTAssertEqual(library.version, ControllerProfileLibrary.currentVersion)
        var format23 = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        format23["version"] = 23
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: format23)), library)
        var old = b; old.doubleTapRepeatEnabled = false
        let oldData = try JSONEncoder().encode(old)
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        XCTAssertNil(oldJSON["doubleTapRepeatEnabled"]); XCTAssertNil(oldJSON["centerLeftStickBeforePress"])
        let oldProfile = try profile([old])
        let oldLibrary = try ControllerProfileLibrary(activeProfileID: oldProfile.id, profiles: [oldProfile])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(oldLibrary)) as? [String: Any])
        json["version"] = 22
        let migrated = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.activeProfile, oldProfile)
        XCTAssertFalse(migrated.activeProfile.controls[0].doubleTapRepeatEnabled)
        var unsupported = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        unsupported["version"] = 22
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: unsupported)))
    }
    func testCenterHookRunsForMacroRestartAfterUnobservedCompletion() throws {
        let stick = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false))
        let pickup = ProfileControl(payload: "X360LB(D50)(U150)", macroModeEnabled: true, centerLeftStickBeforePress: true)
        var e = try ProfileInputEngine(profile: profile([stick, pickup]))
        try e.begin(contact: 1, control: stick.id, position: .init(x: 0.7), at: 0)
        try e.end(contact: 1, at: 0.05)
        try e.begin(contact: 2, control: pickup.id, at: 0.1)
        XCTAssertEqual(e.state.leftStick, .zero)
        try e.end(contact: 2, at: 0.11)
        try e.begin(contact: 3, control: stick.id, position: .init(x: 0.8), at: 0.2)
        try e.end(contact: 3, at: 0.21)
        XCTAssertGreaterThan(e.state.leftStick.x, 0)
        // The old macro expires at .30, but no timer tick is delivered before this tap.
        try e.begin(contact: 4, control: pickup.id, at: 0.8)
        XCTAssertEqual(e.state.leftStick, .zero)
        XCTAssertFalse(e.state.buttons.contains(.leftBumper))
        try e.tick(at: 0.85)
        XCTAssertEqual(e.state.leftStick, .zero); XCTAssertTrue(e.state.buttons.contains(.leftBumper))
    }
    func testDifferentAcceptedSurfacesBreakConsecutiveTapSequence() throws {
        let b = button()
        let ordinary = ProfileControl(actions: [.b])
        let stick = ProfileControl(kind: .leftStick)
        let pad = ProfileControl(kind: .touchpad)
        let aim = ProfileControl(buttonAim: .init(enabled: true))
        let touchAim = ProfileControl(kind: .touchAim)
        for other in [ordinary, stick, pad, aim, touchAim] {
            var e = try ProfileInputEngine(profile: profile([b, other]))
            try tap(&e, b, at: 0)
            if other.isTouchpad { try e.beginTouchpad(contact: 2, control: other.id, at: 0.1) }
            else if other.isTouchAim {
                try e.beginTouchAim(contact: 2, control: other.id,
                                    sample: .init(pointer: .init(x: 50, y: 50, width: 100, height: 100), metrics: .init(majorRadius: 1), elapsed: 0), at: 0.1)
            } else { try e.begin(contact: 2, control: other.id, at: 0.1) }
            XCTAssertTrue(e.isCapturedInputOwner(for: 2))
            try e.end(contact: 2, at: 0.12)
            try tap(&e, b, at: 0.15, contact: 3)
            XCTAssertFalse(e.latchedControls.contains(b.id), "Intervening \(other.kind) entry must break double tap")
            try e.tick(at: 0.25)
            XCTAssertFalse(e.state.buttons.contains(.a))
        }
    }
    func testAcceptedRingEntryBreaksTapSequence() throws {
        let b = button(); var p = try profile([b])
        let zone = FloatingRingZone(portraitGeometry: .init(canvasWidth: 700, canvasHeight: 900,
                                    zone: .init(x: 0, y: 0, width: 700, height: 900)), config: .init())
        p.pages[0].floatingRingZones = [zone]
        var e = try ProfileInputEngine(profile: p)
        try tap(&e, b, at: 0)
        let session = UUID()
        XCTAssertTrue(try e.beginFloatingRing(contact: 2, zoneID: zone.id, sessionID: session,
                                             point: .init(x: 300, y: 300), usable: .init(x: 0, y: 0, width: 700, height: 900), at: 0.1))
        try e.endFloatingRing(contact: 2, sessionID: session, at: 0.12)
        try tap(&e, b, at: 0.15, contact: 3)
        XCTAssertFalse(e.latchedControls.contains(b.id))
    }
    func testRejectedCompetingTouchAndExistingContactMoveKeepTapSequence() throws {
        let b = button(), stick = ProfileControl(kind: .rightStick)
        let blocked = ProfileControl(buttonAim: .init(enabled: true, tuning: .init(output: .rightStick)))
        var e = try ProfileInputEngine(profile: profile([b, stick, blocked]))
        try e.begin(contact: 9, control: stick.id, position: .init(x: 0.3), at: 0)
        try tap(&e, b, at: 0.01)
        try e.move(contact: 9, position: .init(x: 0.6), at: 0.1)
        try e.beginButton(contact: 2, control: blocked.id, sample: .init(x: 22, y: 22, width: 44, height: 44), at: 0.12)
        XCTAssertNil(e.capturedControl(for: 2))
        try tap(&e, b, at: 0.15, contact: 3)
        XCTAssertTrue(e.latchedControls.contains(b.id))
        try e.tick(at: 0.25); XCTAssertTrue(e.state.buttons.contains(.a))
    }
    func testInterveningAcceptedTouchDuringSecondPressCancelsRepeatCandidate() throws {
        let b = button(), other = ProfileControl(actions: [.b])
        var e = try ProfileInputEngine(profile: profile([b, other]))
        try tap(&e, b, at: 0)
        try e.begin(contact: 2, control: b.id, at: 0.15)
        try e.begin(contact: 3, control: other.id, at: 0.17)
        try e.end(contact: 3, at: 0.18); try e.end(contact: 2, at: 0.2)
        XCTAssertFalse(e.latchedControls.contains(b.id)); XCTAssertTrue(e.state.isNeutral)
    }
}

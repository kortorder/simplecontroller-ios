import Foundation
import XCTest
@testable import ControllerCore

final class ProfileSwipeRouterTests: XCTestCase {
    private func profile(_ controls: [ProfileControl], _ mode: ProfileSwipeMode = .controls) throws -> ControllerProfile {
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: positions, landscape: positions, swipeMode: mode)
    }
    func testOffCapturesEveryOriginalKindAcrossGapsAndOtherControls() throws {
        let controls = [ProfileControl(), ProfileControl(kind: .leftStick), ProfileControl(kind: .touchpad)]
        var router = try ProfileSwipeRouter(profile: profile(controls, .off))
        for (contact, control) in controls.enumerated() {
            try router.begin(contact: contact, control: control.id, at: 0)
            XCTAssertEqual(try router.decision(contact: contact, hitControls: [], at: 0), .moveCurrent)
            XCTAssertEqual(try router.decision(contact: contact, hitControls: [controls[(contact + 1) % 3].id], at: 0), .moveCurrent)
            XCTAssertEqual(router.currentControl(for: contact), control.id)
        }
    }
    func testButtonsReleasesThroughGapReentersImmediatelyAndCapturesSurfaces() throws {
        let a = ProfileControl(), b = ProfileControl(), stick = ProfileControl(kind: .leftStick), pad = ProfileControl(kind: .touchpad)
        var router = try ProfileSwipeRouter(profile: profile([a, b, stick, pad], .buttons))
        try router.begin(contact: 1, control: a.id, at: 0)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [], at: 0.01), .transfer(to: nil))
        try router.accept(contact: 1, target: nil, at: 0.01)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [b.id], at: 0.02), .transfer(to: b.id))
        try router.accept(contact: 1, target: b.id, at: 0.02)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [a.id], at: 0.03), .transfer(to: a.id))
        try router.accept(contact: 1, target: a.id, at: 0.03)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [b.id], at: 0.04), .transfer(to: b.id))
        for (contact, control) in [stick, pad].enumerated() {
            try router.begin(contact: contact + 2, control: control.id, at: 0.1)
            XCTAssertEqual(try router.decision(contact: contact + 2, hitControls: [a.id], at: 0.1), .moveCurrent)
        }
    }
    func testButtonIngressFlagDoesNotBlockDirectTouchOrSwipeOut() throws {
        let blocked = ProfileControl(swipeActivationEnabled: false), allowed = ProfileControl()
        for mode in [ProfileSwipeMode.buttons, .controls] {
            var router = try ProfileSwipeRouter(profile: profile([blocked, allowed], mode))
            try router.begin(contact: 1, control: blocked.id, at: 0)
            XCTAssertEqual(try router.decision(contact: 1, hitControls: [blocked.id], at: 0), .moveCurrent)
            XCTAssertEqual(try router.decision(contact: 1, hitControls: [allowed.id], at: 0), .transfer(to: allowed.id))
            try router.accept(contact: 1, target: allowed.id, at: 0)
            XCTAssertEqual(try router.decision(contact: 1, hitControls: [blocked.id], at: 0.2), mode == .buttons ? .transfer(to: nil) : .hold)
        }
    }
    func testAcrossControlsCurrentContainmentWinsEvenBehindAnOverlappingTarget() throws {
        let a = ProfileControl(), b = ProfileControl()
        var router = try ProfileSwipeRouter(profile: profile([a, b]))
        try router.begin(contact: 1, control: a.id, at: 0)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [b.id, a.id], at: 0.01), .moveCurrent)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [], at: 0.02), .hold)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [b.id], at: 0.03), .transfer(to: b.id))
        XCTAssertEqual(router.currentControl(for: 1), a.id)
        try router.accept(contact: 1, target: b.id, at: 0.03)
        XCTAssertEqual(router.currentControl(for: 1), b.id)
    }
    func testOnlyAcceptedEntryStartsGlobalDestinationCooldownAndEndDoesNotEraseIt() throws {
        let a = ProfileControl(), b = ProfileControl()
        var router = try ProfileSwipeRouter(profile: profile([a, b]))
        try router.begin(contact: 1, control: a.id, at: 0)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [b.id], at: 0), .transfer(to: b.id))
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [b.id], at: 0.001), .transfer(to: b.id))
        try router.accept(contact: 1, target: b.id, at: 0.001)
        router.end(contact: 1)
        try router.begin(contact: 2, control: a.id, at: 0.002)
        XCTAssertEqual(try router.decision(contact: 2, hitControls: [b.id], at: 0.120), .hold)
        XCTAssertEqual(try router.decision(contact: 2, hitControls: [b.id], at: 0.121), .transfer(to: b.id))
        try router.accept(contact: 2, target: b.id, at: 0.121)
        router.reset()
        try router.begin(contact: 3, control: a.id, at: 0)
        XCTAssertEqual(try router.decision(contact: 3, hitControls: [b.id], at: 0), .transfer(to: b.id))
    }
    func testDirectBeginDoesNotConsumeCooldown() throws {
        let a = ProfileControl(), b = ProfileControl()
        var router = try ProfileSwipeRouter(profile: profile([a, b]))
        try router.begin(contact: 1, control: b.id, at: 0); router.end(contact: 1)
        try router.begin(contact: 2, control: a.id, at: 0.001)
        XCTAssertEqual(try router.decision(contact: 2, hitControls: [b.id], at: 0.001), .transfer(to: b.id))
    }
    func testPadKeepsTrackingPathThroughGapDisabledTargetAndCooldown() throws {
        let pad = ProfileControl(kind: .touchpad), blocked = ProfileControl(swipeActivationEnabled: false), a = ProfileControl()
        var router = try ProfileSwipeRouter(profile: profile([pad, blocked, a]))
        try router.begin(contact: 1, control: pad.id, at: 0)
        for hits in [[], [blocked.id]] {
            XCTAssertEqual(try router.decision(contact: 1, hitControls: hits, at: 0), .moveCurrent)
        }
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [a.id], unavailableControls: [a.id], at: 0), .moveCurrent)
        try router.begin(contact: 2, control: blocked.id, at: 0)
        _ = try router.decision(contact: 2, hitControls: [a.id], at: 0)
        try router.accept(contact: 2, target: a.id, at: 0)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [a.id], at: 0.01), .moveCurrent)
    }
    func testLocalActionsAreDirectOnlyAndCannotBecomeSwipeDestinations() throws {
        let a = ProfileControl(), recenter = ProfileControl(kind: .recenter), scroll = ProfileControl(payload: "SCROLL_MODE_TOGGLE")
        var router = try ProfileSwipeRouter(profile: profile([a, recenter, scroll]))
        try router.begin(contact: 1, control: a.id, at: 0)
        for (contact, local) in [recenter, scroll].enumerated() {
            XCTAssertEqual(try router.decision(contact: 1, hitControls: [local.id], at: 0), .hold)
            try router.begin(contact: contact + 2, control: local.id, at: 0)
            XCTAssertEqual(try router.decision(contact: contact + 2, hitControls: [a.id], at: 0), .moveCurrent)
        }
    }
    func testOccupiedAnalogChannelAndPadAreBlockedWhileDirectionalInstanceIsIndependent() throws {
        let a = ProfileControl(), left = ProfileControl(kind: .leftStick), copy = ProfileControl(kind: .leftStick)
        let directional = ProfileControl(kind: .leftStick, directionalEnabled: true), pad = ProfileControl(kind: .touchpad)
        var router = try ProfileSwipeRouter(profile: profile([a, left, copy, directional, pad]))
        try router.begin(contact: 1, control: a.id, at: 0)
        try router.begin(contact: 2, control: left.id, at: 0)
        try router.begin(contact: 3, control: pad.id, at: 0)
        for id in [left.id, copy.id, pad.id] {
            XCTAssertEqual(try router.decision(contact: 1, hitControls: [id], at: 0), .hold)
        }
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [directional.id], at: 0), .transfer(to: directional.id))
        router.end(contact: 2)
        XCTAssertEqual(try router.decision(contact: 1, hitControls: [copy.id], at: 0), .transfer(to: copy.id))
    }
    func testMalformedRoutingInputsAndUnacceptedCommitDoNotChangeOwnership() throws {
        let a = ProfileControl(), b = ProfileControl()
        var router = try ProfileSwipeRouter(profile: profile([a, b]))
        try router.begin(contact: 1, control: a.id, at: 1)
        XCTAssertThrowsError(try router.begin(contact: 1, control: b.id, at: 1))
        XCTAssertThrowsError(try router.accept(contact: 1, target: b.id, at: 1))
        for time in [0.9, .nan, .infinity] { XCTAssertThrowsError(try router.decision(contact: 1, hitControls: [], at: time)) }
        for hits in [[UUID()], [a.id, a.id]] { XCTAssertThrowsError(try router.decision(contact: 1, hitControls: hits, at: 1)) }
        XCTAssertEqual(router.currentControl(for: 1), a.id)
        var invalid = router.profile; invalid.controls.append(a)
        XCTAssertThrowsError(try router.apply(profile: invalid))
        XCTAssertEqual(router.currentControl(for: 1), a.id)
        try router.apply(profile: profile([a, b], .off))
        XCTAssertNil(router.currentControl(for: 1))
    }
}

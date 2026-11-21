import XCTest
@testable import ControllerCore

final class FloatingActionEngineTests: XCTestCase {
    private let geometry = FloatingZoneGeometry(canvasWidth: 700, canvasHeight: 900,
                                                zone: .init(x: 0, y: 0, width: 700, height: 900))
    private let canvas = FloatingRect(x: 0, y: 0, width: 700, height: 900)
    private func profile(_ controls: [ProfileControl], groups: [FloatingButtonZone] = [], rings: [FloatingRingZone] = []) throws -> ControllerProfile {
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        var p = try ControllerProfile(controls: controls, portrait: positions, landscape: positions)
        p.pages[0].floatingButtonZones = groups; p.pages[0].floatingRingZones = rings
        try p.validate(); return p
    }
    private func group(_ controls: [ProfileControl]) -> FloatingButtonZone {
        let frames = controls.enumerated().map { FloatingMemberGeometry(id: $0.element.id, frame: .init(x: Double($0.offset) * 80, y: 100, width: 60, height: 60)) }
        return .init(kind: .buttonGroup, memberIDs: controls.map(\.id), startMemberID: nil,
                     portraitGeometry: geometry, portraitMembers: frames, portraitRestoration: frames)
    }
    private func action(_ action: FloatingLocalAction, _ target: ProfileFloatingActionTarget) -> ProfileControl {
        .init(actions: [.guide], payload: "RELEASE_ALL", floatingAction: .init(action: action, target: target))
    }
    private func beginRing(_ e: inout ProfileInputEngine, _ z: FloatingRingZone, contact: Int = 10, time: Double = 0) throws -> UUID {
        let session = UUID()
        XCTAssertTrue(try e.beginFloatingRing(contact: contact, zoneID: z.id, sessionID: session,
                                              point: .init(x: 300, y: 300), usable: canvas, at: time))
        return session
    }
    func testRegisterRevealOnlyAndGenerationFencedFinish() throws {
        let a = ProfileControl(actions: [.a]), zone = group([ProfileControl(actions: [.b])])
        let member = ProfileControl(id: zone.memberIDs[0], actions: [.b])
        var e = try ProfileInputEngine(profile: profile([a, member], groups: [zone]))
        let first = UUID(), second = UUID()
        XCTAssertTrue(try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: first, at: 0))
        XCTAssertEqual(e.state, .neutral)
        XCTAssertTrue(try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: first, at: 0))
        XCTAssertFalse(try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: second, at: 0))
        XCTAssertTrue(try e.finishFloatingButtonSession(zoneID: zone.id, sessionID: first, at: 0.1))
        XCTAssertEqual(e.dismissedFloatingButtonSessions[zone.id], first)
        XCTAssertFalse(try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: first, at: 0.1))
        XCTAssertTrue(try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: second, at: 0.1))
        try e.begin(contact: 1, control: member.id, at: 0.1)
        XCTAssertFalse(try e.finishFloatingButtonSession(zoneID: zone.id, sessionID: first, at: 0.2))
        XCTAssertEqual(e.state.buttons, [.b]); XCTAssertEqual(e.floatingButtonSessions[zone.id], second)
    }
    func testGroupFinishClearsOnlyItsOwnedClaimsAndNoSharedMouseUp() throws {
        let member = ProfileControl(buttonBehavior: .init(holdToggle: true, holdMilliseconds: 50), payload: "MOUSE_LEFT_DOWN,X360A")
        let independent = ProfileControl(payload: "MOUSE_LEFT_DOWN,X360B")
        let zone = group([member])
        let local = action(.finish, .zone(zone.id))
        var e = try ProfileInputEngine(profile: profile([member, independent, local], groups: [zone]))
        let session = UUID(); _ = try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: session, at: 0)
        try e.begin(contact: 1, control: member.id, at: 0); try e.tick(at: 0.05); try e.end(contact: 1, at: 0.06)
        try e.begin(contact: 2, control: independent.id, at: 0.06); _ = e.drainPracticeEvents()
        try e.begin(contact: 3, control: local.id, at: 0.1)
        XCTAssertEqual(e.state.buttons, [.b]); XCTAssertEqual(e.practiceState.heldMouseButtons, [.left])
        XCTAssertFalse(e.latchedControls.contains(member.id)); XCTAssertEqual(e.dismissedFloatingButtonSessions[zone.id], session)
        XCTAssertFalse(e.drainPracticeEvents().events.contains { $0.kind == .mouseUp(.left) })
        XCTAssertTrue(e.isCapturedInputOwner(for: 2)); XCTAssertTrue(e.isCapturedInputOwner(for: 3))
    }
    func testFinishCancelsOverdueWaitAndPendingHoldBeforeAdvance() throws {
        let wait = ProfileControl(payload: "W,WAIT_500,MOUSE_LEFT_DOWN"), hold = ProfileControl(buttonBehavior: .init(holdToggle: true, holdMilliseconds: 500), payload: "MOUSE_RIGHT_DOWN")
        let zone = group([wait, hold]), independent = ProfileControl(actions: [.b])
        let finish = action(.finish, .zone(zone.id))
        var e = try ProfileInputEngine(profile: profile([wait, hold, independent, finish], groups: [zone]))
        _ = try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: UUID(), at: 0)
        try e.begin(contact: 1, control: wait.id, at: 0); try e.begin(contact: 2, control: hold.id, at: 0)
        try e.begin(contact: 3, control: independent.id, at: 0); _ = e.drainPracticeEvents()
        try e.activate(finish.id, at: 1)
        XCTAssertEqual(e.state.buttons, [.b]); XCTAssertTrue(e.practiceState.heldKeys.isEmpty); XCTAssertTrue(e.latchedControls.isEmpty)
        XCTAssertFalse(e.drainPracticeEvents().events.contains { if case .mouseDown = $0.kind { true } else { false } })
        try e.tick(at: 10); XCTAssertEqual(e.state.buttons, [.b]); XCTAssertTrue(e.practiceState.heldMouseButtons.isEmpty)
    }
    func testSelfFinishReleasesItsOwnContactAndCannotReappearFromStaleEnd() throws {
        let id = UUID(), member = ProfileControl(actions: [.a])
        let finish = action(.finish, .zone(id)); var zone = group([member, finish]); zone.id = id
        var e = try ProfileInputEngine(profile: profile([member, finish], groups: [zone]))
        let session = UUID(); _ = try e.registerFloatingButtonSession(zoneID: id, sessionID: session, at: 0)
        try e.begin(contact: 1, control: member.id, at: 0); try e.begin(contact: 2, control: finish.id, at: 0.1)
        XCTAssertNil(e.capturedControl(for: 1)); XCTAssertNil(e.capturedControl(for: 2)); XCTAssertEqual(e.state, .neutral)
        try e.end(contact: 1, at: 0.2); try e.end(contact: 2, at: 0.2)
        XCTAssertEqual(e.dismissedFloatingButtonSessions[id], session); XCTAssertEqual(e.state, .neutral)
    }
    func testMissingUnsummonedDisabledAndOtherPageTargetsAreInert() throws {
        let member = ProfileControl(actions: [.a]); var zone = group([member]); zone.enabled = false
        let finish = action(.finish, .zone(zone.id)), missing = action(.finish, .zone(UUID()))
        var p = try profile([member, finish, missing], groups: [zone])
        var e = try ProfileInputEngine(profile: p)
        XCTAssertFalse(try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: UUID(), at: 0))
        try e.begin(contact: 1, control: member.id, at: 0); try e.activate(finish.id, at: 0); try e.activate(missing.id, at: 0)
        XCTAssertEqual(e.state.buttons, [.a])
        p.pages[0].floatingButtonZones[0].enabled = true; try e.apply(profile: p)
        try e.begin(contact: 2, control: member.id, at: 0); try e.activate(finish.id, at: 0)
        XCTAssertEqual(e.state.buttons, [.a], "An unsummoned template must not cancel an unrelated canonical activation.")
        let other = try p.addPage(name: "Other"); try e.apply(profile: p); _ = try e.selectPage(other, at: 0)
        XCTAssertFalse(try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: UUID(), at: 0))
    }
    func testPageReleaseAndApplyDismissSessionsWithoutPersistingRuntime() throws {
        let member = ProfileControl(actions: [.a]); let zone = group([member]); var p = try profile([member], groups: [zone])
        let other = try p.addPage(name: "Other"); var e = try ProfileInputEngine(profile: p)
        let first = UUID(); _ = try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: first, at: 0)
        _ = try e.selectPage(other, at: 0.1)
        XCTAssertTrue(e.floatingButtonSessions.isEmpty); XCTAssertEqual(e.dismissedFloatingButtonSessions[zone.id], first)
        try e.apply(profile: p); XCTAssertTrue(e.dismissedFloatingButtonSessions.isEmpty)
        let second = UUID(); _ = try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: second, at: 0.2)
        try e.handle(.cancelAll, at: 0.3)
        XCTAssertEqual(e.dismissedFloatingButtonSessions[zone.id], second); XCTAssertTrue(e.floatingButtonSessions.isEmpty)
        XCTAssertEqual(e.profile, p)
    }
    func testDirectAndAccessibilityActionsIgnoreTurboHoldAndSwipeEntry() throws {
        let member = ProfileControl(actions: [.a]), source = ProfileControl(actions: [.b]); let zone = group([member])
        let finish = action(.finish, .zone(zone.id)); var p = try profile([member, source, finish], groups: [zone])
        p.turboEnabled = true; p.globalHoldEnabled = true; p.swipeMode = .controls
        var e = try ProfileInputEngine(profile: p); let first = UUID()
        _ = try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: first, at: 0)
        try e.begin(contact: 1, control: source.id, at: 0)
        XCTAssertFalse(try e.handoff(contact: 1, to: finish.id, departingStickPosition: nil, arrivingStickPosition: .zero, finalPadDeltas: [], at: 0.1))
        XCTAssertEqual(e.floatingButtonSessions[zone.id], first)
        try e.begin(contact: 2, control: finish.id, at: 0.1)
        let second = UUID(); _ = try e.registerFloatingButtonSession(zoneID: zone.id, sessionID: second, at: 0.1)
        try e.begin(contact: 3, control: finish.id, at: 0.2); try e.tick(at: 1)
        XCTAssertEqual(e.floatingButtonSessions[zone.id], second, "Second finger and Turbo must not repeat a scoped action.")
        try e.activate(finish.id, at: 1.1); XCTAssertNil(e.floatingButtonSessions[zone.id])
        XCTAssertFalse(e.latchedControls.contains(finish.id)); XCTAssertFalse(e.state.buttons.contains(.guide))
    }
    func testRingStopFirePreservesADSAndIndependentOutput() throws {
        var config = FloatingRingConfig(); config.startRole = .aim
        config.knobs[0].fire.mode = .repeat; config.knobs[0].fire.adsPayload = "MOUSE_LEFT_DOWN"; config.knobs[0].fire.firePayload = "X360A"
        let ring = FloatingRingZone(portraitGeometry: geometry, config: config)
        let stop = action(.stopFire, .zone(ring.id)), independent = ProfileControl(actions: [.b])
        var e = try ProfileInputEngine(profile: profile([stop, independent], rings: [ring])); _ = try beginRing(&e, ring)
        try e.begin(contact: 2, control: independent.id, at: 0)
        try e.activate(stop.id, at: 1)
        XCTAssertEqual(e.state.buttons, [.b]); XCTAssertEqual(e.practiceState.heldMouseButtons, [.left])
        try e.tick(at: 2); XCTAssertEqual(e.state.buttons, [.b]); XCTAssertTrue(e.floatingRingStates[ring.id]!.visible)
    }
    func testRingReleaseADSPreservesFireAndSharedMouseOwner() throws {
        var config = FloatingRingConfig(); config.startRole = .aim
        config.knobs[0].fire.mode = .hold; config.knobs[0].fire.adsPayload = "MOUSE_LEFT_DOWN"; config.knobs[0].fire.firePayload = "X360A"
        let ring = FloatingRingZone(portraitGeometry: geometry, config: config)
        let release = action(.releaseADS, .zone(ring.id)), independent = ProfileControl(payload: "MOUSE_LEFT_DOWN,X360B")
        var e = try ProfileInputEngine(profile: profile([release, independent], rings: [ring])); _ = try beginRing(&e, ring)
        try e.begin(contact: 2, control: independent.id, at: 0); _ = e.drainPracticeEvents()
        try e.activate(release.id, at: 0.1)
        XCTAssertEqual(e.state.buttons, [.a, .b]); XCTAssertFalse(e.floatingRingStates[ring.id]!.ads)
        XCTAssertEqual(e.practiceState.heldMouseButtons, [.left]); XCTAssertFalse(e.drainPracticeEvents().events.contains { $0.kind == .mouseUp(.left) })
    }
    func testRingFinishCancelsReleaseShotAndPreservesAnotherRing() throws {
        var config = FloatingRingConfig(); config.startRole = .aim; config.knobs[0].fire.mode = .releaseShot; config.knobs[0].fire.firePayload = "MOUSE_RIGHT_DOWN"
        let first = FloatingRingZone(portraitGeometry: geometry, config: config)
        var secondConfig = FloatingRingConfig(); secondConfig.startRole = .aim; secondConfig.knobs[0].fire.adsPayload = "X360B"
        let second = FloatingRingZone(portraitGeometry: geometry, config: secondConfig), finish = action(.finish, .zone(first.id))
        var e = try ProfileInputEngine(profile: profile([finish], rings: [first, second]))
        let session = try beginRing(&e, first); _ = try beginRing(&e, second, contact: 11); _ = e.drainPracticeEvents()
        try e.activate(finish.id, at: 10); try e.endFloatingRing(contact: 10, sessionID: session, at: 10.1)
        XCTAssertTrue(e.floatingRingStates[first.id]!.finished); XCTAssertTrue(e.floatingRingStates[second.id]!.visible)
        XCTAssertEqual(e.state.buttons, [.b]); XCTAssertFalse(e.drainPracticeEvents().events.contains { $0.kind == .mouseDown(.right) })
    }
    func testRingEndSuppressionIsScopedAndDoesNotStopAim() throws {
        var config = FloatingRingConfig(); config.startRole = .aim; config.aim.suppressCameraFollow = true
        let first = FloatingRingZone(portraitGeometry: geometry, config: config), second = FloatingRingZone(portraitGeometry: geometry, config: config)
        let end = action(.endSuppression, .zone(first.id))
        var e = try ProfileInputEngine(profile: profile([end], rings: [first, second]), allowCameraFollowPractice: true)
        _ = try beginRing(&e, first); _ = try beginRing(&e, second, contact: 11)
        XCTAssertTrue(e.floatingRingStates[first.id]!.suppressed); XCTAssertTrue(e.floatingRingStates[second.id]!.suppressed)
        try e.activate(end.id, at: 0.1)
        XCTAssertFalse(e.floatingRingStates[first.id]!.suppressed); XCTAssertTrue(e.floatingRingStates[second.id]!.suppressed)
        XCTAssertTrue(e.floatingRingStates[first.id]!.aiming)
    }
    func testControlEndSuppressionKeepsMouseHeldAndRearmsOnlyNewDirectDown() throws {
        let left = ProfileControl(kind: .leftStick), mouse = ProfileControl(payload: "MOUSE_LEFT_DOWN", mouseSuppressCameraFollow: true)
        let end = action(.endSuppression, .control(mouse.id)), source = ProfileControl(actions: [.b])
        var p = try profile([left, mouse, end, source]); p.swipeMode = .controls
        var e = try ProfileInputEngine(profile: p, allowCameraFollowPractice: true)
        try e.setCameraFollowEnabled(true, at: 0); try e.begin(contact: 1, control: left.id, position: .init(x: 1), at: 0)
        try e.begin(contact: 2, control: mouse.id, at: 0); XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
        try e.activate(end.id, at: 0.1); try e.tick(at: 0.31); try e.tick(at: 0.5)
        XCTAssertEqual(e.practiceState.heldMouseButtons, [.left]); XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
        XCTAssertGreaterThan(e.practiceState.gamepad.rightStick.x, 0)
        try e.end(contact: 2, at: 0.6); try e.begin(contact: 3, control: source.id, at: 0.6)
        XCTAssertTrue(try e.handoff(contact: 3, to: mouse.id, departingStickPosition: nil, arrivingStickPosition: .zero, finalPadDeltas: [], at: 0.7))
        XCTAssertFalse(e.cameraFollowSnapshot.mouseSuppressed)
        try e.end(contact: 3, at: 0.8); try e.begin(contact: 4, control: mouse.id, at: 0.9)
        XCTAssertTrue(e.cameraFollowSnapshot.mouseSuppressed)
    }
}

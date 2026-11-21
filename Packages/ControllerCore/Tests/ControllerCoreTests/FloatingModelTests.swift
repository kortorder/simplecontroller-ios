import XCTest
@testable import ControllerCore

final class FloatingModelTests: XCTestCase {
    private func profile(_ controls: [ProfileControl]) throws -> ControllerProfile {
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try .init(controls: controls, portrait: positions, landscape: positions)
    }
    private let geometry = FloatingZoneGeometry(canvasWidth: 400, canvasHeight: 800, zone: .init(x: 0, y: 200, width: 180, height: 180))
    private func group(_ members: [ProfileControl]) -> FloatingButtonZone {
        let frames = members.enumerated().map { FloatingMemberGeometry(id: $0.element.id, frame: .init(x: Double($0.offset)*80, y: 100, width: 60, height: 60)) }
        return .init(kind: .buttonGroup, memberIDs: members.map(\.id), startMemberID: members.first?.id,
                     groupSwipe: true, portraitGeometry: geometry, portraitMembers: frames, portraitRestoration: frames)
    }
    private func grouped() throws -> ControllerProfile {
        let a = ProfileControl(actions: [.a]), b = ProfileControl(actions: [.b])
        var p = try profile([a,b]); p.pages[0].floatingButtonZones = [group([a,b])]
        p.pages[0].floatingRingZones = [.init(portraitGeometry: geometry)]
        try p.validate(); return p
    }
    func testFormat12RoundTripPreservesInactiveAndOrientationSnapshots() throws {
        var p = try grouped(); p.pages[0].floatingButtonZones[0].enabled = false
        p.pages[0].floatingRingZones[0].config.aim.fine.sensitivity = 0.8
        let library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p])
        let encoded = try ControllerProfileLibraryCodec.encode(library)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(encoded), library)
        XCTAssertEqual(p.pages[0].floatingMemberIDs, Set(p.controls.map(\.id)))
    }
    func testFormat11MigrationAddsEmptyZonesWithoutInventingTemplates() throws {
        let p = try profile([.init(actions: [.a])])
        let library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        object["version"] = 11; removeCameraFollowFieldsForPreSeventeenFixture(&object); object.removeValue(forKey: "settingsPresets")
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        var oldControls = try XCTUnwrap(profiles[0]["controls"] as? [[String:Any]])
        for i in oldControls.indices {
            var touch = try XCTUnwrap(oldControls[i]["touchAim"] as? [String:Any]); touch.removeValue(forKey:"requiresLocalSetup"); oldControls[i]["touchAim"] = touch
        }
        profiles[0]["controls"] = oldControls
        var pages = try XCTUnwrap(profiles[0]["pages"] as? [[String: Any]])
        pages[0].removeValue(forKey: "floatingButtonZones"); pages[0].removeValue(forKey: "floatingRingZones")
        profiles[0]["pages"] = pages; object["profiles"] = profiles
        let original = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        let migrated = try ControllerProfileLibraryCodec.decode(original)
        XCTAssertEqual(migrated.version, ControllerProfileLibrary.currentVersion)
        XCTAssertEqual(migrated.profiles[0], p)
        XCTAssertTrue(migrated.profiles[0].pages[0].floatingRingZones.isEmpty)
        pages[0]["floatingButtonZones"] = []; profiles[0]["pages"] = pages; object["profiles"] = profiles
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testCurrentMissingZoneArrayAndFutureVersionRejected() throws {
        let p = try grouped(), library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        object["version"] = 999
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
        object["version"] = ControllerProfileLibrary.currentVersion
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        var pages = try XCTUnwrap(profiles[0]["pages"] as? [[String: Any]])
        pages[0].removeValue(forKey: "floatingRingZones"); profiles[0]["pages"] = pages; object["profiles"] = profiles
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testZoneIDsCannotCollideAcrossPagesOrControls() throws {
        var p = try grouped(); let other = try p.addPage(name: "Other")
        p.pages[1].floatingRingZones = p.pages[0].floatingRingZones
        XCTAssertThrowsError(try p.validate()); p.pages[1].floatingRingZones = []
        p.pages[0].floatingRingZones[0].id = other; XCTAssertThrowsError(try p.validate())
        p.pages[0].floatingRingZones[0].id = p.controls[0].id; XCTAssertThrowsError(try p.validate())
    }
    func testCrossPageMembersAndNonButtonsRejected() throws {
        var p = try grouped(); let member = p.controls[0].id
        p.pages[0].controlIDs.removeAll { $0 == member }; p.pages.append(.init(name: "Other", controlIDs: [member]))
        XCTAssertThrowsError(try p.validate())
        p = try grouped(); p.controls[0].kind = .recenter; p.controls[0].actions = []
        XCTAssertThrowsError(try p.validate())
    }
    func testProfileCopyRefreshesEveryRuntimeOwnerButKeepsGeometryAndKnobSlots() throws {
        let p = try grouped(), copy = try p.cloned(name: "Copy")
        XCTAssertNotEqual(copy.id, p.id); XCTAssertNotEqual(copy.pages[0].id, p.pages[0].id)
        XCTAssertTrue(Set(copy.controls.map(\.id)).isDisjoint(with: p.controls.map(\.id)))
        let original = p.pages[0].floatingButtonZones[0], duplicate = copy.pages[0].floatingButtonZones[0]
        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.memberIDs, copy.controls.map(\.id))
        XCTAssertEqual(duplicate.portraitMembers.map(\.frame), original.portraitMembers.map(\.frame))
        XCTAssertEqual(duplicate.portraitRestoration.map(\.id), duplicate.memberIDs)
        XCTAssertNotEqual(copy.pages[0].floatingRingZones[0].id, p.pages[0].floatingRingZones[0].id)
        XCTAssertEqual(copy.pages[0].floatingRingZones[0].config, p.pages[0].floatingRingZones[0].config)
        XCTAssertEqual(p.pages[0].floatingButtonZones[0], original)
    }
    func testPageCopyAndImportKeepTemplatesWithFreshIDs() throws {
        var p = try grouped(); let original = p.pages[0]
        let copied = try p.duplicatePage(original.id)
        XCTAssertNotEqual(p.page(for: copied)?.floatingRingZones[0].id, original.floatingRingZones[0].id)
        XCTAssertEqual(p.page(for: copied)?.floatingButtonZones[0].memberIDs, p.page(for: copied)?.controlIDs)
        var target = try profile([]); let imported = try target.importPage(original.id, from: p)
        XCTAssertEqual(target.page(for: imported)?.floatingRingZones[0].config, original.floatingRingZones[0].config)
        XCTAssertTrue(Set(target.page(for: imported)!.floatingButtonZones[0].memberIDs).isDisjoint(with: original.controlIDs))
    }
    func testDeletingMemberKeepsOthersAndTurnsDeletedStartIntoRevealOnly() throws {
        var p = try grouped(); let first = p.controls[0].id, remaining = p.controls[1].id
        try p.removeControl(first)
        let zone = p.pages[0].floatingButtonZones[0]
        XCTAssertEqual(zone.memberIDs, [remaining]); XCTAssertNil(zone.startMemberID)
        XCTAssertEqual(zone.portraitMembers.map(\.id), [remaining]); XCTAssertEqual(zone.portraitRestoration.map(\.id), [remaining])
        try p.removeControl(remaining); XCTAssertTrue(p.pages[0].floatingButtonZones.isEmpty)
        XCTAssertEqual(p.pages[0].floatingRingZones.count, 1)
    }
    func testMovingMemberOutDetachesOnlyItsMembershipAndPreservesCanonicalPlacement() throws {
        var p = try grouped(); let member = p.controls[0].id, positions = p.portrait
        let other = try p.addPage(name: "Other"); try p.moveControl(member, toPage: other)
        XCTAssertFalse(p.pages[0].floatingMemberIDs.contains(member)); XCTAssertTrue(p.page(for: other)!.controlIDs.contains(member))
        XCTAssertEqual(p.portrait, positions)
    }
    func testRingCopyDoesNotReuseZoneIDOrChangeStableKnobs() throws {
        let zone = FloatingRingZone(portraitGeometry: geometry)
        let copy = zone.replacingID(); XCTAssertNotEqual(copy.id, zone.id)
        XCTAssertEqual(copy.config, zone.config); XCTAssertEqual(copy.portraitGeometry, zone.portraitGeometry)
    }
    func testScopedFinishPreservesSharedIndependentOutputsAndHistory() throws {
        let a = ProfileControl(payload: "X360A,W,MOUSE_LEFT_DOWN,RT:0.8"), b = ProfileControl(payload: "X360A,W,MOUSE_LEFT_DOWN,RT:0.3")
        var e = try ProfileInputEngine(profile: profile([a,b]))
        try e.begin(contact: 1, control: a.id, at: 0); try e.begin(contact: 2, control: b.id, at: 0)
        _ = e.drainPracticeEvents(); e.releaseControls([a.id])
        XCTAssertNil(e.capturedControl(for: 1)); XCTAssertEqual(e.capturedControl(for: 2), b.id)
        XCTAssertEqual(e.practiceState.rightTrigger, 0.3); XCTAssertEqual(e.practiceState.heldKeys, [.w])
        XCTAssertEqual(e.practiceState.heldMouseButtons, [.left]); XCTAssertTrue(e.state.buttons.contains(.a))
        XCTAssertTrue(e.drainPracticeEvents().events.isEmpty)
        try e.end(contact: 2, at: 0.1); XCTAssertEqual(e.state, .neutral)
    }
    func testScopedFinishCancelsUnobservedHoldWAITAndDetachedPulse() throws {
        let h = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true, holdMilliseconds: 500))
        let w = ProfileControl(payload: "WAIT_500, X360B"), pulse = ProfileControl(payload: "RT:0.8P10")
        let other = ProfileControl(payload: "WAIT_500, X360X")
        var e = try ProfileInputEngine(profile: profile([h,w,pulse,other]))
        for (i,c) in [h,w,pulse,other].enumerated() { try e.begin(contact: i, control: c.id, at: 0) }
        try e.end(contact: 2, at: 0.1); XCTAssertEqual(e.practiceState.rightTrigger, 0.8)
        e.releaseControls([h.id,w.id,pulse.id]); try e.tick(at: 1)
        XCTAssertEqual(e.state.buttons, [.x]); XCTAssertEqual(e.practiceState.rightTrigger, 0)
        XCTAssertFalse(e.latchedControls.contains(h.id)); XCTAssertNil(e.capturedControl(for: 0))
    }
    func testScopedFinishNeverSynthesizesAdvancedReleaseShot() throws {
        let aimed = ProfileControl(payload: "X360A", buttonAim: .init(enabled: true, payloadTiming: .sendOnRelease, releaseDelayMilliseconds: 100))
        let other = ProfileControl(actions: [.b])
        var e = try ProfileInputEngine(profile: profile([aimed,other]))
        try e.beginButton(contact: 1, control: aimed.id, sample: .init(x: 30, y: 30, width: 60, height: 60), at: 0)
        try e.begin(contact: 2, control: other.id, at: 0)
        e.releaseControls([aimed.id]); try e.tick(at: 1)
        XCTAssertEqual(e.state.buttons, [.b]); XCTAssertNil(e.capturedControl(for: 1))
        XCTAssertNil(e.buttonAimStates[aimed.id])
    }
    func testScopedFinishClearsAdvancedDetachedPendingAndPadLock() throws {
        let aimed = ProfileControl(payload: "X360A", buttonAim: .init(enabled: true, payloadTiming: .sendOnRelease, releaseDelayMilliseconds: 500))
        let pad = ProfileControl(kind: .touchpad, touchpadBehavior: .init(clickMode: .toggle))
        var e = try ProfileInputEngine(profile: profile([aimed,pad]))
        try e.beginButton(contact: 1, control: aimed.id, sample: .init(x: 30, y: 30, width: 60, height: 60), at: 0)
        try e.end(contact: 1, at: 0.1)
        try e.beginTouchpad(contact: 2, control: pad.id, at: 0.1); try e.end(contact: 2, at: 0.2)
        e.releaseControls([aimed.id,pad.id]); try e.tick(at: 1)
        XCTAssertEqual(e.state, .neutral); XCTAssertTrue(e.lockedTouchpads.isEmpty); XCTAssertNil(e.nextDeadline)
    }
    func testFloatingSwipeIndependentOfGlobalOffAndNoCooldown() throws {
        var p = try grouped(); let a = p.controls[0].id, b = p.controls[1].id, zone = p.pages[0].floatingButtonZones[0].id
        p.swipeMode = .off
        var e = try ProfileInputEngine(profile: p); try e.begin(contact: 1, control: a, at: 0)
        XCTAssertTrue(try e.handoffFloatingButton(contact: 1, zoneID: zone, to: b, at: 0.01))
        XCTAssertTrue(try e.handoffFloatingButton(contact: 1, zoneID: zone, to: a, at: 0.02))
        XCTAssertTrue(try e.handoffFloatingButton(contact: 1, zoneID: zone, to: b, at: 0.03))
        XCTAssertEqual(e.state.buttons, [.b])
    }
    func testFloatingSwipeRejectsIneligibleIngressButAllowsDeparture() throws {
        var p = try grouped(); p.controls[0].swipeActivationEnabled = false
        let a = p.controls[0].id, b = p.controls[1].id, zone = p.pages[0].floatingButtonZones[0].id
        var e = try ProfileInputEngine(profile: p); try e.begin(contact: 1, control: a, at: 0)
        XCTAssertTrue(try e.handoffFloatingButton(contact: 1, zoneID: zone, to: b, at: 0.01))
        XCTAssertFalse(try e.handoffFloatingButton(contact: 1, zoneID: zone, to: a, at: 0.02))
        XCTAssertEqual(e.capturedControl(for: 1), b); XCTAssertEqual(e.state.buttons, [.b])
    }
    func testFloatingHandoffCancelsUnobservedSourceHoldBeforeDeadline() throws {
        var p = try grouped(); p.controls[0].buttonBehavior = .init(holdToggle: true, holdMilliseconds: 500)
        let a = p.controls[0].id, b = p.controls[1].id, zone = p.pages[0].floatingButtonZones[0].id
        var e = try ProfileInputEngine(profile: p); try e.begin(contact: 1, control: a, at: 0)
        XCTAssertTrue(try e.handoffFloatingButton(contact: 1, zoneID: zone, to: b, at: 1))
        XCTAssertFalse(e.latchedControls.contains(a)); XCTAssertEqual(e.state.buttons, [.b])
    }
}

import XCTest
@testable import ControllerCore

final class ProfileVersionEighteenTests: XCTestCase {
    private func fixture() throws -> ControllerProfile {
        var p = try ControllerProfile()
        let member = ProfileControl(name: "Member", payload: "X360A")
        try p.addControl(member, toPage: p.homePageID)
        let zone = FloatingButtonZone(name: "Group", kind: .singleButton, memberIDs: [member.id], startMemberID: member.id, portraitGeometry: .init(canvasWidth: 400, canvasHeight: 800, zone: .init(x: 0, y: 0, width: 240, height: 240)))
        p.pages[0].floatingButtonZones.append(zone)
        try p.addControl(.init(name: "Finish", floatingAction: .init(action: .finish, target: .zone(zone.id))), toPage: p.homePageID)
        try p.addControl(.init(name: "End suppression", floatingAction: .init(action: .endSuppression, target: .control(member.id))), toPage: p.homePageID)
        return p
    }
    func testStrictRoundTripAndAuthenticSeventeenDefaults() throws {
        let p = try fixture(), library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p])
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library)), library)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        raw["version"] = 17
        var profiles = try XCTUnwrap(raw["profiles"] as? [[String: Any]]), controls = try XCTUnwrap((raw["profiles"] as? [[String: Any]])?[0]["controls"] as? [[String: Any]])
        controls = controls.map { var c = $0; c.removeValue(forKey: "floatingAction"); c.removeValue(forKey: "orientationDimensions"); c.removeValue(forKey: "stickPlusRepeatIntervalMilliseconds"); return c }
        profiles[0]["controls"] = controls; raw["profiles"] = profiles
        let old = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: raw))
        XCTAssertTrue(old.profiles[0].controls.allSatisfy { $0.floatingAction == nil })
        XCTAssertEqual(old.profiles[0].pages, p.pages)
        raw["version"] = 18
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: raw)))
    }
    func testDormantPayloadCannotBecomeGlobalReleaseOrGameOutput() throws {
        for payload in ["RELEASE_ALL", "CAMERA_FOLLOW", "FUTURE_UNSUPPORTED", "X360A,WAIT_1000"] {
            let c = ProfileControl(payload: payload, floatingAction: .init(action: .finish, target: .zone(UUID())))
            XCTAssertNoThrow(try c.validate()); XCTAssertTrue(c.isFloatingAction); XCTAssertTrue(c.isLocalAction)
            XCTAssertFalse(c.acceptsSwipeEntry); XCTAssertFalse(c.isReleaseAllAction); XCTAssertFalse(c.isCameraFollowAction)
            XCTAssertTrue(try c.payloadProgram().steps.isEmpty); XCTAssertTrue(c.outputTargets.isEmpty)
        }
    }
    func testConflictingModesAndWrongTargetTypesReject() throws {
        let binding = ProfileFloatingActionBinding(action: .finish, target: .zone(UUID()))
        for c in [ProfileControl(buttonBehavior: .init(holdToggle: true), floatingAction: binding),
                  .init(autoTapEnabled: true, floatingAction: binding),
                  .init(buttonDirectional: .init(enabled: true), floatingAction: binding),
                  .init(buttonAim: .init(enabled: true), floatingAction: binding),
                  .init(kind: .touchpad, floatingAction: binding),
                  .init(kind: .pageButton, floatingAction: binding)] { XCTAssertThrowsError(try c.validate()) }
        for action in [FloatingLocalAction.finish, .stopFire, .releaseADS] { XCTAssertThrowsError(try ProfileFloatingActionBinding(action: action, target: .control(UUID())).validate()) }
        var p = try fixture(); p.controls[1].floatingAction?.action = .stopFire
        XCTAssertThrowsError(try p.validate())
    }
    func testMissingTargetSurvivesDeletionAndStaysDistinctFromOtherZones() throws {
        var p = try fixture(), binding = try XCTUnwrap(p.controls[1].floatingAction)
        p.pages[0].floatingButtonZones.removeAll()
        XCTAssertNoThrow(try p.validate()); XCTAssertEqual(p.controls[1].floatingAction, binding)
        binding.target = .zone(UUID()); p.controls[1].floatingAction = binding
        XCTAssertNoThrow(try p.validate())
    }
    func testWholeProfileAndPageCopiesRemapEachTypedTarget() throws {
        let p = try fixture(), clone = try p.cloned()
        XCTAssertEqual(clone.controls[1].floatingAction?.target, .zone(clone.pages[0].floatingButtonZones[0].id))
        XCTAssertEqual(clone.controls[2].floatingAction?.target, .control(clone.controls[0].id))
        XCTAssertNotEqual(clone.controls[1].floatingAction?.target, p.controls[1].floatingAction?.target)
        var duplicate = p; let page = try duplicate.duplicatePage(p.homePageID)
        let copied = duplicate.controls(on: page)
        XCTAssertEqual(copied[1].floatingAction?.target, .zone(try XCTUnwrap(duplicate.page(for: page)?.floatingButtonZones.first?.id)))
        XCTAssertEqual(copied[2].floatingAction?.target, .control(copied[0].id))
    }
    func testImportOnePageIsolatesExternalTargetsEvenWhenDestinationHasSameIdentity() throws {
        var source = try fixture(), target = try ControllerProfile()
        let external = ProfileControl(name: "External", payload: "MOUSE_LEFT_DOWN")
        let extraPage = try source.addPage(name: "Other")
        try source.addControl(external, toPage: extraPage)
        source.controls[2].floatingAction?.target = .control(external.id)
        try target.addControl(external, toPage: target.homePageID)
        let imported = try target.importPage(source.homePageID, from: source)
        let copied = target.controls(on: imported)
        XCTAssertNotEqual(copied[2].floatingAction?.target.targetID, external.id)
        XCTAssertNil(target.control(for: try XCTUnwrap(copied[2].floatingAction?.target.targetID)))
        XCTAssertEqual(copied[1].floatingAction?.target, .zone(try XCTUnwrap(target.page(for: imported)?.floatingButtonZones.first?.id)))
    }
    func testUnknownBindingFieldsAndEnumsReject() throws {
        for json in [#"{"action":"finish","target":{"kind":"all","id":"00000000-0000-0000-0000-000000000000"}}"#,
                     #"{"action":"future","target":{"kind":"zone","id":"00000000-0000-0000-0000-000000000000"}}"#,
                     #"{"action":"finish","target":{"kind":"zone","id":"00000000-0000-0000-0000-000000000000"},"extra":true}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ProfileFloatingActionBinding.self, from: Data(json.utf8)))
        }
    }
    func testSingleControlDuplicateRemapsItsOwnSuppressionTargetOnly() throws {
        var p = try ControllerProfile(), original = ProfileControl(name: "Self end")
        original.floatingAction = .init(action: .endSuppression, target: .control(original.id))
        try p.addControl(original, toPage: p.homePageID)
        var copy = original; copy.id = UUID()
        try p.addControl(copy, toPage: p.homePageID)
        try p.duplicateSourceBinding(from: original.id, to: copy.id)
        XCTAssertEqual(p.controls[1].floatingAction?.target, .control(copy.id))
        XCTAssertEqual(p.controls[0].floatingAction?.target, .control(original.id))
    }
}

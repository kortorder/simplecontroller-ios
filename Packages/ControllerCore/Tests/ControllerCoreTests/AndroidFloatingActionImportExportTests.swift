import XCTest
@testable import ControllerCore

final class AndroidFloatingActionImportExportTests: XCTestCase {
    private func action(_ id: String, _ action: String, _ target: String, extra: String = "") -> String {
        #"{"id":"\#(id)","type":"BUTTON","name":"\#(id)","payload":"FUTURE_DORMANT_PAYLOAD","x":20,"y":20,"w":44,"h":44,"floatingLocalAction":"\#(action)","floatingActionTargetId":"\#(target)","future":{"number":9007199254740993}\#(extra)}"#
    }
    private func fixture(actions: [String]? = nil) throws -> (AndroidProfileDocument, ControllerProfile) {
        let actions = actions ?? [action("finish", "FINISH", "group"), action("stop", "STOP_FIRE", "ring"), action("ads", "RELEASE_ADS", "ring"), action("end", "END_SUPPRESSION", "ring"), action("mouseEnd", "END_SUPPRESSION", "mouse")]
        let geometry = #"{"canvasWidth":400,"canvasHeight":800,"zone":{"x":10,"y":20,"w":240,"h":240}}"#
        let data = Data(#"{"formatVersion":10,"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[{"id":"mouse","type":"BUTTON","name":"Mouse","payload":"MOUSE_LEFT_DOWN","x":1,"y":2,"w":44,"h":44,"mouseSuppressCameraFollow":true},\#(actions.joined(separator: ","))],"floatingZones":[{"id":"group","kind":"SINGLE_BUTTON","memberIds":["mouse"],"startMemberId":"mouse","portraitGeometry":\#(geometry)},{"id":"ring","kind":"RING","name":"Ring","portraitGeometry":\#(geometry),"ring":{}}]}]}"#.utf8)
        let d = try AndroidProfileDocument.parse(data), plan = try AndroidProfileImportPlan.prepare(d, archiveID: UUID())
        return (d, try XCTUnwrap(plan.profiles.first?.profile, "\(plan.issues)"))
    }
    private func preview(_ p: ControllerProfile, _ d: AndroidProfileDocument) -> AndroidEditedExportPreview { .prepare(profile: p, original: d, source: p.androidSources[0]) }
    private func exported(_ p: ControllerProfile, _ d: AndroidProfileDocument) throws -> AndroidProfileDocument {
        let result = preview(p, d); XCTAssertTrue(result.canExport, "\(result.diagnostics)")
        return try .parse(XCTUnwrap(result.data))
    }
    func testAllFourActionsResolveTypedTargetsAfterZonesAndKeepDormantPayloads() throws {
        let (d, p) = try fixture()
        XCTAssertEqual(p.controls.count, 6)
        XCTAssertEqual(p.controls[1].floatingAction, .init(action: .finish, target: .zone(p.pages[0].floatingButtonZones[0].id)))
        for i in 2...4 { XCTAssertEqual(p.controls[i].floatingAction?.target, .zone(p.pages[0].floatingRingZones[0].id)) }
        XCTAssertEqual(p.controls[5].floatingAction?.target, .control(p.controls[0].id))
        for c in p.controls.dropFirst() { XCTAssertEqual(c.payload, "FUTURE_DORMANT_PAYLOAD"); XCTAssertTrue(try c.payloadProgram().steps.isEmpty); XCTAssertFalse(c.acceptsSwipeEntry) }
        XCTAssertEqual(preview(p, d).data, d.originalData)
    }
    func testPageCopyRemapsZoneAndControlTargetsWhilePreservingUnknownData() throws {
        let (d, original) = try fixture(); var p = original
        _ = try p.duplicatePage(p.homePageID)
        let result = try exported(p, d), page = result.profiles[0].pages[1]
        let zones = try XCTUnwrap(page.value["floatingZones"]?.arrayValue)
        XCTAssertEqual(page.controls[1].value["floatingActionTargetId"], zones[0]["id"])
        for i in 2...4 { XCTAssertEqual(page.controls[i].value["floatingActionTargetId"], zones[1]["id"]) }
        XCTAssertEqual(page.controls[5].value["floatingActionTargetId"]?.stringValue, page.controls[0].sourceID)
        XCTAssertEqual(page.controls[1].value["future"], d.profiles[0].pages[0].controls[1].value["future"])
        XCTAssertEqual(page.controls[1].payload, "FUTURE_DORMANT_PAYLOAD")
        let roundTrip = try AndroidProfileImportPlan.prepare(result, archiveID: UUID())
        XCTAssertEqual(roundTrip.convertedControlCount, 12)
    }
    func testMissingOrIncompatibleTargetStaysInertWithoutRetargeting() throws {
        for item in [action("missing", "FINISH", "not-present"), action("wrongKind", "STOP_FIRE", "group"), action("notRing", "RELEASE_ADS", "mouse")] {
            let (d, original) = try fixture(actions: [item]); var p = original
            let target = try XCTUnwrap(p.controls[1].floatingAction?.target.targetID)
            XCTAssertFalse(p.pages[0].floatingButtonZones.contains { $0.id == target }); XCTAssertFalse(p.pages[0].floatingRingZones.contains { $0.id == target })
            XCTAssertNil(p.control(for: target)); XCTAssertEqual(preview(p, d).data, d.originalData)
            p.controls[1].name = "Renamed"
            XCTAssertEqual(try exported(p, d).profiles[0].pages[0].controls[1].value["floatingActionTargetId"], d.profiles[0].pages[0].controls[1].value["floatingActionTargetId"])
        }
    }
    func testRetargetAndActionEditKeepUnknownOriginalFields() throws {
        let (d, original) = try fixture(); var p = original
        p.controls[1].floatingAction = .init(action: .stopFire, target: .zone(p.pages[0].floatingRingZones[0].id))
        let result = try exported(p, d).profiles[0].pages[0].controls[1].value
        XCTAssertEqual(result["floatingLocalAction"], .string("STOP_FIRE")); XCTAssertEqual(result["floatingActionTargetId"], .string("ring"))
        XCTAssertEqual(result["future"], d.profiles[0].pages[0].controls[1].value["future"])
    }
    func testConflictingSourceModesAndBlankTargetsAreArchivedRatherThanExecuted() throws {
        for item in [action("hold", "FINISH", "group", extra: #", "holdToggle":true"#), action("turbo", "FINISH", "group", extra: #", "autoTapEnabled":true"#), action("blank", "FINISH", ""), action("future", "FUTURE", "group")] {
            let (d, p) = try fixture(actions: [item])
            XCTAssertEqual(p.controls.count, 1); XCTAssertEqual(preview(p, d).data, d.originalData)
        }
    }
    func testDeletingTargetPreservesExplicitDanglingSourceReferenceAndWarnsAboutZoneRemoval() throws {
        let (d, original) = try fixture(); var p = original
        p.pages[0].floatingButtonZones.removeAll()
        let result = preview(p, d)
        XCTAssertTrue(result.canExport); XCTAssertTrue(result.diagnostics.contains { $0.message.contains("removes one converted floating") })
        let after = try AndroidProfileDocument.parse(XCTUnwrap(result.data))
        XCTAssertEqual(after.profiles[0].pages[0].controls[1].value["floatingActionTargetId"], .string("group"))
    }
    func testSelfTargetEndSuppressionRemapsWhenPageIsCopied() throws {
        let (d, original) = try fixture(actions: [action("self", "END_SUPPRESSION", "self")]); var p = original
        XCTAssertEqual(p.controls[1].floatingAction?.target, .control(p.controls[1].id))
        _ = try p.duplicatePage(p.homePageID)
        let copied = try exported(p, d).profiles[0].pages[1].controls[1]
        XCTAssertEqual(copied.value["floatingActionTargetId"]?.stringValue, copied.sourceID)
    }
}

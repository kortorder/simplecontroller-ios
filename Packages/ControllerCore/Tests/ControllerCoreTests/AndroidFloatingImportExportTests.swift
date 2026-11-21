import XCTest
@testable import ControllerCore

final class AndroidFloatingImportExportTests: XCTestCase {
    private func fixture(archived: Bool = false, zoneExtra: String = "", ring: String = "{}", version: Int = 10) throws -> (AndroidProfileDocument, ControllerProfile) {
        let geometry = #"{"canvasWidth":400,"canvasHeight":800,"zone":{"x":10,"y":20,"w":240,"h":240,"futureRect":9007199254740993},"futureCanvas":false}"#
        let members = #"{"a":{"x":10,"y":20,"w":44,"h":44,"futureMember":{"n":9007199254740993}},"b":{"x":70,"y":20,"w":44,"h":44}}"#
        let extra = archived ? #",{"id":"unknown","kind":"FUTURE_FLOATING","future":{"number":9007199254740993}}"# : ""
        let data = Data(#"{"formatVersion":\#(version),"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[{"id":"a","name":"A","type":"BUTTON","x":10,"y":20,"w":44,"h":44,"payload":"X360A"},{"id":"b","name":"B","type":"BUTTON","x":70,"y":20,"w":44,"h":44,"payload":"X360B"}],"floatingZones":[{"id":"group","kind":"BUTTON_GROUP","name":"Buttons","memberIds":["a","b"],"startMemberId":"","groupSwipe":true,"portraitGeometry":\#(geometry),"portraitMemberGeometry":\#(members),"portraitRestorationGeometry":\#(members),"futureZone":{"value":9007199254740993}\#(zoneExtra)},{"id":"ring","kind":"RING","name":"Aim ring","portraitGeometry":\#(geometry),"ring":\#(ring),"futureRing":"keep"}\#(extra)]}]}"#.utf8)
        let source = try AndroidProfileDocument.parse(data), plan = try AndroidProfileImportPlan.prepare(source, archiveID: UUID())
        return (source, try XCTUnwrap(plan.profiles.first?.profile, "\(plan.issues)"))
    }
    private func preview(_ p: ControllerProfile, _ d: AndroidProfileDocument) -> AndroidEditedExportPreview { .prepare(profile: p, original: d, source: p.androidSources[0]) }
    private func exported(_ p: ControllerProfile, _ d: AndroidProfileDocument) throws -> AndroidProfileDocument {
        let result = preview(p, d); XCTAssertTrue(result.canExport, "\(result.diagnostics)")
        return try .parse(XCTUnwrap(result.data))
    }
    private func zones(_ d: AndroidProfileDocument, page: Int = 0) throws -> [AndroidJSONValue] { try XCTUnwrap(d.profiles[0].pages[page].value["floatingZones"]?.arrayValue) }
    func testRoleGeometryAndFinishOptionsRoundTripWithoutDroppingUnknownFields() throws {
        let ring = #"{"compactAimBoosts":true,"directBoostStartsAim":true,"boostBanks":{"enabled":true,"directStartBank":"AIM","aim":{"boost1":{"enabled":true,"payload":"X360Y"},"boost2":{"distanceDp":160,"directInnerDistanceDp":160,"directOuterDistanceDp":184,"skipDelayOnDirectTouch":true},"geometry":{"enabled":true,"boost1DistanceDp":49,"boost1ThicknessDp":8,"boost2ThicknessDp":10,"directStartDistanceDp":89,"futureFlag":"keep"}}}}"#
        let (source, original) = try fixture(zoneExtra: #","finishIgnoresSwipes":true"#, ring:ring, version:13)
        XCTAssertEqual(preview(original, source).data, source.originalData)
        var profile = original
        let config = try XCTUnwrap(profile.pages[0].floatingRingZones.first?.config)
        XCTAssertTrue(profile.pages[0].floatingButtonZones[0].finishIgnoresSwipes)
        let banks = try XCTUnwrap(config.boostBanks)
        XCTAssertEqual(banks.directStartBank,.aim); XCTAssertEqual(banks.aim.boost1.payload,"X360Y")
        XCTAssertTrue(banks.aim.boost2.skipDelayOnDirectTouch); XCTAssertEqual(banks.aim.geometry.boost1Distance,49)
        profile.pages[0].floatingRingZones[0].config.boostBanks?.aim.geometry.boost1Thickness = 14
        profile.pages[0].floatingRingZones[0].config.directBoostStartsAim = false
        profile.pages[0].floatingButtonZones[0].finishIgnoresSwipes = false
        let result = try exported(profile, source), saved = try zones(result)
        let edited = try XCTUnwrap(saved[1]["ring"])
        XCTAssertEqual(edited["boostBanks"]?["aim"]?["geometry"]?["futureFlag"],.string("keep"))
        XCTAssertEqual(edited["boostBanks"]?["aim"]?["geometry"]?["boost1ThicknessDp"]?.numberValue?.rawValue,"14")
        let updated = try XCTUnwrap(AndroidProfileImportPlan.prepare(result, archiveID:UUID()).profiles.first?.profile)
        XCTAssertFalse(updated.pages[0].floatingRingZones[0].config.directBoostStartsAim)
        XCTAssertFalse(updated.pages[0].floatingButtonZones[0].finishIgnoresSwipes)
    }

    func testSupportedTemplatesHaveStableLineageAndUntouchedExportIsByteExact() throws {
        let (d, p) = try fixture(archived: true)
        XCTAssertEqual(p.pages[0].floatingButtonZones.count, 1); XCTAssertEqual(p.pages[0].floatingRingZones.count, 1)
        XCTAssertEqual(p.pages[0].floatingButtonZones[0].memberIDs, p.controls.map(\.id))
        XCTAssertNil(p.pages[0].floatingButtonZones[0].startMemberID); XCTAssertTrue(p.pages[0].floatingButtonZones[0].groupSwipe)
        XCTAssertEqual(p.androidSources[0].zones.count, 2); XCTAssertEqual(p.androidSources[0].exportBaseline?.version, 2)
        XCTAssertEqual(preview(p, d).data, d.originalData); XCTAssertTrue(preview(p, d).isUnchanged)
        let clone = try p.cloned(); XCTAssertEqual(preview(clone, d).data, d.originalData)
        XCTAssertEqual(Set(clone.androidSources[0].zones.map(\.nativeID)), Set(clone.pages[0].floatingButtonZones.map(\.id) + clone.pages[0].floatingRingZones.map(\.id)))
        XCTAssertTrue(Set(clone.androidSources[0].zones.map(\.nativeID)).isDisjoint(with: p.androidSources[0].zones.map(\.nativeID)))
    }
    func testKnownNestedEditsPreserveUnknownValuesAndArchivedOnlyZone() throws {
        let (d, initial) = try fixture(archived: true); var p = initial
        p.pages[0].floatingButtonZones[0].portraitGeometry?.zone.x = 45
        p.pages[0].floatingButtonZones[0].portraitMembers[0].frame.width = 70
        p.pages[0].floatingRingZones[0].config.boost1.enabled = true
        p.pages[0].floatingRingZones[0].config.boost1.payload = "X360Y"
        let result = try zones(exported(p, d)), original = try zones(d)
        XCTAssertEqual(result[0]["portraitGeometry"]?["zone"]?["x"]?.numberValue?.rawValue, "45")
        XCTAssertEqual(result[0]["portraitGeometry"]?["zone"]?["futureRect"], original[0]["portraitGeometry"]?["zone"]?["futureRect"])
        XCTAssertEqual(result[0]["portraitMemberGeometry"]?["a"]?["futureMember"], original[0]["portraitMemberGeometry"]?["a"]?["futureMember"])
        XCTAssertEqual(result[0]["portraitRestorationGeometry"], original[0]["portraitRestorationGeometry"])
        XCTAssertEqual(result[0]["futureZone"], original[0]["futureZone"]); XCTAssertEqual(result[2], original[2])
        XCTAssertEqual(result[1]["ring"]?["boost1"]?["payload"]?.stringValue, "X360Y")
        let reimport = try AndroidProfileImportPlan.prepare(exported(p, d), archiveID: UUID())
        XCTAssertEqual(reimport.profiles[0].profile.pages[0].floatingRingZones[0].config, p.pages[0].floatingRingZones[0].config)
    }
    func testCopiedPageRemapsZoneAndMemberIDsWithoutDroppingUnknownGeometry() throws {
        let (d, initial) = try fixture(); var p = initial
        let copyID = try p.duplicatePage(p.homePageID)
        let clone = try XCTUnwrap(p.page(for: copyID))
        XCTAssertEqual(p.androidSources[0].zones.filter { $0.exportID != nil }.count, 2)
        let result = try exported(p, d), original = try zones(d), copied = try zones(result, page: 1)
        let ids = result.profiles[0].pages[1].controls.map(\.sourceID)
        XCTAssertEqual(copied[0]["memberIds"]?.arrayValue?.compactMap(\.stringValue), ids)
        XCTAssertNotEqual(copied[0]["id"], original[0]["id"]); XCTAssertNotEqual(copied[1]["id"], original[1]["id"])
        XCTAssertEqual(copied[0]["portraitMemberGeometry"]?[ids[0]]?["futureMember"], original[0]["portraitMemberGeometry"]?["a"]?["futureMember"])
        XCTAssertEqual(copied[0]["futureZone"], original[0]["futureZone"])
        XCTAssertEqual(Set(clone.floatingButtonZones[0].memberIDs), Set(clone.controlIDs))
    }
    func testUnknownIdentityReferenceOrArchivedZoneBlocksPageCopy() throws {
        for (archived, extra) in [(true, ""), (false, #", "futureReference":"group""#), (false, #", "futureReference":"a""#)] {
            let (d, initial) = try fixture(archived: archived, zoneExtra: extra); var p = initial
            _ = try p.duplicatePage(p.homePageID)
            XCTAssertFalse(preview(p, d).canExport)
        }
    }
    func testConvertedZoneDeletionIsExplicitAndPreservesArchivedOnlyZones() throws {
        let (d, initial) = try fixture(archived: true); var p = initial
        p.pages[0].floatingButtonZones.removeAll(); try p.validate()
        let result = preview(p, d); XCTAssertTrue(result.canExport, "\(result.diagnostics)")
        let after = try zones(.parse(XCTUnwrap(result.data)))
        XCTAssertEqual(after.map { $0["id"]?.stringValue }, ["ring", "unknown"])
        XCTAssertEqual(after.last, try zones(d).last); XCTAssertTrue(result.diagnostics.contains { $0.message.contains("removes one converted floating") })
    }
    func testNativeRingAdditionExportsFullAuditedDefaultsAndReimports() throws {
        let (d, initial) = try fixture(); var p = initial
        p.pages[0].floatingRingZones.append(.init(portraitGeometry: .init(canvasWidth: 400, canvasHeight: 800, zone: .init(x: 0, y: 0, width: 400, height: 400))))
        let next = try exported(p, d), reimport = try AndroidProfileImportPlan.prepare(next, archiveID: UUID())
        XCTAssertEqual(reimport.profiles[0].profile.pages[0].floatingRingZones.count, 2)
        XCTAssertEqual(reimport.profiles[0].profile.pages[0].floatingRingZones[1].config, p.pages[0].floatingRingZones[1].config)
    }
    func testRingKnobStructuralEditsBlockButNestedFireFieldsPreserveUnknowns() throws {
        let ring = #"{"knobs":[{"id":"aim_1","name":"Aim","futureSlot":9007199254740993,"fire":{"futureFire":{"keep":true}}}]}"#
        let (d, initial) = try fixture(ring: ring); var p = initial
        p.pages[0].floatingRingZones[0].config.knobs[0].fire.mode = .hold
        p.pages[0].floatingRingZones[0].config.knobs[0].fire.firePayload = "X360X"
        let result = try zones(exported(p, d))[1]["ring"]?["knobs"]?.arrayValue?.first
        XCTAssertEqual(result?["futureSlot"]?.numberValue?.rawValue, "9007199254740993")
        XCTAssertEqual(result?["fire"]?["futureFire"], try zones(d)[1]["ring"]?["knobs"]?.arrayValue?.first?["fire"]?["futureFire"])
        p.pages[0].floatingRingZones[0].config.knobs[0].id = "renamed"
        p.pages[0].floatingRingZones[0].config.startKnobID = "renamed"; p.pages[0].floatingRingZones[0].config.directBoostAimKnobID = "renamed"
        XCTAssertFalse(preview(p, d).canExport)
    }
    func testUnsupportedRingPayloadArchivesWholeRingAndKeepsFullOriginal() throws {
        let (d, p) = try fixture(ring: #"{"boost1":{"payload":"FUTURE_OUTPUT"}}"#)
        XCTAssertTrue(p.pages[0].floatingRingZones.isEmpty); XCTAssertEqual(p.androidSources[0].zones.count, 1)
        XCTAssertEqual(preview(p, d).data, d.originalData)
    }
    func testAuditedRingEnumsTimingAndOriginMapWithoutImplicitCalibration() throws {
        let ring = #"{"movement":{"profile":"RESPONSE_CURVE","initialY":0.4},"aim":{"tuning":{"output":"RIGHT_STICK","sensitivity":1,"invertY":false,"mouseProfile":"LINEAR_RELATIVE","haptics":true,"stickUsesTouchPosition":true,"stickProfile":"RADIAL_RESPONSE_CURVE","stickFullDisplacementPx":180,"stickDeadzonePx":5}},"boost1":{"enabled":true,"payload":"X360A","action":"HOLD"},"boost2":{"distanceDp":160,"directInnerDistanceDp":160,"directOuterDistanceDp":184,"enabled":true,"payload":"X360B","action":"REPEAT","pulsePressMs":20,"pulseGapMs":40,"activationDelayMs":200,"repeatAfterExit":true,"cancelDelayOnExit":false}}"#
        let (d, p) = try fixture(ring: ring), config = try XCTUnwrap(p.pages[0].floatingRingZones.first?.config)
        XCTAssertEqual(config.movement.response, .perAxis); XCTAssertEqual(config.movement.initialPosition.y, -0.4)
        XCTAssertEqual(config.aim.tuning.output, .rightStick); XCTAssertEqual(config.aim.tuning.origin, .controlCenter); XCTAssertEqual(config.aim.tuning.stickResponse, .radial)
        XCTAssertEqual(config.boost2.activationDelayMilliseconds, 200); XCTAssertEqual(config.boost2.action, .repeat)
        XCTAssertEqual(preview(p, d).data, d.originalData)
    }
    func testFormatSixteenRoundTripAndAuthenticFifteenDefaultsZoneLineageToEmpty() throws {
        let (d, p) = try fixture()
        let ref = try AndroidSourceArchiveReference(id: p.androidSources[0].archiveID, sha256: androidSHA256(d.originalData), byteCount: d.originalData.count, displayName: "Original")
        let library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p], androidSources: [ref])
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library)), library)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        raw["version"] = 15; removeCameraFollowFieldsForPreSeventeenFixture(&raw)
        var profiles = try XCTUnwrap(raw["profiles"] as? [[String: Any]]), sources = try XCTUnwrap((raw["profiles"] as? [[String: Any]])?[0]["androidSources"] as? [[String: Any]])
        sources[0].removeValue(forKey: "zones")
        var baseline = try XCTUnwrap(sources[0]["exportBaseline"] as? [String: Any]); baseline["version"] = 1; baseline.removeValue(forKey: "zones")
        sources[0]["exportBaseline"] = baseline; profiles[0]["androidSources"] = sources; raw["profiles"] = profiles
        let old = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: raw))
        XCTAssertTrue(old.profiles[0].androidSources[0].zones.isEmpty); XCTAssertEqual(old.profiles[0].androidSources[0].exportBaseline?.version, 1)
        var bad = raw; bad["version"] = 16
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: bad)))
    }
    func testPresentBoostTwoUsesItsOwnDefaultsAndMissingRequiredTuningIsNotRepaired() throws {
        let (_, absent) = try fixture(ring: "{}")
        XCTAssertEqual(absent.pages[0].floatingRingZones.first?.config.boost2.distance, 160)
        for raw in [#"{"boost2":{}}"#, #"{"aim":{"tuning":{"output":"MOUSE"}}}"#] {
            let (source, imported) = try fixture(ring: raw)
            XCTAssertTrue(imported.pages[0].floatingRingZones.isEmpty)
            XCTAssertEqual(preview(imported, source).data, source.originalData)
        }
    }

    func testRingOriginMatchesAuditedControlCenterFlagAndExportsBothDirections() throws {
        let (d, imported) = try fixture()
        XCTAssertEqual(imported.pages[0].floatingRingZones[0].config.aim.tuning.origin, .initialTouch)
        var edited = imported
        edited.pages[0].floatingRingZones[0].config.aim.tuning.origin = .controlCenter
        let center = try exported(edited, d)
        XCTAssertEqual(try zones(center)[1]["ring"]?["aim"]?["tuning"]?["stickUsesTouchPosition"], .bool(true))
        let plan = try AndroidProfileImportPlan.prepare(center, archiveID: UUID())
        XCTAssertEqual(plan.profiles[0].profile.pages[0].floatingRingZones[0].config.aim.tuning.origin, .controlCenter)
        var returned = plan.profiles[0].profile
        returned.pages[0].floatingRingZones[0].config.aim.tuning.origin = .initialTouch
        XCTAssertEqual(try zones(exported(returned, center))[1]["ring"]?["aim"]?["tuning"]?["stickUsesTouchPosition"], .bool(false))
    }

}

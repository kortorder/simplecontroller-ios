import XCTest
@testable import ControllerCore

final class AndroidFloatingRestorationTests: XCTestCase {
    private func fixture(landscape: Bool = true, restoreX: Double = 270) throws -> (AndroidProfileDocument, ControllerProfile) {
        let landscapePage = #", "landscapeGeometry":{"canvasWidth":800,"canvasHeight":400,"controls":{"a":{"x":100,"y":100,"w":100,"h":100}}}"#
        let landscapeZone = landscape ? #", "landscapeGeometry":{"canvasWidth":800,"canvasHeight":400,"zone":{"x":0,"y":0,"w":240,"h":240}},"landscapeMemberGeometry":{"a":{"x":10,"y":20,"w":100,"h":100}},"landscapeRestorationGeometry":{"a":{"x":500,"y":200,"w":160,"h":70}}"# : ""
        let raw = #"{"formatVersion":10,"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[{"id":"a","type":"BUTTON","name":"A","x":100,"y":200,"w":80,"h":80,"payload":"X360A"},{"id":"b","type":"BUTTON","name":"Independent","x":20,"y":20,"w":100,"h":100,"payload":"X360B"}],"portraitGeometry":{"canvasWidth":400,"canvasHeight":800,"controls":{"a":{"x":100,"y":200,"w":80,"h":80,"unknownCanonical":9007199254740993}}}\#(landscapePage),"floatingZones":[{"id":"zone","kind":"BUTTON_GROUP","name":"Imported","memberIds":["a"],"startMemberId":"","groupSwipe":false,"portraitGeometry":{"canvasWidth":400,"canvasHeight":800,"zone":{"x":0,"y":0,"w":240,"h":240}},"portraitMemberGeometry":{"a":{"x":10,"y":20,"w":80,"h":80}},"portraitRestorationGeometry":{"a":{"x":\#(restoreX),"y":400,"w":50,"h":50,"unknownRestore":9223372036854775809}}\#(landscapeZone),"futureZone":"preserve in original"}]}]}"#
        let d = try AndroidProfileDocument.parse(Data(raw.utf8))
        let plan = try AndroidProfileImportPlan.prepare(d, archiveID: UUID())
        return (d, try XCTUnwrap(plan.profiles.first?.profile))
    }
    private func restore(_ p: ControllerProfile, _ d: AndroidProfileDocument, pageID: UUID? = nil) throws -> ControllerProfile {
        let page = try XCTUnwrap(p.page(for: pageID ?? p.homePageID))
        return try AndroidFloatingRestoration.restore(profile: p, zoneID: XCTUnwrap(page.floatingButtonZones.first?.id),
            pageID: page.id, original: d, source: p.androidSources[0])
    }
    private func exported(_ p: ControllerProfile, _ d: AndroidProfileDocument) throws -> AndroidProfileDocument {
        let result = AndroidEditedExportPreview.prepare(profile: p, original: d, source: p.androidSources[0])
        return try .parse(XCTUnwrap(result.data, result.diagnostics.map(\.message).joined(separator: " | ")))
    }
    func testBothOrientationsRestoreWithFitAndPreserveBaseIndependentControlAndBaseline() throws {
        let (d, p) = try fixture(), before = p
        let next = try restore(p, d), a = next.controls[0]
        XCTAssertEqual(a.dimensions(for: .portrait), .init(width: 44, height: 44))
        XCTAssertEqual(a.dimensions(for: .landscape).width, 83.2, accuracy: 1e-9)
        XCTAssertEqual(a.dimensions(for: .landscape).height, 44)
        XCTAssertEqual(a.resolvedWidth, before.controls[0].resolvedWidth)
        XCTAssertEqual(a.resolvedHeight, before.controls[0].resolvedHeight)
        XCTAssertEqual(next.controls[1], before.controls[1])
        XCTAssertEqual(next.androidSources[0].exportBaseline, before.androidSources[0].exportBaseline)
        XCTAssertEqual(next.androidSources[0].zones, before.androidSources[0].zones)
        XCTAssertEqual(next.androidSources[0].controls[0].floatingRestoration?.orientations, Set(ControllerOrientation.allCases))
        XCTAssertNil(next.androidSources[0].controls[1].floatingRestoration)
        XCTAssertEqual(next.portrait[1], before.portrait[1]); XCTAssertEqual(next.landscape[1], before.landscape[1])
        XCTAssertTrue(next.pages[0].floatingButtonZones.isEmpty); XCTAssertEqual(p, before)
        XCTAssertEqual(d.exportOriginalData(), d.originalData)
    }
    func testMinimumCollisionAndClippedPositionExportExactRawRestoration() throws {
        for x in [270.0, 900.0] {
            let (d, p) = try fixture(restoreX: x), next = try restore(p, d)
            XCTAssertEqual(p.controls[0].dimensions(for: .portrait).width, next.controls[0].dimensions(for: .portrait).width)
            let result = try exported(next, d).profiles[0].pages[0].value
            let rectangle = result["portraitGeometry"]?["controls"]?["a"]
            XCTAssertEqual(Double(try XCTUnwrap(rectangle?["x"]?.numberValue?.rawValue)), x)
            XCTAssertEqual(rectangle?["w"]?.numberValue?.rawValue, "50")
            XCTAssertEqual(rectangle?["h"]?.numberValue?.rawValue, "50")
            XCTAssertEqual(rectangle?["unknownCanonical"], d.profiles[0].pages[0].value["portraitGeometry"]?["controls"]?["a"]?["unknownCanonical"])
            XCTAssertTrue(result["floatingZones"]?.arrayValue?.isEmpty == true)
            XCTAssertEqual(result["landscapeGeometry"]?["controls"]?["a"]?["w"]?.numberValue?.rawValue, "160")
        }
    }
    func testDetachedEditsDoNotReplaceOriginalRestorationAndLaterNativeResizeExportsFromRestoredBasis() throws {
        let (d, original) = try fixture(); var p = original
        p.pages[0].floatingButtonZones[0].portraitMembers[0].frame = .init(x: 50, y: 60, width: 200, height: 110)
        var next = try restore(p, d)
        next.controls[0].orientationDimensions.portrait?.width = 60
        let rectangle = try exported(next, d).profiles[0].pages[0].value["portraitGeometry"]?["controls"]?["a"]
        let w = Double(try XCTUnwrap(rectangle?["w"]?.numberValue?.rawValue))!
        let x = Double(try XCTUnwrap(rectangle?["x"]?.numberValue?.rawValue))!
        XCTAssertEqual(w, 60 / 0.535, accuracy: 1e-9); XCTAssertEqual(x + w / 2, 295, accuracy: 1e-9)
    }
    func testPreparedNativeOrientationWithoutArchivedRestorationKeepsCanonicalGeometry() throws {
        let (d, original) = try fixture(landscape: false); var p = original
        let id = p.controls[0].id
        p.pages[0].floatingButtonZones[0].landscapeGeometry = .init(canvasWidth: 494, canvasHeight: 208, zone: .init(x: 0, y: 0, width: 200, height: 160))
        p.pages[0].floatingButtonZones[0].landscapeMembers = [.init(id: id, frame: .init(x: 0, y: 0, width: 80, height: 80))]
        p.pages[0].floatingButtonZones[0].landscapeRestoration = [.init(id: id, frame: .init(x: 10, y: 20, width: 44, height: 44))]
        let next = try restore(p, d)
        XCTAssertEqual(next.controls[0].dimensions(for: .landscape), p.controls[0].dimensions(for: .landscape))
        XCTAssertEqual(next.landscape, p.landscape)
        XCTAssertEqual(try exported(next, d).profiles[0].pages[0].value["landscapeGeometry"], d.profiles[0].pages[0].value["landscapeGeometry"])
    }
    func testCopiedPageRestoresOnlyItsMembersAndCloneAfterRestorationPreservesExport() throws {
        let (d, original) = try fixture(); var p = original
        let copyID = try p.duplicatePage(p.homePageID)
        let next = try restore(p, d, pageID: copyID)
        XCTAssertEqual(next.pages[0], p.pages[0]); XCTAssertEqual(next.controls[0], p.controls[0])
        XCTAssertEqual(next.pages[1].floatingButtonZones.count, 0)
        let result = try exported(next, d)
        XCTAssertEqual(result.profiles[0].pages[0].value["portraitGeometry"], d.profiles[0].pages[0].value["portraitGeometry"])
        let copiedA = result.profiles[0].pages[1].controls[0].sourceID
        XCTAssertEqual(result.profiles[0].pages[1].value["portraitGeometry"]?["controls"]?[copiedA]?["w"]?.numberValue?.rawValue, "50")
        let restoredOriginal = try restore(original, d), clone = try restoredOriginal.cloned()
        XCTAssertEqual(try exported(clone, d).profiles[0].pages[0].value["portraitGeometry"]?["controls"]?["a"]?["w"]?.numberValue?.rawValue, "50")
    }
    func testNativeOversizedCanonicalSizeIsNeverShrunkToMeasuredRestorationFrame() throws {
        var p = try ControllerProfile()
        let c = ProfileControl(actions: [.a], controlWidth: 800, controlHeight: 200,
            orientationDimensions: .init(landscape: .init(width: 900, height: 180)))
        try p.addControl(c, toPage: p.homePageID); let before = p
        let snapshot = FloatingCanvasSnapshot(width: 337, height: 428, frames: [c.id: .init(x: 0, y: 0, width: 337, height: 200)])
        let zone = try p.convertToFloatingButtons(on: p.homePageID, memberIDs: [c.id], kind: .singleButton, name: "Native", snapshots: [.portrait: snapshot])
        try p.unfloatButtons(zone, on: p.homePageID)
        XCTAssertEqual(p, before)
    }
    func testTamperedRestorationAndWrongArchiveFailWithoutMutation() throws {
        let (d, original) = try fixture(); var p = original
        p.pages[0].floatingButtonZones[0].portraitRestoration[0].frame.width = 100
        XCTAssertThrowsError(try restore(p, d)); XCTAssertEqual(original.pages[0].floatingButtonZones[0].portraitRestoration[0].frame.width, 50)
        let other = try AndroidProfileDocument.parse(Data(String(decoding: d.originalData, as: UTF8.self).replacingOccurrences(of: "Imported", with: "Changed").utf8))
        XCTAssertThrowsError(try restore(original, other))
    }
    func testLooseCopyBeforeRestorationKeepsOriginalPixelBasisButCopyAfterInheritsRestoredBasis() throws {
        let (d, original) = try fixture(); var p = original
        let first = p.controls[0]; var loose = first; loose.id = UUID(); loose.name = "Before"
        try p.addControl(loose, toPage: p.homePageID); try p.duplicateSourceBinding(from: first.id, to: loose.id)
        var next = try restore(p, d)
        var later = next.controls[0]; later.id = UUID(); later.name = "After"
        try next.addControl(later, toPage: next.homePageID); try next.duplicateSourceBinding(from: first.id, to: later.id)
        XCTAssertNil(next.androidSources[0].controls.first { $0.nativeID == loose.id }?.floatingRestoration)
        XCTAssertNotNil(next.androidSources[0].controls.first { $0.nativeID == later.id }?.floatingRestoration)
        let beforeID = try XCTUnwrap(next.androidSources[0].controls.first { $0.nativeID == loose.id }?.exportID)
        let afterID = try XCTUnwrap(next.androidSources[0].controls.first { $0.nativeID == later.id }?.exportID)
        let page = try exported(next, d).profiles[0].pages[0].value
        XCTAssertEqual(page["portraitGeometry"]?["controls"]?["a"]?["w"]?.numberValue?.rawValue, "50")
        XCTAssertEqual(page["portraitGeometry"]?["controls"]?[beforeID]?["w"]?.numberValue?.rawValue, "80")
        XCTAssertEqual(page["portraitGeometry"]?["controls"]?[afterID]?["w"]?.numberValue?.rawValue, "50")
        let roundTrip = try JSONDecoder().decode(ControllerProfile.self, from: JSONEncoder().encode(next))
        XCTAssertEqual(roundTrip, next)
    }
    func testRestorationMarkerStrictnessAndSourceProof() throws {
        for json in [#"{"zoneSourcePath":"/z","orientations":[]}"#,
                     #"{"zoneSourcePath":"/z","orientations":["portrait","portrait"]}"#,
                     #"{"zoneSourcePath":"/z","orientations":["sideways"]}"#,
                     #"{"zoneSourcePath":"/z","orientations":["portrait"],"future":1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(AndroidFloatingRestorationRecord.self, from: Data(json.utf8)))
        }
        let (d, original) = try fixture(); var next = try restore(original, d)
        next.androidSources[0].controls[0].floatingRestoration = .init(zoneSourcePath: "/missing", orientations: [.portrait])
        XCTAssertThrowsError(try next.validate())
        var wrongMember = try restore(original, d)
        wrongMember.androidSources[0].controls[1].floatingRestoration = wrongMember.androidSources[0].controls[0].floatingRestoration
        let preview = AndroidEditedExportPreview.prepare(profile: wrongMember, original: d, source: wrongMember.androidSources[0])
        XCTAssertFalse(preview.canExport)
    }
    func testAuthenticEighteenBindingDefaultsNilAndNineteenRequiresNullableKey() throws {
        let (d, p) = try fixture()
        let archive = try AndroidSourceArchiveReference(id: p.androidSources[0].archiveID, sha256: androidSHA256(d.originalData), byteCount: d.originalData.count, displayName: "Original")
        let library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p], androidSources: [archive])
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        raw["version"] = 18
        var profiles = try XCTUnwrap(raw["profiles"] as? [[String: Any]])
        profiles[0]["controls"] = (profiles[0]["controls"] as! [[String: Any]]).map { var c = $0; c.removeValue(forKey: "orientationDimensions"); c.removeValue(forKey: "stickPlusRepeatIntervalMilliseconds"); return c }
        var sources = try XCTUnwrap(profiles[0]["androidSources"] as? [[String: Any]])
        for key in ["pages", "controls", "zones"] {
            sources[0][key] = (sources[0][key] as! [[String: Any]]).map { var b = $0; b.removeValue(forKey: "floatingRestoration"); return b }
        }
        profiles[0]["androidSources"] = sources; raw["profiles"] = profiles
        let decoded = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: raw))
        XCTAssertTrue(decoded.profiles[0].androidSources[0].controls.allSatisfy { $0.floatingRestoration == nil })
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(decoded)) as? [String: Any])
        var currentProfiles = encoded["profiles"] as! [[String: Any]]
        var currentSources = currentProfiles[0]["androidSources"] as! [[String: Any]]
        var bindings = currentSources[0]["controls"] as! [[String: Any]]; bindings[0].removeValue(forKey: "floatingRestoration")
        currentSources[0]["controls"] = bindings; currentProfiles[0]["androidSources"] = currentSources; encoded["profiles"] = currentProfiles
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: encoded)))
    }
}

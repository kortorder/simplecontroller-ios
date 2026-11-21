import Foundation
import XCTest
@testable import ControllerCore

final class AndroidEditedExportTests: XCTestCase {
    private func fixture(geometry: Bool = true, navigation: Bool = false, unknown: Bool = true) throws -> (AndroidProfileDocument, ControllerProfile) {
        let sensor = unknown ? #",{"id":"sensor","type":"FUTURE_SENSOR","x":10,"y":10,"w":44,"h":44,"payload":"TOUCH_AIM","futureSensor":{"n":9007199254740993}}"# : ""
        let nav = navigation ? #",{"id":"nav","type":"BUTTON","x":20,"y":20,"w":44,"h":44,"payload":"","pageAction":"TOGGLE","pageTargetId":"p"}"# : ""
        let geometry = geometry ? #", "portraitGeometry":{"canvasWidth":400,"canvasHeight":800,"controls":{"a":{"x":100,"y":200,"w":80,"h":160,"unknownGeometry":9223372036854775809}}},"landscapeGeometry":{"canvasWidth":800,"canvasHeight":400,"controls":{"a":{"x":600,"y":200,"w":80,"h":80}}}"# : ""
        let raw = #" {"formatVersion":10,"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[{"id":"a","type":"BUTTON","name":"A","x":20,"y":30,"w":120,"h":80,"payload":"X360A","future":{"n":9007199254740993,"keys":{"é":1,"e\u0301":2}}}\#(sensor)\#(nav)]\#(geometry)},{"id":"q","name":"Other","controls":[]}],"futureProfile":[null,true,1e999]} "#
        let original = try AndroidProfileDocument.parse(Data(raw.utf8), fallbackName: "Original")
        let plan = try AndroidProfileImportPlan.prepare(original, archiveID: UUID())
        return (original, plan.profiles[0].profile)
    }
    private func preview(_ profile: ControllerProfile, _ original: AndroidProfileDocument) -> AndroidEditedExportPreview {
        .prepare(profile: profile, original: original, source: profile.androidSources[0])
    }
    private func decoded(_ preview: AndroidEditedExportPreview) throws -> AndroidProfileDocument {
        try AndroidProfileDocument.parse(XCTUnwrap(preview.data, preview.diagnostics.map(\.message).joined(separator: " | ")))
    }
    func testUntouchedImportReturnsExactOriginalBytesDespiteGeometryAdaptation() throws {
        let (original, profile) = try fixture()
        let result = preview(profile, original)
        XCTAssertTrue(result.isUnchanged); XCTAssertEqual(result.data, original.originalData)
        XCTAssertEqual(result.changedFieldCount, 0)
    }
    func testPayloadOnlyEditPreservesUnknownNumbersUnicodeAndBothOriginalGeometries() throws {
        let (original, initial) = try fixture(); var profile = initial
        profile.controls[0].payload = "X360B"
        let result = try decoded(preview(profile, original))
        let before = original.profiles[0].pages[0], after = result.profiles[0].pages[0]
        XCTAssertEqual(after.controls[0].payload, "X360B")
        XCTAssertEqual(after.controls[0].value["future"], before.controls[0].value["future"])
        XCTAssertEqual(after.controls[1].value, before.controls[1].value)
        XCTAssertEqual(after.value["portraitGeometry"], before.value["portraitGeometry"])
        XCTAssertEqual(after.value["landscapeGeometry"], before.value["landscapeGeometry"])
        XCTAssertEqual(result.root["futureProfile"], original.root["futureProfile"])
    }
    func testPortraitMoveDoesNotRewriteLandscapeRawFallbackOrUnknownGeometry() throws {
        let (original, initial) = try fixture(); var profile = initial
        profile.portrait[0].position = .init(x: 0.7, y: profile.portrait[0].position.y)
        let result = try decoded(preview(profile, original)), page = result.profiles[0].pages[0]
        XCTAssertEqual(page.value["portraitGeometry"]?["controls"]?["a"]?["x"]?.numberValue?.rawValue, "240")
        XCTAssertEqual(page.value["portraitGeometry"]?["controls"]?["a"]?["unknownGeometry"], original.profiles[0].pages[0].value["portraitGeometry"]?["controls"]?["a"]?["unknownGeometry"])
        XCTAssertEqual(page.value["landscapeGeometry"], original.profiles[0].pages[0].value["landscapeGeometry"])
        for key in ["x", "y", "w", "h"] { XCTAssertEqual(page.controls[0].value[key], original.profiles[0].pages[0].controls[0].value[key]) }
    }
    func testCreatingOneOrientationSnapshotPreservesTheOtherFallback() throws {
        let (original, initial) = try fixture(geometry: false, unknown: false); var profile = initial
        profile.portrait[0].position = .init(x: 0.4, y: profile.portrait[0].position.y)
        let result = try decoded(preview(profile, original)), page = result.profiles[0].pages[0]
        XCTAssertNotNil(page.value["portraitGeometry"]?["controls"]?["a"])
        XCTAssertEqual(page.value["landscapeGeometry"]?["controls"]?["a"]?["x"], original.profiles[0].pages[0].controls[0].value["x"])
        XCTAssertEqual(page.value["landscapeGeometry"]?["controls"]?["a"]?["w"], original.profiles[0].pages[0].controls[0].value["w"])
    }
    func testResizeUsesSourceScaleAndKeepsOriginalCenter() throws {
        let (original, initial) = try fixture(); var profile = initial
        profile.controls[0].orientationDimensions.portrait?.width = 80
        let result = try decoded(preview(profile, original)), geometry = result.profiles[0].pages[0].value["portraitGeometry"]?["controls"]?["a"]
        let x = Double(try XCTUnwrap(geometry?["x"]?.numberValue?.rawValue))!
        let width = Double(try XCTUnwrap(geometry?["w"]?.numberValue?.rawValue))!
        XCTAssertEqual(width, 80 / 0.535, accuracy: 1e-9)
        XCTAssertEqual(x + width / 2, 140, accuracy: 1e-9)
        XCTAssertEqual(geometry?["h"]?.numberValue?.rawValue, "160")
    }
    func testExplicitConvertedDeletionPreservesArchivedOnlyControlAndUnknownProfile() throws {
        let (original, initial) = try fixture(); var profile = initial
        try profile.removeControl(profile.controls[0].id)
        let result = preview(profile, original), restored = try decoded(result)
        XCTAssertEqual(result.deletedControlCount, 1)
        XCTAssertEqual(restored.profiles[0].pages[0].controls.map(\.sourceID), ["sensor"])
        XCTAssertEqual(restored.profiles[0].pages[0].controls[0].value, original.profiles[0].pages[0].controls[1].value)
        XCTAssertNil(restored.profiles[0].pages[0].value["portraitGeometry"]?["controls"]?["a"])
        XCTAssertEqual(restored.root["futureProfile"], original.root["futureProfile"])
    }
    func testDeletedPageContainingArchivedOnlyDataBlocksExport() throws {
        let (original, initial) = try fixture(); var profile = initial
        try profile.deletePage(profile.pages[0].id)
        let result = preview(profile, original)
        XCTAssertFalse(result.canExport); XCTAssertTrue(result.diagnostics.contains { $0.message.contains("archived-only") })
    }
    func testCopiedControlHasStableFreshIDAndPreservesUnknownTemplate() throws {
        let (original, initial) = try fixture(unknown: false); var profile = initial
        let source = profile.controls[0]; var copy = source; copy.id = UUID()
        try profile.addControl(copy, toPage: profile.homePageID)
        try profile.duplicateSourceBinding(from: source.id, to: copy.id)
        let expectedID = try XCTUnwrap(profile.androidSources[0].controls.first { $0.nativeID == copy.id }?.exportID)
        let result = preview(profile, original), decoded = try decoded(result)
        XCTAssertEqual(result.addedControlCount, 1)
        XCTAssertEqual(decoded.profiles[0].pages[0].controls.map(\.sourceID), ["a", expectedID])
        XCTAssertEqual(decoded.profiles[0].pages[0].controls[1].value["future"], original.profiles[0].pages[0].controls[0].value["future"])
        XCTAssertEqual(preview(profile, original).data, result.data)
        XCTAssertEqual(decoded.profiles[0].pages[0].value["portraitGeometry"]?["controls"]?[expectedID]?["unknownGeometry"], original.profiles[0].pages[0].value["portraitGeometry"]?["controls"]?["a"]?["unknownGeometry"])
    }
    func testCopiedPageRemapsItsSelfNavigationAndPreservesIndependentIDs() throws {
        let (original, initial) = try fixture(navigation: true, unknown: false); var profile = initial
        let newPage = try profile.duplicatePage(profile.homePageID)
        let newID = try XCTUnwrap(profile.androidSources[0].pages.first { $0.nativeID == newPage }?.exportID)
        let result = try decoded(preview(profile, original))
        let page = try XCTUnwrap(result.profiles[0].pages.first { $0.sourceID == newID })
        let nav = try XCTUnwrap(page.controls.first { $0.value["pageAction"] == .string("TOGGLE") })
        XCTAssertEqual(nav.value["pageTargetId"], .string(newID))
        XCTAssertFalse(page.controls.contains { ["a", "nav"].contains($0.sourceID) })
        XCTAssertNil(page.value["portraitGeometry"]?["controls"]?["a"])
    }
    func testUnknownSelfReferenceBlocksCopyInsteadOfGuessing() throws {
        let (base, _) = try fixture(unknown: false)
        let json = String(decoding: base.originalData, as: UTF8.self).replacingOccurrences(of: #""name":"A""#, with: #""name":"A","customSelfReference":"a""#)
        let original = try AndroidProfileDocument.parse(Data(json.utf8)), plan = try AndroidProfileImportPlan.prepare(original, archiveID: UUID())
        var profile = plan.profiles[0].profile; let source = profile.controls[0]; var copy = source; copy.id = UUID()
        try profile.addControl(copy, toPage: profile.homePageID); try profile.duplicateSourceBinding(from: source.id, to: copy.id)
        let result = preview(profile, original)
        XCTAssertFalse(result.canExport); XCTAssertTrue(result.diagnostics.contains { $0.message.contains("unknown self-reference") })
    }
    func testConflictingOrientationOrderBlocksRatherThanChoosingOne() throws {
        let (original, initial) = try fixture(navigation: true, unknown: false); var profile = initial
        profile.portrait.reverse()
        let result = preview(profile, original)
        XCTAssertFalse(result.canExport); XCTAssertTrue(result.diagnostics.contains { $0.message.contains("stacking orders") })
    }
    func testGlobalOptionsAndCrossSourceProfilesBlockEditedExport() throws {
        let (original, initial) = try fixture(); var profile = initial
        profile.swipeMode = .controls
        XCTAssertFalse(preview(profile, original).canExport)
        profile = initial; let (_, other) = try fixture()
        _ = try profile.importPage(other.homePageID, from: other)
        XCTAssertFalse(preview(profile, original).canExport)
    }
    func testPreBaselineSourceBlocksButOriginalBytesRemainAvailable() throws {
        let (original, initial) = try fixture(); var profile = initial
        let source = profile.androidSources[0]
        profile.androidSources = [.init(archiveID: source.archiveID, sourceProfilePath: source.sourceProfilePath, pages: source.pages, controls: source.controls)]
        XCTAssertFalse(preview(profile, original).canExport)
        XCTAssertEqual(original.exportOriginalData(), original.originalData)
    }
    func testNativeTouchAimAdditionBlocksEditedExportWithoutChangingOriginal() throws {
        let (original, initial) = try fixture(); var profile = initial
        try profile.addControl(.init(name: "Native Touch Aim", kind: .touchAim), toPage: profile.homePageID)
        let result = preview(profile, original)
        XCTAssertFalse(result.canExport)
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("Touch Aim calibration") })
        XCTAssertEqual(original.exportOriginalData(), original.originalData)
    }
    func testMalformedDuplicateSourceBindingsReturnBlockedPreviewWithoutTrapping() throws {
        let (original, initial) = try fixture(); var profile = initial
        let first = profile.androidSources[0].controls[0]
        profile.androidSources[0].controls += [.init(nativeID: first.nativeID, sourcePath: first.sourcePath, exportID: UUID().uuidString),
                                              .init(nativeID: first.nativeID, sourcePath: first.sourcePath, exportID: UUID().uuidString)]
        XCTAssertFalse(preview(profile, original).canExport)
    }
    func testNativeFloatingAdditionCannotBeMistakenForUnchangedImport() throws {
        let (original, initial) = try fixture(); var profile = initial
        profile.pages[0].floatingRingZones = [.init(portraitGeometry: .init(canvasWidth: 400, canvasHeight: 800,
            zone: .init(x: 0, y: 0, width: 400, height: 400)))]
        try profile.validate()
        let result = preview(profile, original)
        XCTAssertTrue(result.canExport, "\(result.diagnostics)"); XCTAssertFalse(result.isUnchanged)
        let exported = try decoded(result)
        XCTAssertEqual(exported.profiles[0].pages[0].value["floatingZones"]?.arrayValue?.count, 1)
        XCTAssertEqual(exported.profiles[0].pages[0].value["floatingZones"]?.arrayValue?.first?["kind"]?.stringValue, "RING")
        XCTAssertEqual(original.exportOriginalData(), original.originalData)
    }
    func testAdvancedButtonEditsPatchExactSourceFieldNamesAndIntegerTimings() throws {
        let (original, initial) = try fixture(); var profile = initial
        profile.controls[0].buttonAim = .init(enabled: true, payloadTiming: .sendOnRelease, releaseDelayMilliseconds: 250,
            cancelOnBoundaryExit: true, tuning: .init(output: .rightStick, fullDisplacement: 180))
        profile.controls[0].buttonDirectional.enabled = true
        profile.controls[0].buttonDirectional.directions[.up] = .init(firstDistance: 30, secondDistance: 70, firstPayload: "X360B", secondPayload: "X360Y")
        let result = try decoded(preview(profile, original)), c = result.profiles[0].pages[0].controls[0].value
        XCTAssertEqual(c["buttonAimPayloadTiming"], .string("SEND_ON_RELEASE"))
        XCTAssertEqual(c["buttonAimReleaseDelayMs"]?.numberValue?.rawValue, "250")
        XCTAssertEqual(c["buttonAimOutput"], .string("RIGHT_STICK"))
        XCTAssertEqual(c["buttonDirectional"]?["up"]?["firstDistancePx"]?.numberValue?.rawValue, "30")
        XCTAssertEqual(c["future"], original.profiles[0].pages[0].controls[0].value["future"])
    }
    func testNewControlUsesDestinationSourceCanvasAndRequiredFields() throws {
        let (original, initial) = try fixture(unknown: false); var profile = initial
        let new = ProfileControl(name: "New", actions: [.b])
        try profile.addControl(new, toPage: profile.homePageID, portrait: .init(x: 0.5, y: 0.5), landscape: .init(x: 0.5, y: 0.5))
        let result = try decoded(preview(profile, original)), page = result.profiles[0].pages[0]
        let added = try XCTUnwrap(page.controls.first { $0.sourceID == new.id.uuidString })
        XCTAssertEqual(added.payload, "X360B")
        let geometry = page.value["portraitGeometry"]?["controls"]?[new.id.uuidString]
        let x = Double(try XCTUnwrap(geometry?["x"]?.numberValue?.rawValue))!, w = Double(try XCTUnwrap(geometry?["w"]?.numberValue?.rawValue))!
        XCTAssertEqual(x + w / 2, 200, accuracy: 1e-8)
    }
    func testFormatTenMetadataRoundTripsAndCloneKeepsBaselineButCopyGetsID() throws {
        let (original, profile) = try fixture(), source = profile.androidSources[0]
        let ref = try AndroidSourceArchiveReference(id: source.archiveID, sha256: androidSHA256(original.originalData), byteCount: original.originalData.count, displayName: "Source")
        let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile], androidSources: [ref])
        let restored = try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library))
        XCTAssertEqual(restored, library)
        let clone = try profile.cloned()
        XCTAssertEqual(clone.androidSources[0].exportBaseline, source.exportBaseline)
        XCTAssertTrue(clone.androidSources[0].controls.allSatisfy { $0.exportID == nil })
        XCTAssertEqual(preview(clone, original).data, original.originalData)
    }
    func testAuthenticFormatNinePreservesSourceBindingsWithoutInventingBaseline() throws {
        let (original, profile) = try fixture(), source = profile.androidSources[0]
        let ref = try AndroidSourceArchiveReference(id: source.archiveID, sha256: androidSHA256(original.originalData), byteCount: original.originalData.count, displayName: "Source")
        let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile], androidSources: [ref])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        object["version"] = 9; removeCameraFollowFieldsForPreSeventeenFixture(&object); object.removeValue(forKey: "settingsPresets")
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        var controls = try XCTUnwrap(profiles[0]["controls"] as? [[String: Any]])
        for i in controls.indices { controls[i].removeValue(forKey: "touchAim") }
        profiles[0]["controls"] = controls
        var pages = try XCTUnwrap(profiles[0]["pages"] as? [[String: Any]])
        for i in pages.indices { pages[i].removeValue(forKey: "floatingButtonZones"); pages[i].removeValue(forKey: "floatingRingZones") }
        profiles[0]["pages"] = pages
        var sources = try XCTUnwrap(profiles[0]["androidSources"] as? [[String: Any]])
        sources[0].removeValue(forKey: "exportBaseline"); sources[0].removeValue(forKey: "zones")
        for key in ["pages", "controls"] {
            var values = try XCTUnwrap(sources[0][key] as? [[String: Any]])
            for i in values.indices { values[i].removeValue(forKey: "exportID") }
            sources[0][key] = values
        }
        profiles[0]["androidSources"] = sources; object["profiles"] = profiles
        let restored = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.profiles[0].controls, profile.controls.map { var c = $0; c.orientationDimensions = .init(); return c })
        XCTAssertEqual(restored.profiles[0].androidSources[0].controls, source.controls)
        XCTAssertNil(restored.profiles[0].androidSources[0].exportBaseline)
        XCTAssertFalse(preview(restored.profiles[0], original).canExport)
    }
    func testUnknownBaselineFieldsAndFutureBaselineVersionsAreRejected() throws {
        let (_, profile) = try fixture(), baseline = profile.androidSources[0].exportBaseline!
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any])
        object["future"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(AndroidSourceExportBaseline.self, from: JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "future"); object["version"] = AndroidSourceExportBaseline.currentVersion + 1
        XCTAssertThrowsError(try JSONDecoder().decode(AndroidSourceExportBaseline.self, from: JSONSerialization.data(withJSONObject: object)))
        object["version"] = 1
        var controls = try XCTUnwrap(object["controls"] as? [[String: Any]])
        controls[0]["future"] = true; object["controls"] = controls
        XCTAssertThrowsError(try JSONDecoder().decode(AndroidSourceExportBaseline.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}

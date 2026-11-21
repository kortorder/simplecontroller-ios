import Foundation
import XCTest
@testable import ControllerCore

final class AndroidProfileMetadataTests: XCTestCase {
    private func fixture() throws -> (AndroidProfileDocument, AndroidSourceArchiveReference, AndroidProfileImportPlan) {
        let data = Data(#"{"formatVersion":5,"homePageId":"p","pages":[{"id":"p","name":"Base","controls":[{"id":"a","type":"BUTTON","x":10,"y":10,"w":44,"h":44,"payload":"X360A"}]}]}"#.utf8)
        let doc = try AndroidProfileDocument.parse(data)
        let reference = try AndroidSourceArchiveReference(sha256: androidSHA256(data), byteCount: data.count, displayName: "Source.json")
        return (doc, reference, try .prepare(doc, archiveID: reference.id))
    }
    func testFormatSevenMigratesWithoutMetadataAndFormatEightRoundTrips() throws {
        let library = ControllerProfileLibrary.default
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        raw["version"] = 7; removeCameraFollowFieldsForPreSeventeenFixture(&raw); raw.removeValue(forKey: "androidSources"); raw.removeValue(forKey: "settingsPresets")
        var profiles = try XCTUnwrap(raw["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        for i in profiles.indices {
            profiles[i].removeValue(forKey: "androidSources")
            var pages = try XCTUnwrap(profiles[i]["pages"] as? [[String: Any]])
            for j in pages.indices { pages[j].removeValue(forKey: "floatingButtonZones"); pages[j].removeValue(forKey: "floatingRingZones") }
            profiles[i]["pages"] = pages
            var controls = try XCTUnwrap(profiles[i]["controls"] as? [[String: Any]])
            for j in controls.indices { for key in ["buttonDirectional", "buttonAim", "controlWidth", "controlHeight", "touchAim"] { controls[j].removeValue(forKey: key) } }
            profiles[i]["controls"] = controls
        }; raw["profiles"] = profiles
        let restored = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(restored.version, ControllerProfileLibrary.currentVersion); XCTAssertTrue(restored.androidSources.isEmpty)
        XCTAssertTrue(restored.profiles.allSatisfy { $0.androidSources.isEmpty })
        XCTAssertEqual(restored.profiles[0].controls, library.profiles[0].controls)
        let (_, reference, plan) = try fixture()
        let merged = try plan.merged(into: library, source: reference)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(merged)), merged)
    }
    func testAuthenticFormatEightKeepsArchiveReferencesDuringLaterMigration() throws {
        let (_, reference, plan) = try fixture()
        let library = try plan.merged(into: .default, source: reference)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        raw["version"] = 8; removeCameraFollowFieldsForPreSeventeenFixture(&raw); raw.removeValue(forKey: "settingsPresets")
        var profiles = try XCTUnwrap(raw["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        for i in profiles.indices {
            var pages = try XCTUnwrap(profiles[i]["pages"] as? [[String: Any]])
            for j in pages.indices { pages[j].removeValue(forKey: "floatingButtonZones"); pages[j].removeValue(forKey: "floatingRingZones") }
            profiles[i]["pages"] = pages
            var controls = try XCTUnwrap(profiles[i]["controls"] as? [[String: Any]])
            for j in controls.indices { for key in ["buttonDirectional", "buttonAim", "controlWidth", "controlHeight", "touchAim"] { controls[j].removeValue(forKey: key) } }
            profiles[i]["controls"] = controls
            var sources = try XCTUnwrap(profiles[i]["androidSources"] as? [[String: Any]])
            for sourceIndex in sources.indices {
                sources[sourceIndex].removeValue(forKey: "exportBaseline"); sources[sourceIndex].removeValue(forKey: "zones")
                for key in ["pages", "controls"] {
                    var bindings = try XCTUnwrap(sources[sourceIndex][key] as? [[String: Any]])
                    for binding in bindings.indices { bindings[binding].removeValue(forKey: "exportID") }
                    sources[sourceIndex][key] = bindings
                }
            }
            profiles[i]["androidSources"] = sources
        }
        raw["profiles"] = profiles
        let restored = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(restored.androidSources, library.androidSources)
        XCTAssertEqual(restored.profiles.map { $0.androidSources.map(\.archiveID) }, library.profiles.map { $0.androidSources.map(\.archiveID) })
        XCTAssertEqual(restored.profiles.map { $0.androidSources.flatMap(\.controls) }, library.profiles.map { $0.androidSources.flatMap(\.controls) })
        XCTAssertTrue(restored.profiles.flatMap(\.androidSources).allSatisfy { $0.exportBaseline == nil })
    }
    func testMergePreservesActiveAndAllOldProfilesAndRenamesRepeatedImports() throws {
        let (_, source, plan) = try fixture(), original = ControllerProfileLibrary.default
        let first = try plan.merged(into: original, source: source)
        let second = try plan.merged(into: first, source: source)
        XCTAssertEqual(second.activeProfileID, original.activeProfileID)
        XCTAssertEqual(second.profiles[0], original.profiles[0]); XCTAssertEqual(second.androidSources, [source])
        XCTAssertEqual(second.profiles.count, 3)
        XCTAssertNotEqual(second.profiles[1].controls[0].id, second.profiles[2].controls[0].id)
        XCTAssertNotEqual(second.profiles[1].name, second.profiles[2].name)
    }
    func testMismatchedArchiveAndProfileCapacityRejectWithoutMutation() throws {
        let (_, source, plan) = try fixture()
        let wrong = try AndroidSourceArchiveReference(sha256: String(repeating: "a", count: 64), byteCount: source.byteCount, displayName: "Wrong")
        let original = ControllerProfileLibrary.default
        XCTAssertThrowsError(try plan.merged(into: original, source: wrong))
        var full = original
        full.profiles += try (0..<31).map { try original.activeProfile.cloned(name: "P\($0)") }
        XCTAssertThrowsError(try plan.merged(into: full, source: source)); XCTAssertEqual(full.profiles.count, 32)
        XCTAssertTrue(full.androidSources.isEmpty)
    }
    func testCloningAndDuplicatingPagesRemapSourceBindings() throws {
        let (_, _, plan) = try fixture()
        let original = plan.profiles[0].profile
        let cloned = try original.cloned()
        XCTAssertEqual(cloned.androidSources[0].archiveID, original.androidSources[0].archiveID)
        XCTAssertEqual(cloned.androidSources[0].controls[0].nativeID, cloned.controls[0].id)
        XCTAssertEqual(cloned.androidSources[0].pages[0].nativeID, cloned.pages[0].id)
        var duplicate = original
        let page = try duplicate.duplicatePage(original.homePageID)
        XCTAssertEqual(duplicate.androidSources[0].pages.count, 2)
        XCTAssertTrue(duplicate.androidSources[0].pages.contains { $0.nativeID == page })
        XCTAssertEqual(Set(duplicate.androidSources[0].controls.map(\.nativeID)), Set(duplicate.controls.map(\.id)))
    }
    func testPageImportCanRetainMultipleOriginalSources() throws {
        let (_, _, first) = try fixture(), (_, _, second) = try fixture()
        var destination = first.profiles[0].profile
        let source = second.profiles[0].profile
        let newPage = try destination.importPage(source.homePageID, from: source)
        XCTAssertEqual(destination.androidSources.count, 2)
        XCTAssertTrue(destination.androidSources[1].pages.contains { $0.nativeID == newPage })
        XCTAssertEqual(destination.androidSources[1].archiveID, source.androidSources[0].archiveID)
    }
    func testControlCopyAndDeletionKeepOriginalArchiveReference() throws {
        let (_, _, plan) = try fixture()
        var profile = plan.profiles[0].profile
        let old = profile.controls[0].id
        var copy = profile.controls[0]; copy.id = UUID()
        try profile.addControl(copy, toPage: profile.homePageID)
        try profile.duplicateSourceBinding(from: old, to: copy.id)
        XCTAssertEqual(profile.androidSources[0].controls.count, 2)
        try profile.removeControl(old)
        XCTAssertEqual(profile.androidSources[0].controls.map(\.nativeID), [copy.id])
        try profile.removeControl(copy.id)
        XCTAssertEqual(profile.androidSources.count, 1); XCTAssertTrue(profile.androidSources[0].controls.isEmpty)
    }
    func testDeletePageRemovesOnlyDeletedBindings() throws {
        let (_, _, plan) = try fixture()
        var profile = plan.profiles[0].profile
        let copy = try profile.duplicatePage(profile.homePageID)
        try profile.deletePage(copy)
        XCTAssertEqual(profile.androidSources[0].pages.map(\.nativeID), [profile.homePageID])
        XCTAssertEqual(profile.androidSources[0].controls.count, 1)
    }
    func testDanglingArchiveOrControlBindingsAreRejected() throws {
        let (_, reference, plan) = try fixture()
        let profile = plan.profiles[0].profile
        XCTAssertThrowsError(try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile]))
        var broken = profile
        broken.androidSources[0].controls[0].nativeID = UUID()
        XCTAssertThrowsError(try broken.validate())
        XCTAssertNoThrow(try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile], androidSources: [reference]))
    }
    func testUnknownNativeMetadataCannotBeSilentlyDiscarded() throws {
        let (_, reference, plan) = try fixture()
        let library = try plan.merged(into: .default, source: reference)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        var sources = try XCTUnwrap(raw["androidSources"] as? [[String: Any]])
        sources[0]["future"] = true; raw["androidSources"] = sources
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: raw)))
    }
}

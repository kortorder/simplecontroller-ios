import Foundation
import XCTest
@testable import ControllerCore

final class ProfileVersionTwentyTests: XCTestCase {
    private func library(interval: Int? = 200) throws -> ControllerProfileLibrary {
        let c = ProfileControl(kind: .leftStick, stickBehavior: .init(stickPlusEnabled: true),
                               stickPlusRepeatIntervalMilliseconds: interval)
        let placements = [ProfilePlacement(id: c.id, position: .init(x: 0.4, y: 0.6))]
        let p = try ControllerProfile(controls: [c], portrait: placements, landscape: placements)
        return try .init(activeProfileID: p.id, profiles: [p])
    }
    private func object(_ value: ControllerProfileLibrary) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(value)) as? [String: Any])
    }
    private func changedControl(_ source: [String: Any], _ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var result = source, profiles = source["profiles"] as! [[String: Any]]
        var controls = profiles[0]["controls"] as! [[String: Any]]
        change(&controls[0]); profiles[0]["controls"] = controls; result["profiles"] = profiles
        return result
    }
    private func decode(_ value: [String: Any]) throws -> ControllerProfileLibrary {
        try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: value))
    }
    func testNativeTwentyRoundTripsValueAndExplicitDisabledNull() throws {
        for interval in [nil, 16, 200, 1_000] as [Int?] {
            let saved = try library(interval: interval)
            XCTAssertEqual(saved.version, ControllerProfileLibrary.currentVersion)
            XCTAssertEqual(try decode(object(saved)), saved)
            let rawControl = (try object(saved)["profiles"] as! [[String: Any]])[0]["controls"] as! [[String: Any]]
            XCTAssertNotNil(rawControl[0]["stickPlusRepeatIntervalMilliseconds"])
            if interval == nil { XCTAssertTrue(rawControl[0]["stickPlusRepeatIntervalMilliseconds"] is NSNull) }
        }
    }
    func testAuthenticNineteenDefaultsDisabledAndPreservesAllExistingValues() throws {
        let expected = try library(interval: nil)
        var old = try object(expected)
        old = changedControl(old) { $0.removeValue(forKey: "stickPlusRepeatIntervalMilliseconds") }
        old["version"] = 19
        let bytes = try JSONSerialization.data(withJSONObject: old)
        let decoded = try ControllerProfileLibraryCodec.decode(bytes)
        XCTAssertEqual(decoded, expected); XCTAssertNil(decoded.activeProfile.controls[0].stickPlusRepeatIntervalMilliseconds)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(decoded)), decoded)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bytes) as? NSDictionary, old as NSDictionary)
    }
    func testOlderVersionCannotSmuggleRepeatAndCurrentRequiresStrictNullableKey() throws {
        let saved = try object(library())
        var old = saved; old["version"] = 19
        XCTAssertThrowsError(try decode(old))
        XCTAssertThrowsError(try decode(changedControl(saved) { $0.removeValue(forKey: "stickPlusRepeatIntervalMilliseconds") }))
        for invalid in [true, "200", 200.5, 15, 1_001, -1] as [Any] {
            XCTAssertThrowsError(try decode(changedControl(saved) { $0["stickPlusRepeatIntervalMilliseconds"] = invalid }))
        }
        XCTAssertThrowsError(try decode(changedControl(saved) { $0["futureRepeatField"] = true }))
        var future = saved; future["version"] = ControllerProfileLibrary.currentVersion + 1
        XCTAssertThrowsError(try decode(future))
    }
    func testValidationAllowsDormantPreferenceOnlyOnStickKinds() throws {
        for kind in ProfileControlKind.allCases {
            let c = ProfileControl(kind: kind, stickPlusRepeatIntervalMilliseconds: 200)
            if kind.isStick { XCTAssertNoThrow(try c.validate()) }
            else { XCTAssertThrowsError(try c.validate()) }
        }
        var c = ProfileControl(kind: .leftStick, directionalEnabled: true, stickPlusRepeatIntervalMilliseconds: 200)
        XCTAssertNoThrow(try c.validate())
        c.stickPlusRepeatIntervalMilliseconds = 0; XCTAssertThrowsError(try c.validate())
    }
    func testCloneDuplicatePageAndPortableBackupKeepPerControlPreference() throws {
        let saved = try library(); var p = saved.activeProfile
        let clone = try p.cloned()
        XCTAssertNotEqual(clone.controls[0].id, p.controls[0].id)
        XCTAssertEqual(clone.controls[0].stickPlusRepeatIntervalMilliseconds, 200)
        let page = try p.duplicatePage(p.homePageID)
        XCTAssertEqual(p.controls(on: page)[0].stickPlusRepeatIntervalMilliseconds, 200)
        let raw = try ControllerProfileLibraryCodec.encode(saved)
        let portable = try AndroidPortableBackup(nativeLibraryData: raw, archives: [])
        let decoded = try AndroidPortableBackup.decode(portable.encodedData())
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(decoded.nativeLibraryData), saved)
    }
    func testDirectionalPresetsPreserveTargetRepeatRatherThanCopyingSourceRepeat() throws {
        let source = try library(interval: 200).activeProfile.controls[0]
        let preset = try StickDirectionalPreset.capture(source)
        var target = source; target.stickPlusRepeatIntervalMilliseconds = 400
        try preset.apply(to: &target, scope: .settingsOnly)
        XCTAssertEqual(target.stickPlusRepeatIntervalMilliseconds, 400)
        try preset.apply(to: &target, scope: .settingsAndMode)
        XCTAssertEqual(target.stickPlusRepeatIntervalMilliseconds, 400)
        target.stickPlusRepeatIntervalMilliseconds = nil
        try preset.apply(to: &target, scope: .settingsAndMode)
        XCTAssertNil(target.stickPlusRepeatIntervalMilliseconds)
    }
    func testAndroidEditedExportBlocksRepeatBeforeUnchangedFastPathButKeepsOriginal() throws {
        let raw = Data(#"[{"id":"stick","name":"Move","type":"STICK","payload":"STICK_L","x":20,"y":40,"w":120,"h":120,"future":{"n":9007199254740993}}]"#.utf8)
        let document = try AndroidProfileDocument.parse(raw)
        let plan = try AndroidProfileImportPlan.prepare(document, archiveID: UUID())
        var p = try XCTUnwrap(plan.profiles.first?.profile)
        XCTAssertEqual(p.controls.count, 1); XCTAssertNil(p.controls[0].stickPlusRepeatIntervalMilliseconds)
        let source = p.androidSources[0]
        XCTAssertEqual(AndroidEditedExportPreview.prepare(profile: p, original: document, source: source).data, raw)
        // Also blocks a saved dormant preference; Android cannot round-trip that choice.
        p.controls[0].stickPlusRepeatIntervalMilliseconds = 200
        let blocked = AndroidEditedExportPreview.prepare(profile: p, original: document, source: source)
        XCTAssertFalse(blocked.canExport); XCTAssertNil(blocked.data)
        XCTAssertTrue(blocked.diagnostics.contains { $0.message.contains("Stick+ repeat") })
        XCTAssertEqual(document.originalData, raw)
        XCTAssertEqual(p.androidSources[0].exportBaseline, source.exportBaseline)
        p.controls[0].stickPlusRepeatIntervalMilliseconds = nil
        XCTAssertEqual(AndroidEditedExportPreview.prepare(profile: p, original: document, source: source).data, raw)
    }
}

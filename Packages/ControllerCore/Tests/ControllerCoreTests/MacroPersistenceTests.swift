import XCTest
@testable import ControllerCore

final class MacroPersistenceTests: XCTestCase {
    private func library(_ control: ProfileControl) throws -> ControllerProfileLibrary {
        let placements = [ProfilePlacement(id: control.id, position: .init(x: 0.2, y: 0.8))]
        let profile = try ControllerProfile(name: "Saved controls", controls: [control], portrait: placements, landscape: placements)
        return try .init(activeProfileID: profile.id, profiles: [profile])
    }
    private func android(_ payload: String = "X360A", macro: Bool = false, version: Int = 17) throws -> AndroidProfileDocument {
        let raw = """
        {"formatVersion":\(version),"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[{"id":"a","name":"A","type":"BUTTON","x":20,"y":30,"w":120,"h":80,"payload":"\(payload)","macroModeEnabled":\(macro),"future":{"keep":123}}]}]}
        """
        return try .parse(Data(raw.utf8))
    }
    func testNativeMacroRoundTripAndOldLayoutPreservation() throws {
        let original = try library(ProfileControl(payload: "X360A", buttonAim: .init()))
        var old = try JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(original)) as! [String: Any]
        old["version"] = 21
        let recovered = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(recovered, original)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(recovered)), original)
        XCTAssertFalse(recovered.activeProfile.controls[0].macroModeEnabled)
        var changed = recovered
        changed.profiles[0].controls[0].macroModeEnabled = true
        changed.profiles[0].controls[0].payload = "X360A(U100),X360B(D300)"
        let bytes = try ControllerProfileLibraryCodec.encode(changed)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(bytes), changed)
        XCTAssertEqual(changed.profiles[0].portrait, original.profiles[0].portrait)
        XCTAssertEqual(changed.profiles[0].landscape, original.profiles[0].landscape)
        XCTAssertEqual(changed.profiles[0].id, original.profiles[0].id)
    }
    func testOldNativeVersionCannotAcceptNewMacroOrReleaseSyntax() throws {
        for control in [ProfileControl(payload: "X360A", macroModeEnabled: true), ProfileControl(payload: "X360A(U100)")] {
            var object = try JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library(control))) as! [String: Any]
            object["version"] = 21
            XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
        }
    }
    func testAndroidMacroImportAndEditedExportRetainNewSettings() throws {
        let document = try android("X360A(U100),X360B(D500)", macro: true)
        let plan = try AndroidProfileImportPlan.prepare(document, archiveID: UUID())
        XCTAssertEqual(plan.convertedControlCount, 1)
        var profile = plan.profiles[0].profile
        XCTAssertTrue(profile.controls[0].macroModeEnabled)
        let untouched = AndroidEditedExportPreview.prepare(profile: profile, original: document, source: profile.androidSources[0])
        XCTAssertEqual(untouched.data, document.originalData)
        profile.controls[0].macroModeEnabled = false
        profile.controls[0].payload = "X360A(U300)"
        let changed = AndroidEditedExportPreview.prepare(profile: profile, original: document, source: profile.androidSources[0])
        let after = try AndroidProfileDocument.parse(XCTUnwrap(changed.data))
        let control = after.profiles[0].pages[0].controls[0]
        XCTAssertEqual(control.value["macroModeEnabled"], .bool(false))
        XCTAssertEqual(control.payload, "X360A(U300)")
        XCTAssertEqual(control.value["future"], document.profiles[0].pages[0].controls[0].value["future"])
    }
    func testOlderAndroidProfileUpgradesOnlyWhenNewFeaturesAreAdded() throws {
        let document = try android(version: 16)
        let plan = try AndroidProfileImportPlan.prepare(document, archiveID: UUID())
        var profile = plan.profiles[0].profile
        let untouched = AndroidEditedExportPreview.prepare(profile: profile, original: document, source: profile.androidSources[0])
        XCTAssertEqual(untouched.data, document.originalData)
        profile.controls[0].macroModeEnabled = true
        let changed = AndroidEditedExportPreview.prepare(profile: profile, original: document, source: profile.androidSources[0])
        let after = try AndroidProfileDocument.parse(XCTUnwrap(changed.data))
        XCTAssertEqual(after.profiles[0].formatVersion, 17)
        XCTAssertEqual(after.profiles[0].pages[0].controls[0].value["macroModeEnabled"], .bool(true))
    }
    func testAndroidOldFormatRejectsActiveAndDormantReleaseConfiguration() throws {
        XCTAssertThrowsError(try android(macro: true, version: 16))
        XCTAssertThrowsError(try android("X360A(U100)", version: 16))
        XCTAssertThrowsError(try android("X360A(Ubad)", version: 16))
        let source = try android(version: 16).originalData
        let changed = String(decoding: source, as: UTF8.self).replacingOccurrences(of: "\"future\":{\"keep\":123}", with: "\"future\":{\"payload\":\"X360A(U100)\"}")
        XCTAssertThrowsError(try AndroidProfileDocument.parse(Data(changed.utf8)))
    }
    func testButtonAimPresetDisablesMacroOnApplication() throws {
        var button = ProfileControl(payload: "X360A", macroModeEnabled: true)
        let preset = ButtonAimPreset(payload: "LT:0.5", settings: .init(enabled: true))
        try preset.apply(to: &button, scope: .complete)
        XCTAssertFalse(button.macroModeEnabled)
        XCTAssertTrue(button.buttonAim.enabled)
        XCTAssertNoThrow(try button.validate())
    }
    func testReleasePresetRequiresNewWireVersionAndRoundTrips() throws {
        let preset = SettingsPreset(name: "Pulse", createdAtMilliseconds: 1,
            value: .buttonAim(.init(payload: "X360A(U100)", settings: .init(enabled: true))))
        let library = SettingsPresetLibrary(entries: [preset])
        let bytes = try SettingsPresetLibraryCodec.encode(library)
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        XCTAssertEqual(object["version"] as? Int, 3)
        XCTAssertEqual(try SettingsPresetLibraryCodec.decode(bytes), library)
        object["version"] = 2
        XCTAssertThrowsError(try SettingsPresetLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
    }
}

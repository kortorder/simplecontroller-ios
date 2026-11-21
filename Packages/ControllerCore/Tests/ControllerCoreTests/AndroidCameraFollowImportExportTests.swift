import XCTest
@testable import ControllerCore

final class AndroidCameraFollowImportExportTests: XCTestCase {
    private func fixture(format: Int = 10, fields: String = #", "cameraFollowStrengthPercent":150,"excludeFromCameraFollow":true,"mouseSuppressCameraFollow":true"#, payload: String = "STICK_L", type: String = "STICK") throws -> (AndroidProfileDocument, ControllerProfile) {
        let data = Data(#"{"formatVersion":\#(format),"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[{"id":"c","name":"Movement","type":"\#(type)","payload":"\#(payload)","x":10,"y":20,"w":120,"h":120,"future":{"number":9007199254740993}\#(fields)}]}]}"#.utf8)
        let d = try AndroidProfileDocument.parse(data), p = try AndroidProfileImportPlan.prepare(d, archiveID: UUID())
        return (d, try XCTUnwrap(p.profiles.first?.profile))
    }
    private func preview(_ p: ControllerProfile, _ d: AndroidProfileDocument) -> AndroidEditedExportPreview { .prepare(profile: p, original: d, source: p.androidSources[0]) }
    private func exported(_ p: ControllerProfile, _ d: AndroidProfileDocument) throws -> AndroidProfileDocument {
        let result = preview(p, d); XCTAssertTrue(result.canExport, "\(result.diagnostics)")
        return try .parse(XCTUnwrap(result.data))
    }
    private func value(_ d: AndroidProfileDocument) -> AndroidJSONValue { d.profiles[0].pages[0].controls[0].value }
    func testFlagsAndStrengthConvertWithExactUntouchedExport() throws {
        let (d, p) = try fixture(), c = try XCTUnwrap(p.controls.first)
        XCTAssertEqual(c.cameraFollowStrengthPercent, 150); XCTAssertTrue(c.excludeFromCameraFollow); XCTAssertTrue(c.mouseSuppressCameraFollow)
        XCTAssertEqual(preview(p, d).data, d.originalData); XCTAssertTrue(preview(p, d).isUnchanged)
    }
    func testEditedFlagsPatchOnlyKnownValuesAndRoundTrip() throws {
        let (d, original) = try fixture(); var p = original
        p.controls[0].cameraFollowStrengthPercent = 45; p.controls[0].excludeFromCameraFollow = false; p.controls[0].mouseSuppressCameraFollow = false
        let next = try exported(p, d), raw = value(next)
        XCTAssertEqual(raw["cameraFollowStrengthPercent"]?.numberValue?.rawValue, "45")
        XCTAssertEqual(raw["excludeFromCameraFollow"], .bool(false)); XCTAssertEqual(raw["mouseSuppressCameraFollow"], .bool(false))
        XCTAssertEqual(raw["future"], value(d)["future"])
        let roundTrip = try AndroidProfileImportPlan.prepare(next, archiveID: UUID()).profiles[0].profile.controls[0]
        XCTAssertEqual(roundTrip.cameraFollowStrengthPercent, 45); XCTAssertFalse(roundTrip.excludeFromCameraFollow); XCTAssertFalse(roundTrip.mouseSuppressCameraFollow)
    }
    func testNewSettingsRaiseAndroidFormatToAuditedEightOrTen() throws {
        let (d, original) = try fixture(format: 5, fields: ""); var p = original
        p.controls[0].cameraFollowStrengthPercent = 80
        XCTAssertEqual(try exported(p, d).profiles[0].formatVersion, 8)
        p.controls[0].mouseSuppressCameraFollow = true
        XCTAssertEqual(try exported(p, d).profiles[0].formatVersion, 10)
    }
    func testOutOfRangeStrengthArchivesWholeControlWithoutClamping() throws {
        for amount in ["-1", "201", "1e500"] {
            let (d, p) = try fixture(fields: #", "cameraFollowStrengthPercent":\#(amount)"#)
            XCTAssertTrue(p.controls.isEmpty); XCTAssertEqual(preview(p, d).data, d.originalData)
        }
    }
    func testDirectCameraCommandsIgnoreInactiveAndroidHoldAndAimSettings() throws {
        for payload in ["CAMERA_FOLLOW", "CAMERA_FOLLOW:1", "CAMERA_FOLLOW:0"] {
            let (d, p) = try fixture(fields: #", "holdToggle":true,"autoTapEnabled":true,"buttonAimEnabled":true"#, payload: payload, type: "BUTTON")
            let c = try XCTUnwrap(p.controls.first)
            XCTAssertTrue(c.isCameraFollowAction); XCTAssertFalse(c.buttonBehavior.holdToggle); XCTAssertFalse(c.autoTapEnabled); XCTAssertFalse(c.buttonAim.enabled)
            XCTAssertEqual(preview(p, d).data, d.originalData)
        }
    }
    private func priorBaseline(_ d: AndroidProfileDocument, _ imported: ControllerProfile) throws -> ControllerProfile {
        var p = imported
        p.controls[0].cameraFollowStrengthPercent = 100; p.controls[0].excludeFromCameraFollow = false; p.controls[0].mouseSuppressCameraFollow = false
        let ref = p.androidSources[0], current = try XCTUnwrap(ref.exportBaseline)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var controls = try XCTUnwrap(raw["controls"] as? [[String: Any]])
        for i in controls.indices {
            var digests = try XCTUnwrap(controls[i]["fieldDigests"] as? [String: String])
            for key in AndroidExportProjection.cameraMigrationDefaults.keys { digests.removeValue(forKey: key) }
            controls[i]["fieldDigests"] = digests
        }
        raw["controls"] = controls
        let legacy = try JSONDecoder().decode(AndroidSourceExportBaseline.self, from: JSONSerialization.data(withJSONObject: raw))
        p.androidSources[0] = ref.withExportBaseline(legacy)
        return p
    }
    func testOlderImportDefaultsDoNotOverwriteArchivedFlagsOnUnrelatedEditOrPageCopy() throws {
        let (d, imported) = try fixture(); var p = try priorBaseline(d, imported)
        XCTAssertTrue(preview(p, d).isUnchanged); XCTAssertEqual(preview(p, d).data, d.originalData)
        p.controls[0].name = "Renamed"
        var result = try exported(p, d)
        for key in AndroidExportProjection.cameraMigrationDefaults.keys { XCTAssertEqual(value(result)[key], value(d)[key]) }
        _ = try p.duplicatePage(p.homePageID)
        result = try exported(p, d)
        for key in AndroidExportProjection.cameraMigrationDefaults.keys { XCTAssertEqual(result.profiles[0].pages[1].controls[0].value[key], value(d)[key]) }
    }
    func testOlderImportExplicitNondefaultEditPatchesOnlyThatField() throws {
        let (d, imported) = try fixture(); var p = try priorBaseline(d, imported)
        p.controls[0].cameraFollowStrengthPercent = 75
        let result = try exported(p, d)
        XCTAssertEqual(value(result)["cameraFollowStrengthPercent"]?.numberValue?.rawValue, "75")
        XCTAssertEqual(value(result)["excludeFromCameraFollow"], .bool(true)); XCTAssertEqual(value(result)["mouseSuppressCameraFollow"], .bool(true))
    }
}

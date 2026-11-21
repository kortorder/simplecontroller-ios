import XCTest
@testable import ControllerCore

final class AndroidTouchAimImportTests: XCTestCase {
    private func fixture(mode: String = "MANUAL_THREE_STAGE", output: String = "MOUSE", highPayload: String = "RT:0.6") throws -> (AndroidProfileDocument, ControllerProfile) {
        let data = Data("""
        {"formatVersion":6,"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[
        {"id":"touch","name":"Android aim","type":"TOUCH_AIM","x":20,"y":30,"w":220,"h":160,"payload":"TOUCH_AIM",
        "touchAimMode":"\(mode)","touchAimOutput":"\(output)","sensitivity":1.8,"touchInvertY":true,
        "touchUseResponseCurve":true,"touchAimStickFullDisplacementPx":180,"touchAimStickDeadzonePx":6,
        "touchUseSize":true,"touchUseMajor":true,"touchUseMinor":true,"touchSizeScale":90,
        "touchLowThreshold":90,"touchMediumThreshold":100,"touchHighThreshold":110,"touchLowPayload":"X360A",
        "touchMediumPayload":"W","touchHighPayload":"\(highPayload)","touchAimAimPayload":"LT:0.3","touchAimShootPayload":"X360B",
        "touchAimAppliedCalibrationId":"android-sensor-id","touchAimSensorTransforms":[{"sensor":"MAJOR","center":9,"scale":2,"weight":1}],
        "futureSensor":{"exact":9007199254740993,"unknown":[true,null,"retained"]}}]}]}
        """.utf8)
        let original = try AndroidProfileDocument.parse(data)
        let plan = try AndroidProfileImportPlan.prepare(original,archiveID:UUID())
        XCTAssertEqual(plan.convertedControlCount,1)
        XCTAssertTrue(plan.issues.contains { $0.message.contains("Contact actions stay disabled") })
        return (original,try XCTUnwrap(plan.profiles.first?.profile))
    }
    private func preview(_ profile:ControllerProfile,_ original:AndroidProfileDocument)->AndroidEditedExportPreview {
        .prepare(profile:profile,original:original,source:profile.androidSources[0])
    }
    func testAllSourceModesKeepAimAndActionsButDoNotTranslateSensorNumbers() throws {
        for mode in ["MANUAL_THREE_STAGE","MANUAL_TWO_STATE","CALIBRATED_TWO_STATE"] {
            let (original,p)=try fixture(mode:mode,output:"RIGHT_STICK"), c=p.controls[0]
            XCTAssertTrue(c.isTouchAim);XCTAssertTrue(c.touchAim.requiresLocalSetup)
            XCTAssertEqual(c.touchAim.aim.output,.rightStick);XCTAssertEqual(c.touchAim.aim.sensitivity,1.8)
            XCTAssertEqual(c.touchAim.aim.stickResponse,.perAxis);XCTAssertEqual(c.touchAim.aim.fullDisplacement,180)
            XCTAssertEqual(c.touchAim.threeStage.low.payload,"X360A");XCTAssertEqual(c.touchAim.threeStage.high.payload,"RT:0.6")
            XCTAssertEqual(c.touchAim.twoState.shootPayload,"X360B")
            XCTAssertEqual(c.touchAim.threeStage.high.threshold,TouchAimSettings().threeStage.high.threshold)
            XCTAssertNil(c.touchAim.calibration)
            XCTAssertEqual(preview(p,original).data,original.originalData)
        }
    }
    func testImportedAimWorksWithMissingMetricsWhileEveryContactActionRemainsOff() throws {
        let (_,p)=try fixture(output:"LEFT_STICK"), c=p.controls[0]
        var engine=try ProfileInputEngine(profile:p)
        let first=TouchAimSample(pointer:.init(x:110,y:80,width:220,height:160),metrics:.init(),elapsed:0)
        try engine.beginTouchAim(contact:1,control:c.id,sample:first,at:0)
        let moved=TouchAimSample(pointer:.init(x:170,y:80,width:220,height:160),metrics:.init(majorRadius:1200),elapsed:0.1)
        try engine.moveTouchAimBatch(contact:1,samples:[moved],at:0.1);try engine.tick(at:10)
        XCTAssertGreaterThan(engine.state.leftStick.x,0);XCTAssertTrue(engine.state.buttons.isEmpty)
        XCTAssertTrue(engine.practiceState.heldKeys.isEmpty);XCTAssertEqual(engine.practiceState.rightTrigger,0)
    }
    func testEditedAimNameAndGeometryPreserveEveryOriginalSensorFieldAndUnknownValue() throws {
        let (original,initial)=try fixture();var p=initial
        p.controls[0].name="Moved aim";p.controls[0].touchAim.aim.sensitivity=2.3
        p.portrait[0].position = .init(x:0.7,y:0.6)
        let result=preview(p,original)
        XCTAssertTrue(result.canExport,result.diagnostics.map(\.message).joined(separator:" | "))
        let exported=try AndroidProfileDocument.parse(try XCTUnwrap(result.data))
        let before=original.profiles[0].pages[0].controls[0].value, after=exported.profiles[0].pages[0].controls[0].value
        for key in ["touchAimMode","touchUseSize","touchUseMajor","touchUseMinor","touchSizeScale","touchLowThreshold","touchMediumThreshold","touchHighThreshold","touchLowPayload","touchMediumPayload","touchHighPayload","touchAimAppliedCalibrationId","touchAimSensorTransforms","futureSensor"] {
            XCTAssertEqual(after[key],before[key],key)
        }
        XCTAssertEqual(after["name"],.string("Moved aim"))
        XCTAssertEqual(after["sensitivity"]?.numberValue?.rawValue,"2.3")
        XCTAssertFalse(String(decoding:result.data!,as:UTF8.self).contains(AndroidExportProjection.touchSetupKey))
    }
    func testChangingNativeSensorFieldsOrClearingSetupBlocksEditedAndroidExport() throws {
        let (original,initial)=try fixture()
        var p=initial;p.controls[0].touchAim.requiresLocalSetup=false
        XCTAssertFalse(preview(p,original).canExport)
        p=initial;p.controls[0].touchAim.threeStage.high.threshold=8
        XCTAssertFalse(preview(p,original).canExport)
        p=initial;p.controls[0].touchAim.metricScale=2
        XCTAssertFalse(preview(p,original).canExport)
        p=initial;p.controls[0].touchAim.aim.mouseResponse = .linearRelative
        XCTAssertFalse(preview(p,original).canExport)
    }
    func testContactPayloadEditsRoundTripIndependentlyOfAndroidSensorSetup() throws {
        let (original, initial) = try fixture()
        var p = initial
        let commands = ["X360B(I)", "LT:0.5(HRD200)", "RT:0.7(R100)", "X360Y(D100)", "X360X(SOR)"]
        for (field, command) in zip(AndroidExportProjection.contactPayloads, commands) {
            p.controls[0].touchAim[keyPath: field.path] = command
        }
        let result = preview(p, original)
        let doc = try AndroidProfileDocument.parse(XCTUnwrap(result.data, result.diagnostics.map(\.message).joined(separator: " | ")))
        XCTAssertEqual(doc.profiles[0].formatVersion, 16)
        let before = original.profiles[0].pages[0].controls[0].value
        let after = doc.profiles[0].pages[0].controls[0].value
        for member in try XCTUnwrap(before.objectValue).members where !AndroidExportProjection.contactPayloadKeys.contains(member.name) {
            XCTAssertEqual(after[member.name], member.value, member.name)
        }
        let imported = try XCTUnwrap(AndroidProfileImportPlan.prepare(doc, archiveID: UUID()).profiles.first?.profile.controls.first)
        XCTAssertTrue(imported.touchAim.requiresLocalSetup)
        for (field, command) in zip(AndroidExportProjection.contactPayloads, commands) {
            XCTAssertEqual(after[field.key], .string(command))
            XCTAssertEqual(imported.touchAim[keyPath: field.path], command)
        }
    }
    func testArchivedOnlyActionSurvivesRenameAndCopyButCanBeReplacedExplicitly() throws {
        let unsupported = "WAIT_100, X360A"
        let (original, initial) = try fixture(highPayload: unsupported)
        var p = initial, copy = initial.controls[0]
        copy.id = UUID(); copy.name = "Second aim pad"
        try p.addControl(copy, toPage: p.homePageID); try p.duplicateSourceBinding(from: initial.controls[0].id, to: copy.id)
        p.controls[0].touchAim.threeStage.medium.payload = "LT:0.5(HRD100)"
        let preserved = try AndroidProfileDocument.parse(XCTUnwrap(preview(p, original).data)).profiles[0].pages[0].controls
        XCTAssertEqual(preserved.map { $0.value["touchHighPayload"] }, [.string(unsupported), .string(unsupported)])
        let index = try XCTUnwrap(p.controls.firstIndex { $0.id == copy.id })
        p.controls[index].touchAim.threeStage.high.payload = "RT:0.6(R200)"
        let changed = try AndroidProfileDocument.parse(XCTUnwrap(preview(p, original).data)).profiles[0].pages[0].controls
        XCTAssertEqual(changed.map { $0.value["touchHighPayload"] }, [.string(unsupported), .string("RT:0.6(R200)")])
    }
    func testOldCombinedDigestMustProveSensorAndContactValuesBeforeSplitting() throws {
        let (original, initial) = try fixture(highPayload: "WAIT_100,X360A")
        var p = initial
        let reference = p.androidSources[0], baseline = try XCTUnwrap(reference.exportBaseline)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any])
        var controls = try XCTUnwrap(json["controls"] as? [[String: Any]])
        var digests = try XCTUnwrap(controls[0]["fieldDigests"] as? [String: String])
        for key in AndroidExportProjection.contactPayloadKeys { digests.removeValue(forKey: key) }
        digests[AndroidExportProjection.touchSetupKey] = try androidExportDigest(AndroidExportProjection.touchSetup(initial.controls[0].touchAim, separatePayloads: false))
        controls[0]["fieldDigests"] = digests; json["controls"] = controls
        let old = try JSONDecoder().decode(AndroidSourceExportBaseline.self, from: JSONSerialization.data(withJSONObject: json))
        p.androidSources[0] = reference.withExportBaseline(old)
        XCTAssertEqual(preview(p, original).data, original.originalData)
        p.controls[0].touchAim.threeStage.medium.payload = "LT:0.7(HRD300)"
        let after = try AndroidProfileDocument.parse(XCTUnwrap(preview(p, original).data)).profiles[0].pages[0].controls[0].value
        XCTAssertEqual(after["touchMediumPayload"], .string("LT:0.7(HRD300)"))
        XCTAssertEqual(after["touchHighPayload"], .string("WAIT_100,X360A"))
        p.controls[0].touchAim.metricScale = 2
        XCTAssertFalse(preview(p, original).canExport)
    }
    func testUnsupportedStageStaysArchivedRatherThanBecomingPlayable() throws {
        let (original,p)=try fixture(highPayload:"WAIT_100,X360A")
        XCTAssertEqual(p.controls[0].touchAim.threeStage.high.payload,"")
        XCTAssertEqual(preview(p,original).data,original.originalData)
        XCTAssertEqual(original.profiles[0].pages[0].controls[0].value["touchHighPayload"],.string("WAIT_100,X360A"))
    }
    func testCopyRetainsSensorOriginalButGetsIndependentNativeAndAndroidIDs() throws {
        let (original,initial)=try fixture();var p=initial,copy=p.controls[0]
        let old=copy.id;copy.id=UUID();try p.addControl(copy,toPage:p.homePageID);try p.duplicateSourceBinding(from:old,to:copy.id)
        let result=preview(p,original);XCTAssertTrue(result.canExport,result.diagnostics.map(\.message).joined(separator:" | "))
        let document=try AndroidProfileDocument.parse(try XCTUnwrap(result.data))
        XCTAssertEqual(document.profiles[0].pages[0].controls.count,2)
        XCTAssertNotEqual(document.profiles[0].pages[0].controls[0].sourceID,document.profiles[0].pages[0].controls[1].sourceID)
        XCTAssertEqual(document.profiles[0].pages[0].controls[1].value["touchAimSensorTransforms"],original.profiles[0].pages[0].controls[0].value["touchAimSensorTransforms"])
    }
}

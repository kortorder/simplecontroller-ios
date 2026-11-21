import Foundation
import XCTest
@testable import ControllerCore

final class SettingsPresetTests:XCTestCase {
    private func directional()throws->ProfileControl {
        var c=ProfileControl(kind:.leftStick,directionalEnabled:true)
        c.directionPayloads[.up]?.normalPayload="W";c.directionPayloads[.up]?.boostPayload="W,SHIFT"
        c.stickBehavior.autoCenter=false;c.stickResponse.sensitivity=2;try c.validate();return c
    }
    private func calibrated()->TouchAimCalibrationProfile {
        .init(transforms:[.init(metric:.majorRadius,center:2,scale:1)],quality:.good,validationCompleted:true)
    }
    private func ring()throws->FloatingRingZone {
        let zone=FloatingRingZone(portraitGeometry:.init(canvasWidth:400,canvasHeight:600,zone:.init(x:20,y:20,width:300,height:400)),config:.init())
        try zone.validate();return zone
    }
    private func preset(_ name:String="Saved",value:SettingsPresetValue?=nil)throws->SettingsPreset {
        try .init(name:name,createdAtMilliseconds:100,value:value ?? .stickDirectional(.capture(directional())))
    }
    func testStandaloneAndEmbeddedPresetTimingVersions() throws {
        var stick = try directional()
        var library = SettingsPresetLibrary(entries: [try preset()])
        func object(_ bytes: Data) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        }
        XCTAssertEqual(try object(SettingsPresetLibraryCodec.encode(library))["version"] as? Int, 1)
        stick.directionPayloads[.up]?.boostPayload = "X360A(R100)"
        try library.save(preset("Sprint", value: .stickDirectional(.capture(stick))))
        let encoded = try SettingsPresetLibraryCodec.encode(library)
        XCTAssertEqual(try SettingsPresetLibraryCodec.decode(encoded), library)
        var oldPresetFile = try object(encoded)
        XCTAssertEqual(oldPresetFile["version"] as? Int, 2)
        oldPresetFile["version"] = 1
        XCTAssertThrowsError(try SettingsPresetLibraryCodec.decode(JSONSerialization.data(withJSONObject: oldPresetFile)))

        var controller = ControllerProfileLibrary.default
        controller.settingsPresets = library
        var oldController = try object(ControllerProfileLibraryCodec.encode(controller))
        oldController["version"] = 20
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: oldController)))
    }
    func testDirectionalSettingsOnlyPreservesResponseRetentionModeGeometryAndIdentity() throws {
        let saved=try StickDirectionalPreset.capture(directional())
        var target=ProfileControl(name:"Target",kind:.rightStick,diameter:150,stickBehavior:.init(autoCenter:true,stickPlusEnabled:true),controlWidth:210,controlHeight:130)
        target.stickResponse.sensitivity=0.3;let id=target.id
        try saved.apply(to:&target,scope:.settingsOnly)
        XCTAssertEqual(target.id,id);XCTAssertEqual(target.name,"Target");XCTAssertEqual(target.resolvedWidth,210);XCTAssertEqual(target.resolvedHeight,130)
        XCTAssertTrue(target.stickBehavior.autoCenter);XCTAssertEqual(target.stickResponse.sensitivity,0.3)
        XCTAssertTrue(target.stickBehavior.stickPlusEnabled);XCTAssertFalse(target.directionalEnabled);XCTAssertEqual(try target.stageProgram(direction:.up,stage:.normal).source,"W")
        try saved.apply(to:&target,scope:.settingsAndMode);XCTAssertTrue(target.directionalEnabled);XCTAssertFalse(target.stickBehavior.stickPlusEnabled)
    }
    func testDirectionalCaptureRejectsPlainAnalogAndAtomicWrongTargetApply() throws {
        XCTAssertThrowsError(try StickDirectionalPreset.capture(ProfileControl(kind:.leftStick)))
        let saved=try StickDirectionalPreset.capture(directional());var target=ProfileControl(actions:[.a]),before=target
        XCTAssertThrowsError(try saved.apply(to:&target,scope:.settingsAndMode));XCTAssertEqual(target,before)
        before=target;var invalid=saved;invalid.boostThreshold=2
        XCTAssertThrowsError(try invalid.apply(to:&target,scope:.settingsOnly));XCTAssertEqual(target,before)
    }
    func testButtonAimTuningOnlyPreservesPayloadActionTimingAndAlternateEnable() throws {
        let source=ProfileControl(payload:"X360Y",buttonAim:.init(enabled:true,payloadTiming:.sendOnRelease,releaseDelayMilliseconds:100,tuning:.init(output:.rightStick,sensitivity:2),alternate:.init(enabled:true,payload:"X360B",tuning:.init(sensitivity:0.3))))
        let preset=try ButtonAimPreset.capture(source)
        var target=ProfileControl(actions:[.a],autoTapEnabled:true,buttonAim:.init(releaseDelayMilliseconds:20),controlWidth:180,controlHeight:44)
        let id=target.id;try preset.apply(to:&target,scope:.tuningOnly)
        XCTAssertEqual(target.id,id);XCTAssertEqual(target.resolvedWidth,180);XCTAssertEqual(target.actions,[.a]);XCTAssertNil(target.payload)
        XCTAssertEqual(target.buttonAim.releaseDelayMilliseconds,20);XCTAssertFalse(target.buttonAim.alternate.enabled)
        XCTAssertEqual(target.buttonAim.tuning.output,.rightStick);XCTAssertEqual(target.buttonAim.alternate.tuning.sensitivity,0.3)
        XCTAssertTrue(target.buttonAim.enabled);XCTAssertFalse(target.autoTapEnabled)
    }
    func testCompleteButtonAimCopiesActionsButPreservesUnrelatedDirectionalSettings() throws {
        let source=ProfileControl(actions:[.a],buttonBehavior:.init(holdToggle:true),buttonAim:.init(enabled:true,payloadTiming:.sendOnRelease,releaseDelayMilliseconds:100))
        let saved=try ButtonAimPreset.capture(source)
        var target=ProfileControl(payload:"X360X",buttonDirectional:.init(enabled:true));target.buttonDirectional.directions[.right]?.firstPayload="W"
        let id=target.id;try saved.apply(to:&target,scope:.complete)
        XCTAssertEqual(target.id,id);XCTAssertEqual(target.actions,[.a]);XCTAssertNil(target.payload);XCTAssertTrue(target.buttonBehavior.holdToggle)
        XCTAssertEqual(target.buttonAim.releaseDelayMilliseconds,100);XCTAssertEqual(target.buttonDirectional.directions[.right]?.firstPayload,"W")
    }
    func testManualTouchPresetChangesSelectedModeOnlyAndClearsCalibration() throws {
        var source=ProfileControl(kind:.touchAim);source.touchAim.threeStage.high.payload="X360Y"
        let saved=try TouchAimManualPreset.capture(source)
        var target=ProfileControl(kind:.touchAim);target.touchAim.twoState.shootPayload="X360B"
        target.touchAim.calibration=calibrated();target.touchAim.mode = .calibratedTwoState
        let id=target.id;try saved.apply(to:&target)
        XCTAssertEqual(target.id,id);XCTAssertEqual(target.touchAim.mode,.manualThreeStage);XCTAssertNil(target.touchAim.calibration)
        XCTAssertEqual(target.touchAim.threeStage.high.payload,"X360Y");XCTAssertEqual(target.touchAim.twoState.shootPayload,"X360B")
        source.touchAim.calibration=calibrated();source.touchAim.mode = .calibratedTwoState
        XCTAssertThrowsError(try TouchAimManualPreset.capture(source))
    }
    func testNativeCalibrationCaptureApplyAndImportInvalidationAreExplicit() throws {
        let value=try SettingsPresetValue.captureCalibration(calibrated());var target=ProfileControl(kind:.touchAim)
        try value.applyCalibration(to:&target);XCTAssertEqual(target.touchAim.mode,.calibratedTwoState)
        let imported=value.requiringLocalCalibrationValidation(),before=target
        XCTAssertThrowsError(try imported.applyCalibration(to:&target));XCTAssertEqual(target,before)
        if case let .touchCalibration(profile)=imported { XCTAssertFalse(profile.validationCompleted);XCTAssertEqual(profile.transforms,calibrated().transforms) } else { XCTFail() }
        var unavailable=calibrated();unavailable.validationCompleted=false;XCTAssertThrowsError(try SettingsPresetValue.captureCalibration(unavailable))
    }
    func testImportedProfileCalibrationKeepsEvidenceAndManualFallbackWithoutChangingLocal() throws {
        var c=ProfileControl(kind:.touchAim);c.touchAim.calibration=calibrated();c.touchAim.mode = .calibratedTwoState;c.touchAim.twoState.shootPayload="X360A"
        var p=ControllerProfileLibrary.default.activeProfile;try p.addControl(c,toPage:p.homePageID)
        let copy=try p.requiringLocalTouchCalibrationValidation()
        XCTAssertTrue(p.controls.last!.touchAim.calibration!.validationCompleted)
        XCTAssertFalse(copy.controls.last!.touchAim.calibration!.validationCompleted);XCTAssertEqual(copy.controls.last!.touchAim.mode,.manualTwoState)
        XCTAssertTrue(copy.controls.last!.touchAim.requiresLocalSetup);XCTAssertFalse(p.controls.last!.touchAim.requiresLocalSetup)
        XCTAssertEqual(copy.controls.last!.touchAim.twoState.shootPayload,"X360A");XCTAssertEqual(copy.portrait,p.portrait);XCTAssertEqual(copy.pages,p.pages)
        let original=try ControllerProfileLibrary(activeProfileID:p.id,profiles:[p]);let normalized=try original.requiringLocalTouchCalibrationValidation()
        XCTAssertEqual(normalized.activeProfile,copy);XCTAssertEqual(normalized.activeProfileID,original.activeProfileID)
    }
    func testImportedCalibrationCannotActivateSavedManualThresholds() throws {
        var c=ProfileControl(kind:.touchAim);c.touchAim.calibration=calibrated();c.touchAim.mode = .calibratedTwoState
        c.touchAim.twoState.aimPayload="X360A";c.touchAim.twoState.shootPayload="X360B"
        var p=ControllerProfileLibrary.default.activeProfile;try p.addControl(c,toPage:p.homePageID)
        let normalized=try p.requiringLocalTouchCalibrationValidation()
        var detector=try TouchAimDetector(settings:normalized.controls.last!.touchAim)
        XCTAssertTrue(try detector.begin(metrics:.init(majorRadius:10)).isEmpty)
        XCTAssertTrue(try detector.observe(metrics:.init(majorRadius:10),at:1).isEmpty)
        XCTAssertTrue(try detector.tick(at:2).isEmpty)
        XCTAssertNil(detector.nextDeadline)
    }
    func testManualPresetPreservesSetupGateAndCannotBeCapturedToBypassIt() throws {
        let saved=try TouchAimManualPreset.capture(ProfileControl(kind:.touchAim))
        var target=ProfileControl(kind:.touchAim);target.touchAim.requiresLocalSetup=true
        target.touchAim.calibration=calibrated()
        XCTAssertThrowsError(try SettingsPreset.capture(target,category:.touchCalibration,name:"Blocked",at:100))
        try saved.apply(to:&target)
        XCTAssertTrue(target.touchAim.requiresLocalSetup);XCTAssertNil(target.touchAim.calibration)
        XCTAssertThrowsError(try TouchAimManualPreset.capture(target))
        target.touchAim.requiresLocalSetup=false
        XCTAssertNoThrow(try TouchAimManualPreset.capture(target))
    }
    func testFreshValidatedCalibrationExplicitlyClearsSetupGate() throws {
        var target=ProfileControl(kind:.touchAim);target.touchAim.requiresLocalSetup=true
        let value=try SettingsPresetValue.captureCalibration(calibrated())
        let before=target
        XCTAssertThrowsError(try value.requiringLocalCalibrationValidation().applyCalibration(to:&target))
        XCTAssertEqual(target,before)
        try value.applyCalibration(to:&target)
        XCTAssertFalse(target.touchAim.requiresLocalSetup);XCTAssertEqual(target.touchAim.mode,.calibratedTwoState)
    }
    func testBoostOnlyPreservesEnableSwitchesOtherTuningAndGeometry() throws {
        var source=FloatingRingConfig();source.boost1.distance=130;source.boost1.directInnerDistance=130;source.boost1.directOuterDistance=155;source.boost1.payload="X360A"
        let saved=try FloatingBoostPreset.capture(source)
        var target=FloatingRingConfig();target.boost1.enabled=false;target.boost2.enabled=true;target.aim.tuning.sensitivity=0.4
        let old=target;try saved.applyBoostSettings(to:&target)
        XCTAssertFalse(target.boost1.enabled);XCTAssertTrue(target.boost2.enabled);XCTAssertEqual(target.boost1.payload,"X360A")
        XCTAssertEqual(target.aim,old.aim);XCTAssertEqual(target.knobs,old.knobs);XCTAssertEqual(target.innerRadius,old.innerRadius)
    }
    func testAimSlotApplyPreservesKnobIdentityGeometryEnableAndRejectsCountMismatch() throws {
        var source=FloatingRingConfig();source.knobs[0].fire.adsPayload="LT:0.6"
        let saved=try FloatingBoostPreset.capture(source,includeAimActions:true)
        var target=FloatingRingConfig();target.aim.enabled=false;target.knobs[0].id="custom";target.startKnobID="custom";target.directBoostAimKnobID="custom";target.knobs[0].enabled=false
        let knob=target.knobs[0];try saved.applyAimActions(to:&target)
        XCTAssertEqual(target.knobs[0].id,knob.id);XCTAssertEqual(target.knobs[0].x,knob.x);XCTAssertFalse(target.knobs[0].enabled);XCTAssertFalse(target.aim.enabled)
        XCTAssertEqual(target.knobs[0].fire.adsPayload,"LT:0.6")
        var mismatch=saved;mismatch.knobActions?.append(.init());let before=target
        XCTAssertThrowsError(try mismatch.applyAimActions(to:&target));XCTAssertEqual(target,before)
    }
    func testRingTemplateInstantiationCopiesBothOrientationsAndInactiveSettingsWithFreshZoneID() throws {
        var original=try ring();original.enabled=false;original.landscapeGeometry=original.portraitGeometry;original.config.boost2.payload="X360Y"
        let value=SettingsPresetValue.floatingRing(original),copy=try value.instantiateRing(name:"Copy")
        XCTAssertNotEqual(copy.id,original.id);XCTAssertEqual(copy.name,"Copy");XCTAssertFalse(copy.enabled)
        XCTAssertEqual(copy.config,original.config);XCTAssertEqual(copy.portraitGeometry,original.portraitGeometry);XCTAssertEqual(copy.landscapeGeometry,original.landscapeGeometry)
        XCTAssertThrowsError(try value.instantiateRing(id:original.id))
    }
    func testLibraryRoundTripSixCategoriesContainsNoLiveContactData() throws {
        let c=ProfileControl(kind:.touchAim)
        let values:[SettingsPresetValue]=[.stickDirectional(try .capture(directional())),.buttonAim(try .capture(ProfileControl(actions:[.a]))),.touchAimManual(try .capture(c)),try .captureCalibration(calibrated()),.floatingBoost(try .capture(.init())),.floatingRing(try ring())]
        let library=SettingsPresetLibrary(entries:try values.map{try preset($0.category.rawValue,value:$0)})
        let data=try SettingsPresetLibraryCodec.encode(library)
        XCTAssertEqual(try SettingsPresetLibraryCodec.decode(data),library)
        let text=String(decoding:data,as:UTF8.self);for forbidden in ["contacts","lastTime","rawSamples","pendingDeadline"] { XCTAssertFalse(text.contains(forbidden)) }
    }
    func testCaseInsensitiveNamesAreUniquePerCategoryAndRenameIsAtomic() throws {
        var library=SettingsPresetLibrary();let first=try preset("Drive");try library.save(first)
        let before=library;XCTAssertThrowsError(try library.save(preset("dRIVE")));XCTAssertEqual(library,before)
        try library.save(preset("Drive",value:.buttonAim(.capture(ProfileControl(actions:[.a])))))
        let second=try preset("Other");try library.save(second);let saved=library
        XCTAssertThrowsError(try library.rename(second.id,to:"DRIVE",at:101));XCTAssertEqual(library,saved)
        try library.rename(second.id,to:" Trimmed ",at:102);XCTAssertEqual(library.entry(second.id)?.name,"Trimmed")
        XCTAssertEqual(library.orderedEntries().first?.id,second.id)
    }
    func testMergeFreshIDsNamesAndCalibrationValidationWithoutOverwritingOriginal() throws {
        let first=try preset("Saved"),calibration=try preset("Fit",value:.captureCalibration(calibrated()))
        var local=SettingsPresetLibrary(entries:[first]);let incoming=SettingsPresetLibrary(entries:[first,calibration])
        let ids=try local.merge(incoming,at:200)
        XCTAssertNotEqual(ids[first.id],first.id);XCTAssertEqual(local.entry(ids[first.id]!)?.name,"Saved (2)");XCTAssertEqual(local.entry(first.id),first)
        if case let .touchCalibration(copy)=local.entry(ids[calibration.id]!)!.value { XCTAssertFalse(copy.validationCompleted) } else { XCTFail() }
        if case let .touchCalibration(original)=incoming.entry(calibration.id)!.value { XCTAssertTrue(original.validationCompleted) } else { XCTFail() }
    }
    func testPerCategoryLimitAndFailedMergeAreAtomic() throws {
        let entries=try (0..<64).map{try preset("Preset \($0)")};var library=SettingsPresetLibrary(entries:entries);let before=library
        XCTAssertThrowsError(try library.save(preset("One too many")));XCTAssertEqual(library,before)
        let imported=SettingsPresetLibrary(entries:[try preset("Extra")]);XCTAssertThrowsError(try library.merge(imported,at:200));XCTAssertEqual(library,before)
        try library.delete(entries[0].id);XCTAssertEqual(library.entries.count,63)
    }
    func testUnknownFutureAndDuplicateFieldsOrIDsAreRejected() throws {
        let library=SettingsPresetLibrary(entries:[try preset()]);let data=try SettingsPresetLibraryCodec.encode(library)
        var object=try JSONSerialization.jsonObject(with:data) as! [String:Any];object["future"]=true
        XCTAssertThrowsError(try SettingsPresetLibraryCodec.decode(JSONSerialization.data(withJSONObject:object)))
        object.removeValue(forKey:"future");object["version"]=SettingsPresetLibrary.currentVersion+1;XCTAssertThrowsError(try SettingsPresetLibraryCodec.decode(JSONSerialization.data(withJSONObject:object)))
        XCTAssertThrowsError(try SettingsPresetLibrary(entries:[library.entries[0],library.entries[0]]).validate())
        var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(library.entries[0].value)) as! [String:Any];value["category"]="futureCategory"
        XCTAssertThrowsError(try JSONDecoder().decode(SettingsPresetValue.self,from:JSONSerialization.data(withJSONObject:value)))
        XCTAssertThrowsError(try SettingsPresetLibraryCodec.decode(Data(repeating:32,count:SettingsPresetLibraryCodec.maximumBytes+1)))
    }
    func testInvalidTimestampOrCategoryReplacementDoesNotMutateStoredValue() throws {
        let first=try preset();var library=SettingsPresetLibrary(entries:[first]);let before=library
        XCTAssertThrowsError(try library.rename(first.id,to:"Changed",at:99));XCTAssertEqual(library,before)
        XCTAssertThrowsError(try library.replaceValue(first.id,with:.buttonAim(.capture(ProfileControl(actions:[.a]))),at:200));XCTAssertEqual(library,before)
    }
}

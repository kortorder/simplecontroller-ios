import Foundation
import XCTest
@testable import ControllerCore

final class ProfileVersionFourteenTests:XCTestCase {
    private func preset()throws->SettingsPreset {
        try SettingsPreset.capture(.init(actions:[.a]),category:.buttonAim,name:"Aim",at:100)
    }
    func testAuthenticThirteenDefaultsLibraryAndKeepsGlobalHoldControlsAndPages() throws {
        var library=ControllerProfileLibrary.default;library.profiles[0].globalHoldEnabled=true
        var raw=try JSONSerialization.jsonObject(with:ControllerProfileLibraryCodec.encode(library)) as! [String:Any]
        raw["version"]=13; removeCameraFollowFieldsForPreSeventeenFixture(&raw);raw.removeValue(forKey:"settingsPresets")
        var profiles=raw["profiles"] as! [[String:Any]]
        for i in profiles.indices {
            var controls=profiles[i]["controls"] as! [[String:Any]]
            for j in controls.indices { var touch=controls[j]["touchAim"] as! [String:Any];touch.removeValue(forKey:"requiresLocalSetup");controls[j]["touchAim"]=touch }
            profiles[i]["controls"]=controls
        };raw["profiles"]=profiles
        let original=try JSONSerialization.data(withJSONObject:raw)
        let restored=try ControllerProfileLibraryCodec.decode(original)
        XCTAssertEqual(restored,library);XCTAssertTrue(restored.activeProfile.globalHoldEnabled);XCTAssertTrue(restored.settingsPresets.entries.isEmpty)
        XCTAssertEqual((try JSONSerialization.jsonObject(with:original) as! [String:Any])["version"] as? Int,13)
    }
    func testFormatFourteenPersistsTypedLibraryButLocalLoadingDoesNotInvalidateCalibration() throws {
        var library=ControllerProfileLibrary.default
        let calibration=TouchAimCalibrationProfile(transforms:[.init(metric:.majorRadius,center:2,scale:1)],quality:.good,validationCompleted:true)
        try library.settingsPresets.save(.init(name:"Fit",createdAtMilliseconds:100,value:.captureCalibration(calibration)))
        try library.settingsPresets.save(preset())
        let copy=try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library))
        XCTAssertEqual(copy,library)
        if case let .touchCalibration(local)=copy.settingsPresets.entries[0].value { XCTAssertTrue(local.validationCompleted) } else { XCTFail() }
        let imported=try copy.requiringLocalTouchCalibrationValidation()
        if case let .touchCalibration(foreign)=imported.settingsPresets.entries[0].value { XCTAssertFalse(foreign.validationCompleted) } else { XCTFail() }
        XCTAssertEqual(imported.activeProfileID,copy.activeProfileID);XCTAssertEqual(imported.androidSources,copy.androidSources)
    }
    func testMissingUnknownAndOlderVersionPresetFieldsAreRejected() throws {
        var raw=try JSONSerialization.jsonObject(with:ControllerProfileLibraryCodec.encode(.default)) as! [String:Any]
        let original=raw;raw.removeValue(forKey:"settingsPresets")
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:raw)))
        raw=original;raw["version"]=13; removeCameraFollowFieldsForPreSeventeenFixture(&raw)
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:raw)))
        raw=original;raw["unknownPresets"]=[]
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:raw)))
    }
    func testInvalidDuplicatePresetIDsFailNativeLibraryAtomically() throws {
        var library=ControllerProfileLibrary.default;let saved=try preset()
        library.settingsPresets.entries=[saved,saved]
        XCTAssertThrowsError(try library.validate());XCTAssertThrowsError(try ControllerProfileLibraryCodec.encode(library))
    }
}

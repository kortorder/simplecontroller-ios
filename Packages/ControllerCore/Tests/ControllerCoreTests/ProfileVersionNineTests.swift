import Foundation
import XCTest
@testable import ControllerCore

final class ProfileVersionNineTests: XCTestCase {
    func testFormatEightMigrationPreservesLayoutAndDisablesNewGestures() throws {
        let library=ControllerProfileLibrary.default
        var value=try JSONSerialization.jsonObject(with:ControllerProfileLibraryCodec.encode(library)) as! [String:Any]
        value["version"]=8; removeCameraFollowFieldsForPreSeventeenFixture(&value); value.removeValue(forKey:"settingsPresets")
        var profiles=value["profiles"] as! [[String:Any]]
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        for profileIndex in profiles.indices {
            var pages=profiles[profileIndex]["pages"] as! [[String:Any]]
            for pageIndex in pages.indices { pages[pageIndex].removeValue(forKey:"floatingButtonZones");pages[pageIndex].removeValue(forKey:"floatingRingZones") }
            profiles[profileIndex]["pages"]=pages
        }

        for i in profiles.indices {
            var controls=profiles[i]["controls"] as! [[String:Any]]
            for j in controls.indices { for key in ["buttonDirectional","buttonAim","controlWidth","controlHeight","touchAim"] { controls[j].removeValue(forKey:key) } }
            profiles[i]["controls"]=controls
        }
        value["profiles"]=profiles
        let migrated=try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:value))
        XCTAssertEqual(migrated,library)
        XCTAssertTrue(migrated.activeProfile.controls.allSatisfy{!$0.isAdvancedButton && $0.controlWidth == nil && $0.controlHeight == nil})
    }
    func testFormatNineStrictRoundTripPreservesSettingsGeometryAndClone() throws {
        var p=ControllerProfileLibrary.default.activeProfile
        var c=p.controls[0];c.buttonAim = .init(enabled:true,payloadTiming:.sendOnRelease,releaseDelayMilliseconds:100,cancelOnBoundaryExit:true,rearmOnBoundaryReturn:true,tuning:.init(output:.dpad),alternate:.init(enabled:true,payload:"X360B",displayName:"Second"))
        c.buttonDirectional.enabled=true;c.buttonDirectional.directions[.up]?.firstPayload="X360Y";c.controlWidth=200;c.controlHeight=60;p.controls[0]=c
        let library=try ControllerProfileLibrary(activeProfileID:p.id,profiles:[p])
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library)),library)
        XCTAssertEqual(try JSONDecoder().decode(ProfileControl.self,from:JSONEncoder().encode(c)),c)
        let clone=try p.cloned();XCTAssertEqual(clone.controls[0].buttonAim,c.buttonAim);XCTAssertEqual(clone.controls[0].controlHeight,60)
    }
    func testFormatNineMissingAndUnknownControlFieldsAreRejected() throws {
        var c=try JSONSerialization.jsonObject(with:JSONEncoder().encode(ProfileControl())) as! [String:Any]
        for key in ["buttonAim","buttonDirectional","controlWidth","controlHeight"] {
            var changed=c;changed.removeValue(forKey:key)
            XCTAssertThrowsError(try JSONDecoder().decode(ProfileControl.self,from:JSONSerialization.data(withJSONObject:changed)))
        }
        c["future"]=true;XCTAssertThrowsError(try JSONDecoder().decode(ProfileControl.self,from:JSONSerialization.data(withJSONObject:c)))
    }
    func testNestedSettingsRejectUnknownAndMissingFields() throws {
        let values:[Data]=[try JSONEncoder().encode(ButtonAimSettings()),try JSONEncoder().encode(ButtonAimTuning()),try JSONEncoder().encode(ButtonAimAlternateSettings()),try JSONEncoder().encode(ButtonDirectionalSettings()),try JSONEncoder().encode(ButtonDirectionStages())]
        for (index,data) in values.enumerated() {
            var object=try JSONSerialization.jsonObject(with:data) as! [String:Any];object["future"]=1
            let raw=try JSONSerialization.data(withJSONObject:object)
            switch index {
            case 0:XCTAssertThrowsError(try JSONDecoder().decode(ButtonAimSettings.self,from:raw))
            case 1:XCTAssertThrowsError(try JSONDecoder().decode(ButtonAimTuning.self,from:raw))
            case 2:XCTAssertThrowsError(try JSONDecoder().decode(ButtonAimAlternateSettings.self,from:raw))
            case 3:XCTAssertThrowsError(try JSONDecoder().decode(ButtonDirectionalSettings.self,from:raw))
            default:XCTAssertThrowsError(try JSONDecoder().decode(ButtonDirectionStages.self,from:raw))
            }
        }
    }
    func testSettingsRejectNonfiniteThresholdsAndInvalidTiming() throws {
        for value in [Double.nan,.infinity,-1,1201] { XCTAssertThrowsError(try ButtonDirectionStages(firstDistance:value).validate()) }
        XCTAssertThrowsError(try ButtonDirectionStages(firstDistance:48,secondDistance:48).validate())
        for value in [Double.nan,.infinity,-1,5.01] { XCTAssertThrowsError(try ButtonAimTuning(sensitivity:value).validate()) }
        XCTAssertThrowsError(try ButtonAimTuning(fullDisplacement:8,deadzone:8).validate())
        XCTAssertThrowsError(try ButtonAimSettings(releaseDelayMilliseconds:-1).validate())
        XCTAssertThrowsError(try ButtonAimAlternateSettings(resetHoldMilliseconds:60001).validate())
        XCTAssertThrowsError(try ButtonAimAlternateSettings(displayName:String(repeating:"x",count:65)).validate())
        var d=ButtonDirectionalSettings();d.directions[.up]=nil;XCTAssertThrowsError(try d.validate())
    }
    func testAdvancedGesturePayloadAndModeConflictsAreExplicit() throws {
        for payload in ["WAIT_10","MOUSE_LEFT_UP","SCROLL_MODE_TOGGLE"] { XCTAssertThrowsError(try ProfileControl(payload:payload,buttonAim:.init(enabled:true)).validate()) }
        XCTAssertThrowsError(try ProfileControl(autoTapEnabled:true,buttonAim:.init(enabled:true)).validate())
        XCTAssertThrowsError(try ProfileControl(buttonBehavior:.init(holdToggle:true),buttonDirectional:.init(enabled:true)).validate())
        XCTAssertNoThrow(try ProfileControl(buttonBehavior:.init(holdToggle:true),buttonDirectional:.init(enabled:true),buttonAim:.init(enabled:true)).validate())
        XCTAssertThrowsError(try ProfileControl(kind:.leftStick,buttonAim:.init(enabled:true)).validate())
        XCTAssertThrowsError(try ProfileControl(buttonAim:.init(enabled:true,alternate:.init(enabled:true,payload:"X360A"))).validate())
    }
    func testGeometryDefaultsAndBoundsPreserveLegacyCircles() throws {
        var c=ProfileControl(diameter:60);XCTAssertEqual(c.resolvedWidth,60);XCTAssertEqual(c.resolvedHeight,60)
        c.controlWidth=200;c.controlHeight=44;try c.validate();XCTAssertEqual(c.resolvedWidth,200);XCTAssertEqual(c.resolvedHeight,44)
        c.controlWidth=1201;XCTAssertThrowsError(try c.validate())
        c.controlWidth = .nan;XCTAssertThrowsError(try c.validate())
        XCTAssertThrowsError(try ProfileControl(kind:.leftStick,controlWidth:100).validate())
        XCTAssertNoThrow(try ProfileControl(kind:.leftStick,controlWidth:300,controlHeight:104).validate())
    }
    func testCapabilityMetadataIncludesAimAndDirectionalPayloads() throws {
        var c=ProfileControl(buttonAim:.init(enabled:true,tuning:.init(output:.rightStick),alternate:.init(enabled:true,payload:"W",tuning:.init(output:.mouse))))
        c.actions=[.a];c.buttonDirectional.enabled=true;c.buttonDirectional.directions[.down]?.firstPayload="MOUSE_RIGHT_DOWN"
        try c.validate();XCTAssertTrue(c.hasAnyOutput);XCTAssertTrue(c.hasKeyboardOrMouseOutputs);XCTAssertTrue(c.outputTargets.contains(.rightStick));XCTAssertTrue(c.outputTargets.contains(.a))
        c.buttonAim.tuning.output = .dpad;XCTAssertTrue(c.outputTargets.isSuperset(of:[.dpadUp,.dpadDown,.dpadLeft,.dpadRight]))
    }
    func testLegacyBehaviorAndWireFormatsRemainUnchanged() throws {
        let text=String(decoding:try JSONEncoder().encode(ControllerBehaviors.default),as:UTF8.self)
        XCTAssertFalse(text.contains("buttonAim"));XCTAssertFalse(text.contains("buttonDirectional"))
        let packet=BridgePacket(kind:.state,session:UUID().uuidString,sequence:1,state:.neutral)
        let wire=try BridgeCodec.encode(packet);XCTAssertFalse(String(decoding:wire,as:UTF8.self).contains("buttonAim"))
        XCTAssertEqual(try BridgeCodec.decode(wire),packet)
    }
}

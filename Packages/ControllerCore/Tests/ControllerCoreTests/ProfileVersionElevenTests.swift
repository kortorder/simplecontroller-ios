import Foundation
import XCTest
@testable import ControllerCore

final class ProfileVersionElevenTests:XCTestCase {
    func testAuthenticFormatTenMigratesWithoutChangingExistingControlsOrPages() throws {
        let library=ControllerProfileLibrary.default
        var raw=try JSONSerialization.jsonObject(with:ControllerProfileLibraryCodec.encode(library)) as! [String:Any];raw["version"]=10; removeCameraFollowFieldsForPreSeventeenFixture(&raw); raw.removeValue(forKey:"settingsPresets")
        var profiles=raw["profiles"] as! [[String:Any]]
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        for profileIndex in profiles.indices {
            var pages=profiles[profileIndex]["pages"] as! [[String:Any]]
            for pageIndex in pages.indices { pages[pageIndex].removeValue(forKey:"floatingButtonZones");pages[pageIndex].removeValue(forKey:"floatingRingZones") }
            profiles[profileIndex]["pages"]=pages
        }

        for i in profiles.indices { var controls=profiles[i]["controls"] as! [[String:Any]];for j in controls.indices { controls[j].removeValue(forKey:"touchAim") };profiles[i]["controls"]=controls };raw["profiles"]=profiles
        let bytes=try JSONSerialization.data(withJSONObject:raw),restored=try ControllerProfileLibraryCodec.decode(bytes)
        XCTAssertEqual(restored,library);XCTAssertTrue(restored.activeProfile.controls.allSatisfy{!$0.isTouchAim && $0.touchAim == .init()})
        XCTAssertEqual((try JSONSerialization.jsonObject(with:bytes) as! [String:Any])["version"] as? Int,10)
    }
    func testTouchAimRoundTripCloneGeometryAndCapabilityMetadata() throws {
        var p=ControllerProfileLibrary.default.activeProfile,c=ProfileControl(kind:.touchAim,controlWidth:300,controlHeight:180)
        c.touchAim.aim.output = .rightStick;c.touchAim.mode = .manualTwoState;c.touchAim.twoState.aimPayload="W"
        try p.addControl(c,toPage:p.homePageID)
        let library=try ControllerProfileLibrary(activeProfileID:p.id,profiles:[p])
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library)),library)
        let clone=try p.cloned(),copy=clone.controls.last!;XCTAssertNotEqual(copy.id,c.id);XCTAssertEqual(copy.touchAim,c.touchAim)
        XCTAssertEqual(copy.resolvedWidth,300);XCTAssertEqual(copy.resolvedHeight,180);XCTAssertTrue(copy.hasAnyOutput);XCTAssertTrue(copy.hasKeyboardOrMouseOutputs)
        XCTAssertEqual(copy.outputTargets,[.rightStick,.rightTrigger]);XCTAssertFalse(copy.acceptsSwipeEntry)
        let plain=ProfileControl(kind:.touchAim);XCTAssertEqual(plain.resolvedWidth,220);XCTAssertEqual(plain.resolvedHeight,160)
    }
    func testTouchAimIsStrictRequiredFormatElevenFieldAndRejectsOlderKind() throws {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(ProfileControl())) as! [String:Any]
        object.removeValue(forKey:"touchAim");XCTAssertThrowsError(try JSONDecoder().decode(ProfileControl.self,from:JSONSerialization.data(withJSONObject:object)))
        var library=ControllerProfileLibrary.default;var profile=library.profiles[0];try profile.addControl(.init(kind:.touchAim),toPage:profile.homePageID);library.profiles[0]=profile
        var root=try JSONSerialization.jsonObject(with:ControllerProfileLibraryCodec.encode(library)) as! [String:Any];root["version"]=10; removeCameraFollowFieldsForPreSeventeenFixture(&root); root.removeValue(forKey:"settingsPresets")
        var profiles=root["profiles"] as! [[String:Any]],controls=profiles[0]["controls"] as! [[String:Any]]
        for i in controls.indices { controls[i].removeValue(forKey:"touchAim") };profiles[0]["controls"]=controls;root["profiles"]=profiles
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:root)))
    }
    func testTouchAimRejectsUnsupportedModeCombinationsAndNonfiniteValues() throws {
        XCTAssertThrowsError(try ProfileControl(kind:.touchAim,buttonBehavior:.init(holdToggle:true)).validate())
        XCTAssertThrowsError(try ProfileControl(kind:.touchAim,autoTapEnabled:true).validate())
        XCTAssertThrowsError(try ProfileControl(kind:.touchAim,actions:[.a]).validate())
        var s=TouchAimSettings();s.aim.autoCenter=false;XCTAssertThrowsError(try s.validate());s.aim.autoCenter=true;s.aim.output = .dpad;XCTAssertThrowsError(try s.validate())
        for value in [Double.nan,.infinity,-1] { s = .init();s.metricScale=value;XCTAssertThrowsError(try s.validate()) }
        s = .init();s.threeStage.high.payload="WAIT_10";XCTAssertThrowsError(try s.validate())
    }
    func testBridgeWireStaysUnchangedAndContainsNoSensorsOrCalibration() throws {
        let packet=BridgePacket(kind:.state,session:UUID().uuidString,sequence:1,state:.neutral)
        let text=String(decoding:try BridgeCodec.encode(packet),as:UTF8.self)
        XCTAssertFalse(text.contains("touchAim"));XCTAssertFalse(text.contains("majorRadius"));XCTAssertFalse(text.contains("calibration"))
    }
}

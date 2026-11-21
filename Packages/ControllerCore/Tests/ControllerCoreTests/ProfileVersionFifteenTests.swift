import XCTest
@testable import ControllerCore

final class ProfileVersionFifteenTests: XCTestCase {
    func testAuthenticFourteenKeepsExistingTouchSettingsAndDefaultsSetupGateOff() throws {
        var profile = try ControllerProfile()
        try profile.addControl(.init(kind:.touchAim),toPage:profile.homePageID)
        let library = try ControllerProfileLibrary(activeProfileID:profile.id,profiles:[profile])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:ControllerProfileLibraryCodec.encode(library)) as? [String:Any])
        object["version"] = 14; removeCameraFollowFieldsForPreSeventeenFixture(&object)
        var profiles = try XCTUnwrap(object["profiles"] as? [[String:Any]])
        var controls = try XCTUnwrap(profiles[0]["controls"] as? [[String:Any]])
        var touch = try XCTUnwrap(controls[0]["touchAim"] as? [String:Any]);touch.removeValue(forKey:"requiresLocalSetup")
        controls[0]["touchAim"] = touch;profiles[0]["controls"] = controls;object["profiles"] = profiles
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:object)),library)
        touch["requiresLocalSetup"] = true;controls[0]["touchAim"] = touch;profiles[0]["controls"] = controls;object["profiles"] = profiles
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:object)))
    }
    func testSetupFlagPersistsAndIsRequiredBoolean() throws {
        var settings = TouchAimSettings(requiresLocalSetup:true)
        settings.threeStage.high.payload = "W,RT:1.0"
        XCTAssertEqual(try JSONDecoder().decode(TouchAimSettings.self,from:JSONEncoder().encode(settings)),settings)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(settings)) as? [String:Any])
        for replacement in [nil,"true",1] as [Any?] {
            var object=original;object["requiresLocalSetup"]=replacement
            XCTAssertThrowsError(try JSONDecoder().decode(TouchAimSettings.self,from:JSONSerialization.data(withJSONObject:object)))
        }
    }
    func testUnvalidatedCalibrationOnlyAllowedBehindSetupGate() throws {
        var settings = TouchAimSettings(mode:.calibratedTwoState,requiresLocalSetup:true)
        XCTAssertNoThrow(try settings.validate())
        settings.requiresLocalSetup=false;XCTAssertThrowsError(try settings.validate())
    }
    func testAllModesRemainAimOnlyWithNoMetricAndExtremeSamplesWhileSetupIsRequired() throws {
        for mode in TouchAimMode.allCases {
            var settings = TouchAimSettings(mode:mode,requiresLocalSetup:true)
            settings.threeStage.low.payload="X360A";settings.threeStage.medium.payload="W";settings.threeStage.high.payload="RT:1.0"
            settings.twoState.aimPayload="MOUSE_LEFT_DOWN";settings.twoState.shootPayload="RT:1.0"
            var detector = try TouchAimDetector(settings:settings)
            XCTAssertTrue(try detector.begin(metrics:.init(),at:0).isEmpty)
            XCTAssertTrue(try detector.observe(metrics:.init(majorRadius:1200,normalizedForce:1),at:0.1).isEmpty)
            XCTAssertTrue(try detector.tick(at:30).isEmpty)
            XCTAssertEqual(detector.state,.aim);XCTAssertNil(detector.nextDeadline);XCTAssertNil(detector.issue)
            XCTAssertTrue(detector.end().isEmpty)
        }
    }
    func testGatedRuntimeStillMovesAimButNeverProducesAnyStagedOutput() throws {
        for mode in TouchAimMode.allCases {
            var c=ProfileControl(kind:.touchAim);c.touchAim.mode=mode;c.touchAim.requiresLocalSetup=true
            c.touchAim.aim.output = .rightStick;c.touchAim.aim.fullDisplacement=100
            c.touchAim.threeStage.low.payload="X360A";c.touchAim.threeStage.high.payload="W,RT:1.0,MOUSE_LEFT_DOWN"
            c.touchAim.twoState.aimPayload="MOUSE_RIGHT_DOWN";c.touchAim.twoState.shootPayload="X360B,LT:1.0"
            var p=try ControllerProfile();try p.addControl(c,toPage:p.homePageID)
            var e=try ProfileInputEngine(profile:p)
            let begin=TouchAimSample(pointer:.init(x:100,y:100,width:200,height:200),metrics:.init(),elapsed:0)
            try e.beginTouchAim(contact:1,control:c.id,sample:begin,at:0)
            let move=TouchAimSample(pointer:.init(x:150,y:100,width:200,height:200),metrics:.init(majorRadius:1200),elapsed:0.1)
            try e.moveTouchAimBatch(contact:1,samples:[move],at:0.1);try e.tick(at:10)
            XCTAssertGreaterThan(e.state.rightStick.x,0)
            XCTAssertTrue(e.state.buttons.isEmpty);XCTAssertEqual(e.practiceState.leftTrigger,0);XCTAssertEqual(e.practiceState.rightTrigger,0)
            XCTAssertTrue(e.practiceState.heldKeys.isEmpty);XCTAssertTrue(e.practiceState.heldMouseButtons.isEmpty);XCTAssertNil(e.nextDeadline)
            XCTAssertEqual(c.outputTargets,[.rightStick]);XCTAssertFalse(c.hasKeyboardOrMouseOutputs)
            try e.end(contact:1,at:10.1);XCTAssertTrue(e.state.isNeutral)
        }
    }
    func testExplicitLocalSetupCanEnableActionsButProfileApplyClearsOldContacts() throws {
        var c=ProfileControl(kind:.touchAim);c.touchAim.requiresLocalSetup=true;c.touchAim.threeStage.high.payload="X360Y"
        var p=try ControllerProfile();try p.addControl(c,toPage:p.homePageID)
        var e=try ProfileInputEngine(profile:p)
        let sample=TouchAimSample(pointer:.init(x:100,y:100,width:200,height:200),metrics:.init(majorRadius:10),elapsed:0)
        try e.beginTouchAim(contact:1,control:c.id,sample:sample,at:0);XCTAssertTrue(e.state.buttons.isEmpty)
        p.controls[0].touchAim.requiresLocalSetup=false
        try e.apply(profile:p);XCTAssertTrue(e.state.isNeutral)
        try e.beginTouchAim(contact:2,control:c.id,sample:sample,at:1);XCTAssertTrue(e.state.buttons.contains(.y))
    }
}

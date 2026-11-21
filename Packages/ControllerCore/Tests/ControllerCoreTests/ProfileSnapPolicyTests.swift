import XCTest
@testable import ControllerCore

final class ProfileSnapPolicyTests: XCTestCase {
    func testBatchEditsBothStickKindsAndEnabledAimButNeverTouchAimOrOrdinaryButtons() throws {
        var left = ProfileControl(name:"Left",kind:.leftStick)
        left.stickBehavior.stickPlusEnabled = true
        var directional = ProfileControl(name:"Directions",kind:.rightStick)
        directional.directionalEnabled = true
        var aim = ProfileControl(name:"Aim",kind:.button)
        aim.buttonAim.enabled = true
        let touch = ProfileControl(name:"Touch Aim",kind:.touchAim)
        let ordinary = ProfileControl(name:"Button",kind:.button)
        let pad = ProfileControl(name:"Pad",kind:.touchpad)
        var profile = try ControllerProfile(name:"Snap draft")
        for control in [left,directional,aim,touch,ordinary,pad] { try profile.addControl(control,toPage:profile.homePageID) }
        let before = profile
        XCTAssertEqual(try profile.setAllAutoCenter(false),3)
        XCTAssertFalse(profile.controls[0].stickBehavior.autoCenter)
        XCTAssertFalse(profile.controls[1].stickBehavior.autoCenter)
        XCTAssertFalse(profile.controls[2].buttonAim.tuning.autoCenter)
        XCTAssertFalse(profile.controls[2].buttonAim.alternate.tuning.autoCenter)
        XCTAssertEqual(Array(profile.controls[3...]),Array(before.controls[3...]))
        XCTAssertEqual(profile.portrait,before.portrait)
        XCTAssertEqual(profile.landscape,before.landscape)
        XCTAssertEqual(profile.pages,before.pages)
        XCTAssertEqual(try profile.setAllAutoCenter(false),0)
        XCTAssertEqual(try profile.setAllAutoCenter(true),3)
        XCTAssertEqual(profile,before)
    }
    func testInvalidProfileDoesNotPartiallyMutate() throws {
        var profile = try ControllerProfile(name:"Draft")
        try profile.addControl(.init(name:"Stick",kind:.leftStick),toPage:profile.homePageID)
        profile.name = ""
        let before = profile
        XCTAssertThrowsError(try profile.setAllAutoCenter(false))
        XCTAssertEqual(profile,before)
    }
}

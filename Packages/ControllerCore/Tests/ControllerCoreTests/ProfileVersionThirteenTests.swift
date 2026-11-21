import XCTest
@testable import ControllerCore

final class ProfileVersionThirteenTests: XCTestCase {
    func testAuthenticFormatTwelveMigratesWithGlobalHoldOffAndExactExistingSettings() throws {
        let library = ControllerProfileLibrary.default
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String:Any])
        object["version"] = 12; removeCameraFollowFieldsForPreSeventeenFixture(&object); object.removeValue(forKey:"settingsPresets")
        var profiles = try XCTUnwrap(object["profiles"] as? [[String:Any]])
        for i in profiles.indices { profiles[i].removeValue(forKey:"globalHoldEnabled") }
        var oldControls = try XCTUnwrap(profiles[0]["controls"] as? [[String:Any]])
        for i in oldControls.indices {
            var touch = try XCTUnwrap(oldControls[i]["touchAim"] as? [String:Any]); touch.removeValue(forKey:"requiresLocalSetup"); oldControls[i]["touchAim"] = touch
        }
        profiles[0]["controls"] = oldControls
        object["profiles"] = profiles
        let restored = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(restored,library)
        XCTAssertFalse(restored.activeProfile.globalHoldEnabled)
    }
    func testGlobalHoldRoundTripAndCloneKeepExplicitChoice() throws {
        var profile = ControllerProfileLibrary.default.activeProfile
        profile.globalHoldEnabled = true
        let library = try ControllerProfileLibrary(activeProfileID:profile.id,profiles:[profile])
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library)),library)
        XCTAssertTrue(try profile.cloned().globalHoldEnabled)
        XCTAssertFalse(try ControllerProfile().globalHoldEnabled)
        XCTAssertFalse(try ControllerProfile.migrating(layout:.default,behaviors:.default).globalHoldEnabled)
    }
    func testGlobalHoldIsStrictRequiredBooleanAndCannotBeSmuggledIntoOlderFormat() throws {
        let library = ControllerProfileLibrary.default
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with:ControllerProfileLibraryCodec.encode(library)) as? [String:Any])
        for value in [nil, "true", 1] as [Any?] {
            var object = original
            var profiles = try XCTUnwrap(object["profiles"] as? [[String:Any]])
            profiles[0]["globalHoldEnabled"] = value
            object["profiles"] = profiles
            XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:object)))
        }
        var old = original; old["version"] = 12; removeCameraFollowFieldsForPreSeventeenFixture(&old); old.removeValue(forKey:"settingsPresets")
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject:old)))
    }
    func testReleaseAllMetadataIsDirectOnlyEvenBeforeParserRuntimeIntegration() {
        let control = ProfileControl(payload:" release_all ")
        XCTAssertTrue(control.isReleaseAllAction)
        XCTAssertTrue(control.isLocalAction)
        XCTAssertFalse(control.acceptsSwipeEntry)
        XCTAssertFalse(ProfileControl(payload:"X360A,RELEASE_ALL").isReleaseAllAction)
    }
    func testGlobalHoldScopePreservesExplicitAndAdvancedBehaviors() throws {
        var profile = try ControllerProfile(globalHoldEnabled: true)
        let plain = ProfileControl(payload:"W")
        XCTAssertTrue(plain.supportsGlobalHold)
        XCTAssertTrue(profile.usesGlobalHold(for: plain))
        XCTAssertFalse(profile.usesGlobalHold(for:.init(buttonBehavior:.init(holdToggle:true),payload:"W")))
        XCTAssertFalse(profile.usesGlobalHold(for:.init(payload:"W",autoTapEnabled:true)))
        var advanced = plain; advanced.buttonAim.enabled = true
        XCTAssertFalse(profile.usesGlobalHold(for:advanced))
        advanced = plain; advanced.buttonDirectional.enabled = true
        XCTAssertFalse(profile.usesGlobalHold(for:advanced))
        XCTAssertFalse(profile.usesGlobalHold(for:.init(payload:"SCROLL_MODE_TOGGLE")))
        XCTAssertFalse(profile.usesGlobalHold(for:.init(payload:"RELEASE_ALL")))
        profile.turboEnabled = true
        XCTAssertFalse(profile.usesGlobalHold(for:plain))
        XCTAssertTrue(profile.usesGlobalHold(for:.init(payload:"RT:1.0P0.3")))
        XCTAssertTrue(profile.usesGlobalHold(for:.init(payload:"W,WAIT_100,A")))
    }
}

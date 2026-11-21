import Foundation
import XCTest
@testable import ControllerCore

final class ProfileVersionFourTests: XCTestCase {
    func testTouchpadDefaultGeometryModesAndBounds() throws {
        let p = ProfileControl(kind: .touchpad)
        XCTAssertEqual(p.touchpadWidth, 220); XCTAssertEqual(p.touchpadHeight, 160)
        XCTAssertEqual(p.touchpadBehavior, .init()); XCTAssertTrue(p.isTouchpad)
        XCTAssertTrue(p.hasAnyOutput); XCTAssertTrue(p.hasKeyboardOrMouseOutputs); XCTAssertEqual(p.outputTargets, [])
        for value in [44.0, 1_200] { XCTAssertNoThrow(try ProfileControl(kind: .touchpad, touchpadWidth: value, touchpadHeight: value).validate()) }
        for value in [43.9, 1_201, .nan, .infinity] {
            XCTAssertThrowsError(try ProfileControl(kind: .touchpad, touchpadWidth: value).validate())
            XCTAssertThrowsError(try ProfileControl(kind: .touchpad, touchpadHeight: value).validate())
        }
        for value in [0.0, 5] { XCTAssertNoThrow(try TouchpadBehavior(sensitivity: value).validate()) }
        for value in [-0.1, 5.1, .nan, .infinity] { XCTAssertThrowsError(try TouchpadBehavior(sensitivity: value).validate()) }
    }
    func testScrollToggleIsStandaloneAndCannotBeRepeatedOrUsedByStages() throws {
        let button = ProfileControl(payload: "scroll_mode_toggle")
        XCTAssertTrue(button.isScrollModeToggle); XCTAssertTrue(button.hasAnyOutput); XCTAssertTrue(button.hasKeyboardOrMouseOutputs)
        XCTAssertThrowsError(try ControllerPayloadProgram.parse("SCROLL_MODE_TOGGLE, X360A"))
        XCTAssertThrowsError(try ProfileControl(buttonBehavior: .init(holdToggle: true), payload: "SCROLL_MODE_TOGGLE").validate())
        XCTAssertThrowsError(try ProfileControl(payload: "SCROLL_MODE_TOGGLE", autoTapEnabled: true).validate())
        XCTAssertThrowsError(try ControllerPayloadProgram.parse("SCROLL_MODE_TOGGLE").validateSustained())
        XCTAssertThrowsError(try ProfileControl(kind: .touchpad, payload: "W").validate())
    }
    func testAuthenticVersionThreeAddsTouchpadDefaultsWithoutLosingExistingData() throws {
        var library = ControllerProfileLibrary.default
        library.profiles[0].swipeMode = .buttons
        library.profiles[0].controls[0].payload = "W,MOUSE_LEFT_DOWN"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        object["version"] = 3; removeCameraFollowFieldsForPreSeventeenFixture(&object); object.removeValue(forKey:"settingsPresets"); object.removeValue(forKey: "androidSources")
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        for i in profiles.indices {
            profiles[i].removeValue(forKey: "androidSources")
            profiles[i].removeValue(forKey: "swipeMode")
            profiles[i].removeValue(forKey: "pages"); profiles[i].removeValue(forKey: "homePageID")
            var controls = try XCTUnwrap(profiles[i]["controls"] as? [[String: Any]])
            for j in controls.indices { for key in ["touchpadWidth", "touchpadHeight", "touchpadBehavior", "swipeActivationEnabled", "pageNavigation", "stickResponse", "extendedBoost", "buttonDirectional", "buttonAim", "controlWidth", "controlHeight", "touchAim"] { controls[j].removeValue(forKey: key) } }
            profiles[i]["controls"] = controls
        }
        object["profiles"] = profiles
        let migrated = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated, library); XCTAssertEqual(migrated.version, ControllerProfileLibrary.currentVersion)
    }
    func testTouchpadRoundTripPreservesRectangleAndClickMode() throws {
        let pad = ProfileControl(kind: .touchpad, touchpadWidth: 320, touchpadHeight: 90,
                                 touchpadBehavior: .init(sensitivity: 2.5, clickMode: .doubleTapLock))
        let placement = ProfilePlacement(id: pad.id, position: .init(x: 0.3, y: 0.7))
        let profile = try ControllerProfile(controls: [pad], portrait: [placement], landscape: [placement])
        let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile])
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library)), library)
    }
    func testStrictTouchpadFieldsAndEarlierVersionCannotSmuggleNewKind() throws {
        let pad = ProfileControl(kind: .touchpad)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pad)) as? [String: Any])
        var behavior = try XCTUnwrap(object["touchpadBehavior"] as? [String: Any]); behavior["future"] = true
        object["touchpadBehavior"] = behavior
        XCTAssertThrowsError(try JSONDecoder().decode(ProfileControl.self, from: JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "touchpadBehavior")
        XCTAssertThrowsError(try JSONDecoder().decode(ProfileControl.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}

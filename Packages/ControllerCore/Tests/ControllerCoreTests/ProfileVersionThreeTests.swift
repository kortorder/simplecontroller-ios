import Foundation
import XCTest
@testable import ControllerCore

final class ProfileVersionThreeTests: XCTestCase {
    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(.default)) as? [String: Any])
    }
    func testAuthenticVersionTwoDefaultsNewFieldsAndPreservesIDsPayloadAndTiming() throws {
        var library = ControllerProfileLibrary.default
        library.profiles[0].swipeMode = .buttons
        library.profiles[0].turboEnabled = true
        library.profiles[0].controls[0].payload = "RT:0.5"
        library.profiles[0].controls[0].autoTapEnabled = true
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        object["version"] = 2; removeCameraFollowFieldsForPreSeventeenFixture(&object); object.removeValue(forKey:"settingsPresets"); object.removeValue(forKey: "androidSources")
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        for index in profiles.indices {
            profiles[index].removeValue(forKey: "androidSources")
            profiles[index].removeValue(forKey: "swipeMode")
            profiles[index].removeValue(forKey: "pages"); profiles[index].removeValue(forKey: "homePageID")
            var controls = try XCTUnwrap(profiles[index]["controls"] as? [[String: Any]])
            for control in controls.indices {
                controls[control].removeValue(forKey: "directionalEnabled"); controls[control].removeValue(forKey: "directionPayloads")
                for key in ["touchpadWidth", "touchpadHeight", "touchpadBehavior", "swipeActivationEnabled", "pageNavigation", "stickResponse", "extendedBoost", "buttonDirectional", "buttonAim", "controlWidth", "controlHeight", "touchAim"] { controls[control].removeValue(forKey: key) }
            }
            profiles[index]["controls"] = controls
        }
        object["profiles"] = profiles
        let migrated = try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated, library); XCTAssertEqual(migrated.version, ControllerProfileLibrary.currentVersion)
    }
    func testVersionThreeRoundTripPreservesOverridesDormantSetsAndDirectionalMode() throws {
        var library = ControllerProfileLibrary.default
        let index = try XCTUnwrap(library.profiles[0].controls.firstIndex { $0.kind.isStick })
        library.profiles[0].controls[index].directionalEnabled = true
        library.profiles[0].controls[index].directionPayloads[.up] = .init(normalPayload: "W", boostPayload: "W, SHIFT", superBoostPayload: "W, SPACE")
        library.profiles[0].controls[index].stickBehavior.directions[.up]?.normalControls = [.a]
        let data = try ControllerProfileLibraryCodec.encode(library)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(data), library)
    }
    func testVersionThreeRejectsUnknownNestedFieldsAndIncompleteDirections() throws {
        var object = try object()
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        var controls = try XCTUnwrap(profiles[0]["controls"] as? [[String: Any]])
        var directions = try XCTUnwrap(controls[0]["directionPayloads"] as? [String: Any])
        var up = try XCTUnwrap(directions["up"] as? [String: Any]); up["future"] = true
        directions["up"] = up; controls[0]["directionPayloads"] = directions
        profiles[0]["controls"] = controls; object["profiles"] = profiles
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
        directions.removeValue(forKey: "up"); controls[0]["directionPayloads"] = directions
        profiles[0]["controls"] = controls; object["profiles"] = profiles
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testVersionTwoCannotSmuggleNewFieldsAndLegacyBehaviorCodecStillRoundTrips() throws {
        var object = try object(); object["version"] = 2; removeCameraFollowFieldsForPreSeventeenFixture(&object); object.removeValue(forKey:"settingsPresets"); object.removeValue(forKey: "androidSources")
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
        let legacy = ControllerBehaviors.default
        XCTAssertEqual(try ControllerBehaviorsCodec.decode(ControllerBehaviorsCodec.encode(legacy)), legacy)
        XCTAssertEqual(legacy.version, 1)
    }
}

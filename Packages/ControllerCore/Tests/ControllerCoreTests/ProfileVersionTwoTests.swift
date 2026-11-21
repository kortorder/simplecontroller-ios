import Foundation
import XCTest
@testable import ControllerCore

final class ProfileVersionTwoTests: XCTestCase {
    private func legacyObject() throws -> [String: Any] {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(.default)) as? [String: Any])
        object["version"] = 1; removeCameraFollowFieldsForPreSeventeenFixture(&object); object.removeValue(forKey:"settingsPresets"); object.removeValue(forKey: "androidSources")
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        for index in profiles.indices {
            profiles[index].removeValue(forKey: "androidSources")
            profiles[index].removeValue(forKey: "swipeMode")
            profiles[index].removeValue(forKey: "pages"); profiles[index].removeValue(forKey: "homePageID")
            profiles[index].removeValue(forKey: "turboEnabled"); profiles[index].removeValue(forKey: "turboIntervalMilliseconds")
            var controls = try XCTUnwrap(profiles[index]["controls"] as? [[String: Any]])
            for control in controls.indices {
                for key in ["payload", "autoTapEnabled", "autoTapIntervalMilliseconds", "directionalEnabled", "directionPayloads", "touchpadWidth", "touchpadHeight", "touchpadBehavior", "swipeActivationEnabled", "pageNavigation", "stickResponse", "extendedBoost", "buttonDirectional", "buttonAim", "controlWidth", "controlHeight", "touchAim"] { controls[control].removeValue(forKey: key) }
            }
            profiles[index]["controls"] = controls
        }
        object["profiles"] = profiles
        return object
    }
    func testLegacyLibraryMigratesWithExactIDsPositionsAndSafeDefaultsThenWritesCurrentVersion() throws {
        let original = try legacyObject(), data = try JSONSerialization.data(withJSONObject: original)
        let migrated = try ControllerProfileLibraryCodec.decode(data)
        XCTAssertEqual(migrated.version, ControllerProfileLibrary.currentVersion)
        XCTAssertEqual(migrated.activeProfileID.uuidString, original["activeProfileID"] as? String)
        XCTAssertFalse(migrated.activeProfile.turboEnabled)
        XCTAssertEqual(migrated.activeProfile.turboIntervalMilliseconds, 16)
        XCTAssertTrue(migrated.activeProfile.controls.allSatisfy { $0.payload == nil && !$0.autoTapEnabled && $0.autoTapIntervalMilliseconds == 100 })
        let saved = try ControllerProfileLibraryCodec.encode(migrated)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(saved), migrated)
        let savedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(savedObject["version"] as? Int, ControllerProfileLibrary.currentVersion)
    }
    func testVersionOneCannotSmuggleVersionTwoOrUnknownFields() throws {
        var object = try legacyObject()
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["turboEnabled"] = true; object["profiles"] = profiles
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
        profiles[0].removeValue(forKey: "turboEnabled")
        var controls = try XCTUnwrap(profiles[0]["controls"] as? [[String: Any]])
        controls[0]["payload"] = "X360A"; profiles[0]["controls"] = controls; object["profiles"] = profiles
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testVersionTwoRequiresAllNewFieldsAndRejectsInvalidPayloads() throws {
        var object = try legacyObject(); object["version"] = 2; removeCameraFollowFieldsForPreSeventeenFixture(&object); object.removeValue(forKey:"settingsPresets"); object.removeValue(forKey: "androidSources")
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
        var library = ControllerProfileLibrary.default
        library.profiles[0].controls[0].payload = "KEY_A"
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.encode(library))
    }
    func testRoundTripPreservesCustomPayloadDormantActionsAutoTapAndTurboSettings() throws {
        var library = ControllerProfileLibrary.default
        library.profiles[0].turboEnabled = true; library.profiles[0].turboIntervalMilliseconds = 37
        library.profiles[0].controls[0].payload = "RT:0.5, X360A"
        library.profiles[0].controls[0].autoTapEnabled = true
        library.profiles[0].controls[0].autoTapIntervalMilliseconds = 80
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library)), library)
    }
}

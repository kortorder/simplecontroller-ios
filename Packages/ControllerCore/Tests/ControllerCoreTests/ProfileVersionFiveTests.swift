import Foundation
import XCTest
@testable import ControllerCore

final class ProfileVersionFiveTests: XCTestCase {
    private func object(_ library: ControllerProfileLibrary = .default) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> ControllerProfileLibrary {
        try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object))
    }
    func testFreshDefaultsOffWhileLegacyLayoutMigrationPreservesButtonsOnly() throws {
        XCTAssertEqual(ControllerProfileLibrary.default.activeProfile.swipeMode, .off)
        XCTAssertEqual(try ControllerProfile().swipeMode, .off)
        let migrated = try ControllerProfile.migrating(layout: .default, behaviors: .default)
        XCTAssertEqual(migrated.swipeMode, .buttons)
        XCTAssertTrue(migrated.controls.allSatisfy(\.swipeActivationEnabled))
    }
    func testVersionFourMigrationPreservesAllDataAndAddsOnlyLegacySwipeDefaults() throws {
        var library = ControllerProfileLibrary.default
        library.profiles[0].swipeMode = .buttons
        library.profiles[0].controls[0].payload = "RT:0.4,W"
        library.profiles[0].controls[0].buttonBehavior = .init(holdToggle: true, holdMilliseconds: 750)
        library.profiles[0].controls[0].touchpadBehavior = .init(sensitivity: 2, clickMode: .toggle)
        var old = try object(library); old["version"] = 4; removeCameraFollowFieldsForPreSeventeenFixture(&old); old.removeValue(forKey:"settingsPresets"); old.removeValue(forKey: "androidSources")
        var profiles = try XCTUnwrap(old["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        for i in profiles.indices {
            profiles[i].removeValue(forKey: "androidSources")
            profiles[i].removeValue(forKey: "swipeMode")
            profiles[i].removeValue(forKey: "pages"); profiles[i].removeValue(forKey: "homePageID")
            var controls = try XCTUnwrap(profiles[i]["controls"] as? [[String: Any]])
            for j in controls.indices { controls[j].removeValue(forKey: "swipeActivationEnabled"); controls[j].removeValue(forKey: "pageNavigation"); controls[j].removeValue(forKey: "stickResponse"); controls[j].removeValue(forKey: "extendedBoost"); for key in ["buttonDirectional", "buttonAim", "controlWidth", "controlHeight", "touchAim"] { controls[j].removeValue(forKey:key) } }
            profiles[i]["controls"] = controls
        }
        old["profiles"] = profiles
        let migrated = try decode(old)
        XCTAssertEqual(migrated, library)
        XCTAssertEqual(migrated.version, ControllerProfileLibrary.currentVersion)
    }
    func testCurrentRoundTripPreservesAllModesAndDisabledDestinationFlag() throws {
        for mode in ProfileSwipeMode.allCases {
            var library = ControllerProfileLibrary.default
            library.profiles[0].swipeMode = mode
            library.profiles[0].controls[0].swipeActivationEnabled = false
            XCTAssertEqual(try decode(object(library)), library)
        }
    }
    func testCurrentRequiresTypedSwipeFieldsAndRejectsFutureModeOrUnknownFields() throws {
        let original = try object()
        let profiles = try XCTUnwrap(original["profiles"] as? [[String: Any]])
        for invalidMode in [NSNull(), "future", true] as [Any] {
            var changed = original, values = profiles
            values[0]["swipeMode"] = invalidMode; changed["profiles"] = values
            XCTAssertThrowsError(try decode(changed))
        }
        var changed = original, values = profiles
        values[0].removeValue(forKey: "swipeMode"); changed["profiles"] = values
        XCTAssertThrowsError(try decode(changed))
        values = profiles
        var controls = try XCTUnwrap(values[0]["controls"] as? [[String: Any]])
        controls[0].removeValue(forKey: "swipeActivationEnabled")
        values[0]["controls"] = controls; changed["profiles"] = values
        XCTAssertThrowsError(try decode(changed))
        controls[0]["swipeActivationEnabled"] = "true"
        values[0]["controls"] = controls; changed["profiles"] = values
        XCTAssertThrowsError(try decode(changed))
        changed = original; changed["future"] = true
        XCTAssertThrowsError(try decode(changed))
        changed = original; changed["version"] = ControllerProfileLibrary.currentVersion + 1
        XCTAssertThrowsError(try decode(changed))
    }
    func testEarlierVersionRejectsSmuggledNewSwipeFields() throws {
        var old = try object(); old["version"] = 4; removeCameraFollowFieldsForPreSeventeenFixture(&old); old.removeValue(forKey:"settingsPresets"); old.removeValue(forKey: "androidSources")
        XCTAssertThrowsError(try decode(old))
        var profiles = try XCTUnwrap(old["profiles"] as? [[String: Any]])
        profiles[0].removeValue(forKey: "swipeMode"); old["profiles"] = profiles
        XCTAssertThrowsError(try decode(old))
    }
}

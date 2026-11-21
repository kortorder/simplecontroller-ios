import Foundation
import XCTest
@testable import ControllerCore

final class ProfileVersionSevenTests: XCTestCase {
    private func object(_ library: ControllerProfileLibrary) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> ControllerProfileLibrary {
        try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object))
    }
    func testAuthenticFormatSixDefaultsResponseWithoutChangingPagesGeometryOrActions() throws {
        var library = ControllerProfileLibrary.default
        var profile = library.profiles[0]
        let page = try profile.addPage(name: "Driving")
        let navigation = ProfileControl(kind: .pageButton, pageNavigation: .toggle(page))
        try profile.addControl(navigation, toPage: profile.homePageID)
        try profile.moveControl(profile.controls[0].id, toPage: page)
        profile.controls[0].payload = "RT:0.6,W"
        profile.controls[0].buttonBehavior = .init(holdToggle: true, holdMilliseconds: 1000)
        try profile.setHomePage(page); library.profiles[0] = profile
        var old = try object(library); old["version"] = 6; removeCameraFollowFieldsForPreSeventeenFixture(&old); old.removeValue(forKey:"settingsPresets"); old.removeValue(forKey: "androidSources")
        var profiles = try XCTUnwrap(old["profiles"] as? [[String: Any]])
        for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
        for profileIndex in profiles.indices {
            var pages=profiles[profileIndex]["pages"] as! [[String:Any]]
            for pageIndex in pages.indices { pages[pageIndex].removeValue(forKey:"floatingButtonZones");pages[pageIndex].removeValue(forKey:"floatingRingZones") }
            profiles[profileIndex]["pages"]=pages
        }

        for i in profiles.indices {
            profiles[i].removeValue(forKey: "androidSources")
            var controls = try XCTUnwrap(profiles[i]["controls"] as? [[String: Any]])
            for j in controls.indices { controls[j].removeValue(forKey: "stickResponse"); controls[j].removeValue(forKey: "extendedBoost"); for key in ["buttonDirectional", "buttonAim", "controlWidth", "controlHeight", "touchAim"] { controls[j].removeValue(forKey:key) } }
            profiles[i]["controls"] = controls
        }
        old["profiles"] = profiles
        let migrated = try decode(old)
        XCTAssertEqual(migrated, library); XCTAssertEqual(migrated.version, ControllerProfileLibrary.currentVersion)
        XCTAssertTrue(migrated.activeProfile.controls.allSatisfy { $0.stickResponse == .init() && $0.extendedBoost == .init() })
    }
    func testCurrentRoundTripPreservesEveryDirectionResponseAndDormantMappings() throws {
        var library = ControllerProfileLibrary.default
        let index = try XCTUnwrap(library.profiles[0].controls.firstIndex { $0.kind.isStick })
        library.profiles[0].controls[index].stickResponse = .init(mode: .radial, sensitivity: 2.4)
        var extended = ExtendedBoostSettings(enabled: true, mode: .addOuterStage)
        for (offset, direction) in StickDirection.allCases.enumerated() {
            extended.directions[direction] = .init(regularThreshold: 0.2 + Double(offset) * 0.1,
                                                   superThreshold: 1.1 + Double(offset) * 0.1,
                                                   outerThreshold: 2 + Double(offset) * 0.2,
                                                   outerPayload: "W,RT:0.5")
        }
        library.profiles[0].controls[index].extendedBoost = extended
        let bytes = try ControllerProfileLibraryCodec.encode(library)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(bytes), library)
        XCTAssertEqual(try ControllerProfileLibraryCodec.encode(library), bytes)
        let clone = try library.activeProfile.cloned()
        XCTAssertEqual(clone.controls[index].extendedBoost, extended)
        XCTAssertEqual(clone.controls[index].stickResponse, .init(mode: .radial, sensitivity: 2.4))
    }
    func testFormatSevenRequiresBothFieldsAndEarlierVersionRejectsThem() throws {
        let original = try object(.default)
        var profiles = try XCTUnwrap(original["profiles"] as? [[String: Any]])
        let controls = try XCTUnwrap(profiles[0]["controls"] as? [[String: Any]])
        for key in ["stickResponse", "extendedBoost"] {
            var changed = original, values = controls
            values[0].removeValue(forKey: key); profiles[0]["controls"] = values; changed["profiles"] = profiles
            XCTAssertThrowsError(try decode(changed))
        }
        var old = original; old["version"] = 6; removeCameraFollowFieldsForPreSeventeenFixture(&old); old.removeValue(forKey:"settingsPresets"); old.removeValue(forKey: "androidSources")
        XCTAssertThrowsError(try decode(old))
        var future = original; future["version"] = ControllerProfileLibrary.currentVersion + 1
        XCTAssertThrowsError(try decode(future))
    }
    func testUnknownResponseAndExtendedFieldsOrMissingDirectionReject() throws {
        for json in ["{\"mode\":\"future\",\"sensitivity\":1}", "{\"mode\":\"linear\",\"sensitivity\":1,\"unknown\":true}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(StickResponseSettings.self, from: Data(json.utf8)))
        }
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ExtendedBoostSettings())) as? [String: Any])
        value["unknown"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(ExtendedBoostSettings.self, from: JSONSerialization.data(withJSONObject: value)))
        value.removeValue(forKey: "unknown")
        var directions = try XCTUnwrap(value["directions"] as? [String: Any]); directions.removeValue(forKey: "up"); value["directions"] = directions
        XCTAssertThrowsError(try JSONDecoder().decode(ExtendedBoostSettings.self, from: JSONSerialization.data(withJSONObject: value)))
    }
    func testExtendedRangeGapAndOuterDistanceValidation() throws {
        XCTAssertNoThrow(try ExtendedBoostDirectionSettings(regularThreshold: 0.1, superThreshold: 0.11, outerThreshold: 1.01).validate(sharedSuperThreshold: 0.95))
        XCTAssertNoThrow(try ExtendedBoostDirectionSettings(regularThreshold: 4.99, superThreshold: 5, outerThreshold: 5).validate(sharedSuperThreshold: 1))
        for invalid in [ExtendedBoostDirectionSettings(regularThreshold: 0.09),
                        .init(regularThreshold: .nan), .init(superThreshold: .infinity),
                        .init(regularThreshold: 0.5, superThreshold: 0.509), .init(outerThreshold: 1.009),
                        .init(outerThreshold: 5.1)] { XCTAssertThrowsError(try invalid.validate(sharedSuperThreshold: 0.75)) }
        var settings = ExtendedBoostSettings(); settings.directions.removeValue(forKey: .left)
        XCTAssertThrowsError(try settings.validate(sharedSuperThreshold: 0.75))
        XCTAssertThrowsError(try ProfileControl(extendedBoost: .init(enabled: true)).validate())
    }
    func testOuterPayloadMustBeSustainedAndBoundedEvenWhenDisabled() throws {
        for payload in ["WAIT_10", "RT:1P0.3", "MOUSE_LEFT_UP", "SCROLL_MODE_TOGGLE", "PAGE_HOME", String(repeating: " ", count: 1001)] {
            var settings = ExtendedBoostSettings(); settings.directions[.up]?.outerPayload = payload
            XCTAssertThrowsError(try settings.validate(sharedSuperThreshold: 0.75))
        }
        for payload in ["", "W,SHIFT", "MOUSE_LEFT_DOWN", "RT:0.5,X360A"] {
            XCTAssertNoThrow(try ExtendedBoostDirectionSettings(outerPayload: payload).validate(sharedSuperThreshold: 0.75))
        }
    }
    func testInvalidSettingsApplyIsAtomicAndValidApplyClearsRawRetainedOutput() throws {
        let axis = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false))
        let position = ProfilePlacement(id: axis.id, position: .init(x: 0.5, y: 0.5))
        let original = try ControllerProfile(controls: [axis], portrait: [position], landscape: [position])
        var engine = try ProfileInputEngine(profile: original)
        try engine.beginStick(contact: 1, control: axis.id, travel: .init(x: 2), at: 0); try engine.end(contact: 1, at: 0.1)
        var changed = original; changed.controls[0].stickResponse.sensitivity = .nan
        XCTAssertThrowsError(try engine.apply(profile: changed)); XCTAssertEqual(engine.state.leftStick.x, 1)
        changed.controls[0].stickResponse = .init(mode: .radial, sensitivity: 2)
        try engine.apply(profile: changed)
        XCTAssertTrue(engine.state.isNeutral); XCTAssertTrue(engine.retainedSticks.isEmpty)
        try engine.tick(at: 1); XCTAssertTrue(engine.state.isNeutral)
    }
    func testLegacyBehaviorAndWireFormatsDoNotGainResponseOrRawTravelFields() throws {
        let legacy = ControllerBehaviors.default
        XCTAssertEqual(try ControllerBehaviorsCodec.decode(ControllerBehaviorsCodec.encode(legacy)), legacy)
        XCTAssertEqual(legacy.version, 1)
        let packet = BridgePacket(kind: .state, session: UUID().uuidString, sequence: 1, state: .init(leftStick: .init(x: 1)))
        let data = try BridgeCodec.encode(packet)
        XCTAssertEqual(try BridgeCodec.decode(data), packet)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("stickResponse")); XCTAssertFalse(text.contains("extendedBoost")); XCTAssertFalse(text.contains("travel"))
    }
}

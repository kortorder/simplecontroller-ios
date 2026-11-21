import Foundation
import XCTest
@testable import ControllerCore

final class ControllerProfilesTests: XCTestCase {
    func testMigrationPreservesEverySettingPositionAndOrientationOrder() throws {
        var layout = ControllerLayout.default
        try layout.move(.a, to: .init(x: 0.2, y: 0.8), orientation: .portrait)
        var behaviors = ControllerBehaviors.default
        try behaviors.setButton(.init(holdToggle: true, holdMilliseconds: 800), for: .a)
        var stick = StickBehavior(autoCenter: false, stickPlusEnabled: true)
        stick.directions[.up] = .init(normalControls: [.menu], boostControls: [.leftStickClick], superBoostControls: [.a])
        try behaviors.setStick(stick, for: .leftStick)
        let profile = try ControllerProfile.migrating(layout: layout, behaviors: behaviors)
        XCTAssertEqual(profile.controls.count, 20)
        let byName = Dictionary(uniqueKeysWithValues: profile.controls.map { ($0.name, $0) })
        for legacy in ControllerControlID.allCases {
            let control = try XCTUnwrap(byName[legacy.displayName])
            XCTAssertEqual(control.actions, legacy.isStick ? [] : [legacy])
            XCTAssertEqual(control.buttonBehavior, behaviors.button(for: legacy))
            XCTAssertEqual(control.stickBehavior, behaviors.stick(for: legacy))
            for orientation in ControllerOrientation.allCases {
                XCTAssertEqual(profile.placements(for: orientation).first { $0.id == control.id }?.position,
                               layout.placement(for: legacy, orientation: orientation).position)
            }
        }
        XCTAssertEqual(profile.portrait.last?.id, byName["A"]?.id)
    }
    func testIndependentMigrationsHaveFreshProfileAndControlIDs() throws {
        let first = try ControllerProfile.migrating(layout: .default, behaviors: .default)
        let second = try ControllerProfile.migrating(layout: .default, behaviors: .default)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(Set(first.controls.map(\.id)).isDisjoint(with: Set(second.controls.map(\.id))))
    }
    func testNamedLibraryRoundTripPreservesMappingSizeAndActiveProfile() throws {
        var first = try ControllerProfile.migrating(layout: .default, behaviors: .default, name: "Driving")
        first.controls[0].name = "Accelerate"
        first.controls[0].diameter = 125
        first.controls[0].actions = [.a, .dpadUp]
        let second = try ControllerProfile(name: "Empty editor")
        let library = try ControllerProfileLibrary(activeProfileID: second.id, profiles: [first, second])
        let data = try ControllerProfileLibraryCodec.encode(library)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(data), library)
        XCTAssertEqual(try ControllerProfileLibraryCodec.encode(library), data)
        XCTAssertEqual(library.activeProfile, second)
    }
    func testZeroAndMaximumControlsAreValidButOneMoreIsRejected() throws {
        XCTAssertNoThrow(try ControllerProfile())
        let controls = (0..<ControllerProfile.maximumControls).map { ProfileControl(name: "Button \($0)") }
        var profile = try makeProfile(controls)
        let extra = ProfileControl()
        profile.controls.append(extra)
        profile.portrait.append(.init(id: extra.id, position: .init(x: 0.5, y: 0.5)))
        profile.landscape = profile.portrait
        XCTAssertThrowsError(try profile.validate()) { XCTAssertEqual($0 as? ControllerProfileError, .tooManyControls) }
    }
    func testLibraryProfileCountAndActiveIDLimits() throws {
        let profiles = try (0..<32).map { try ControllerProfile(name: "Profile \($0)") }
        XCTAssertNoThrow(try ControllerProfileLibrary(activeProfileID: profiles[0].id, profiles: profiles))
        XCTAssertThrowsError(try ControllerProfileLibrary(activeProfileID: UUID(), profiles: []))
        XCTAssertThrowsError(try ControllerProfileLibrary(activeProfileID: profiles[0].id, profiles: profiles + [try ControllerProfile()]))
        XCTAssertThrowsError(try ControllerProfileLibrary(activeProfileID: UUID(), profiles: profiles))
        XCTAssertThrowsError(try ControllerProfileLibrary(activeProfileID: profiles[0].id, profiles: [profiles[0], profiles[0]]))
    }
    func testNamesRequireOneThroughSixtyFourNonblankCharacters() throws {
        for name in ["", " \n\t ", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try ProfileControl(name: name).validate())
            XCTAssertThrowsError(try ControllerProfile(name: name))
        }
        XCTAssertNoThrow(try ProfileControl(name: "A").validate())
        XCTAssertNoThrow(try ControllerProfile(name: String(repeating: "a", count: 64)))
    }
    func testDiameterBoundsAndFiniteRequirementDependOnKind() {
        for kind in ProfileControlKind.allCases {
            let lower: Double = kind.isStick ? 104 : 44
            let upper: Double = kind.isStick ? 300 : 200
            XCTAssertNoThrow(try ProfileControl(kind: kind, diameter: lower).validate())
            XCTAssertNoThrow(try ProfileControl(kind: kind, diameter: upper).validate())
            for size in [lower - 0.1, upper + 0.1, .nan, .infinity] {
                XCTAssertThrowsError(try ProfileControl(kind: kind, diameter: size).validate())
            }
        }
    }
    func testDuplicateControlsAndMismatchedPlacementIDsAreRejected() throws {
        let control = ProfileControl(actions: [.a])
        var profile = try makeProfile([control])
        profile.controls.append(control)
        XCTAssertThrowsError(try profile.validate())
        profile = try makeProfile([control]); profile.portrait.append(profile.portrait[0])
        XCTAssertThrowsError(try profile.validate())
        profile = try makeProfile([control]); profile.landscape.removeAll()
        XCTAssertThrowsError(try profile.validate())
        profile = try makeProfile([control]); profile.portrait[0].id = UUID()
        XCTAssertThrowsError(try profile.validate())
    }
    func testMoveClampsFiniteCoordinatesOnlyInChosenOrientationAndPersistsZOrder() throws {
        let a = ProfileControl(actions: [.a]), b = ProfileControl(actions: [.b])
        var profile = try makeProfile([a, b])
        let landscape = profile.landscape
        try profile.move(a.id, to: .init(x: -2, y: 3), orientation: .portrait)
        XCTAssertEqual(profile.portrait.last?.id, a.id)
        XCTAssertEqual(profile.portrait.last?.position, .init(x: 0, y: 1))
        XCTAssertEqual(profile.landscape, landscape)
        let valid = profile
        XCTAssertThrowsError(try profile.move(a.id, to: .init(x: .nan, y: 0), orientation: .portrait))
        XCTAssertEqual(profile, valid)
        XCTAssertThrowsError(try profile.move(UUID(), to: .init(x: 0, y: 0), orientation: .portrait))
        XCTAssertEqual(profile, valid)
    }
    func testInvalidDraftCannotMoveOrEncodeSilently() throws {
        var profile = try makeProfile([ProfileControl()])
        profile.controls[0].diameter = -1
        let invalid = profile
        XCTAssertThrowsError(try profile.move(profile.controls[0].id, to: .init(x: 0, y: 0), orientation: .portrait))
        XCTAssertEqual(profile, invalid)
        XCTAssertThrowsError(try JSONEncoder().encode(profile))
    }
    func testActionsCannotTargetAnalogSurfacesOrHideOnNonButtonKinds() {
        XCTAssertThrowsError(try ProfileControl(actions: [.leftStick]).validate())
        XCTAssertThrowsError(try ProfileControl(kind: .recenter, actions: [.a]).validate())
        XCTAssertThrowsError(try ProfileControl(kind: .leftStick, actions: [.a]).validate())
        XCTAssertNoThrow(try ProfileControl(actions: [.a, .dpadUp, .leftTrigger, .guide]).validate())
    }
    func testNestedBehaviorAndPositionValidationCannotBeBypassed() throws {
        var profile = try makeProfile([ProfileControl()])
        profile.controls[0].buttonBehavior.holdMilliseconds = 10
        XCTAssertThrowsError(try profile.validate())
        profile.controls[0].buttonBehavior = .init()
        profile.controls[0].stickBehavior.boostThreshold = .nan
        XCTAssertThrowsError(try profile.validate())
        profile.controls[0].stickBehavior = .init()
        profile.portrait[0].position = .init(x: 1.1, y: 0.5)
        XCTAssertThrowsError(try profile.validate())
    }
    func testUnknownFieldsAtEveryNewModelLevelAreRejected() throws {
        var object = try libraryObject(); object["future"] = true
        XCTAssertThrowsError(try decode(object))
        object = try libraryObject()
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["future"] = true; object["profiles"] = profiles
        XCTAssertThrowsError(try decode(object))
        profiles[0].removeValue(forKey: "future")
        var controls = try XCTUnwrap(profiles[0]["controls"] as? [[String: Any]])
        controls[0]["future"] = true; profiles[0]["controls"] = controls; object["profiles"] = profiles
        XCTAssertThrowsError(try decode(object))
        controls[0].removeValue(forKey: "future"); profiles[0]["controls"] = controls
        var placements = try XCTUnwrap(profiles[0]["portrait"] as? [[String: Any]])
        placements[0]["future"] = true; profiles[0]["portrait"] = placements; object["profiles"] = profiles
        XCTAssertThrowsError(try decode(object))
    }
    func testWireDuplicateActionsAndUnknownKindsAreRejected() throws {
        var object = try libraryObject()
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        var controls = try XCTUnwrap(profiles[0]["controls"] as? [[String: Any]])
        controls[0]["actions"] = ["a", "a"]
        profiles[0]["controls"] = controls; object["profiles"] = profiles
        XCTAssertThrowsError(try decode(object))
        controls[0]["actions"] = ["a"]; controls[0]["kind"] = "mouse"
        profiles[0]["controls"] = controls; object["profiles"] = profiles
        XCTAssertThrowsError(try decode(object))
    }
    func testFutureVersionAndOversizedOrMalformedDataAreRejected() {
        let future = ControllerProfileLibrary.currentVersion + 1
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(Data("{\"version\":\(future),\"future\":true}".utf8))) {
            XCTAssertEqual($0 as? ControllerProfileError, .unsupportedVersion(future))
        }
        for data in [Data("{".utf8), Data("[]".utf8), Data("null".utf8),
                     Data(repeating: 32, count: ControllerProfileLibraryCodec.maximumBytes + 1)] {
            XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(data))
        }
    }
    private func makeProfile(_ controls: [ProfileControl]) throws -> ControllerProfile {
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: positions, landscape: positions)
    }
    private func libraryObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(.default)) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> ControllerProfileLibrary {
        try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object))
    }
}

import Foundation
import XCTest
@testable import ControllerCore

final class ControllerBehaviorsTests: XCTestCase {
    func testDefaultsPreserveMomentaryButtonsAndCenteringSticks() {
        let configuration = ControllerBehaviors.default
        XCTAssertTrue(configuration.isValid)
        for id in ControllerControlID.allCases {
            if id.isStick {
                let stick = configuration.stick(for: id)
                XCTAssertTrue(stick.autoCenter)
                XCTAssertFalse(stick.stickPlusEnabled)
                XCTAssertEqual(stick.boostThreshold, 0.5)
                XCTAssertEqual(stick.superBoostThreshold, 0.75)
                XCTAssertEqual(stick.directions.count, 4)
                XCTAssertTrue(stick.directions.values.allSatisfy { $0.normalControls.isEmpty && $0.boostControls.isEmpty && $0.superBoostControls.isEmpty })
            } else {
                XCTAssertFalse(configuration.button(for: id).holdToggle)
                XCTAssertEqual(configuration.button(for: id).holdMilliseconds, 500)
            }
        }
    }
    func testCompleteConfigurationRoundTripsDeterministically() throws {
        var configuration = ControllerBehaviors.default
        try configuration.setButton(.init(holdToggle: true, holdMilliseconds: 750), for: .a)
        var stick = StickBehavior(autoCenter: false, stickPlusEnabled: true)
        stick.directions[.up] = .init(normalControls: [.menu], boostControls: [.a, .dpadUp], superBoostControls: [.rightTrigger, .guide])
        try configuration.setStick(stick, for: .rightStick)
        let data = try ControllerBehaviorsCodec.encode(configuration)
        XCTAssertEqual(try ControllerBehaviorsCodec.decode(data), configuration)
        XCTAssertEqual(try ControllerBehaviorsCodec.encode(configuration), data)
        XCTAssertEqual(configuration.button(for: .b), ButtonBehavior())
        XCTAssertEqual(configuration.stick(for: .leftStick), StickBehavior())
    }
    func testInvalidHoldDurationIsRejectedAtomically() {
        var configuration = ControllerBehaviors.default
        for duration in [-1, 0, 49, 5001] {
            XCTAssertThrowsError(try configuration.setButton(.init(holdToggle: true, holdMilliseconds: duration), for: .a))
            XCTAssertEqual(configuration, .default)
        }
    }
    func testHoldDurationBoundaryValuesAreAccepted() throws {
        var configuration = ControllerBehaviors.default
        for duration in [50, 5000] {
            try configuration.setButton(.init(holdToggle: true, holdMilliseconds: duration), for: .a)
            XCTAssertEqual(configuration.button(for: .a).holdMilliseconds, duration)
        }
    }
    func testThresholdsMustBeFiniteInRangeAndStrictlyOrdered() {
        for (boost, superBoost) in [(0.5, 0.5), (0.9, 0.8), (-0.1, 0.9), (0.5, 1.1), (.nan, 0.9), (0.5, .infinity)] {
            var configuration = ControllerBehaviors.default
            XCTAssertThrowsError(try configuration.setStick(.init(boostThreshold: boost, superBoostThreshold: superBoost), for: .leftStick))
            XCTAssertEqual(configuration, .default)
        }
    }
    func testAllDirectionsAndOnlyNonStickMappingsRequired() {
        var configuration = ControllerBehaviors.default
        var behavior = StickBehavior()
        behavior.directions.removeValue(forKey: .left)
        XCTAssertThrowsError(try configuration.setStick(behavior, for: .leftStick))
        behavior = StickBehavior()
        behavior.directions[.up] = .init(normalControls: [.leftStick])
        XCTAssertThrowsError(try configuration.setStick(behavior, for: .leftStick))
        behavior.directions[.up] = .init(boostControls: [.leftStick])
        XCTAssertThrowsError(try configuration.setStick(behavior, for: .leftStick))
        behavior.directions[.up] = .init(superBoostControls: [.rightStick])
        XCTAssertThrowsError(try configuration.setStick(behavior, for: .leftStick))
        XCTAssertEqual(configuration, .default)
    }
    func testWrongControlKindCannotModifyConfiguration() {
        var configuration = ControllerBehaviors.default
        XCTAssertThrowsError(try configuration.setButton(.init(), for: .leftStick))
        XCTAssertThrowsError(try configuration.setStick(.init(), for: .a))
        XCTAssertEqual(configuration, .default)
    }
    func testMissingDuplicateAndUnknownControlEntriesAreRejected() throws {
        let base = try object()
        var data = base
        var buttons = try XCTUnwrap(base["buttons"] as? [[String: Any]])
        buttons.removeLast(); data["buttons"] = buttons
        XCTAssertThrowsError(try decode(data))
        buttons = try XCTUnwrap(base["buttons"] as? [[String: Any]])
        buttons[1] = buttons[0]; data["buttons"] = buttons
        XCTAssertThrowsError(try decode(data))
        buttons[0]["control"] = "futureButton"; data["buttons"] = buttons
        XCTAssertThrowsError(try decode(data))
    }
    func testUnknownFieldsAtConfigurationEntryAndBehaviorLevelsAreRejected() throws {
        var data = try object(); data["future"] = true
        XCTAssertThrowsError(try decode(data))
        data = try object()
        var buttons = try XCTUnwrap(data["buttons"] as? [[String: Any]])
        buttons[0]["future"] = true; data["buttons"] = buttons
        XCTAssertThrowsError(try decode(data))
        buttons[0].removeValue(forKey: "future")
        buttons[0]["behavior"] = ["holdToggle": false, "holdMilliseconds": 500, "turbo": true]
        data["buttons"] = buttons
        XCTAssertThrowsError(try decode(data))
    }
    func testFutureVersionIsExplicitlyRejectedWithoutInterpretingNewFields() {
        let saved = Data("{\"version\":2,\"newFormat\":true}".utf8)
        XCTAssertThrowsError(try ControllerBehaviorsCodec.decode(saved)) {
            XCTAssertEqual($0 as? ControllerBehaviorError, .unsupportedVersion(2))
        }
    }
    func testMalformedAndOversizedDataAreRejected() {
        for data in [Data("{".utf8), Data("null".utf8), Data("[]".utf8),
                     Data(repeating: 32, count: ControllerBehaviorsCodec.maximumBytes + 1)] {
            XCTAssertThrowsError(try ControllerBehaviorsCodec.decode(data))
        }
    }
    func testMappingRejectsDuplicateActionsAndUnknownFields() {
        for json in ["{\"normalControls\":[],\"boostControls\":[\"a\",\"a\"],\"superBoostControls\":[]}",
                     "{\"normalControls\":[],\"boostControls\":[],\"superBoostControls\":[],\"future\":true}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(StickDirectionMapping.self, from: Data(json.utf8)))
        }
    }
    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerBehaviorsCodec.encode(.default)) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> ControllerBehaviors {
        try ControllerBehaviorsCodec.decode(JSONSerialization.data(withJSONObject: object))
    }
}

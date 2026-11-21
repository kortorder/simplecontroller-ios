import Foundation
import XCTest
@testable import ControllerCore

/// Only fixture construction uses this: older documents never contained these newer keys.
func removeCameraFollowFieldsForPreSeventeenFixture(_ object: inout [String: Any]) {
    guard var profiles = object["profiles"] as? [[String: Any]] else { return }
    for p in profiles.indices {
        guard var controls = profiles[p]["controls"] as? [[String: Any]] else { continue }
        for c in controls.indices {
            for key in ["cameraFollowStrengthPercent", "excludeFromCameraFollow", "mouseSuppressCameraFollow", "floatingAction", "orientationDimensions", "stickPlusRepeatIntervalMilliseconds"] {
                controls[c].removeValue(forKey: key)
            }
        }
        profiles[p]["controls"] = controls
        if var sources = profiles[p]["androidSources"] as? [[String: Any]] {
            for index in sources.indices {
                for key in ["pages", "controls", "zones"] {
                    if let bindings = sources[index][key] as? [[String: Any]] {
                        sources[index][key] = bindings.map { var b = $0; b.removeValue(forKey: "floatingRestoration"); return b }
                    }
                }
            }
            profiles[p]["androidSources"] = sources
        }
    }
    object["profiles"] = profiles
}

final class ProfileVersionSeventeenTests: XCTestCase {
    func testAuthenticSixteenDefaultsNewSettingsWithoutChangingSavedContent() throws {
        var library = ControllerProfileLibrary.default
        library.profiles[0].controls[0].payload = "LS:R60"
        library.profiles[0].controls[0].actions = [.a, .b]
        library.profiles[0].globalHoldEnabled = true
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        object["version"] = 16
        removeCameraFollowFieldsForPreSeventeenFixture(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let original = bytes
        let decoded = try ControllerProfileLibraryCodec.decode(bytes)
        XCTAssertEqual(decoded, library)
        XCTAssertEqual(bytes, original)
        XCTAssertTrue(decoded.profiles[0].controls.allSatisfy { $0.cameraFollowStrengthPercent == 100 && !$0.excludeFromCameraFollow && !$0.mouseSuppressCameraFollow })
    }
    func testSettingsRoundTripAndWholeProfileCopiesKeepPreferences() throws {
        var p = try ControllerProfile()
        var control = ProfileControl(payload: "CAMERA_FOLLOW:1")
        control.cameraFollowStrengthPercent = 123.5
        control.excludeFromCameraFollow = true; control.mouseSuppressCameraFollow = true
        try p.addControl(control, toPage: p.homePageID)
        let library = try ControllerProfileLibrary(activeProfileID: p.id, profiles: [p])
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library)), library)
        XCTAssertEqual(try JSONDecoder().decode(ProfileControl.self, from: JSONEncoder().encode(control)), control)
        let clone = try p.cloned(name: "Copy")
        XCTAssertNotEqual(clone.id, p.id); XCTAssertNotEqual(clone.controls[0].id, control.id)
        var clonedControl = clone.controls[0]; clonedControl.id = control.id
        XCTAssertEqual(clonedControl, control)
    }
    func testCurrentFieldsAreRequiredTypedAndUnknownOldKeysRejected() throws {
        let library = ControllerProfileLibrary.default
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        for key in ["cameraFollowStrengthPercent", "excludeFromCameraFollow", "mouseSuppressCameraFollow"] {
            for replacement: Any? in [nil, "invalid"] {
                var object = source
                var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
                var controls = try XCTUnwrap(profiles[0]["controls"] as? [[String: Any]])
                controls[0][key] = replacement
                profiles[0]["controls"] = controls; object["profiles"] = profiles
                XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)), key)
            }
        }
        var old = source; old["version"] = 16
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: old)))
        var future = source; future["version"] = ControllerProfileLibrary.currentVersion + 1
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: future)))
    }
    func testStrengthRejectsNonfiniteAndOutOfRangeWithoutChangingInput() throws {
        for value in [-0.01, 200.01, .nan, .infinity, -.infinity] {
            var c = ProfileControl(); c.cameraFollowStrengthPercent = value
            XCTAssertThrowsError(try c.validate())
            XCTAssertThrowsError(try JSONEncoder().encode(c))
        }
        for value in [0.0, 100, 200] {
            XCTAssertNoThrow(try ProfileControl(cameraFollowStrengthPercent: value).validate())
        }
    }
    func testCameraCommandsAreStandaloneCanonicalLocalActions() throws {
        for (source, expected) in [("camera_follow", CameraFollowCommand.toggle), (" CAMERA_FOLLOW:1 ", .enable), ("CAMERA_FOLLOW:0", .disable)] {
            let program = try ControllerPayloadProgram.parse(source)
            XCTAssertEqual(program.cameraFollowCommand, expected)
            XCTAssertEqual(try ControllerPayloadProgram.parse(program.source), program)
            XCTAssertTrue(program.hasAnyOutput); XCTAssertTrue(program.outputTargets.isEmpty)
            XCTAssertFalse(program.hasKeyboardOrMouse)
            let c = ProfileControl(payload: source)
            XCTAssertNoThrow(try c.validate()); XCTAssertTrue(c.isCameraFollowAction)
            XCTAssertTrue(c.isLocalAction); XCTAssertFalse(c.acceptsSwipeEntry)
            XCTAssertThrowsError(try program.validateSustained())
        }
        for source in ["CAMERA_FOLLOW:2", "CAMERA_FOLLOW:ON", "CAMERA_FOLLOW:1.0", "CAMERA_FOLLOW, X360A", "WAIT_1, CAMERA_FOLLOW", "CAMERA_FOLLOW:0,CAMERA_FOLLOW:1"] {
            XCTAssertThrowsError(try ControllerPayloadProgram.parse(source), source)
        }
    }
    func testCameraCommandsRejectRepeatedAndAdvancedModesButKeepSavedCheckboxActions() throws {
        var control = ProfileControl(actions: [.a], payload: "CAMERA_FOLLOW")
        XCTAssertNoThrow(try control.validate()); XCTAssertEqual(control.actions, [.a])
        control.buttonBehavior.holdToggle = true; XCTAssertThrowsError(try control.validate())
        control.buttonBehavior.holdToggle = false; control.autoTapEnabled = true; XCTAssertThrowsError(try control.validate())
        control.autoTapEnabled = false; control.buttonAim.enabled = true; XCTAssertThrowsError(try control.validate())
        control.buttonAim.enabled = false; control.buttonDirectional.enabled = true; XCTAssertThrowsError(try control.validate())
        control.buttonDirectional.enabled = false; control.payload = nil
        XCTAssertEqual(try control.payloadProgram().outputTargets, [.a])
    }
}

import XCTest
@testable import ControllerCore

final class ProfileVersionNineteenTests: XCTestCase {
    func testOldBaseAndPartialOverridesResolveWithoutMutation() throws {
        for kind in ProfileControlKind.allCases {
            var c = ProfileControl(kind: kind)
            let base = ProfileControlDimensions(width: c.resolvedWidth, height: c.resolvedHeight)
            XCTAssertEqual(c.dimensions(for: .portrait), base); XCTAssertEqual(c.dimensions(for: .landscape), base)
            c.orientationDimensions.landscape = .init(width: 220, height: 130)
            XCTAssertEqual(c.dimensions(for: .portrait), base)
            XCTAssertEqual(c.dimensions(for: .landscape), .init(width: 220, height: 130))
            XCTAssertEqual(c.resolvedWidth, base.width); XCTAssertEqual(c.resolvedHeight, base.height)
            c.orientationDimensions = .init()
            XCTAssertEqual(c.dimensions(for: .landscape), base)
        }
    }
    func testAuthenticEighteenMigratesWithExactSharedSizeAndStrictNineteenRoundTrip() throws {
        var library = ControllerProfileLibrary.default
        library.profiles[0].controls[0].controlWidth = 185
        library.profiles[0].controls[0].controlHeight = 160
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library)) as? [String: Any])
        object["version"] = 18
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        for i in profiles.indices {
            profiles[i]["controls"] = (profiles[i]["controls"] as! [[String: Any]]).map { c in var c = c; c.removeValue(forKey: "orientationDimensions"); c.removeValue(forKey: "stickPlusRepeatIntervalMilliseconds"); return c }
        }
        object["profiles"] = profiles
        let raw = try JSONSerialization.data(withJSONObject: object)
        let decoded = try ControllerProfileLibraryCodec.decode(raw)
        XCTAssertEqual(decoded, library)
        XCTAssertTrue(decoded.profiles[0].controls.allSatisfy { $0.orientationDimensions.isEmpty })
        XCTAssertEqual(decoded.profiles[0].controls[0].dimensions(for: .landscape), .init(width: 185, height: 160))
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(decoded)), decoded)
        object["version"] = 19
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testStrictNestedSchemaRejectsUnknownMissingAndNonfiniteOrSmallSizes() throws {
        for json in [#"{}"#, #"{"portrait":null}"#, #"{"portrait":null,"landscape":null,"extra":1}"#,
                     #"{"portrait":{"width":100},"landscape":null}"#,
                     #"{"portrait":{"width":100,"height":100,"extra":1},"landscape":null}"#,
                     #"{"portrait":{"width":43,"height":100},"landscape":null}"#,
                     #"{"portrait":{"width":1201,"height":100},"landscape":null}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ProfileOrientationDimensions.self, from: Data(json.utf8)), json)
        }
        for amount in [Double.nan, .infinity, -1, 103, 1201] {
            var stick = ProfileControl(kind: .leftStick)
            stick.orientationDimensions.landscape = .init(width: amount, height: 104)
            XCTAssertThrowsError(try stick.validate())
        }
        let pad = ProfileControl(kind: .touchpad, orientationDimensions: .init(portrait: .init(width: 44, height: 44)))
        XCTAssertNoThrow(try pad.validate())
    }
    func testClonesPagesAndFloatUnfloatPreserveBothCanonicalSizes() throws {
        var profile = try ControllerProfile()
        let control = ProfileControl(name: "Sized", actions: [.a], orientationDimensions: .init(
            portrait: .init(width: 70, height: 90), landscape: .init(width: 130, height: 60)))
        try profile.addControl(control, toPage: profile.homePageID)
        let original = profile
        let p = FloatingCanvasSnapshot(width: 400, height: 800, frames: [control.id: .init(x: 30, y: 40, width: 70, height: 90)])
        let l = FloatingCanvasSnapshot(width: 800, height: 400, frames: [control.id: .init(x: 80, y: 90, width: 130, height: 60)])
        let zone = try profile.convertToFloatingButtons(on: profile.homePageID, memberIDs: [control.id], kind: .singleButton,
            name: "Float", snapshots: [.portrait: p, .landscape: l])
        try profile.setFloatingMemberFrame(control.id, zoneID: zone, on: profile.homePageID, orientation: .landscape,
            frame: .init(x: 20, y: 20, width: 180, height: 80), snapshot: l)
        XCTAssertEqual(profile.controls, original.controls)
        XCTAssertEqual(profile.pages[0].floatingButtonZones[0].landscapeRestoration.first?.frame, l.frames[control.id])
        let clone = try profile.cloned()
        XCTAssertEqual(clone.controls[0].orientationDimensions, control.orientationDimensions)
        let duplicate = try profile.duplicatePage(profile.homePageID)
        XCTAssertEqual(profile.controls(on: duplicate)[0].orientationDimensions, control.orientationDimensions)
        try profile.unfloatButtons(zone, on: profile.homePageID)
        XCTAssertEqual(profile.controls[0], control)
        XCTAssertEqual(profile.placements(for: .portrait, on: profile.homePageID), original.portrait)
        XCTAssertEqual(profile.placements(for: .landscape, on: profile.homePageID), original.landscape)
    }
}

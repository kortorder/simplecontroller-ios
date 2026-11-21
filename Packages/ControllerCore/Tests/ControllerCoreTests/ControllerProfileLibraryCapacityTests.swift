import Foundation
import XCTest
@testable import ControllerCore

final class ControllerProfileLibraryCapacityTests: XCTestCase {
    func testExpandedNativeBoundLeavesOtherDocumentBoundsUnchanged() {
        XCTAssertEqual(ControllerProfileLibraryCodec.legacyMaximumBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(ControllerProfileLibraryCodec.maximumBytes, 16 * 1_024 * 1_024)
        XCTAssertEqual(SettingsPresetLibraryCodec.maximumBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(AndroidProfileDocument.maximumBytes, 25 * 1_024 * 1_024)
        XCTAssertEqual(AndroidPortableBackup.maximumBytes, 40 * 1_024 * 1_024)
    }

    func testSmallDocumentKeepsRelease33FieldsAfterVersionMigration() throws {
        let library = try smallLibrary()
        // Generated with the unmodified Release 33 codec, not this test's encoder.
        let original = #"{"activeProfileID":"11111111-1111-1111-1111-111111111111","androidSources":[],"profiles":[{"androidSources":[],"controls":[],"globalHoldEnabled":false,"homePageID":"11111111-1111-1111-1111-111111111111","id":"11111111-1111-1111-1111-111111111111","landscape":[],"name":"Saved profile","pages":[{"controlIDs":[],"floatingButtonZones":[],"floatingRingZones":[],"id":"11111111-1111-1111-1111-111111111111","name":"Main"}],"portrait":[],"swipeMode":"off","turboEnabled":false,"turboIntervalMilliseconds":16}],"settingsPresets":{"entries":[],"version":1},"version":22}"#
        let bytes = Data(original.utf8)
        let encoded = try ControllerProfileLibraryCodec.encode(library)
        var current = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(current["version"] as? Int, ControllerProfileLibrary.currentVersion)
        // Format 23 deliberately identifies the new optional button behaviors. Every
        // pre-existing field in this legacy fixture must remain byte-for-byte canonical.
        current["version"] = 22
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]), bytes)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(bytes), library)
    }

    func testValidLargeCollectionAndPortableBackupRoundTripAboveOldLimit() throws {
        let library = try populatedLibrary(profileCount: 3)
        let data = try ControllerProfileLibraryCodec.encode(library)
        XCTAssertGreaterThan(data.count, ControllerProfileLibraryCodec.legacyMaximumBytes)
        XCTAssertLessThan(data.count, ControllerProfileLibraryCodec.maximumBytes)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(data), library)
        let portable = try AndroidPortableBackup(nativeLibraryData: data, archives: [])
        let decodedBackup = try AndroidPortableBackup.decode(portable.encodedData())
        XCTAssertEqual(decodedBackup.nativeLibraryData, data)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(decodedBackup.nativeLibraryData), library)
    }

    func testDecodeAcceptsExactBoundAndRejectsOneAdditionalByteBeforeParsing() throws {
        let library = try smallLibrary()
        var data = try ControllerProfileLibraryCodec.encode(library)
        data.append(Data(repeating: 32, count: ControllerProfileLibraryCodec.maximumBytes - data.count))
        XCTAssertEqual(data.count, ControllerProfileLibraryCodec.maximumBytes)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(data), library)
        data.append(32)
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(data)) {
            XCTAssertEqual($0 as? ControllerProfileError, .oversizedData)
        }
        // An oversized malformed document must fail its byte bound first as well.
        data[0] = 0
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(data)) {
            XCTAssertEqual($0 as? ControllerProfileError, .oversizedData)
        }
    }

    func testValidCollectionAboveNewBoundStillCannotBeEncoded() throws {
        let library = try populatedLibrary(profileCount: 32)
        XCTAssertNoThrow(try library.validate())
        let unboundedEncoder = JSONEncoder()
        let bytes = try unboundedEncoder.encode(library)
        XCTAssertGreaterThan(bytes.count, ControllerProfileLibraryCodec.maximumBytes)
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.encode(library)) {
            XCTAssertEqual($0 as? ControllerProfileError, .oversizedData)
        }
    }

    private func smallLibrary() throws -> ControllerProfileLibrary {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let profile = try ControllerProfile(id: id, name: "Saved profile")
        return try .init(activeProfileID: id, profiles: [profile])
    }

    private func populatedLibrary(profileCount: Int) throws -> ControllerProfileLibrary {
        // The payload is valid, bounded input: leading spaces are preserved in the
        // authored control but ignored by the command parser. No private fixture.
        let payload = String(repeating: " ", count: 7_990) + "X360A"
        let controls = (0..<64).map { ProfileControl(name: "Button \($0)", payload: payload) }
        let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        let first = try ControllerProfile(name: "Large collection", controls: controls,
                                          portrait: placements, landscape: placements)
        var profiles = [first]
        for _ in 1..<profileCount { profiles.append(try first.cloned()) }
        return try .init(activeProfileID: first.id, profiles: profiles)
    }
}

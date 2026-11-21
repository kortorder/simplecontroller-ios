import Foundation
import XCTest
@testable import ControllerCore

final class PresentationPreferencesTests: XCTestCase {
    func testDefaultPreservesNativeDarkAndAutomaticRotation() {
        XCTAssertEqual(ControllerPresentationPreferences.default.theme, .dark)
        XCTAssertEqual(ControllerPresentationPreferences.default.playOrientation, .automatic)
    }
    func testAllThemeAndSavedOrientationCombinationsRoundTrip() throws {
        for theme in ControllerThemePreference.allCases {
            for orientation in ControllerDisplayOrientation.allCases {
                let value = ControllerPresentationPreferences(theme: theme, playOrientation: orientation)
                XCTAssertEqual(try ControllerPresentationCodec.decode(ControllerPresentationCodec.encode(value)), value)
            }
        }
    }
    func testEditorSelectionIsTransientAndPlayResumesSavedPreference() throws {
        let preferences = ControllerPresentationPreferences(theme: .light, playOrientation: .landscape)
        XCTAssertEqual(ControllerPresentationPolicy.orientation(preferences: preferences, isEditing: false, editorOrientation: .portrait), .landscape)
        XCTAssertEqual(ControllerPresentationPolicy.orientation(preferences: preferences, isEditing: true, editorOrientation: .portrait), .portrait)
        XCTAssertEqual(ControllerPresentationPolicy.orientation(preferences: preferences, isEditing: true), .automatic)
        let json = try JSONSerialization.jsonObject(with: ControllerPresentationCodec.encode(preferences)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["version", "theme", "playOrientation"])
    }
    func testFutureVersionRejectsWithoutAlteringOriginalBytes() throws {
        let original = Data(#"{"version":99,"theme":"dark","playOrientation":"portrait","future":true}"#.utf8)
        let before = original
        XCTAssertThrowsError(try ControllerPresentationCodec.decode(original)) {
            XCTAssertEqual($0 as? ControllerPresentationError, .unsupportedVersion(99))
        }
        XCTAssertEqual(original, before)
        XCTAssertThrowsError(try ControllerPresentationCodec.encode(.init(version: 99)))
    }
    func testUnknownMissingWrongTypeAndUnsupportedEnumReject() {
        for text in [
            #"{"version":1,"theme":"dark","playOrientation":"automatic","editorOrientation":"portrait"}"#,
            #"{"version":1,"playOrientation":"automatic"}"#,
            #"{"version":1,"theme":true,"playOrientation":"automatic"}"#,
            #"{"version":1,"theme":"sepia","playOrientation":"automatic"}"#,
            #"{"version":1,"theme":"dark","playOrientation":"upsideDown"}"#
        ] { XCTAssertThrowsError(try ControllerPresentationCodec.decode(Data(text.utf8))) }
    }
    func testMalformedEmptyAndOversizedInputsReject() {
        XCTAssertThrowsError(try ControllerPresentationCodec.decode(Data()))
        XCTAssertThrowsError(try ControllerPresentationCodec.decode(Data("{broken".utf8)))
        XCTAssertThrowsError(try ControllerPresentationCodec.decode(Data(repeating: 32, count: 4097))) {
            XCTAssertEqual($0 as? ControllerPresentationError, .oversizedData)
        }
    }
}

final class ProfileBulkDeletionTests: XCTestCase {
    private func library() throws -> ControllerProfileLibrary {
        let main = ControllerProfileLibrary.default.activeProfile
        return try .init(activeProfileID: main.id, profiles: [main, main.cloned(name: "Racing"), main.cloned(name: "Other")])
    }
    func testCandidatesExcludeActiveAndPreserveOrder() throws {
        let library = try library()
        XCTAssertEqual(ControllerProfileBulkDeletion.candidates(in: library).map(\.id), Array(library.profiles.dropFirst()).map(\.id))
    }
    func testDeleteSeveralAtomicallyKeepsActiveOriginalsAndPresetLibrary() throws {
        var library = try library()
        library.androidSources = [try .init(sha256: String(repeating: "a", count: 64), byteCount: 20, displayName: "Original")]
        try library.settingsPresets.save(.capture(.init(actions: [.a]), category: .buttonAim, name: "Aim", at: 100))
        let before = library, selected = Set(library.profiles.dropFirst().map(\.id))
        let plan = try ControllerProfileBulkDeletion.prepare(library: library, selectedIDs: selected)
        XCTAssertEqual(library, before)
        XCTAssertEqual(plan.deletedProfileNames, ["Racing", "Other"])
        XCTAssertEqual(plan.deletedProfileIDs, Array(library.profiles.dropFirst()).map(\.id))
        XCTAssertEqual(plan.candidate.profiles, [library.activeProfile])
        XCTAssertEqual(plan.candidate.activeProfileID, library.activeProfileID)
        XCTAssertEqual(plan.candidate.androidSources, library.androidSources)
        XCTAssertEqual(plan.candidate.settingsPresets, library.settingsPresets)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(plan.candidate)), plan.candidate)
    }
    func testActiveSelectionRejectsWholeBatchRatherThanPartiallyDeleting() throws {
        let library = try library()
        let copy = library
        XCTAssertThrowsError(try ControllerProfileBulkDeletion.prepare(library: library, selectedIDs: [library.activeProfileID, library.profiles[1].id])) {
            XCTAssertEqual($0 as? ControllerProfileBulkDeletionError, .activeProfileProtected)
        }
        XCTAssertEqual(library, copy)
    }
    func testStaleUnknownAndEmptySelectionsReject() throws {
        let library = try library()
        XCTAssertThrowsError(try ControllerProfileBulkDeletion.prepare(library: library, selectedIDs: []))
        XCTAssertThrowsError(try ControllerProfileBulkDeletion.prepare(library: library, selectedIDs: [library.profiles[1].id, UUID()])) {
            XCTAssertEqual($0 as? ControllerProfileBulkDeletionError, .unknownProfile)
        }
    }
    func testFreshActiveSelectionProtectsProfileIfItChangedSinceOpeningPicker() throws {
        var library = try library(); let previouslyInactive = library.profiles[1].id
        library.activeProfileID = previouslyInactive
        XCTAssertThrowsError(try ControllerProfileBulkDeletion.prepare(library: library, selectedIDs: [previouslyInactive])) {
            XCTAssertEqual($0 as? ControllerProfileBulkDeletionError, .activeProfileProtected)
        }
    }
    func testInvalidLibraryRejectsBeforePlanningAndLastProfileIsProtected() throws {
        var library = try library(); library.profiles[1].name = ""
        XCTAssertThrowsError(try ControllerProfileBulkDeletion.prepare(library: library, selectedIDs: [library.profiles[2].id]))
        let only = ControllerProfileLibrary.default
        XCTAssertTrue(ControllerProfileBulkDeletion.candidates(in: only).isEmpty)
        XCTAssertThrowsError(try ControllerProfileBulkDeletion.prepare(library: only, selectedIDs: [only.activeProfileID]))
    }
}

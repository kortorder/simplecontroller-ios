import Foundation
import XCTest
@testable import ControllerCore

final class AndroidProfileArchiveTests: XCTestCase {
    private let original = Data(#" {"pages":[],"future":9007199254740993} "#.utf8)
    private func temporaryStore() throws -> AndroidProfileArchiveStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("android-archive-tests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(directory: root)
    }
    private func source(_ data: Data, id: UUID = UUID()) throws -> AndroidArchivedSource {
        try .init(reference: .init(id: id, sha256: androidSHA256(data), byteCount: data.count, displayName: "Original.json"), originalData: data)
    }
    private func nativeData(referencing source: AndroidArchivedSource) throws -> Data {
        var library = ControllerProfileLibrary.default
        library.androidSources = [source.reference]
        return try ControllerProfileLibraryCodec.encode(library)
    }
    func testOriginalIsByteExactAndInsertionDeduplicatesAcrossProfiles() throws {
        let store = try temporaryStore()
        let first = try store.insert(original, displayName: "Source.json")
        let second = try store.insert(original, displayName: "Another name.json")
        XCTAssertEqual(first, second); XCTAssertEqual(try store.list(), [first])
        XCTAssertEqual(try store.load(first).originalData, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(first.id.uuidString.lowercased()).appendingPathComponent("original.json").path))
    }
    func testChecksumMismatchAndCorruptionFailWithoutReplacingSource() throws {
        let store = try temporaryStore(), reference = try store.insert(original, displayName: "Source")
        let file = store.directory.appendingPathComponent(reference.id.uuidString.lowercased()).appendingPathComponent("original.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try store.load(reference)); XCTAssertThrowsError(try store.list())
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
    }
    func testNativeSaveFailureDoesNotLoseStandaloneArchive() throws {
        let store = try temporaryStore(), reference = try store.insert(original, displayName: "Preserved")
        // Deliberately do not save a native library after successful insertion.
        let restored = AndroidProfileArchiveStore(directory: store.directory)
        XCTAssertEqual(try restored.list(), [reference]); XCTAssertEqual(try restored.load(reference).originalData, original)
    }
    func testCompletePendingWriteRecoversOnNextList() throws {
        let store = try temporaryStore(), archived = try source(original)
        let pending = store.directory.appendingPathComponent(".pending-" + archived.reference.id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try JSONEncoder().encode(archived.reference).write(to: pending.appendingPathComponent("manifest.json"))
        try original.write(to: pending.appendingPathComponent("original.json"))
        XCTAssertEqual(try store.list(), [archived.reference]); XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }
    func testIncompletePendingWriteIsNeverDeleted() throws {
        let store = try temporaryStore(), archived = try source(original)
        let pending = store.directory.appendingPathComponent(".pending-" + archived.reference.id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try JSONEncoder().encode(archived.reference).write(to: pending.appendingPathComponent("manifest.json"))
        XCTAssertTrue(try store.list().isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }
    func testPortableSourcesDeduplicateAndReturnArchiveIDRemapping() throws {
        let store = try temporaryStore(), existing = try store.insert(original, displayName: "First")
        let incoming = try source(original)
        let map = try store.insertVerified([incoming])
        XCTAssertEqual(map[incoming.reference.id], existing); XCTAssertEqual(try store.list().count, 1)
    }
    func testConflictingArchiveIDRejectsBeforeWritingAnyNewSource() throws {
        let store = try temporaryStore(), existing = try store.insert(original, displayName: "First")
        let fresh = try source(Data(#"{"pages":[],"new":1}"#.utf8))
        let conflict = try source(Data(#"{"pages":[],"changed":true}"#.utf8), id: existing.id)
        XCTAssertThrowsError(try store.insertVerified([fresh, conflict]))
        XCTAssertEqual(try store.list(), [existing]); XCTAssertEqual(try store.load(existing).originalData, original)
    }
    func testSymlinkOriginalAndRootAreRejected() throws {
        let store = try temporaryStore(), reference = try store.insert(original, displayName: "Original")
        let file = store.directory.appendingPathComponent(reference.id.uuidString.lowercased()).appendingPathComponent("original.json")
        let other = store.directory.appendingPathComponent("other.json"); try original.write(to: other)
        try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try store.load(reference))
        let alias = store.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: store.directory)
        XCTAssertThrowsError(try AndroidProfileArchiveStore(directory: alias).list())
    }
    func testDisplayNameCannotBecomeAPathAndControlsAreRemoved() throws {
        let store = try temporaryStore(), reference = try store.insert(original, displayName: "../../name\n.json")
        XCTAssertEqual(reference.displayName, "../../name.json")
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.load(reference).originalData, original)
    }
    func testInvalidOriginalNeverCreatesArchiveDirectory() throws {
        let store = try temporaryStore()
        XCTAssertThrowsError(try store.insert(Data("not JSON".utf8), displayName: "Bad"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }
    func testArchiveCountLimitRejectsBeforeAnyNewWrites() throws {
        let store = try temporaryStore()
        let sources = try (0..<33).map { try source(Data("{\"pages\":[],\"index\":\($0)}".utf8)) }
        XCTAssertThrowsError(try store.insertVerified(sources)); XCTAssertTrue(try store.list().isEmpty)
    }
    func testPortableBackupRoundTripsNativeAndExactOriginalBytes() throws {
        let archive = try source(original)
        let native = try nativeData(referencing: archive)
        let backup = try AndroidPortableBackup(nativeLibraryData: native, archives: [archive])
        let restored = try AndroidPortableBackup.decode(backup.encodedData())
        XCTAssertEqual(restored, backup); XCTAssertEqual(restored.archives[0].originalData, original)
    }
    func testPortableBackupRejectsTamperedChecksumAndUnknownEnvelopeFields() throws {
        let archive = try source(original)
        let backup = try AndroidPortableBackup(nativeLibraryData: nativeData(referencing: archive), archives: [archive])
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedData()) as? [String: Any])
        fields["future"] = true
        XCTAssertThrowsError(try AndroidPortableBackup.decode(JSONSerialization.data(withJSONObject: fields)))
        fields.removeValue(forKey: "future")
        var entries = try XCTUnwrap(fields["archives"] as? [[String: Any]])
        entries[0]["originalData"] = Data("{}".utf8).base64EncodedString(); fields["archives"] = entries
        XCTAssertThrowsError(try AndroidPortableBackup.decode(JSONSerialization.data(withJSONObject: fields)))
    }
    func testBadMetadataAndMismatchedBytesReject() throws {
        XCTAssertThrowsError(try AndroidSourceArchiveReference(sha256: "bad", byteCount: 5, displayName: "Name"))
        XCTAssertThrowsError(try AndroidSourceArchiveReference(sha256: String(repeating: "a", count: 64), byteCount: 0, displayName: "Name"))
        let reference = try source(original).reference
        XCTAssertThrowsError(try AndroidArchivedSource(reference: reference, originalData: Data("[]".utf8)))
    }
    func testPortableBackupRejectsMissingOrUnreferencedOriginals() throws {
        let archive = try source(original)
        XCTAssertThrowsError(try AndroidPortableBackup(nativeLibraryData: nativeData(referencing: archive), archives: []))
        XCTAssertThrowsError(try AndroidPortableBackup(nativeLibraryData: ControllerProfileLibraryCodec.encode(.default), archives: [archive]))
    }
}

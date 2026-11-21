import Foundation
import CryptoKit
import XCTest
@testable import ControllerCore

final class NativeProfileFileStoreTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDownWithError() throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders.removeAll()
    }
    private func directory() -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("NativeProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        folders.append(parent)
        return parent.appendingPathComponent("Profiles", isDirectory: true)
    }
    private func library(_ name: String) throws -> Data {
        let profile = try ControllerProfile(name: name)
        return try ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile]))
    }
    private func recoveryKey(_ data: Data) -> String {
        "controller.profiles.recovery.file-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func testMissingReadDoesNotCreateFoldersOrSubstituteAnything() throws {
        let folder = directory(), store = NativeProfileFileStore(directory: directory())
        XCTAssertNil(try store.loadLibrary())
        XCTAssertEqual(try store.recoveryDocuments(), [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    func testLargeLibraryIsExactOnDiskAndFreshInstanceReload() throws {
        let folder = directory()
        var bytes = Data(repeating: 0x20, count: 2 * 1024 * 1024)
        bytes.append(try library("Large collection"))
        try NativeProfileFileStore(directory: folder).saveLibrary(bytes, previousData: nil)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("library.json")), bytes)
        let reopened = NativeProfileFileStore(directory: folder)
        XCTAssertEqual(try reopened.loadLibrary(), bytes)
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(XCTUnwrap(reopened.loadLibrary())).profiles.first?.name, "Large collection")
    }
    func testReplacementPreservesExactDiskAndLegacySourcesWithIdempotentKeys() throws {
        let folder = directory(), store = NativeProfileFileStore(directory: folder)
        let legacy = try library("Legacy"), original = try library("Disk"), replacement = try library("Replacement")
        try store.saveLibrary(original)
        try store.saveLibrary(replacement, previousData: legacy)
        XCTAssertEqual(try NativeProfileFileStore(directory: folder).loadLibrary(), replacement)
        XCTAssertEqual(try store.recoveryData(for: recoveryKey(original)), original)
        XCTAssertEqual(try store.recoveryData(for: recoveryKey(legacy)), legacy)
        XCTAssertEqual(try store.recoveryDocuments().count, 2)
        try store.saveLibrary(replacement, previousData: legacy)
        XCTAssertEqual(try store.recoveryDocuments().count, 2)
    }
    func testInvalidSchemaAndOversizeCandidateNeverMutateExistingPrimary() throws {
        let folder = directory(), store = NativeProfileFileStore(directory: folder), original = try library("Original")
        try store.saveLibrary(original)
        for invalid in [Data("{broken".utf8), Data(repeating: 0x20, count: ControllerProfileLibraryCodec.maximumBytes + 1)] {
            XCTAssertThrowsError(try store.saveLibrary(invalid, previousData: original))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("library.json")), original)
        }
        XCTAssertEqual(try store.recoveryDocuments(), [:])
    }
    func testMalformedExistingFileIsReturnedAndPreservedBeforeExplicitReplacement() throws {
        let folder = directory(), store = NativeProfileFileStore(directory: folder), broken = Data("exact malformed saved bytes".utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try broken.write(to: folder.appendingPathComponent("library.json"))
        XCTAssertEqual(try store.loadLibrary(), broken)
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(XCTUnwrap(store.loadLibrary())))
        let valid = try library("Recovered")
        try store.saveLibrary(valid, previousData: broken)
        XCTAssertEqual(try store.recoveryData(for: recoveryKey(broken)), broken)
        XCTAssertEqual(try NativeProfileFileStore(directory: folder).loadLibrary(), valid)
    }
    func testRecoveryIsRawImmutableAndIdempotentAcrossInstances() throws {
        let folder = directory(), key = "controller.profiles.recovery.test", raw = Data([0, 255, 13, 10, 123])
        try NativeProfileFileStore(directory: folder).saveRecovery(raw, key: key)
        let reopened = NativeProfileFileStore(directory: folder)
        try reopened.saveRecovery(raw, key: key)
        XCTAssertThrowsError(try reopened.saveRecovery(Data("different".utf8), key: key))
        XCTAssertEqual(try reopened.recoveryData(for: key), raw)
        XCTAssertEqual(try reopened.recoveryDocuments(), [key: raw])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Recovery").path), [key + ".json"])
    }
    func testReadbackMismatchRestoresPreviousPrimaryAndKeepsRecovery() throws {
        let folder = directory(), original = try library("Original"), replacement = try library("Replacement")
        try NativeProfileFileStore(directory: folder).saveLibrary(original)
        let brokenWriter = NativeProfileFileStore(directory: folder) { _, url in
            try Data("wrong bytes returned by disk write".utf8).write(to: url, options: .atomic)
        }
        XCTAssertThrowsError(try brokenWriter.saveLibrary(replacement, previousData: original))
        let reopened = NativeProfileFileStore(directory: folder)
        XCTAssertEqual(try reopened.loadLibrary(), original)
        XCTAssertEqual(try reopened.recoveryData(for: recoveryKey(original)), original)
    }
    func testOversizedReadbackAlsoRollsBackBeforeReportingFailure() throws {
        let folder = directory(), original = try library("Original"), replacement = try library("Replacement")
        try NativeProfileFileStore(directory: folder).saveLibrary(original)
        let brokenWriter = NativeProfileFileStore(directory: folder) { _, url in
            try Data(repeating: 0x20, count: ControllerProfileLibraryCodec.maximumBytes + 1).write(to: url, options: .atomic)
        }
        XCTAssertThrowsError(try brokenWriter.saveLibrary(replacement))
        XCTAssertEqual(try NativeProfileFileStore(directory: folder).loadLibrary(), original)
    }
    func testWriteErrorAfterReplacementRollsBackAndNewFileFailureLeavesNoPrimary() throws {
        let folder = directory(), original = try library("Original"), replacement = try library("Replacement")
        let failing = NativeProfileFileStore(directory: folder) { data, url in
            try data.write(to: url, options: .atomic)
            throw NativeProfileFileStoreError("Injected completion failure")
        }
        XCTAssertThrowsError(try failing.saveLibrary(replacement, previousData: original))
        let reopened = NativeProfileFileStore(directory: folder)
        XCTAssertNil(try reopened.loadLibrary())
        XCTAssertEqual(try reopened.recoveryData(for: recoveryKey(original)), original)
        try reopened.saveLibrary(original)
        XCTAssertThrowsError(try failing.saveLibrary(replacement))
        XCTAssertEqual(try NativeProfileFileStore(directory: folder).loadLibrary(), original)
    }
    func testRecoveryFailureStopsSaveBeforePrimaryReplacement() throws {
        let folder = directory(), store = NativeProfileFileStore(directory: folder), original = try library("Original")
        try store.saveLibrary(original)
        try store.saveRecovery(Data("conflicting immutable recovery".utf8), key: recoveryKey(original))
        XCTAssertThrowsError(try store.saveLibrary(library("Replacement")))
        XCTAssertEqual(try store.loadLibrary(), original)
    }
    func testActualFilesystemWriteDenialPreservesOldDiskBytes() throws {
        let folder = directory(), store = NativeProfileFileStore(directory: folder), original = try library("Original")
        try store.saveLibrary(original)
        try store.saveRecovery(original, key: recoveryKey(original))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        if FileManager.default.isWritableFile(atPath: folder.path) { throw XCTSkip("Host privileges bypass directory write permissions") }
        XCTAssertThrowsError(try store.saveLibrary(library("Denied")))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("library.json")), original)
    }
    func testInvalidPathsAndSymlinksThrowWithoutSilentMissingResult() throws {
        let folder = directory(), data = try library("Original")
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: folder)
        let invalid = NativeProfileFileStore(directory: folder)
        XCTAssertThrowsError(try invalid.loadLibrary()); XCTAssertThrowsError(try invalid.saveLibrary(data))
        XCTAssertEqual(try Data(contentsOf: folder), data)
        let blockedChild = NativeProfileFileStore(directory: folder.appendingPathComponent("nested", isDirectory: true))
        XCTAssertThrowsError(try blockedChild.loadLibrary())
        XCTAssertThrowsError(try blockedChild.saveLibrary(data))
        let validFolder = directory(), store = NativeProfileFileStore(directory: validFolder)
        try FileManager.default.createDirectory(at: validFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: validFolder.appendingPathComponent("library.json"), withDestinationURL: folder)
        XCTAssertThrowsError(try store.loadLibrary()); XCTAssertThrowsError(try store.saveLibrary(data))
        XCTAssertEqual(try Data(contentsOf: folder), data)
        XCTAssertThrowsError(try NativeProfileFileStore(directory: URL(string: "https://example.invalid/profiles")!).loadLibrary())
    }
    func testRecoveryNamesCannotEscapeFolderAndRecoverySymlinkIsRejected() throws {
        let folder = directory(), store = NativeProfileFileStore(directory: folder)
        for key in ["", ".", "..", "../outside", "a/b", "/absolute", "é", String(repeating: "a", count: 201)] {
            XCTAssertThrowsError(try store.saveRecovery(Data(), key: key), key)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let outside = directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Recovery"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.saveRecovery(Data("raw".utf8), key: "safe"))
        XCTAssertThrowsError(try store.recoveryDocuments())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testReadBoundsRejectOversizedDiskAndRecoveryBytes() throws {
        let folder = directory(), store = NativeProfileFileStore(directory: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let oversized = Data(repeating: 0x20, count: ControllerProfileLibraryCodec.maximumBytes + 1)
        try oversized.write(to: folder.appendingPathComponent("library.json"))
        XCTAssertThrowsError(try store.loadLibrary())
        XCTAssertThrowsError(try store.saveRecovery(oversized, key: "too-large"))
        let raw = Data(repeating: 0x61, count: ControllerProfileLibraryCodec.maximumBytes)
        try store.saveRecovery(raw, key: "at-limit")
        XCTAssertEqual(try NativeProfileFileStore(directory: folder).recoveryData(for: "at-limit"), raw)
    }
}

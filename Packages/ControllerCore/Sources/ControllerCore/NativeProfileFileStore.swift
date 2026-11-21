import Foundation
import CryptoKit

public struct NativeProfileFileStoreError: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The caller serializes saves. Preferences are never read, written or used as a fallback.
/// Reads deliberately open the file again; success is based on disk bytes, not a cache.
public struct NativeProfileFileStore {
    public let directory: URL
    private let writePrimary: (Data, URL) throws -> Void
    private var libraryURL: URL { directory.appendingPathComponent("library.json", isDirectory: false) }
    private var recoveryDirectory: URL { directory.appendingPathComponent("Recovery", isDirectory: true) }

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
        self.writePrimary = { data, url in try data.write(to: url, options: .atomic) }
    }
    // Fault injection still operates on real files, to exercise readback and rollback.
    // It is not exposed to the app and is never used for loading or recovery writes.
    init(directory: URL, writePrimary: @escaping (Data, URL) throws -> Void) {
        self.directory = directory.standardizedFileURL
        self.writePrimary = writePrimary
    }

    /// Missing is different from unreadable. Bounded malformed bytes are returned so
    /// the model can protect/export them rather than silently loading older preferences.
    public func loadLibrary() throws -> Data? {
        guard try requireDirectory(directory, create: false) else { return nil }
        return try readFile(libraryURL)
    }

    public func saveLibrary(_ data: Data, previousData: Data? = nil) throws {
        try requireBound(data)
        _ = try ControllerProfileLibraryCodec.decode(data)
        if let previousData { try requireBound(previousData) }
        let previousFile = try loadLibrary()
        // Preserve both the current disk source and any legacy source supplied by the
        // model. Content-addressed immutable names make retries exact and idempotent.
        for previous in [previousFile, previousData].compactMap({ $0 }) where previous != data {
            try saveRecovery(previous, key: recoveryKey(previous))
        }
        _ = try requireDirectory(directory, create: true)
        if previousFile == data { return } // This equality came from a fresh disk read.
        do {
            try writePrimary(data, libraryURL)
            guard try readFile(libraryURL) == data else {
                throw NativeProfileFileStoreError("Saved profiles could not be verified on disk.")
            }
        } catch {
            let originalError = error
            do {
                if let previousFile {
                    if (try? readFile(libraryURL)) != previousFile {
                        if let found = try attributes(libraryURL), found[.type] as? FileAttributeType != .typeRegular {
                            throw NativeProfileFileStoreError("The primary profile path changed during saving.")
                        }
                        try previousFile.write(to: libraryURL, options: .atomic)
                    }
                    guard try readFile(libraryURL) == previousFile else {
                        throw NativeProfileFileStoreError("The previous profile file could not be verified after restoring it.")
                    }
                } else if let found = try attributes(libraryURL) {
                    guard found[.type] as? FileAttributeType == .typeRegular else {
                        throw NativeProfileFileStoreError("The new profile path changed during saving.")
                    }
                    try FileManager.default.removeItem(at: libraryURL)
                    guard try readFile(libraryURL) == nil else {
                        throw NativeProfileFileStoreError("The unsuccessful new profile file could not be removed.")
                    }
                }
            } catch {
                throw NativeProfileFileStoreError("Saving profiles failed, and the previous primary file could not be restored. Exact recovery copies remain available. \(originalError.localizedDescription) \(error.localizedDescription)")
            }
            throw originalError
        }
    }

    /// Recovery may intentionally contain malformed original bytes. It is bounded,
    /// immutable, and verified exactly; it is never decoded or silently normalized.
    public func saveRecovery(_ data: Data, key: String) throws {
        try requireBound(data)
        let url = try recoveryURL(key)
        _ = try requireDirectory(directory, create: true)
        _ = try requireDirectory(recoveryDirectory, create: true)
        if let existing = try readFile(url) {
            guard existing == data else { throw NativeProfileFileStoreError("A different recovery copy already uses this name.") }
            return
        }
        let temporary = recoveryDirectory.appendingPathComponent(".recovery-\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        do { try FileManager.default.moveItem(at: temporary, to: url) }
        catch {
            // Another serialized/retried writer may already have installed these exact
            // bytes. FileManager move refuses to replace an existing destination.
            if try readFile(url) == data { return }
            throw error
        }
        guard try readFile(url) == data else { throw NativeProfileFileStoreError("The recovery copy could not be verified on disk.") }
    }

    public func recoveryData(for key: String) throws -> Data? {
        let url = try recoveryURL(key)
        guard try requireDirectory(directory, create: false),
              try requireDirectory(recoveryDirectory, create: false) else { return nil }
        return try readFile(url)
    }

    public func recoveryDocuments() throws -> [String: Data] {
        guard try requireDirectory(directory, create: false),
              try requireDirectory(recoveryDirectory, create: false) else { return [:] }
        let urls = try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)
        var result: [String: Data] = [:]
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            let key = url.deletingPathExtension().lastPathComponent
            _ = try recoveryURL(key)
            guard let data = try readFile(url) else { throw NativeProfileFileStoreError("A recovery copy disappeared while reading it.") }
            result[key] = data
        }
        return result
    }

    private func recoveryKey(_ data: Data) -> String {
        "controller.profiles.recovery.file-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func recoveryURL(_ key: String) throws -> URL {
        let bytes = Array(key.utf8)
        func alphanumeric(_ c: UInt8) -> Bool { (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) }
        guard (1...200).contains(bytes.count), let first = bytes.first, alphanumeric(first),
              bytes.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else {
            throw NativeProfileFileStoreError("The recovery copy has an invalid file name.")
        }
        return recoveryDirectory.appendingPathComponent(key + ".json", isDirectory: false)
    }
    private func requireBound(_ data: Data) throws {
        guard data.count <= ControllerProfileLibraryCodec.maximumBytes else { throw ControllerProfileError.oversizedData }
    }
    private func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        guard url.isFileURL else { throw NativeProfileFileStoreError("Profile storage must use a local folder.") }
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
            throw error
        }
    }
    @discardableResult
    private func requireDirectory(_ url: URL, create: Bool) throws -> Bool {
        guard url.isFileURL else { throw NativeProfileFileStoreError("Profile storage must use a local folder.") }
        if let found = try attributes(url) {
            guard found[.type] as? FileAttributeType == .typeDirectory else {
                throw NativeProfileFileStoreError("The profile storage path is not a regular folder.")
            }
            return true
        }
        guard create else { return false }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let created = try attributes(url), created[.type] as? FileAttributeType == .typeDirectory else {
            throw NativeProfileFileStoreError("The profile storage folder could not be created.")
        }
        return true
    }
    private func readFile(_ url: URL) throws -> Data? {
        guard let found = try attributes(url) else { return nil }
        guard found[.type] as? FileAttributeType == .typeRegular else {
            throw NativeProfileFileStoreError("The profile storage file is not a regular file.")
        }
        guard let size = found[.size] as? NSNumber, size.int64Value >= 0,
              size.int64Value <= Int64(ControllerProfileLibraryCodec.maximumBytes) else { throw ControllerProfileError.oversizedData }
        let bytes = try Data(contentsOf: url)
        try requireBound(bytes)
        return bytes
    }
}

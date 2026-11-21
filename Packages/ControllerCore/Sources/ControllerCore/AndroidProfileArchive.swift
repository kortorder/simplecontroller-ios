import Foundation
import CryptoKit

public struct AndroidArchiveError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Small native metadata only. Original bytes live in a separate app-private file.
public struct AndroidSourceArchiveReference: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sha256: String
    public let byteCount: Int
    public let displayName: String
    public init(id: UUID = UUID(), sha256: String, byteCount: Int, displayName: String) throws {
        self.id = id; self.sha256 = sha256; self.byteCount = byteCount; self.displayName = displayName
        try validate()
    }
    public func validate() throws {
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...AndroidProfileDocument.maximumBytes).contains(byteCount),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.count <= 160, !displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AndroidArchiveError("Invalid Android source archive metadata.")
        }
    }
    private enum CodingKeys: String, CodingKey { case id, sha256, byteCount, displayName }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["id", "sha256", "byteCount", "displayName"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), sha256: c.decode(String.self, forKey: .sha256),
                      byteCount: c.decode(Int.self, forKey: .byteCount), displayName: c.decode(String.self, forKey: .displayName))
    }
}

public struct AndroidSourceBinding: Codable, Equatable, Sendable {
    public var nativeID: UUID
    public let sourcePath: String
    public let exportID: String?
    public var floatingRestoration: AndroidFloatingRestorationRecord?
    public init(nativeID: UUID, sourcePath: String, exportID: String? = nil,
                floatingRestoration: AndroidFloatingRestorationRecord? = nil) {
        self.nativeID = nativeID; self.sourcePath = sourcePath; self.exportID = exportID
        self.floatingRestoration = floatingRestoration
    }
    private enum CodingKeys: String, CodingKey { case nativeID, sourcePath, exportID, floatingRestoration }
    public init(from decoder: Decoder) throws { try self.init(from: decoder, libraryVersion: ControllerProfileLibrary.currentVersion) }
    init(from decoder: Decoder, libraryVersion: Int) throws {
        var keys: Set<String> = ["nativeID", "sourcePath"]
        if libraryVersion >= 10 { keys.insert("exportID") }
        if libraryVersion >= 19 { keys.insert("floatingRestoration") }
        try profileKeys(decoder, keys)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if libraryVersion >= 19 && !c.contains(.floatingRestoration) { throw ControllerProfileError.invalidFormat }
        self.init(nativeID: try c.decode(UUID.self, forKey: .nativeID), sourcePath: try c.decode(String.self, forKey: .sourcePath),
                  exportID: libraryVersion < 10 ? nil : try c.decodeIfPresent(String.self, forKey: .exportID),
                  floatingRestoration: libraryVersion < 19 ? nil : try c.decodeIfPresent(AndroidFloatingRestorationRecord.self, forKey: .floatingRestoration))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nativeID, forKey: .nativeID); try c.encode(sourcePath, forKey: .sourcePath); try c.encode(exportID, forKey: .exportID)
        try c.encode(floatingRestoration, forKey: .floatingRestoration)
    }
}

public struct AndroidProfileSourceReference: Codable, Equatable, Sendable {
    public let archiveID: UUID
    public let sourceProfilePath: String
    public var pages: [AndroidSourceBinding]
    public var controls: [AndroidSourceBinding]
    /// Deleted-zone records may remain as immutable lineage; only live zones are cloned.
    public var zones: [AndroidSourceBinding]
    public let exportBaseline: AndroidSourceExportBaseline?
    public init(archiveID: UUID, sourceProfilePath: String, pages: [AndroidSourceBinding], controls: [AndroidSourceBinding], zones: [AndroidSourceBinding] = [],
                exportBaseline: AndroidSourceExportBaseline? = nil) {
        self.archiveID = archiveID; self.sourceProfilePath = sourceProfilePath; self.pages = pages; self.controls = controls; self.zones = zones
        self.exportBaseline = exportBaseline
    }
    private enum CodingKeys: String, CodingKey { case archiveID, sourceProfilePath, pages, controls, zones, exportBaseline }
    public init(from decoder: Decoder) throws { try self.init(from: decoder, libraryVersion: ControllerProfileLibrary.currentVersion) }
    init(from decoder: Decoder, libraryVersion: Int) throws {
        var keys: Set<String> = ["archiveID", "sourceProfilePath", "pages", "controls"]
        if libraryVersion >= 10 { keys.insert("exportBaseline") }; if libraryVersion >= 16 { keys.insert("zones") }
        try profileKeys(decoder, keys)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func bindings(_ key: CodingKeys) throws -> [AndroidSourceBinding] {
            var values = try c.nestedUnkeyedContainer(forKey: key), result: [AndroidSourceBinding] = []
            while !values.isAtEnd { result.append(try .init(from: values.superDecoder(), libraryVersion: libraryVersion)) }
            return result
        }
        self.init(archiveID: try c.decode(UUID.self, forKey: .archiveID), sourceProfilePath: try c.decode(String.self, forKey: .sourceProfilePath),
                  pages: try bindings(.pages), controls: try bindings(.controls), zones: libraryVersion < 16 ? [] : try bindings(.zones),
                  exportBaseline: libraryVersion < 10 ? nil : try c.decodeIfPresent(AndroidSourceExportBaseline.self, forKey: .exportBaseline))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(archiveID, forKey: .archiveID); try c.encode(sourceProfilePath, forKey: .sourceProfilePath)
        try c.encode(pages, forKey: .pages); try c.encode(controls, forKey: .controls); try c.encode(zones, forKey: .zones); try c.encode(exportBaseline, forKey: .exportBaseline)
    }
    public func replacingArchiveID(_ id: UUID) -> Self {
        .init(archiveID: id, sourceProfilePath: sourceProfilePath, pages: pages, controls: controls, zones: zones, exportBaseline: exportBaseline)
    }
    public func withExportBaseline(_ baseline: AndroidSourceExportBaseline) -> Self {
        .init(archiveID: archiveID, sourceProfilePath: sourceProfilePath, pages: pages, controls: controls, zones: zones, exportBaseline: baseline)
    }
    public func validate(pageIDs: Set<UUID>, controlIDs: Set<UUID>) throws {
        func validPath(_ path: String) -> Bool {
            guard path.utf8.count <= 8_192, path.isEmpty || path.hasPrefix("/") else { return false }
            let bytes = Array(path.utf8)
            for index in bytes.indices where bytes[index] == 126 {
                if index + 1 >= bytes.count || ![48, 49].contains(bytes[index + 1]) { return false }
            }
            return true
        }
        guard validPath(sourceProfilePath), pages.count <= 32, controls.count <= 64, zones.count <= 2048,
              Set(zones.map(\.nativeID)).count == zones.count,
              Set(pages.map(\.nativeID)).count == pages.count,
              Set(controls.map(\.nativeID)).count == controls.count,
              Set(pages.map(\.nativeID)).isSubset(of: pageIDs),
              Set(controls.map(\.nativeID)).isSubset(of: controlIDs),
              (pages + controls + zones).allSatisfy({ validPath($0.sourcePath) && ($0.exportID == nil || UUID(uuidString: $0.exportID!) != nil) }) else {
            throw AndroidArchiveError("Invalid Android source bindings.")
        }
        guard (pages + zones).allSatisfy({ $0.floatingRestoration == nil }) else { throw AndroidArchiveError("Floating restoration records belong to control bindings only.") }
        for binding in controls {
            if let record = binding.floatingRestoration {
                try record.validate()
                guard let baseline = exportBaseline,
                      let control = baseline.controls.first(where: { $0.sourcePath == binding.sourcePath }),
                      let zone = baseline.zones.first(where: { $0.sourcePath == record.zoneSourcePath }),
                      control.pageSourcePath == zone.pageSourcePath else {
                    throw AndroidArchiveError("The floating restoration record has no matching converted source zone and control.")
                }
            }
        }
        if let exportBaseline {
            try exportBaseline.validate()
            guard exportBaseline.sourceProfilePath == sourceProfilePath else { throw AndroidArchiveError("Export baseline belongs to a different source profile.") }
        }
    }
    public func remapped(pages pageMap: [UUID: UUID], controls controlMap: [UUID: UUID], zones zoneMap: [UUID: UUID] = [:], asCopies: Bool = false) -> Self {
        .init(archiveID: archiveID, sourceProfilePath: sourceProfilePath,
              pages: pages.compactMap { binding in pageMap[binding.nativeID].map { .init(nativeID: $0, sourcePath: binding.sourcePath, exportID: asCopies ? UUID().uuidString : binding.exportID) } },
              controls: controls.compactMap { binding in controlMap[binding.nativeID].map { .init(nativeID: $0, sourcePath: binding.sourcePath, exportID: asCopies ? UUID().uuidString : binding.exportID, floatingRestoration: binding.floatingRestoration) } },
              zones: zones.compactMap { binding in zoneMap[binding.nativeID].map { .init(nativeID: $0, sourcePath: binding.sourcePath, exportID: asCopies ? UUID().uuidString : binding.exportID) } },
              exportBaseline: exportBaseline)
    }
}

public struct AndroidArchivedSource: Equatable, Sendable {
    public let reference: AndroidSourceArchiveReference
    public let originalData: Data
    public init(reference: AndroidSourceArchiveReference, originalData: Data) throws {
        try reference.validate()
        guard originalData.count == reference.byteCount, androidSHA256(originalData) == reference.sha256 else {
            throw AndroidArchiveError("The Android source archive is missing or its checksum does not match.")
        }
        _ = try AndroidProfileDocument.parse(originalData)
        self.reference = reference; self.originalData = originalData
    }
}

func androidSHA256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Serialized caller access is required. The app owns this directory; filenames never come from imports.
/// Complete archives are immutable, self-describing UUID directories. A native save occurs only AFTER
/// archive insertion. If that save fails, list() still finds the preserved original for recovery/export.
public struct AndroidProfileArchiveStore {
    public static let maximumArchiveCount = 32
    public static let maximumTotalBytes = 25 * 1_024 * 1_024
    public let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public func list() throws -> [AndroidSourceArchiveReference] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try requireDirectory(directory)
        try recoverPending()
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var result: [AndroidSourceArchiveReference] = []
        for child in children {
            guard let id = UUID(uuidString: child.lastPathComponent), child.lastPathComponent == id.uuidString.lowercased() else { continue }
            let reference = try readReference(at: child)
            guard reference.id == id else { throw AndroidArchiveError("An Android archive directory has inconsistent metadata.") }
            _ = try readOriginal(reference, at: child)
            result.append(reference)
        }
        try validateBudget(result)
        return result.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func load(_ reference: AndroidSourceArchiveReference) throws -> AndroidArchivedSource {
        try reference.validate(); try requireDirectory(directory)
        let child = archiveURL(reference.id)
        guard try readReference(at: child) == reference else { throw AndroidArchiveError("Android source metadata does not match its archived original.") }
        return try .init(reference: reference, originalData: readOriginal(reference, at: child))
    }

    /// Deduplicates exact bytes. Does not overwrite or delete any previous archive.
    public func insert(_ data: Data, displayName: String) throws -> AndroidSourceArchiveReference {
        _ = try AndroidProfileDocument.parse(data)
        let checksum = androidSHA256(data)
        try createRoot()
        let existing = try list()
        if let found = existing.first(where: { $0.sha256 == checksum && $0.byteCount == data.count }) {
            guard try load(found).originalData == data else { throw AndroidArchiveError("Archive checksum collision; nothing was changed.") }
            return found
        }
        let cleaned = displayName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = try AndroidSourceArchiveReference(sha256: checksum, byteCount: data.count,
            displayName: String((cleaned.isEmpty ? "Android profile.json" : cleaned).prefix(160)))
        try validateBudget(existing + [reference])
        try writeNew(try .init(reference: reference, originalData: data))
        return reference
    }

    /// Used after an entire portable backup validates. Preserves incoming IDs for its native bindings.
    /// All conflicts/budgets are checked before the first write; I/O failure never deletes old archives.
    @discardableResult
    public func insertVerified(_ sources: [AndroidArchivedSource]) throws -> [UUID: AndroidSourceArchiveReference] {
        try createRoot()
        let existing = try list()
        guard Set(sources.map { $0.reference.id }).count == sources.count else { throw AndroidArchiveError("Duplicate archive IDs in backup.") }
        var additions: [AndroidArchivedSource] = []
        var mapping: [UUID: AndroidSourceArchiveReference] = [:]
        for source in sources {
            _ = try AndroidArchivedSource(reference: source.reference, originalData: source.originalData)
            if let found = existing.first(where: { $0.id == source.reference.id }) {
                guard found == source.reference, try load(found).originalData == source.originalData else {
                    throw AndroidArchiveError("An archive ID conflicts with an existing original. Nothing was imported.")
                }
                mapping[source.reference.id] = found
            } else if let same = (existing + additions.map(\.reference)).first(where: { $0.sha256 == source.reference.sha256 && $0.byteCount == source.reference.byteCount }) {
                let bytes = try additions.first(where: { $0.reference.id == same.id })?.originalData ?? load(same).originalData
                guard bytes == source.originalData else { throw AndroidArchiveError("Archive checksum collision; nothing was imported.") }
                mapping[source.reference.id] = same
            } else { additions.append(source); mapping[source.reference.id] = source.reference }
        }
        try validateBudget(existing + additions.map(\.reference))
        for source in additions { try writeNew(source) }
        return mapping
    }

    private func validateBudget(_ references: [AndroidSourceArchiveReference]) throws {
        guard references.count <= Self.maximumArchiveCount, references.reduce(0, { $0 + $1.byteCount }) <= Self.maximumTotalBytes else {
            throw AndroidArchiveError("Android originals are limited to 32 files and 25 MiB in total. Existing originals are unchanged.")
        }
    }
    private func archiveURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private func createRoot() throws {
        if !FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try requireDirectory(directory)
    }
    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AndroidArchiveError("Archive storage must be an app-private directory, not a symbolic link.") }
    }
    private func boundedFile(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= limit else {
            throw AndroidArchiveError("Invalid or oversized Android archive file.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw AndroidArchiveError("Android archive changed while being read.") }
        return data
    }
    private func readReference(at folder: URL) throws -> AndroidSourceArchiveReference {
        try requireDirectory(folder)
        return try JSONDecoder().decode(AndroidSourceArchiveReference.self, from: boundedFile(folder.appendingPathComponent("manifest.json"), limit: 4_096))
    }
    private func readOriginal(_ reference: AndroidSourceArchiveReference, at folder: URL) throws -> Data {
        try requireDirectory(folder)
        let data = try boundedFile(folder.appendingPathComponent("original.json"), limit: reference.byteCount)
        guard data.count == reference.byteCount, androidSHA256(data) == reference.sha256 else { throw AndroidArchiveError("Android original failed its checksum check.") }
        return data
    }
    private func writeNew(_ source: AndroidArchivedSource) throws {
        let pending = directory.appendingPathComponent(".pending-" + source.reference.id.uuidString.lowercased(), isDirectory: true)
        let final = archiveURL(source.reference.id)
        guard !FileManager.default.fileExists(atPath: final.path), !FileManager.default.fileExists(atPath: pending.path) else {
            throw AndroidArchiveError("Archive path is already occupied; no original was overwritten.")
        }
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(source.reference).write(to: pending.appendingPathComponent("manifest.json"), options: .atomic)
        try source.originalData.write(to: pending.appendingPathComponent("original.json"), options: .atomic)
        _ = try readOriginal(source.reference, at: pending)
        try FileManager.default.moveItem(at: pending, to: final)
    }
    private func recoverPending() throws {
        for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where folder.lastPathComponent.hasPrefix(".pending-") {
            let suffix = String(folder.lastPathComponent.dropFirst(9))
            guard let id = UUID(uuidString: suffix), suffix == id.uuidString.lowercased() else { continue }
            // Incomplete writes are left untouched. A complete pending archive can be recovered safely.
            guard let reference = try? readReference(at: folder), reference.id == id,
                  (try? readOriginal(reference, at: folder)) != nil else { continue }
            let final = archiveURL(id)
            if !FileManager.default.fileExists(atPath: final.path) { try FileManager.default.moveItem(at: folder, to: final) }
        }
    }
}

/// Portable wrapper: the strict native document and each original are included once, as bytes.
/// Decoding validates everything before callers insert sources or merge any profiles.
public struct AndroidPortableBackup: Equatable, Sendable {
    public static let maximumBytes = 40 * 1_024 * 1_024
    public let nativeLibraryData: Data
    public let archives: [AndroidArchivedSource]
    public init(nativeLibraryData: Data, archives: [AndroidArchivedSource]) throws {
        let library = try ControllerProfileLibraryCodec.decode(nativeLibraryData)
        guard archives.count <= AndroidProfileArchiveStore.maximumArchiveCount,
              Set(archives.map { $0.reference.id }).count == archives.count,
              archives.reduce(0, { $0 + $1.originalData.count }) <= AndroidProfileArchiveStore.maximumTotalBytes else {
            throw AndroidArchiveError("Portable backup exceeds the Android source archive limits.")
        }
        for archive in archives { _ = try AndroidArchivedSource(reference: archive.reference, originalData: archive.originalData) }
        guard Set(library.androidSources.map(\.id)) == Set(archives.map { $0.reference.id }),
              library.androidSources.allSatisfy({ reference in archives.contains { $0.reference == reference } }) else {
            throw AndroidArchiveError("Portable backup must include every referenced Android original, with matching metadata.")
        }
        self.nativeLibraryData = nativeLibraryData; self.archives = archives
    }
    public func encodedData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(fileType: "simplecontroller-ios-portable-backup", version: 1,
            nativeLibraryData: nativeLibraryData, archives: archives.map { .init(reference: $0.reference, originalData: $0.originalData) }))
        guard data.count <= Self.maximumBytes else { throw AndroidArchiveError("Portable backup exceeds 40 MiB.") }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw AndroidArchiveError("Portable backup exceeds 40 MiB.") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.fileType == "simplecontroller-ios-portable-backup", envelope.version == 1 else { throw AndroidArchiveError("Unsupported portable backup format.") }
        return try .init(nativeLibraryData: envelope.nativeLibraryData, archives: envelope.archives.map { try .init(reference: $0.reference, originalData: $0.originalData) })
    }
    private struct Entry: Codable {
        let reference: AndroidSourceArchiveReference; let originalData: Data
        init(reference: AndroidSourceArchiveReference, originalData: Data) { self.reference = reference; self.originalData = originalData }
        private enum CodingKeys: String, CodingKey { case reference, originalData }
        init(from decoder: Decoder) throws {
            try profileKeys(decoder, ["reference", "originalData"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reference = try c.decode(AndroidSourceArchiveReference.self, forKey: .reference)
            originalData = try c.decode(Data.self, forKey: .originalData)
        }
    }
    private struct Envelope: Codable {
        let fileType: String; let version: Int; let nativeLibraryData: Data; let archives: [Entry]
        private enum CodingKeys: String, CodingKey { case fileType, version, nativeLibraryData, archives }
        init(fileType: String, version: Int, nativeLibraryData: Data, archives: [Entry]) {
            self.fileType = fileType; self.version = version; self.nativeLibraryData = nativeLibraryData; self.archives = archives
        }
        init(from decoder: Decoder) throws {
            try profileKeys(decoder, ["fileType", "version", "nativeLibraryData", "archives"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fileType = try c.decode(String.self, forKey: .fileType); version = try c.decode(Int.self, forKey: .version)
            nativeLibraryData = try c.decode(Data.self, forKey: .nativeLibraryData); archives = try c.decode([Entry].self, forKey: .archives)
        }
    }
}

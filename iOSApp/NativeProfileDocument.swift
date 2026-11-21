import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ControllerCore

/// Profile JSON export. Native backups may bundle exact Android originals; connection and live input stay excluded.
struct NativeProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    enum Kind: Equatable { case nativeBackup, androidOriginal, androidEdited }
    var data: Data
    var kind: Kind = .nativeBackup

    init(data: Data, kind: Kind = .nativeBackup) { self.data = data; self.kind = kind }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw NativeProfileFileError.unreadable
        }
        try Self.validateBackup(data)
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch kind {
        case .nativeBackup: try Self.validateBackup(data)
        case .androidOriginal, .androidEdited: _ = try AndroidProfileDocument.parse(data)
        }
        return FileWrapper(regularFileWithContents: data)
    }

    /// Read at most the limit plus one byte, so oversized selected files never load in full.
    static func readBounded(from url: URL, maximum: Int = AndroidPortableBackup.maximumBytes) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while result.count <= maximum {
            let requested = min(64 * 1_024, maximum + 1 - result.count)
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        guard result.count <= maximum else { throw NativeProfileFileError.tooLarge(maximum) }
        return result
    }
    private static func validateBackup(_ data: Data) throws {
        guard data.count <= AndroidPortableBackup.maximumBytes else { throw NativeProfileFileError.tooLarge(AndroidPortableBackup.maximumBytes) }
        let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if header?["fileType"] as? String == "simplecontroller-ios-portable-backup" {
            _ = try AndroidPortableBackup.decode(data)
        } else { _ = try ControllerProfileLibraryCodec.decode(data) }
    }
}

enum NativeProfileFileError: LocalizedError {
    case unreadable
    case tooLarge(Int)
    var errorDescription: String? {
        switch self {
        case .unreadable: return "The selected file could not be read as a profile backup."
        case .tooLarge(let limit): return "This file is larger than \(limit / 1_024 / 1_024) MiB. Nothing was imported."
        }
    }
}

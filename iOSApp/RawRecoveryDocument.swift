import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Copies the preserved document byte-for-byte. It never parses, repairs or re-encodes it.
struct RawRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .json] }
    static var writableContentTypes: [UTType] { [.data, .json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

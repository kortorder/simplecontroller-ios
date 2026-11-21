import Foundation

public enum ControllerThemePreference: String, Codable, CaseIterable, Sendable {
    case dark, light, system
}

public enum ControllerDisplayOrientation: String, Codable, CaseIterable, Sendable {
    case automatic, portrait, landscape
}

public enum ControllerPresentationError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion(Int), invalidData, oversizedData
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "These display settings use an unsupported version. Keep the saved data until you choose to reset it."
        case .invalidData: "The saved display settings could not be read."
        case .oversizedData: "The saved display settings are too large."
        }
    }
}

/// App-local preferences, deliberately separate from controller profiles/backups.
/// Edit orientation is transient and is never encoded here.
public struct ControllerPresentationPreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var theme: ControllerThemePreference
    public var playOrientation: ControllerDisplayOrientation
    public init(version: Int = currentVersion, theme: ControllerThemePreference = .dark,
                playOrientation: ControllerDisplayOrientation = .automatic) {
        self.version = version; self.theme = theme; self.playOrientation = playOrientation
    }
    public static let `default` = Self()
    public func validate() throws {
        guard version == Self.currentVersion else { throw ControllerPresentationError.unsupportedVersion(version) }
    }
    private enum CodingKeys: String, CodingKey { case version, theme, playOrientation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        try validateVersion(version)
        try profileKeys(decoder, ["version", "theme", "playOrientation"])
        theme = try c.decode(ControllerThemePreference.self, forKey: .theme)
        playOrientation = try c.decode(ControllerDisplayOrientation.self, forKey: .playOrientation)
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(theme, forKey: .theme)
        try c.encode(playOrientation, forKey: .playOrientation)
    }
}

private func validateVersion(_ version: Int) throws {
    guard version == ControllerPresentationPreferences.currentVersion else {
        throw ControllerPresentationError.unsupportedVersion(version)
    }
}

public enum ControllerPresentationCodec {
    public static let maximumBytes = 4_096
    public static func encode(_ value: ControllerPresentationPreferences) throws -> Data {
        try value.validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw ControllerPresentationError.oversizedData }
        return data
    }
    public static func decode(_ data: Data) throws -> ControllerPresentationPreferences {
        guard !data.isEmpty else { throw ControllerPresentationError.invalidData }
        guard data.count <= maximumBytes else { throw ControllerPresentationError.oversizedData }
        return try JSONDecoder().decode(ControllerPresentationPreferences.self, from: data)
    }
}

public enum ControllerPresentationPolicy {
    /// The caller stores editorOrientation only for the current editing session.
    public static func orientation(preferences: ControllerPresentationPreferences, isEditing: Bool,
                                   editorOrientation: ControllerDisplayOrientation = .automatic) -> ControllerDisplayOrientation {
        isEditing ? editorOrientation : preferences.playOrientation
    }
}

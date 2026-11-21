import Foundation

/// Transient physical finger travel in stick-radius units; transport positions remain normalized.
public struct StickTravel: Equatable, Sendable {
    public static let maximumMagnitude: Double = 64
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
    public init(_ position: StickPosition) { x = position.x; y = position.y }
    public static let zero = StickTravel()
    public var isValid: Bool {
        x.isFinite && y.isFinite && abs(x) <= Self.maximumMagnitude && abs(y) <= Self.maximumMagnitude
    }
    /// Use after validating the sample; this is for knob display and the analog response input.
    public var clampedPosition: StickPosition {
        .init(x: min(1, max(-1, x)), y: min(1, max(-1, y)))
    }
}

public enum StickResponseMode: String, CaseIterable, Codable, Sendable { case linear, perAxis, radial }
public struct StickResponseSettings: Codable, Equatable, Sendable {
    public var mode: StickResponseMode
    public var sensitivity: Double
    public init(mode: StickResponseMode = .linear, sensitivity: Double = 1) {
        self.mode = mode; self.sensitivity = sensitivity
    }
    public func validate() throws {
        guard sensitivity.isFinite, (0...5).contains(sensitivity) else {
            throw ControllerPayloadError("Stick sensitivity must be between 0 and 5.")
        }
    }
    public func apply(_ position: StickPosition) throws -> StickPosition {
        try validate(); guard position.isValid else { throw ControllerInputError.invalidPosition }
        return applyValidated(position)
    }
    func applyValidated(_ position: StickPosition) -> StickPosition {
        guard sensitivity > 0 else { return .zero }
        func curve(_ value: Double) -> Double {
            guard value != 0 else { return 0 }
            return (value < 0 ? -1 : 1) * pow(abs(value), 1 / sensitivity)
        }
        switch mode {
        case .linear:
            return .init(x: min(1, max(-1, position.x * sensitivity)), y: min(1, max(-1, position.y * sensitivity)))
        case .perAxis: return .init(x: curve(position.x), y: curve(position.y))
        case .radial:
            let magnitude = hypot(position.x, position.y)
            guard magnitude > 0 else { return .zero }
            let scale = curve(min(1, magnitude)) / magnitude
            return .init(x: min(1, max(-1, position.x * scale)), y: min(1, max(-1, position.y * scale)))
        }
    }
    private enum CodingKeys: String, CodingKey { case mode, sensitivity }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["mode", "sensitivity"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(StickResponseMode.self, forKey: .mode)
        sensitivity = try values.decode(Double.self, forKey: .sensitivity); try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode); try values.encode(sensitivity, forKey: .sensitivity)
    }
}

public enum ExtendedBoostMode: String, CaseIterable, Codable, Sendable { case replaceThresholds, addOuterStage }
public struct ExtendedBoostDirectionSettings: Codable, Equatable, Sendable {
    public var regularThreshold: Double
    public var superThreshold: Double
    public var outerThreshold: Double
    public var outerPayload: String?
    public init(regularThreshold: Double = 0.5, superThreshold: Double = 0.75,
                outerThreshold: Double = 1.25, outerPayload: String? = nil) {
        self.regularThreshold = regularThreshold; self.superThreshold = superThreshold
        self.outerThreshold = outerThreshold; self.outerPayload = outerPayload
    }
    public func validate(sharedSuperThreshold: Double) throws {
        let values = [regularThreshold, superThreshold, outerThreshold]
        guard sharedSuperThreshold.isFinite, (0...1).contains(sharedSuperThreshold),
              values.allSatisfy({ $0.isFinite && (0.1...5).contains($0) }) else {
            throw ControllerPayloadError("Extended Boost distances must be between 0.10 and 5.")
        }
        guard superThreshold - regularThreshold >= 0.01 - 1e-12 else {
            throw ControllerPayloadError("Super Boost distance must exceed Regular Boost by at least 0.01.")
        }
        guard outerThreshold >= max(1, sharedSuperThreshold) + 0.01 - 1e-12 else {
            throw ControllerPayloadError("Outer Boost distance must be at least 0.01 beyond the stick edge and shared Super Boost.")
        }
        if let outerPayload {
            guard outerPayload.count <= 1_000 else { throw ControllerPayloadError("Outer Boost payload must be at most 1000 characters.") }
            try ControllerPayloadProgram.parse(outerPayload).validateSustained()
        }
    }
    private enum CodingKeys: String, CodingKey { case regularThreshold, superThreshold, outerThreshold, outerPayload }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["regularThreshold", "superThreshold", "outerThreshold", "outerPayload"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        regularThreshold = try values.decode(Double.self, forKey: .regularThreshold)
        superThreshold = try values.decode(Double.self, forKey: .superThreshold)
        outerThreshold = try values.decode(Double.self, forKey: .outerThreshold)
        outerPayload = try values.decodeIfPresent(String.self, forKey: .outerPayload)
        try validate(sharedSuperThreshold: 1)
    }
    public func encode(to encoder: Encoder) throws {
        try validate(sharedSuperThreshold: 1); var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(regularThreshold, forKey: .regularThreshold); try values.encode(superThreshold, forKey: .superThreshold)
        try values.encode(outerThreshold, forKey: .outerThreshold); try values.encode(outerPayload, forKey: .outerPayload)
    }
}
public struct ExtendedBoostSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mode: ExtendedBoostMode
    public var directions: [StickDirection: ExtendedBoostDirectionSettings]
    public init(enabled: Bool = false, mode: ExtendedBoostMode = .replaceThresholds,
                directions: [StickDirection: ExtendedBoostDirectionSettings] = Dictionary(
                    uniqueKeysWithValues: StickDirection.allCases.map { ($0, .init()) })) {
        self.enabled = enabled; self.mode = mode; self.directions = directions
    }
    public func validate(sharedSuperThreshold: Double) throws {
        guard Set(directions.keys) == Set(StickDirection.allCases) else {
            throw ControllerPayloadError("Every stick direction must have Extended Boost settings.")
        }
        for direction in StickDirection.allCases {
            do { try directions[direction]!.validate(sharedSuperThreshold: sharedSuperThreshold) }
            catch { throw ControllerPayloadError("\(direction.rawValue.capitalized): \(error.localizedDescription)") }
        }
    }
    private enum CodingKeys: String, CodingKey { case enabled, mode, directions }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "mode", "directions"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled); mode = try values.decode(ExtendedBoostMode.self, forKey: .mode)
        let saved = try values.decode([String: ExtendedBoostDirectionSettings].self, forKey: .directions)
        guard Set(saved.keys) == Set(StickDirection.allCases.map(\.rawValue)) else {
            throw ControllerPayloadError("Every stick direction must have Extended Boost settings.")
        }
        directions = Dictionary(uniqueKeysWithValues: saved.map { (StickDirection(rawValue: $0.key)!, $0.value) })
        try validate(sharedSuperThreshold: 1)
    }
    public func encode(to encoder: Encoder) throws {
        try validate(sharedSuperThreshold: 1); var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled); try values.encode(mode, forKey: .mode)
        try values.encode(Dictionary(uniqueKeysWithValues: directions.map { ($0.key.rawValue, $0.value) }), forKey: .directions)
    }
}

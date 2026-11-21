import Foundation

public enum ControllerBehaviorError: Error, Equatable, Sendable {
    case unsupportedVersion(Int), invalidFormat, invalidHoldDuration, invalidThresholds
    case invalidControl, missingControls, duplicateControls, invalidDirections, oversizedData
}

public struct ButtonBehavior: Codable, Equatable, Sendable {
    public var holdToggle: Bool
    public var holdMilliseconds: Int
    public init(holdToggle: Bool = false, holdMilliseconds: Int = 500) {
        self.holdToggle = holdToggle; self.holdMilliseconds = holdMilliseconds
    }
    public func validate() throws {
        guard (50...5_000).contains(holdMilliseconds) else { throw ControllerBehaviorError.invalidHoldDuration }
    }
    private enum CodingKeys: String, CodingKey { case holdToggle, holdMilliseconds }
    public init(from decoder: Decoder) throws {
        try behaviorKeys(decoder, ["holdToggle", "holdMilliseconds"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        holdToggle = try values.decode(Bool.self, forKey: .holdToggle)
        holdMilliseconds = try values.decode(Int.self, forKey: .holdMilliseconds)
        try validate()
    }
}

public enum StickDirection: String, Codable, CaseIterable, Sendable { case up, right, down, left }

public struct StickDirectionMapping: Codable, Equatable, Sendable {
    public var normalControls: Set<ControllerControlID>
    public var boostControls: Set<ControllerControlID>
    public var superBoostControls: Set<ControllerControlID>
    public init(normalControls: Set<ControllerControlID> = [], boostControls: Set<ControllerControlID> = [],
                superBoostControls: Set<ControllerControlID> = []) {
        self.normalControls = normalControls
        self.boostControls = boostControls; self.superBoostControls = superBoostControls
    }
    public func validate() throws {
        guard !normalControls.union(boostControls).union(superBoostControls).contains(where: \.isStick) else {
            throw ControllerBehaviorError.invalidControl
        }
    }
    private enum CodingKeys: String, CodingKey { case normalControls, boostControls, superBoostControls }
    public init(from decoder: Decoder) throws {
        try behaviorKeys(decoder, ["normalControls", "boostControls", "superBoostControls"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let normal = try values.decode([ControllerControlID].self, forKey: .normalControls)
        let boost = try values.decode([ControllerControlID].self, forKey: .boostControls)
        let superBoost = try values.decode([ControllerControlID].self, forKey: .superBoostControls)
        guard Set(normal).count == normal.count, Set(boost).count == boost.count, Set(superBoost).count == superBoost.count else {
            throw ControllerBehaviorError.duplicateControls
        }
        normalControls = Set(normal)
        boostControls = Set(boost); superBoostControls = Set(superBoost)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(normalControls.sorted { $0.rawValue < $1.rawValue }, forKey: .normalControls)
        try values.encode(boostControls.sorted { $0.rawValue < $1.rawValue }, forKey: .boostControls)
        try values.encode(superBoostControls.sorted { $0.rawValue < $1.rawValue }, forKey: .superBoostControls)
    }
}

public struct StickBehavior: Codable, Equatable, Sendable {
    public var autoCenter: Bool
    public var stickPlusEnabled: Bool
    public var boostThreshold: Double
    public var superBoostThreshold: Double
    public var directions: [StickDirection: StickDirectionMapping]
    public init(autoCenter: Bool = true, stickPlusEnabled: Bool = false,
                boostThreshold: Double = 0.5, superBoostThreshold: Double = 0.75,
                directions: [StickDirection: StickDirectionMapping] = Dictionary(
                    uniqueKeysWithValues: StickDirection.allCases.map { ($0, StickDirectionMapping()) })) {
        self.autoCenter = autoCenter; self.stickPlusEnabled = stickPlusEnabled
        self.boostThreshold = boostThreshold; self.superBoostThreshold = superBoostThreshold
        self.directions = directions
    }
    public func validate() throws {
        guard boostThreshold.isFinite, superBoostThreshold.isFinite,
              (0...1).contains(boostThreshold), (0...1).contains(superBoostThreshold),
              boostThreshold < superBoostThreshold else { throw ControllerBehaviorError.invalidThresholds }
        guard Set(directions.keys) == Set(StickDirection.allCases) else { throw ControllerBehaviorError.invalidDirections }
        for mapping in directions.values { try mapping.validate() }
    }
    private enum CodingKeys: String, CodingKey {
        case autoCenter, stickPlusEnabled, boostThreshold, superBoostThreshold, directions
    }
    public init(from decoder: Decoder) throws {
        try behaviorKeys(decoder, ["autoCenter", "stickPlusEnabled", "boostThreshold", "superBoostThreshold", "directions"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoCenter = try values.decode(Bool.self, forKey: .autoCenter)
        stickPlusEnabled = try values.decode(Bool.self, forKey: .stickPlusEnabled)
        boostThreshold = try values.decode(Double.self, forKey: .boostThreshold)
        superBoostThreshold = try values.decode(Double.self, forKey: .superBoostThreshold)
        let saved = try values.decode([String: StickDirectionMapping].self, forKey: .directions)
        guard Set(saved.keys) == Set(StickDirection.allCases.map(\.rawValue)) else {
            throw ControllerBehaviorError.invalidDirections
        }
        directions = Dictionary(uniqueKeysWithValues: saved.map { (StickDirection(rawValue: $0.key)!, $0.value) })
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(autoCenter, forKey: .autoCenter)
        try values.encode(stickPlusEnabled, forKey: .stickPlusEnabled)
        try values.encode(boostThreshold, forKey: .boostThreshold)
        try values.encode(superBoostThreshold, forKey: .superBoostThreshold)
        try values.encode(Dictionary(uniqueKeysWithValues: directions.map { ($0.key.rawValue, $0.value) }), forKey: .directions)
    }
}

/// Independent of saved geometry. Mutators validate before replacing any setting.
public struct ControllerBehaviors: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    private var buttons: [ControllerControlID: ButtonBehavior]
    private var sticks: [ControllerControlID: StickBehavior]
    public init() {
        version = Self.currentVersion
        buttons = Dictionary(uniqueKeysWithValues: ControllerControlID.allCases.filter { !$0.isStick }.map { ($0, ButtonBehavior()) })
        sticks = Dictionary(uniqueKeysWithValues: ControllerControlID.allCases.filter(\.isStick).map { ($0, StickBehavior()) })
    }
    public static let `default` = ControllerBehaviors()
    public var isValid: Bool { (try? validate()) != nil }
    /// Wrong-kind queries return inert defaults; setters reject wrong-kind IDs.
    public func button(for id: ControllerControlID) -> ButtonBehavior { buttons[id] ?? ButtonBehavior() }
    public func stick(for id: ControllerControlID) -> StickBehavior { sticks[id] ?? StickBehavior() }
    public mutating func setButton(_ behavior: ButtonBehavior, for id: ControllerControlID) throws {
        guard !id.isStick else { throw ControllerBehaviorError.invalidControl }
        try behavior.validate()
        buttons[id] = behavior
    }
    public mutating func setStick(_ behavior: StickBehavior, for id: ControllerControlID) throws {
        guard id.isStick else { throw ControllerBehaviorError.invalidControl }
        try behavior.validate()
        sticks[id] = behavior
    }
    public func validate() throws {
        guard version == Self.currentVersion else { throw ControllerBehaviorError.unsupportedVersion(version) }
        guard Set(buttons.keys) == Set(ControllerControlID.allCases.filter { !$0.isStick }),
              Set(sticks.keys) == Set(ControllerControlID.allCases.filter(\.isStick)) else {
            throw ControllerBehaviorError.missingControls
        }
        for behavior in buttons.values { try behavior.validate() }
        for behavior in sticks.values { try behavior.validate() }
    }
    private enum CodingKeys: String, CodingKey { case version, buttons, sticks }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw ControllerBehaviorError.unsupportedVersion(version) }
        try behaviorKeys(decoder, ["version", "buttons", "sticks"])
        let savedButtons = try values.decode([ButtonEntry].self, forKey: .buttons)
        let savedSticks = try values.decode([StickEntry].self, forKey: .sticks)
        guard Set(savedButtons.map(\.control)).count == savedButtons.count,
              Set(savedSticks.map(\.control)).count == savedSticks.count else { throw ControllerBehaviorError.duplicateControls }
        buttons = Dictionary(uniqueKeysWithValues: savedButtons.map { ($0.control, $0.behavior) })
        sticks = Dictionary(uniqueKeysWithValues: savedSticks.map { ($0.control, $0.behavior) })
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(buttons.keys.sorted { $0.rawValue < $1.rawValue }.map { ButtonEntry(control: $0, behavior: buttons[$0]!) }, forKey: .buttons)
        try values.encode(sticks.keys.sorted { $0.rawValue < $1.rawValue }.map { StickEntry(control: $0, behavior: sticks[$0]!) }, forKey: .sticks)
    }
}

private struct ButtonEntry: Codable {
    let control: ControllerControlID
    let behavior: ButtonBehavior
    init(control: ControllerControlID, behavior: ButtonBehavior) { self.control = control; self.behavior = behavior }
    private enum CodingKeys: String, CodingKey { case control, behavior }
    init(from decoder: Decoder) throws {
        try behaviorKeys(decoder, ["control", "behavior"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        control = try values.decode(ControllerControlID.self, forKey: .control)
        behavior = try values.decode(ButtonBehavior.self, forKey: .behavior)
    }
}
private struct StickEntry: Codable {
    let control: ControllerControlID
    let behavior: StickBehavior
    init(control: ControllerControlID, behavior: StickBehavior) { self.control = control; self.behavior = behavior }
    private enum CodingKeys: String, CodingKey { case control, behavior }
    init(from decoder: Decoder) throws {
        try behaviorKeys(decoder, ["control", "behavior"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        control = try values.decode(ControllerControlID.self, forKey: .control)
        behavior = try values.decode(StickBehavior.self, forKey: .behavior)
    }
}
public enum ControllerBehaviorsCodec {
    public static let maximumBytes = 65_536
    public static func encode(_ configuration: ControllerBehaviors) throws -> Data {
        try configuration.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= maximumBytes else { throw ControllerBehaviorError.oversizedData }
        return data
    }
    public static func decode(_ data: Data) throws -> ControllerBehaviors {
        guard data.count <= maximumBytes else { throw ControllerBehaviorError.oversizedData }
        do { return try JSONDecoder().decode(ControllerBehaviors.self, from: data) }
        catch let error as ControllerBehaviorError { throw error }
        catch { throw ControllerBehaviorError.invalidFormat }
    }
}
private struct BehaviorKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func behaviorKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let values = try decoder.container(keyedBy: BehaviorKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == expected else { throw ControllerBehaviorError.invalidFormat }
}

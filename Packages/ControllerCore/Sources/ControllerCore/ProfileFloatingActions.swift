import Foundation

/// A stable identity, never a display name or a wildcard. Missing targets remain inert.
public enum ProfileFloatingActionTarget: Equatable, Sendable, Codable {
    case zone(UUID), control(UUID)
    public var targetID: UUID { switch self { case let .zone(id), let .control(id): id } }
    private enum CodingKeys: String, CodingKey { case kind, id }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["kind", "id"])
        let c = try decoder.container(keyedBy: CodingKeys.self), id = try c.decode(UUID.self, forKey: .id)
        switch try c.decode(String.self, forKey: .kind) {
        case "zone": self = .zone(id)
        case "control": self = .control(id)
        default: throw FloatingControlError("Unknown scoped-action target type.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(targetID, forKey: .id)
        switch self { case .zone: try c.encode("zone", forKey: .kind); case .control: try c.encode("control", forKey: .kind) }
    }
    func remapping(zones: [UUID: UUID], controls: [UUID: UUID], missing: [UUID: UUID] = [:]) -> Self {
        switch self {
        case let .zone(id): .zone(zones[id] ?? missing[id] ?? id)
        case let .control(id): .control(controls[id] ?? missing[id] ?? id)
        }
    }
}

public struct ProfileFloatingActionBinding: Equatable, Sendable, Codable {
    public var action: FloatingLocalAction
    public var target: ProfileFloatingActionTarget
    public init(action: FloatingLocalAction, target: ProfileFloatingActionTarget) { self.action = action; self.target = target }
    public func validate() throws {
        if case .control = target, action != .endSuppression { throw FloatingControlError("Only End camera suppression can target an ordinary control.") }
    }
    func remapping(zones: [UUID: UUID], controls: [UUID: UUID], missing: [UUID: UUID] = [:]) -> Self {
        .init(action: action, target: target.remapping(zones: zones, controls: controls, missing: missing))
    }
    private enum CodingKeys: String, CodingKey { case action, target }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["action", "target"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(action: try c.decode(FloatingLocalAction.self, forKey: .action), target: try c.decode(ProfileFloatingActionTarget.self, forKey: .target))
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action); try c.encode(target, forKey: .target)
    }
}

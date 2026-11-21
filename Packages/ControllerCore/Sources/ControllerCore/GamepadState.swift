import Foundation

public enum PadButton: String, CaseIterable, Codable, Sendable {
    case a, b, x, y
    case leftBumper, rightBumper, view, menu, leftStick, rightStick
    // Digital practice controls; actual bridge/Xbox mappings remain unverified.
    case leftTrigger, rightTrigger, guide, share
}

public enum DPadDirection: String, CaseIterable, Codable, Sendable {
    case neutral, up, upRight, right, downRight, down, downLeft, left, upLeft
}

/// Normalized axes: right is positive X; up is positive Y.
/// Encoding rejects values outside -1...1 instead of silently changing them.
public struct StickPosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = StickPosition()

    public var isValid: Bool {
        x.isFinite && y.isFinite && (-1...1).contains(x) && (-1...1).contains(y)
    }
}

/// Complete current output, not a list of press/release transitions.
/// Trigger axes are intentionally absent until the physical XAC route is verified.
public struct GamepadState: Codable, Equatable, Sendable {
    public var buttons: Set<PadButton>
    public var leftStick: StickPosition
    public var rightStick: StickPosition
    public var dpad: DPadDirection

    public init(
        buttons: Set<PadButton> = [],
        leftStick: StickPosition = .zero,
        rightStick: StickPosition = .zero,
        dpad: DPadDirection = .neutral
    ) {
        self.buttons = buttons
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.dpad = dpad
    }

    public static let neutral = GamepadState()

    public var isNeutral: Bool { self == .neutral }
    public var isValid: Bool { leftStick.isValid && rightStick.isValid }

    private enum CodingKeys: String, CodingKey {
        case buttons, leftStick, rightStick, dpad
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([PadButton].self, forKey: .buttons)
        guard Set(values).count == values.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .buttons, in: container, debugDescription: "Duplicate button values"
            )
        }
        buttons = Set(values)
        leftStick = try container.decode(StickPosition.self, forKey: .leftStick)
        rightStick = try container.decode(StickPosition.self, forKey: .rightStick)
        dpad = try container.decode(DPadDirection.self, forKey: .dpad)
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .leftStick, in: container, debugDescription: "Invalid stick axes"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(buttons.sorted { $0.rawValue < $1.rawValue }, forKey: .buttons)
        try container.encode(leftStick, forKey: .leftStick)
        try container.encode(rightStick, forKey: .rightStick)
        try container.encode(dpad, forKey: .dpad)
    }
}

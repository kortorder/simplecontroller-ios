import Foundation

public enum FixedStickChannel: String, Codable, CaseIterable, Sendable {
    case left, right
    public var control: ControllerControlID { self == .left ? .leftStick : .rightStick }
}

/// Audited Android payload syntax. This is a held, reversible vector, not a transport packet.
public struct FixedStickMacro: Equatable, Sendable {
    public let channel: FixedStickChannel
    public let direction: Direction
    public let percentage: Int

    public enum Direction: String, CaseIterable, Sendable {
        case up = "UP", right = "RIGHT", down = "DOWN", left = "LEFT"
        case upRight = "UR", upLeft = "UL", downRight = "BR", downLeft = "BL"
        fileprivate var unitPosition: StickPosition {
            switch self {
            case .up: .init(x: 0, y: 1)
            case .right: .init(x: 1, y: 0)
            case .down: .init(x: 0, y: -1)
            case .left: .init(x: -1, y: 0)
            case .upRight: .init(x: 1, y: 1)
            case .upLeft: .init(x: -1, y: 1)
            case .downRight: .init(x: 1, y: -1)
            case .downLeft: .init(x: -1, y: -1)
            }
        }
    }
    public init(channel: FixedStickChannel, direction: Direction, percentage: Int = 100) throws {
        guard (0...100).contains(percentage) else {
            throw ControllerPayloadError("Fixed stick intensity must be from 0 to 100 percent.")
        }
        self.channel = channel; self.direction = direction; self.percentage = percentage
    }
    public var position: StickPosition {
        let unit = direction.unitPosition, amount = Double(percentage) / 100
        return .init(x: unit.x * amount, y: unit.y * amount)
    }
    public var source: String { (channel == .left ? "LS:" : "RS:") + direction.rawValue + String(percentage) }

    /// Nil means a different token family; malformed LS:/RS: commands throw a corrective error.
    /// Source-compatible integer percentages above 100 clamp to 100; decimals and signs are invalid.
    public static func parse(_ source: String) throws -> Self? {
        let token = source.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard token.hasPrefix("LS:") || token.hasPrefix("RS:") else { return nil }
        let body = token.dropFirst(3)
        let letters = body.prefix { $0.isASCII && $0.isLetter }
        let digits = body.dropFirst(letters.count)
        let aliases: [String: Direction] = ["U": .up, "UP": .up, "R": .right, "RIGHT": .right,
            "D": .down, "DOWN": .down, "L": .left, "LEFT": .left,
            "UR": .upRight, "UL": .upLeft, "BR": .downRight, "BL": .downLeft]
        guard let direction = aliases[String(letters)], digits.count <= 3,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits.isEmpty || Int(digits) != nil else {
            throw ControllerPayloadError("Use LS:UP50 or RS:BL100. Directions are U/UP, R/RIGHT, D/DOWN, L/LEFT, UR, UL, BR or BL, with an optional whole percent; use 0 percent to release your own vector.")
        }
        return try Self(channel: token.hasPrefix("LS:") ? .left : .right, direction: direction,
                        percentage: min(100, digits.isEmpty ? 100 : Int(digits)!))
    }
}

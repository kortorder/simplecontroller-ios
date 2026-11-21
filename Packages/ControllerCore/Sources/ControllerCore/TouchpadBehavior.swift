import Foundation

public struct PointerDelta: Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public init(dx: Double = 0, dy: Double = 0) { self.dx = dx; self.dy = dy }
    public static let zero = Self()
    public var isValidInput: Bool { dx.isFinite && dy.isFinite && abs(dx) <= 4_096 && abs(dy) <= 4_096 }
}

public enum TouchpadClickMode: String, Codable, CaseIterable, Sendable {
    case none, hold, toggle, doubleTapLock
}

public struct TouchpadBehavior: Codable, Equatable, Sendable {
    public var sensitivity: Double
    public var clickMode: TouchpadClickMode
    public init(sensitivity: Double = 1, clickMode: TouchpadClickMode = .none) {
        self.sensitivity = sensitivity; self.clickMode = clickMode
    }
    public func validate() throws {
        guard sensitivity.isFinite, (0...5).contains(sensitivity) else {
            throw ControllerPayloadError("Touchpad sensitivity must be between 0 and 5. Zero stops movement but keeps the click behavior.")
        }
    }
    private enum CodingKeys: String, CodingKey { case sensitivity, clickMode }
    private struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["sensitivity", "clickMode"] else { throw ControllerProfileError.invalidFormat }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sensitivity = try values.decode(Double.self, forKey: .sensitivity)
        clickMode = try values.decode(TouchpadClickMode.self, forKey: .clickMode)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sensitivity, forKey: .sensitivity); try values.encode(clickMode, forKey: .clickMode)
    }
}

// Practice totals are diagnostic offsets, never absolute OS cursor positions.
// Every accepted finite movement still has its own event even when these totals saturate.
func clampedPracticeTotal(_ current: Double, adding delta: Double) -> Double {
    min(PracticeOutputState.maximumMovementTotal, max(-PracticeOutputState.maximumMovementTotal, current + delta))
}

func touchpadResponse(_ value: Double) -> Double {
    let magnitude = abs(value), sign = value < 0 ? -1.0 : 1.0
    if magnitude < 0.2 { return sign * magnitude * 1.5 }
    if magnitude < 0.6 { return value }
    return sign * (0.6 + (magnitude - 0.6) * 0.8)
}

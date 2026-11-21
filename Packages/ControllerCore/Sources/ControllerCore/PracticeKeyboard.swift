import Foundation

/// Finite, platform-neutral key names for local Practice. No OS keyboard injection occurs.
public enum KeyboardKey: String, Codable, CaseIterable, Sendable {
    case a = "A", b = "B", c = "C", d = "D", e = "E", f = "F", g = "G", h = "H", i = "I", j = "J", k = "K", l = "L", m = "M"
    case n = "N", o = "O", p = "P", q = "Q", r = "R", s = "S", t = "T", u = "U", v = "V", w = "W", x = "X", y = "Y", z = "Z"
    case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4", digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"
    case space = "SPACE", enter = "ENTER", escape = "ESC", tab = "TAB", backspace = "BACKSPACE"
    case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT", home = "HOME", end = "END"
    case pageUp = "PAGEUP", pageDown = "PAGEDOWN", insert = "INSERT", delete = "DELETE", capsLock = "CAPSLOCK"
    case leftShift = "LSHIFT", rightShift = "RSHIFT", leftControl = "LCTRL", rightControl = "RCTRL"
    case leftAlt = "LALT", rightAlt = "RALT", leftWindows = "LWIN", rightWindows = "RWIN"
    case f1 = "F1", f2 = "F2", f3 = "F3", f4 = "F4", f5 = "F5", f6 = "F6", f7 = "F7", f8 = "F8", f9 = "F9", f10 = "F10", f11 = "F11", f12 = "F12"

    static func parse(_ source: String) -> Self? {
        let token = source.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let key = Self(rawValue: token) { return key }
        let aliases: [String: Self] = [
            "SPACEBAR": .space, "SPACE BAR": .space, "ESCAPE": .escape,
            "CONTROL": .leftControl, "CTRL": .leftControl, "LEFT CTRL": .leftControl, "LEFT CONTROL": .leftControl,
            "RIGHT CTRL": .rightControl, "RIGHT CONTROL": .rightControl,
            "SHIFT": .leftShift, "LEFT SHIFT": .leftShift, "RIGHT SHIFT": .rightShift,
            "ALT": .leftAlt, "LEFT ALT": .leftAlt, "RIGHT ALT": .rightAlt,
            "WIN": .leftWindows, "WINDOWS": .leftWindows, "LEFT WINDOWS": .leftWindows, "RIGHT WINDOWS": .rightWindows,
            "PAGE UP": .pageUp, "PAGE DOWN": .pageDown, "CAPS LOCK": .capsLock
        ]
        return aliases[token]
    }
}

public enum PracticeMouseButton: String, Codable, CaseIterable, Sendable {
    case left = "LEFT", right = "RIGHT", middle = "MIDDLE"
}

public struct PracticeOutputEvent: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case keyDown(KeyboardKey), keyUp(KeyboardKey)
        case mouseDown(PracticeMouseButton), mouseUp(PracticeMouseButton)
        case pointerMoved(dx: Double, dy: Double)
        case scrolled(delta: Double)
        case scrollModeChanged(Bool)
        case reset
    }
    public let sequence: UInt64
    public let kind: Kind
    public var id: UInt64 { sequence }
    public init(sequence: UInt64, kind: Kind) { self.sequence = sequence; self.kind = kind }
}
public struct PracticeEventBatch: Equatable, Sendable {
    public let events: [PracticeOutputEvent]
    public let omittedCount: Int
    public init(events: [PracticeOutputEvent], omittedCount: Int = 0) { self.events = events; self.omittedCount = omittedCount }
}

public enum StickStage: String, Codable, CaseIterable, Sendable {
    case normal, boost, superBoost
    public var displayName: String {
        switch self { case .normal: "Normal"; case .boost: "Boost"; case .superBoost: "Super boost" }
    }
}
public struct StickDirectionPayloads: Codable, Equatable, Sendable {
    public var normalPayload: String?
    public var boostPayload: String?
    public var superBoostPayload: String?
    public init(normalPayload: String? = nil, boostPayload: String? = nil, superBoostPayload: String? = nil) {
        self.normalPayload = normalPayload; self.boostPayload = boostPayload; self.superBoostPayload = superBoostPayload
    }
    public func payload(for stage: StickStage) -> String? {
        switch stage { case .normal: normalPayload; case .boost: boostPayload; case .superBoost: superBoostPayload }
    }
    private enum CodingKeys: String, CodingKey { case normalPayload, boostPayload, superBoostPayload }
    private struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["normalPayload", "boostPayload", "superBoostPayload"] else { throw ControllerProfileError.invalidFormat }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        normalPayload = try values.decodeIfPresent(String.self, forKey: .normalPayload)
        boostPayload = try values.decodeIfPresent(String.self, forKey: .boostPayload)
        superBoostPayload = try values.decodeIfPresent(String.self, forKey: .superBoostPayload)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(normalPayload, forKey: .normalPayload); try values.encode(boostPayload, forKey: .boostPayload)
        try values.encode(superBoostPayload, forKey: .superBoostPayload)
    }
}

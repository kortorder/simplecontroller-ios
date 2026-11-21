import Foundation

/// A physical bridge snapshot, separate from the richer local Practice display.
/// Construct its gamepad from ProfileInputEngine.state, not practiceState.gamepad,
/// which may include generated Camera Follow output. Pressure is normalized 0...1.
public struct BridgeOutputState: Equatable, Sendable {
    public var gamepad: GamepadState
    public var leftTrigger: Double
    public var rightTrigger: Double

    public init(gamepad: GamepadState = .neutral, leftTrigger: Double = 0, rightTrigger: Double = 0) {
        self.gamepad = gamepad
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }

    public static let neutral = Self()
    public var isValid: Bool {
        gamepad.isValid && leftTrigger.isFinite && rightTrigger.isFinite &&
            (0...1).contains(leftTrigger) && (0...1).contains(rightTrigger)
    }
    public var isNeutral: Bool { gamepad.isNeutral && leftTrigger == 0 && rightTrigger == 0 }
}

/// SCX2's original wire revision remains the default. Pressure requires an
/// explicitly capable receiver; selecting it never falls back to binary output.
public enum SCX2Revision: UInt8, CaseIterable, Sendable {
    case legacy = 2
    case pressure = 3
    case usbButtons = 4
    case usbPressure = 5

    public var hasTriggerFields: Bool { self != .legacy }
}

/// Output selection is independent of saved layouts and payload pressure values.
public enum BridgeTriggerMode: String, Codable, CaseIterable, Sendable {
    case off, usbButtons, adjustable, cronusZen
    public var revision: SCX2Revision {
        switch self { case .off: .legacy; case .usbButtons: .usbButtons; case .adjustable: .pressure; case .cronusZen: .usbPressure }
    }
    public var displayName: String {
        switch self {
        case .off: "Off"
        case .usbButtons: "USB buttons (full press)"
        case .adjustable: "Adjustable (circuit)"
        case .cronusZen: "USB adjustable (Cronus Zen)"
        }
    }
}

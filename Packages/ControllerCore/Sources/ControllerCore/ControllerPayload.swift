import Foundation

public enum TriggerChannel: String, Codable, CaseIterable, Sendable { case left, right }

/// A local Practice action. These commands are never transported to a bridge.
public enum CameraFollowCommand: String, Equatable, Sendable { case toggle, enable, disable }

/// A local gameplay policy; no command is sent to the bridge.
public enum AutoCenterCommand: String, Equatable, Sendable { case toggle, enable, disable }

public enum ControllerPayloadStep: Equatable, Sendable {
    case digital(ControllerControlID)
    case keyDown(KeyboardKey)
    case scrollModeToggle
    case releaseAll
    case cameraFollow(CameraFollowCommand)
    case autoCenter(AutoCenterCommand)
    case fixedStick(FixedStickMacro)
    case mouseDown(PracticeMouseButton), mouseUp(PracticeMouseButton)
    case triggerPressure(TriggerChannel, Double)
    case triggerPulse(TriggerChannel, Double, duration: TimeInterval)
    case wait(milliseconds: Int)
}

public struct ControllerPayloadError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A locally interpreted controller program. It is never sent as an SCX1 datagram.
public struct ControllerPayloadProgram: Equatable, Sendable {
    public static let defaultMacroPressMilliseconds = 200
    public let steps: [ControllerPayloadStep]
    /// Every entry corresponds to the command at the same index in steps.
    public let modifiers: [PayloadCommandModifiers]
    public var hasModifiers: Bool { modifiers.contains(where: \.isModified) }
    public var minimumAndroidModifierVersion: Int { modifiers.map(\.minimumAndroidVersion).max() ?? 0 }

    init(steps: [ControllerPayloadStep], source: String, modifiers: [PayloadCommandModifiers]? = nil) {
        self.steps = steps; self.source = source
        self.modifiers = modifiers ?? Array(repeating: .init(), count: steps.count)
    }

    /// Existing surface mechanics still own every undecorated command.
    var unmodified: Self {
        guard hasModifiers else { return self }
        let indices = steps.indices.filter { !modifiers[$0].isModified }
        let tokens = source.components(separatedBy: ", ")
        return .init(steps: indices.map { steps[$0] }, source: indices.map { tokens[$0] }.joined(separator: ", "))
    }
    public let source: String
    public var outputTargets: Set<ControllerControlID> {
        Set(steps.compactMap { step in
            switch step {
            case let .digital(id): return id
            case let .triggerPressure(channel, value), let .triggerPulse(channel, value, _):
                return value > 0 ? (channel == .left ? .leftTrigger : .rightTrigger) : nil
            case let .fixedStick(macro): return macro.channel.control
            case .wait, .keyDown, .mouseDown, .mouseUp, .scrollModeToggle, .releaseAll, .cameraFollow, .autoCenter: return nil
            }
        })
    }
    public var hasKeyboardOrMouse: Bool {
        steps.contains { switch $0 { case .keyDown, .mouseDown, .mouseUp, .scrollModeToggle: true; default: false } }
    }
    public var isReleaseAll: Bool { steps.count == 1 && steps.first == .releaseAll }
    public var isScrollModeToggle: Bool { steps.count == 1 && steps.first == .scrollModeToggle }
    public var cameraFollowCommand: CameraFollowCommand? {
        guard steps.count == 1, case let .cameraFollow(command) = steps[0] else { return nil }
        return command
    }
    public var autoCenterCommand: AutoCenterCommand? {
        guard steps.count == 1, case let .autoCenter(command) = steps[0] else { return nil }
        return command
    }
    public var hasAnyOutput: Bool { steps.contains { if case .wait = $0 { false } else { true } } }
    public func validateSustained() throws {
        if steps.indices.contains(where: { i in switch steps[i] { case .triggerPulse: !modifiers[i].isModified; case .wait, .mouseUp, .scrollModeToggle, .releaseAll, .cameraFollow: true; default: false } }) {
            throw ControllerPayloadError("Stick stages allow held controller, fixed-stick, key and mouse-down actions only; WAIT, timed Pulse, mouse-up and local actions are not allowed.")
        }
    }
    public func validateMacroMode() throws {
        guard !steps.isEmpty, steps.allSatisfy(\.isReversibleTimingCommand) else {
            throw ControllerPayloadError("Macro Mode needs reversible button, trigger, key, mouse-down or stick commands. Use D for timed steps.")
        }
        guard modifiers.allSatisfy({ $0.repeatMilliseconds == nil }) else {
            throw ControllerPayloadError("Macro Mode completes once. Remove R repetition from this button.")
        }
    }

    /// Finite macro defaults apply only to this run, leaving authored payloads intact.
    var macroProgram: Self {
        let finite = steps.indices.map { index in
            var timing = modifiers[index]
            if timing.pressDurationMilliseconds == nil {
                if case .triggerPulse = steps[index] {} else {
                    timing.pressDurationMilliseconds = Self.defaultMacroPressMilliseconds
                }
            }
            return timing
        }
        return .init(steps: steps, source: source, modifiers: finite)
    }
    /// Independent timed trigger pulses do not disable Turbo/AutoTap on their siblings.
    var containsLegacyWaitOrPulse: Bool {
        steps.indices.contains { i in
            guard !modifiers[i].isModified else { return false }
            switch steps[i] { case .wait, .triggerPulse: return true; default: return false }
        }
    }
    public var containsWaitOrPulse: Bool {
        steps.contains { switch $0 { case .wait, .triggerPulse: true; default: false } }
    }
    public static func parse(_ source: String) throws -> Self {
        guard source.utf8.count <= 8_192 else { throw ControllerPayloadError("Payload must be at most 8 KiB.") }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .init(steps: [], source: "") }
        let timed = source.contains("(")
        let tokens = timed
            ? source.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
            : source.components(separatedBy: ",")
        guard tokens.count <= 64 else { throw ControllerPayloadError("Payload must contain at most 64 commands.") }
        var steps: [ControllerPayloadStep] = [], canonical: [String] = []
        var totalWait = 0
        var modifiers: [PayloadCommandModifiers] = []
        for (index, raw) in tokens.enumerated() {
            let input = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let (token, timing) = try PayloadCommandModifiers.split(input)
            func fail(_ message: String) -> ControllerPayloadError { .init("Command \(index + 1) (\(raw.trimmingCharacters(in: .whitespacesAndNewlines))): \(message)") }
            guard !token.isEmpty else { throw fail("Enter a controller command between commas.") }
            if token.hasPrefix("X360LT") || token.hasPrefix("X360RT") {
                throw fail("Use LT:0.5 or RT:1.0P0.3 for triggers; do not add X360.")
            }
            if ["AUTO_CENTER", "AUTO_CENTER_TOGGLE", "AUTO_CENTER_ON", "AUTO_CENTER_OFF"].contains(token) {
                let command: AutoCenterCommand = token == "AUTO_CENTER_ON" ? .enable : token == "AUTO_CENTER_OFF" ? .disable : .toggle
                steps.append(.autoCenter(command))
                canonical.append(command == .enable ? "AUTO_CENTER_ON" : command == .disable ? "AUTO_CENTER_OFF" : "AUTO_CENTER_TOGGLE")
            } else if token.hasPrefix("AUTO_CENTER") {
                throw fail("Use AUTO_CENTER_TOGGLE, AUTO_CENTER_ON or AUTO_CENTER_OFF.")
            } else if token == "CAMERA_FOLLOW" || token == "CAMERA_FOLLOW:1" || token == "CAMERA_FOLLOW:0" {
                let command: CameraFollowCommand = token == "CAMERA_FOLLOW" ? .toggle : token == "CAMERA_FOLLOW:1" ? .enable : .disable
                steps.append(.cameraFollow(command)); canonical.append(token)
            } else if token.hasPrefix("CAMERA_FOLLOW") {
                throw fail("Use CAMERA_FOLLOW to toggle, CAMERA_FOLLOW:1 to enable, or CAMERA_FOLLOW:0 to disable Practice Camera Follow.")
            } else if token == "RELEASE_ALL" {
                steps.append(.releaseAll); canonical.append(token)
            } else if token.hasPrefix("LS:") || token.hasPrefix("RS:") {
                do {
                    guard let macro = try FixedStickMacro.parse(token) else { throw fail("Invalid fixed-stick command.") }
                    steps.append(.fixedStick(macro)); canonical.append(macro.source)
                } catch { throw fail(error.localizedDescription) }
            } else if token == "SCROLL_MODE_TOGGLE" {
                steps.append(.scrollModeToggle); canonical.append(token)
            } else if token.hasPrefix("WAIT_") {
                let digits = String(token.dropFirst(5))
                guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let value = Int(digits), (0...60_000).contains(value) else {
                    throw fail("WAIT must be an integer from 0 to 60000 milliseconds, such as WAIT_1000.")
                }
                totalWait += value
                guard totalWait <= 120_000 else { throw fail("Total waiting time must not exceed 120 seconds.") }
                steps.append(.wait(milliseconds: value)); canonical.append("WAIT_\(value)")
            } else if token.hasPrefix("LT:") || token.hasPrefix("RT:") {
                let channel: TriggerChannel = token.hasPrefix("LT:") ? .left : .right
                let parts = String(token.dropFirst(3)).components(separatedBy: "P")
                guard (1...2).contains(parts.count), let amount = decimal(parts[0]), (0...1).contains(amount) else {
                    throw fail("Trigger intensity must be a decimal from 0 to 1, such as LT:0.5.")
                }
                let prefix = channel == .left ? "LT:" : "RT:"
                if parts.count == 2 {
                    let minimum = timing.isModified ? 0.001 : 0.01
                    guard let duration = decimal(parts[1]), (minimum...60).contains(duration) else {
                        throw fail("Pulse duration must be \(minimum) through 60 seconds, such as RT:1.0P0.3.")
                    }
                    steps.append(.triggerPulse(channel, amount, duration: duration))
                    canonical.append(prefix + number(amount) + "P" + number(duration))
                } else {
                    steps.append(.triggerPressure(channel, amount)); canonical.append(prefix + number(amount))
                }
            } else if let action = aliases[timed && token.hasSuffix("_HOLD") ? String(token.dropLast(5)) : token] {
                steps.append(.digital(action)); canonical.append(canonicalToken(action))
            } else if let mouse = mouseCommand(token) {
                steps.append(mouse.down ? .mouseDown(mouse.button) : .mouseUp(mouse.button))
                canonical.append("MOUSE_" + mouse.button.rawValue + (mouse.down ? "_DOWN" : "_UP"))
            } else if let key = KeyboardKey.parse(timed && token.hasPrefix("KEY_DOWN:") ? String(token.dropFirst(9)) : token) {
                steps.append(.keyDown(key)); canonical.append(key.rawValue)
            } else {
                throw fail("Unknown command. Use a listed controller command, keyboard key, MOUSE_LEFT_DOWN/MOUSE_LEFT_UP, or WAIT_1000. Raw KEY_DOWN/KEY_UP, controller _HOLD/_RELEASE and scrolling are not supported.")
            }
            try timing.validate(for: steps.last!)
            modifiers.append(timing)
            canonical[canonical.count - 1] += timing.suffix
        }
        if steps.contains(.releaseAll), steps.count != 1 {
            throw ControllerPayloadError("RELEASE_ALL must be the only command on its button.")
        }
        if steps.contains(.scrollModeToggle), steps.count != 1 {
            throw ControllerPayloadError("SCROLL_MODE_TOGGLE must be the only command on its button.")
        }
        if steps.contains(where: { if case .cameraFollow = $0 { true } else { false } }), steps.count != 1 {
            throw ControllerPayloadError("CAMERA_FOLLOW must be the only command on its button.")
        }
        if steps.contains(where: { if case .autoCenter = $0 { true } else { false } }), steps.count != 1 {
            throw ControllerPayloadError("Auto-center must be the only command on its button or stick stage.")
        }
        if modifiers.contains(where: \.isModified), steps.contains(where: { !$0.isReversibleTimingCommand }) {
            throw ControllerPayloadError("A timed payload can contain only reversible outputs. Keep waits and release commands on a separate button.")
        }
        let normalized = canonical.joined(separator: ", ")
        guard normalized.utf8.count <= 8_192 else { throw ControllerPayloadError("Normalized payload must be at most 8 KiB.") }
        return .init(steps: steps, source: normalized, modifiers: modifiers)
    }
    public static func source(for actions: Set<ControllerControlID>) -> String {
        actions.filter { !$0.isStick }.sorted { $0.rawValue < $1.rawValue }.map(canonicalToken).joined(separator: ", ")
    }
    private static func mouseCommand(_ token: String) -> (button: PracticeMouseButton, down: Bool)? {
        for button in PracticeMouseButton.allCases {
            let canonical = "MOUSE_" + button.rawValue, alternate = button.rawValue + "_MOUSE"
            if [canonical, canonical + "_DOWN", alternate, alternate + "_DOWN"].contains(token) { return (button, true) }
            if [canonical + "_UP", alternate + "_UP"].contains(token) { return (button, false) }
        }
        return nil
    }
    private static func decimal(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
              text.filter({ $0 == "." }).count <= 1, let value = Double(text), value.isFinite else { return nil }
        return value
    }
    private static func number(_ value: Double) -> String {
        // Expand Swift's shortest scientific representation without rounding tiny intensities to zero.
        let text = String(value)
        let parts = text.lowercased().components(separatedBy: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return text }
        let mantissa = parts[0].components(separatedBy: ".")
        let digits = mantissa.joined()
        let point = mantissa[0].count + exponent
        if point <= 0 { return "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count { return digits + String(repeating: "0", count: point - digits.count) }
        let split = digits.index(digits.startIndex, offsetBy: point)
        return String(digits[..<split]) + "." + String(digits[split...])
    }
    private static func canonicalToken(_ id: ControllerControlID) -> String {
        switch id {
        case .a: "X360A"; case .b: "X360B"; case .x: "X360X"; case .y: "X360Y"
        case .leftBumper: "X360LB"; case .rightBumper: "X360RB"
        case .leftTrigger: "LT:1.0"; case .rightTrigger: "RT:1.0"
        case .leftStickClick: "X360LSC"; case .rightStickClick: "X360RSC"
        case .view: "X360BACK"; case .menu: "X360START"
        case .guide: "X360GUIDE"; case .share: "X360SHARE"
        case .dpadUp: "X360UP"; case .dpadRight: "X360RIGHT"; case .dpadDown: "X360DOWN"; case .dpadLeft: "X360LEFT"
        case .leftStick, .rightStick: ""
        }
    }
    private static let aliases: [String: ControllerControlID] = [
        "X360A": .a, "X360B": .b, "X360X": .x, "X360Y": .y,
        "X360LB": .leftBumper, "X360RB": .rightBumper,
        "X360LS": .leftStickClick, "X360LSC": .leftStickClick, "X360LSTICK": .leftStickClick,
        "X360RS": .rightStickClick, "X360RSC": .rightStickClick, "X360RSTICK": .rightStickClick,
        "X360BACK": .view, "X360VIEW": .view, "X360START": .menu, "X360MENU": .menu,
        "X360GUIDE": .guide, "X360XBOX": .guide, "X360SHARE": .share,
        "X360UP": .dpadUp, "X360DPADUP": .dpadUp,
        "X360RIGHT": .dpadRight, "X360DPADRIGHT": .dpadRight,
        "X360DOWN": .dpadDown, "X360DPADDOWN": .dpadDown,
        "X360LEFT": .dpadLeft, "X360DPADLEFT": .dpadLeft
    ]
}

/// Rich local preview. Trigger intensity is not an SCX1 field or verified Xbox output.
public struct PracticeOutputState: Equatable, Sendable {
    public var gamepad: GamepadState
    public var leftTrigger: Double
    public var rightTrigger: Double
    public var heldKeys: Set<KeyboardKey>
    public var heldMouseButtons: Set<PracticeMouseButton>
    public static let maximumMovementTotal: Double = 1_000_000_000_000
    public var pointerOffset: PointerDelta
    public var scrollOffset: Double
    public var scrollModeEnabled: Bool
    public init(gamepad: GamepadState = .neutral, leftTrigger: Double = 0, rightTrigger: Double = 0,
                heldKeys: Set<KeyboardKey> = [], heldMouseButtons: Set<PracticeMouseButton> = [],
                pointerOffset: PointerDelta = .zero, scrollOffset: Double = 0, scrollModeEnabled: Bool = false) {
        self.gamepad = gamepad; self.leftTrigger = leftTrigger; self.rightTrigger = rightTrigger
        self.heldKeys = heldKeys; self.heldMouseButtons = heldMouseButtons
        self.pointerOffset = pointerOffset; self.scrollOffset = scrollOffset; self.scrollModeEnabled = scrollModeEnabled
    }
    public static let neutral = Self()
}

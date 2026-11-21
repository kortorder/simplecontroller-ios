import Foundation

public enum ControllerInputEvent: Equatable, Sendable {
    case begin(contact: Int, control: ControllerControlID, position: StickPosition)
    case move(contact: Int, position: StickPosition)
    case transfer(contact: Int, to: ControllerControlID?)
    case end(contact: Int)
    case cancelAll
    case accessibilityActivate(ControllerControlID)
}
public enum ControllerInputError: Error, Equatable, Sendable {
    case invalidTime, invalidPosition, invalidControl, duplicateContact
}

/// Pure semantic input. The UI supplies monotonic time and schedules nextDeadline.
/// All independent owners are unioned before constructing the outgoing gamepad state.
public struct ControllerInputEngine: Sendable {
    private struct Contact: Sendable {
        var control: ControllerControlID?
        var position: StickPosition = .zero
        var holdDeadline: TimeInterval?
        var suppressToggle = false
        var isStick: Bool { control?.isStick == true }
    }
    public private(set) var configuration: ControllerBehaviors
    public private(set) var state: GamepadState = .neutral
    public private(set) var latchedControls: Set<ControllerControlID> = []
    public private(set) var retainedSticks: [ControllerControlID: StickPosition] = [:]
    private var contacts: [Int: Contact] = [:]
    private var pulses: [ControllerControlID: TimeInterval] = [:]
    private var lastTime: TimeInterval?

    public init(configuration: ControllerBehaviors = .default) { self.configuration = configuration }
    public var pendingHoldDeadline: TimeInterval? { contacts.values.compactMap(\.holdDeadline).min() }
    public var nextDeadline: TimeInterval? { ([pendingHoldDeadline].compactMap { $0 } + Array(pulses.values)).min() }

    public mutating func apply(configuration: ControllerBehaviors) {
        releaseAll()
        self.configuration = configuration
    }
    public mutating func handle(_ event: ControllerInputEvent, at time: TimeInterval) throws {
        switch event {
        case let .begin(contact, control, position): try begin(contact: contact, control: control, position: position, at: time)
        case let .move(contact, position): try move(contact: contact, position: position, at: time)
        case let .transfer(contact, control): try transfer(contact: contact, to: control, at: time)
        case let .end(contact): try end(contact: contact, at: time)
        case .cancelAll: try advance(to: time); releaseAll()
        case let .accessibilityActivate(control): try activate(control, at: time)
        }
    }

    public mutating func begin(contact: Int, control: ControllerControlID,
                               position: StickPosition = .zero, at time: TimeInterval) throws {
        guard position.isValid else { throw ControllerInputError.invalidPosition }
        guard contacts[contact] == nil else { throw ControllerInputError.duplicateContact }
        try advance(to: time)
        if control.isStick {
            // A second finger cannot take over or release the first finger's stick.
            guard !contacts.values.contains(where: { $0.control == control }) else { refreshState(); return }
            retainedSticks.removeValue(forKey: control)
            contacts[contact] = Contact(control: control, position: position)
        } else { enterButton(contact: contact, control: control, time: time) }
        refreshState()
    }
    public mutating func move(contact: Int, position: StickPosition, at time: TimeInterval) throws {
        guard position.isValid else { throw ControllerInputError.invalidPosition }
        try advance(to: time)
        if contacts[contact]?.isStick == true { contacts[contact]?.position = position }
        refreshState()
    }
    public mutating func transfer(contact: Int, to control: ControllerControlID?, at time: TimeInterval) throws {
        guard control?.isStick != true else { throw ControllerInputError.invalidControl }
        try advance(to: time)
        guard let current = contacts[contact], !current.isStick else { refreshState(); return }
        if current.control != control {
            contacts.removeValue(forKey: contact)
            if let control { enterButton(contact: contact, control: control, time: time) }
            else { contacts[contact] = Contact(control: nil) }
        }
        refreshState()
    }
    public mutating func end(contact: Int, at time: TimeInterval) throws {
        try advance(to: time)
        if let ended = contacts.removeValue(forKey: contact), let control = ended.control, ended.isStick {
            if !configuration.stick(for: control).autoCenter && ended.position != .zero {
                retainedSticks[control] = ended.position
            } else { retainedSticks.removeValue(forKey: control) }
        }
        refreshState()
    }
    public mutating func tick(at time: TimeInterval) throws { try advance(to: time); refreshState() }

    /// Global cleanup must be used for cancellation, editing, mode changes, background and loss of a session.
    public mutating func releaseAll() {
        contacts.removeAll(); latchedControls.removeAll(); retainedSticks.removeAll(); pulses.removeAll()
        state = .neutral
    }
    /// Stops stick contacts and their mapped actions, preserving independently owned buttons.
    public mutating func recenterSticks() {
        contacts = contacts.filter { !$0.value.isStick }
        retainedSticks.removeAll()
        refreshState()
    }

    /// Accessibility double-tap toggles a configured latch immediately, or pulses a momentary button for 150 ms.
    public mutating func activate(_ control: ControllerControlID, at time: TimeInterval) throws {
        guard !control.isStick else { throw ControllerInputError.invalidControl }
        try advance(to: time)
        if configuration.button(for: control).holdToggle {
            if !latchedControls.insert(control).inserted { latchedControls.remove(control) }
            suppressPendingHolds(for: control)
        } else { pulses[control] = time + 0.15 }
        refreshState()
    }

    private mutating func enterButton(contact: Int, control: ControllerControlID, time: TimeInterval) {
        let behavior = configuration.button(for: control)
        var next = Contact(control: control)
        if behavior.holdToggle {
            if latchedControls.remove(control) != nil {
                suppressPendingHolds(for: control)
                next.suppressToggle = true
            } else if contacts.values.contains(where: { $0.control == control && $0.suppressToggle }) {
                next.suppressToggle = true
            } else {
                next.holdDeadline = time + Double(behavior.holdMilliseconds) / 1_000
            }
        }
        contacts[contact] = next
    }
    private mutating func suppressPendingHolds(for control: ControllerControlID) {
        for token in Array(contacts.keys) where contacts[token]?.control == control {
            contacts[token]?.holdDeadline = nil
            contacts[token]?.suppressToggle = true
        }
    }
    private mutating func advance(to time: TimeInterval) throws {
        guard time.isFinite, time >= 0, lastTime.map({ time >= $0 }) ?? true else { throw ControllerInputError.invalidTime }
        lastTime = time
        pulses = pulses.filter { $0.value > time }
        let matured = Set(contacts.values.compactMap { contact -> ControllerControlID? in
            guard let deadline = contact.holdDeadline, deadline <= time else { return nil }
            return contact.control
        })
        for control in matured {
            latchedControls.insert(control)
            // Once latched, older concurrent fingers cannot latch again after a clearing tap.
            suppressPendingHolds(for: control)
        }
    }
    private mutating func refreshState() {
        var outputControls = latchedControls.union(pulses.keys)
        var stickPositions = retainedSticks
        for contact in contacts.values {
            guard let control = contact.control else { continue }
            if control.isStick { stickPositions[control] = contact.position }
            else if !configuration.button(for: control).holdToggle { outputControls.insert(control) }
        }
        for (control, position) in stickPositions {
            let behavior = configuration.stick(for: control)
            guard behavior.stickPlusEnabled else { continue }
            let axes: [(StickDirection, Double)] = [(.up, position.y), (.right, position.x), (.down, -position.y), (.left, -position.x)]
            for (direction, amount) in axes where amount > 0.1 {
                guard let mapping = behavior.directions[direction] else { continue }
                // Match the original directionalPayload: stages replace each other.
                // Empty stage mappings intentionally release the previous stage.
                if amount > behavior.superBoostThreshold { outputControls.formUnion(mapping.superBoostControls) }
                else if amount > behavior.boostThreshold { outputControls.formUnion(mapping.boostControls) }
                else { outputControls.formUnion(mapping.normalControls) }
            }
        }
        var output = GamepadState(buttons: Set(outputControls.compactMap(\.padButton)),
                                  leftStick: stickPositions[.leftStick] ?? .zero,
                                  rightStick: stickPositions[.rightStick] ?? .zero)
        let x = (outputControls.contains(.dpadRight) ? 1 : 0) - (outputControls.contains(.dpadLeft) ? 1 : 0)
        let y = (outputControls.contains(.dpadUp) ? 1 : 0) - (outputControls.contains(.dpadDown) ? 1 : 0)
        switch (x, y) {
        case (0, 1): output.dpad = .up
        case (1, 1): output.dpad = .upRight
        case (1, 0): output.dpad = .right
        case (1, -1): output.dpad = .downRight
        case (0, -1): output.dpad = .down
        case (-1, -1): output.dpad = .downLeft
        case (-1, 0): output.dpad = .left
        case (-1, 1): output.dpad = .upLeft
        default: break
        }
        state = output
    }
}

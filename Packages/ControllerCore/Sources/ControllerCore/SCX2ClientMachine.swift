import Foundation

/// Deterministic, stop-and-wait SCX2 client. There is no network or USB I/O here.
/// Each queued state is retained until its predecessor's USB-completion ACK.
public struct SCX2ClientMachine: Sendable {
    public enum Failure: Equatable, Sendable {
        case invalidTime, invalidSession, invalidState, helloTimeout, neutralTimeout, acknowledgmentTimeout
        case usbUnavailable, pressureUnavailable, usbButtonTriggersUnavailable, usbPressureUnavailable, bridgeChanged, queueOverflow, sequenceExhausted
    }
    public enum Phase: Equatable, Sendable { case connecting, waitingForNeutral, ready, idle, stopped(Failure) }
    public static let queueCapacity = 16
    public static let acknowledgmentTimeout: TimeInterval = 0.75
    public static let retryInterval: TimeInterval = 0.1
    public private(set) var phase: Phase = .connecting
    public private(set) var acknowledgedPackets: UInt64 = 0
    public private(set) var lastAcknowledgedSequence: UInt64 = 0
    public private(set) var issuedSequence: UInt64 = 0
    public private(set) var currentOutput: BridgeOutputState = .neutral
    public var currentState: GamepadState { currentOutput.gamepad }
    public let revision: SCX2Revision
    public let session: SCX2Token
    public var queuedCount: Int { queue.count }
    public var controlsEnabled: Bool { phase == .ready }

    private var boot: SCX2Token = .zero
    private var challenge: SCX2Token = .zero
    private var queue: [BridgeOutputState] = []
    private struct Outstanding: Sendable {
        var packet: SCX2Packet
        var lastSent: TimeInterval
    }
    private var outstanding: Outstanding?
    private var socketReady = false
    private var lastTime: TimeInterval
    private var started: TimeInterval
    private var lastProgress: TimeInterval
    private var lastHello: TimeInterval = -.infinity
    private var lastIssued: TimeInterval = -.infinity
    private let waitForAvailability: Bool

    public init(sessionID: UUID = UUID(), revision: SCX2Revision = .legacy, at now: TimeInterval, waitForAvailability: Bool = false) {
        self.waitForAvailability = waitForAvailability
        self.revision = revision
        session = .init(uuid: sessionID); lastTime = now; started = now; lastProgress = now
        if !Self.validTime(now) { phase = .stopped(.invalidTime) }
        else if session.isZero { phase = .stopped(.invalidSession) }
    }

    public mutating func socketDidBecomeReady(at now: TimeInterval) -> [SCX2Packet] {
        socketReady = true
        return tick(at: now)
    }

    /// Checks time before processing even malformed or stale network input.
    public mutating func receive(_ packet: SCX2Packet, at now: TimeInterval) -> [SCX2Packet] {
        if let result = advance(now) { return result }
        guard (try? SCX2Codec.validate(packet)) != nil, packet.session == session,
              packet.revision == revision else { return [] }
        if packet.kind == .ready {
            guard phase == .connecting || phase == .waitingForNeutral || phase == .ready else { return [] }
            guard packet.hidReady else {
                // Automatic neutral resynchronization may reach the receiver while
                // its prior STOP barrier completes. This never extends the deadline.
                if phase == .connecting && waitForAvailability { return [] }
                let reason: Failure = switch revision {
                case .legacy: .usbUnavailable
                case .pressure: .pressureUnavailable
                case .usbButtons: .usbButtonTriggersUnavailable
                case .usbPressure: .usbPressureUnavailable
                }
                return fail(reason)
            }
            guard revision != .pressure || packet.pressureCapability else { return fail(.pressureUnavailable) }
            guard revision != .usbButtons || packet.usbButtonTriggerCapability else { return fail(.usbButtonTriggersUnavailable) }
            guard revision != .usbPressure || packet.usbPressureCapability else { return fail(.usbPressureUnavailable) }
            if phase == .connecting {
                boot = packet.boot; challenge = packet.challenge; lastProgress = now
                phase = .waitingForNeutral
                return issue(.neutral, at: now)
            }
            guard packet.boot == boot, packet.challenge == challenge else { return fail(.bridgeChanged) }
            return [] // Duplicate offers cannot renew liveness or arm controls.
        }
        guard phase == .waitingForNeutral || phase == .ready,
              packet.kind == .ack, packet.boot == boot, packet.challenge == challenge,
              let pending = outstanding, packet.sequence == pending.packet.sequence else { return [] }
        outstanding = nil
        lastProgress = now; lastAcknowledgedSequence = packet.sequence; acknowledgedPackets += 1
        if phase == .waitingForNeutral { phase = .ready }
        if !queue.isEmpty { return issue(queue.removeFirst(), at: now) }
        return []
    }

    /// Legacy call sites retain zero trigger pressure. Pressure callers must use updateOutput.
    public mutating func update(_ state: GamepadState, at now: TimeInterval) -> [SCX2Packet] {
        updateOutput(.init(gamepad: state), at: now)
    }

    public mutating func updateOutput(_ output: BridgeOutputState, at now: TimeInterval) -> [SCX2Packet] {
        if let result = advance(now) { return result }
        guard phase == .ready else { return [] }
        guard output.isValid, output.gamepad.buttons.isSubset(of: Set(SCX2Codec.supportedButtons)),
              revision != .legacy || (output.leftTrigger == 0 && output.rightTrigger == 0),
              revision != .usbButtons || ([0.0, 1.0].contains(output.leftTrigger) && [0.0, 1.0].contains(output.rightTrigger)) else {
            return fail(.invalidState)
        }
        guard output != currentOutput else { return [] }
        currentOutput = output
        if outstanding == nil { return issue(output, at: now) }
        guard queue.count < Self.queueCapacity else { return fail(.queueOverflow) }
        queue.append(output)
        return []
    }

    public mutating func tick(at now: TimeInterval) -> [SCX2Packet] {
        if let result = advance(now) { return result }
        switch phase {
        case .connecting:
            guard socketReady, now - lastHello >= 0.25 else { return [] }
            lastHello = now
            return [SCX2Packet(kind: .hello, session: session, revision: revision, pressureCapability: revision == .pressure,
                               usbButtonTriggerCapability: revision == .usbButtons, usbPressureCapability: revision == .usbPressure)]
        case .waitingForNeutral, .ready:
            if var pending = outstanding {
                guard now - pending.lastSent >= Self.retryInterval else { return [] }
                pending.lastSent = now; outstanding = pending
                return [pending.packet] // Same sequence; receiver duplicates never renew its lease.
            }
            if phase == .ready && now - lastIssued >= Self.retryInterval { return issue(currentOutput, at: now) }
            return []
        case .idle, .stopped: return []
        }
    }

    /// Explicit stop discards all pending state; it never drains old presses first.
    public mutating func stop() -> SCX2Packet? {
        let stop: SCX2Packet? = !boot.isZero && !challenge.isZero && issuedSequence < UInt64.max
            ? .init(kind: .stop, session: session, boot: boot, challenge: challenge, sequence: issuedSequence + 1, revision: revision) : nil
        phase = .idle; boot = .zero; challenge = .zero; queue.removeAll(); outstanding = nil
        currentOutput = .neutral; socketReady = false
        return stop
    }

    private mutating func issue(_ output: BridgeOutputState, at now: TimeInterval) -> [SCX2Packet] {
        guard issuedSequence < UInt64.max - 1 else { return fail(.sequenceExhausted) }
        issuedSequence += 1; lastIssued = now
        let packet = SCX2Packet(kind: .state, session: session, boot: boot, challenge: challenge,
                                sequence: issuedSequence, output: output, revision: revision)
        outstanding = Outstanding(packet: packet, lastSent: now)
        return [packet]
    }
    private mutating func fail(_ reason: Failure) -> [SCX2Packet] {
        let packet = stop(); phase = .stopped(reason)
        return packet.map { [$0] } ?? []
    }
    /// nil means processing may continue; [] means an inactive machine or a failure with no stop token.
    private mutating func advance(_ now: TimeInterval) -> [SCX2Packet]? {
        guard phase != .idle else { return [] }
        if case .stopped = phase { return [] }
        guard Self.validTime(now), now >= lastTime else { return fail(.invalidTime) }
        lastTime = now
        if phase == .connecting && now - started >= 3 { return fail(.helloTimeout) }
        if (phase == .waitingForNeutral || phase == .ready) && now - lastProgress >= Self.acknowledgmentTimeout {
            return fail(phase == .waitingForNeutral ? .neutralTimeout : .acknowledgmentTimeout)
        }
        return nil
    }
    private static func validTime(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0 && value + 3 > value && value + retryInterval > value
    }
}

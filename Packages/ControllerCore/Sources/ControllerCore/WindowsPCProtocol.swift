import Foundation

/// Full-state desktop output. Pointer/scroll values are cumulative within one
/// neutral-started session, so a retried packet cannot move the pointer twice.
public struct WindowsPCOutput: Codable, Equatable, Sendable {
    public var gamepad: GamepadState
    public var leftTrigger: Double
    public var rightTrigger: Double
    public var keys: [String]
    public var mouse: [String]
    public var pointer: [Double]
    public var scroll: Double
    public init(gamepad: GamepadState = .neutral, leftTrigger: Double = 0, rightTrigger: Double = 0,
                desktop: PracticeOutputState = .neutral) {
        self.gamepad = gamepad; self.leftTrigger = leftTrigger; self.rightTrigger = rightTrigger
        keys = desktop.heldKeys.map(\.rawValue).sorted(); mouse = desktop.heldMouseButtons.map(\.rawValue).sorted()
        pointer = [desktop.pointerOffset.dx, desktop.pointerOffset.dy]; scroll = desktop.scrollOffset
    }
    public static let neutral = Self()
    public var isValid: Bool {
        gamepad.isValid && gamepad.buttons.isDisjoint(with: [.guide, .share, .leftTrigger, .rightTrigger]) &&
        leftTrigger.isFinite && rightTrigger.isFinite && (0...1).contains(leftTrigger) && (0...1).contains(rightTrigger) &&
        keys.count == Set(keys).count && keys.allSatisfy { KeyboardKey(rawValue: $0) != nil } &&
        mouse.count == Set(mouse).count && mouse.allSatisfy { PracticeMouseButton(rawValue: $0) != nil } &&
        pointer.count == 2 && (pointer + [scroll]).allSatisfy { $0.isFinite && abs($0) <= PracticeOutputState.maximumMovementTotal }
    }
}

public struct WindowsPCPacket: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case hello, ready, state, ack, stop, error }
    public var protocolVersion = "SCPC1"
    public var kind: Kind
    public var session: String
    public var sequence: UInt64
    public var token: String?
    public var output: WindowsPCOutput?
    public init(kind: Kind, session: String, sequence: UInt64 = 0, token: String? = nil, output: WindowsPCOutput? = nil) {
        self.kind = kind; self.session = session; self.sequence = sequence; self.token = token; self.output = output
    }
    public var isValid: Bool {
        func identity(_ value: String) -> Bool {
            value.count == 36 && UUID(uuidString: value) != nil
        }
        guard protocolVersion == "SCPC1", identity(session), sequence <= 9_007_199_254_740_991,
              token == nil || identity(token!) else { return false }
        switch kind {
        case .hello: return sequence == 0 && token == nil && output == nil
        case .ready: return sequence == 0 && token != nil && output == nil
        case .state: return sequence > 0 && token != nil && output?.isValid == true
        case .ack, .stop, .error: return sequence > 0 && token != nil && output == nil
        }
    }
}

public enum WindowsPCCodec {
    public static let maximumBytes = 8192
    public enum Failure: Error { case invalidPacket }
    public static func encode(_ packet: WindowsPCPacket) throws -> Data {
        guard packet.isValid else { throw Failure.invalidPacket }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(packet)
        guard data.count <= maximumBytes else { throw Failure.invalidPacket }
        return data
    }
    public static func decode(_ data: Data) throws -> WindowsPCPacket {
        guard data.count <= maximumBytes else { throw Failure.invalidPacket }
        let packet = try JSONDecoder().decode(WindowsPCPacket.self, from: data)
        guard packet.isValid else { throw Failure.invalidPacket }
        return packet
    }
}

/// Stop-and-wait transport independent of Network.framework. A neutral ACK is
/// required before accepting touches. All pending input is lost on reconnect.
public struct WindowsPCClientMachine: Sendable {
    public enum Phase: Equatable, Sendable { case connecting, neutralizing, ready, idle, stopped(String) }
    public private(set) var phase: Phase = .connecting
    public private(set) var acknowledgedPackets: UInt64 = 0
    public let session: String
    public var controlsEnabled: Bool { phase == .ready }
    public static let queueCapacity = 128
    public static let acknowledgmentTimeout: TimeInterval = 0.4
    private var token: String?
    private var sequence: UInt64 = 0
    private var current: WindowsPCOutput = .neutral
    private var queue: [WindowsPCOutput] = []
    private var outstanding: WindowsPCPacket?
    private var lastSent: TimeInterval = -.infinity
    private var lastProgress: TimeInterval
    private var lastTime: TimeInterval
    private var started: TimeInterval
    private var socketReady = false
    public init(sessionID: UUID = UUID(), at time: TimeInterval) {
        session = sessionID.uuidString; lastTime = time; started = time; lastProgress = time
        if !time.isFinite || time < 0 { phase = .stopped("Invalid PC connection clock.") }
    }
    public mutating func socketDidBecomeReady(at time: TimeInterval) -> [WindowsPCPacket] {
        socketReady = true; return tick(at: time)
    }
    public mutating func tick(at time: TimeInterval) -> [WindowsPCPacket] {
        if let failure = advance(time) { return failure }
        if phase == .connecting {
            guard socketReady, time - lastSent >= 0.25 else { return [] }
            lastSent = time; return [.init(kind: .hello, session: session)]
        }
        guard phase == .ready || phase == .neutralizing else { return [] }
        if let outstanding {
            guard time - lastSent >= 0.05 else { return [] }
            lastSent = time; return [outstanding]
        }
        if phase == .ready && time - lastSent >= 0.05 { return issue(current, at: time) }
        return []
    }
    public mutating func update(_ output: WindowsPCOutput, at time: TimeInterval) -> [WindowsPCPacket] {
        if let failure = advance(time) { return failure }
        guard phase == .ready else { return [] }
        guard output.isValid else { return fail("Invalid PC input. Controls released.") }
        guard output != current else { return [] }
        current = output
        if outstanding == nil { return issue(output, at: time) }
        guard queue.count < Self.queueCapacity else { return fail("The PC could not keep up. Controls released.") }
        queue.append(output); return []
    }
    public mutating func receive(_ packet: WindowsPCPacket, at time: TimeInterval) -> [WindowsPCPacket] {
        if let failure = advance(time) { return failure }
        guard packet.isValid, packet.session == session else { return [] }
        if packet.kind == .ready {
            if phase == .connecting {
                token = packet.token; phase = .neutralizing; lastProgress = time
                return issue(.neutral, at: time)
            }
            if (phase == .ready || phase == .neutralizing), token != packet.token {
                return fail("The PC receiver restarted. Controls released.")
            }
            return []
        }
        guard packet.token == token, let outstanding, packet.sequence == outstanding.sequence,
              phase == .ready || phase == .neutralizing else { return [] }
        if packet.kind == .error { return fail("The PC receiver could not apply input. Check its window.") }
        guard packet.kind == .ack else { return [] }
        self.outstanding = nil; lastProgress = time; acknowledgedPackets += 1
        if phase == .neutralizing { phase = .ready }
        if !queue.isEmpty { return issue(queue.removeFirst(), at: time) }
        return []
    }
    public mutating func stop() -> WindowsPCPacket? {
        let packet = token.map { WindowsPCPacket(kind: .stop, session: session, sequence: sequence + 1, token: $0) }
        phase = .idle; current = .neutral; queue = []; outstanding = nil
        return packet
    }
    private mutating func advance(_ time: TimeInterval) -> [WindowsPCPacket]? {
        if case .stopped = phase { return [] }; if phase == .idle { return [] }
        guard time.isFinite, time >= lastTime, time >= 0 else { return fail("Invalid PC connection clock.") }
        lastTime = time
        if phase == .connecting && time - started >= 3 {
            return fail("No compatible computer receiver replied. Start the updated free receiver and check its IP, port, Wi-Fi and firewall.")
        }
        if (phase == .ready || phase == .neutralizing) && time - lastProgress >= Self.acknowledgmentTimeout {
            return fail("The computer receiver stopped replying. Controls released.")
        }
        return nil
    }
    private mutating func issue(_ output: WindowsPCOutput, at time: TimeInterval) -> [WindowsPCPacket] {
        guard sequence < 9_007_199_254_740_990, let token else { return fail("PC session reached its message limit.") }
        sequence += 1; lastSent = time
        let packet = WindowsPCPacket(kind: .state, session: session, sequence: sequence, token: token, output: output)
        outstanding = packet; return [packet]
    }
    private mutating func fail(_ message: String) -> [WindowsPCPacket] {
        let stopPacket = stop(); phase = .stopped(message)
        return stopPacket.map { [$0] } ?? []
    }
}

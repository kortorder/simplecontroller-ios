import Foundation

public enum BridgeSafetyError: Error, Equatable, Sendable {
    case invalidTime
}

/// Deterministic reference receiver used to test a future bridge implementation.
/// It does not perform USB I/O or establish physical XAC compatibility.
public struct BridgeSafetyMachine: Sendable {
    public let leaseDuration: TimeInterval
    public let hidReady: Bool
    public private(set) var output: GamepadState = .neutral
    public private(set) var activeSession: String?
    public private(set) var lastSequence: UInt64 = 0
    public private(set) var deadline: TimeInterval?

    private var retiredSessions: Set<UUID> = []
    private var mostRecentTime: TimeInterval?

    public init(leaseDuration: TimeInterval = 1, hidReady: Bool = false) {
        precondition(leaseDuration.isFinite && leaseDuration > 0)
        self.leaseDuration = leaseDuration
        self.hidReady = hidReady
    }

    /// Call periodically with monotonic seconds, even when no packets arrive.
    @discardableResult
    public mutating func expire(at now: TimeInterval) throws -> Bool {
        try advanceClock(to: now)
        guard let deadline, now >= deadline else { return false }
        retireActiveSession()
        return true
    }

    /// Returns a protocol reply only for accepted requests or safe retry responses.
    /// Invalid, stale, competing, and retired-session output never changes active state.
    public mutating func receive(_ packet: BridgePacket, at now: TimeInterval) throws -> BridgePacket? {
        try BridgeCodec.validate(packet)
        _ = try expire(at: now)
        // Validation above establishes UUID syntax.
        guard let sessionID = UUID(uuidString: packet.session) else { return nil }
        let activeID = activeSession.flatMap(UUID.init(uuidString:))

        switch packet.kind {
        case .hello:
            guard !retiredSessions.contains(sessionID) else { return nil }
            if let activeID {
                guard activeID == sessionID else { return nil }
                // Hello retries do not clear output, change ordering, or renew the lease.
            } else {
                activeSession = sessionID.uuidString
                lastSequence = 0
                output = .neutral
                deadline = now + leaseDuration
            }
            return BridgePacket(kind: .ready, session: packet.session, sequence: 0, hidReady: hidReady)

        case .state:
            // Readiness is enforced by the receiver as well as the UI. A packet
            // from an older or buggy client cannot drive unavailable hardware.
            // Rejected state does not keep an unready session alive.
            guard hidReady else { return nil }
            guard activeID == sessionID, !retiredSessions.contains(sessionID) else { return nil }
            guard packet.sequence >= lastSequence else { return nil }
            if packet.sequence > lastSequence {
                output = packet.state! // validate requires a complete valid state.
                lastSequence = packet.sequence
                deadline = now + leaseDuration
            }
            // Duplicate state gets an ACK but does not renew the lease or change output.
            return BridgePacket(kind: .ack, session: packet.session,
                                sequence: packet.sequence, hidReady: hidReady)

        case .stop:
            if retiredSessions.contains(sessionID) {
                return BridgePacket(kind: .stopped, session: packet.session, sequence: packet.sequence)
            }
            guard activeID == sessionID, packet.sequence > lastSequence else { return nil }
            retireActiveSession()
            return BridgePacket(kind: .stopped, session: packet.session, sequence: packet.sequence)

        case .ready, .ack, .stopped:
            return nil
        }
    }

    private mutating func advanceClock(to now: TimeInterval) throws {
        guard now.isFinite, now >= 0, mostRecentTime.map({ now >= $0 }) ?? true else {
            throw BridgeSafetyError.invalidTime
        }
        mostRecentTime = now
    }

    private mutating func retireActiveSession() {
        if let session = activeSession, let id = UUID(uuidString: session) {
            retiredSessions.insert(id)
        }
        activeSession = nil
        lastSequence = 0
        deadline = nil
        output = .neutral
    }
}

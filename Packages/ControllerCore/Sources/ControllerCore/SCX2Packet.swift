import Foundation

/// Opaque 128-bit receiver token. Tokens fence stale sessions; they are not authentication.
public struct SCX2Token: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) { self.bytes = bytes }
    public init(uuid: UUID) { var value = uuid.uuid; bytes = withUnsafeBytes(of: &value) { Array($0) } }
    public static let zero = SCX2Token(bytes: Array(repeating: 0, count: 16))
    public var isValid: Bool { bytes.count == 16 }
    public var isZero: Bool { isValid && bytes.allSatisfy { $0 == 0 } }
}

/// Binary SCX2, specified in bridge/PROTOCOL.md. All integers use network order.
public struct SCX2Packet: Equatable, Sendable {
    public enum Kind: UInt8, CaseIterable, Sendable {
        case hello = 1, ready, state, ack, stop, stopped
    }
    public var kind: Kind
    public var session: SCX2Token
    public var boot: SCX2Token
    public var challenge: SCX2Token
    public var sequence: UInt64
    public var hidReady: Bool
    public var revision: SCX2Revision
    /// Revision 3 HELLO requests pressure; READY confirms a ready proportional backend.
    /// It is false on every other packet, including pressure-bearing STATE packets.
    public var pressureCapability: Bool
    public var usbButtonTriggerCapability: Bool
    public var usbPressureCapability: Bool
    public var output: BridgeOutputState?
    /// Backward-compatible gamepad view. Setting nil removes the entire snapshot.
    public var state: GamepadState? {
        get { output?.gamepad }
        set {
            if let newValue {
                if output != nil { output?.gamepad = newValue }
                else { output = .init(gamepad: newValue) }
            } else { output = nil }
        }
    }

    public init(kind: Kind, session: SCX2Token, boot: SCX2Token = .zero,
                challenge: SCX2Token = .zero, sequence: UInt64 = 0,
                hidReady: Bool = false, state: GamepadState? = nil,
                revision: SCX2Revision = .legacy, pressureCapability: Bool = false, usbButtonTriggerCapability: Bool = false,
                usbPressureCapability: Bool = false) {
        self.kind = kind; self.session = session; self.boot = boot; self.challenge = challenge
        self.sequence = sequence; self.hidReady = hidReady
        self.revision = revision; self.pressureCapability = pressureCapability
        self.usbButtonTriggerCapability = usbButtonTriggerCapability
        self.usbPressureCapability = usbPressureCapability
        self.output = state.map { .init(gamepad: $0) }
    }

    public init(kind: Kind, session: SCX2Token, boot: SCX2Token = .zero,
                challenge: SCX2Token = .zero, sequence: UInt64 = 0,
                hidReady: Bool = false, output: BridgeOutputState,
                revision: SCX2Revision = .pressure, pressureCapability: Bool = false, usbButtonTriggerCapability: Bool = false,
                usbPressureCapability: Bool = false) {
        self.init(kind: kind, session: session, boot: boot, challenge: challenge, sequence: sequence,
                  hidReady: hidReady, revision: revision, pressureCapability: pressureCapability, usbButtonTriggerCapability: usbButtonTriggerCapability,
                  usbPressureCapability: usbPressureCapability)
        self.output = output
    }
}

public enum SCX2CodecError: Error, Equatable, Sendable {
    case invalidSize, invalidHeader, invalidFields, invalidState
}

public enum SCX2Codec {
    public static let maximumDatagramBytes = 80
    public static let supportedButtons: [PadButton] = [.a, .b, .x, .y, .leftBumper, .rightBumper,
                                                      .view, .menu, .leftStick, .rightStick]
    private static let hats: [DPadDirection] = [.up, .upRight, .right, .downRight, .down,
                                               .downLeft, .left, .upLeft, .neutral]

    public static func validate(_ packet: SCX2Packet) throws {
        guard packet.session.isValid, !packet.session.isZero, packet.boot.isValid,
              packet.challenge.isValid else { throw SCX2CodecError.invalidFields }
        if packet.kind != .state && packet.output != nil { throw SCX2CodecError.invalidFields }
        if packet.pressureCapability && packet.revision != .pressure { throw SCX2CodecError.invalidFields }
        if packet.usbButtonTriggerCapability && packet.revision != .usbButtons { throw SCX2CodecError.invalidFields }
        if packet.usbPressureCapability && packet.revision != .usbPressure { throw SCX2CodecError.invalidFields }
        if packet.kind != .hello && packet.kind != .ready && (packet.pressureCapability || packet.usbButtonTriggerCapability || packet.usbPressureCapability) {
            throw SCX2CodecError.invalidFields
        }
        switch packet.kind {
        case .hello:
            guard packet.sequence == 0, !packet.hidReady, packet.boot.isZero, packet.challenge.isZero,
                  packet.pressureCapability == (packet.revision == .pressure),
                  packet.usbButtonTriggerCapability == (packet.revision == .usbButtons),
                  packet.usbPressureCapability == (packet.revision == .usbPressure) else {
                throw SCX2CodecError.invalidFields
            }
        case .ready:
            guard packet.sequence == 0, !packet.boot.isZero,
                  packet.challenge.isZero != packet.hidReady,
                  packet.revision != .pressure || packet.pressureCapability == packet.hidReady,
                  packet.revision != .usbButtons || packet.usbButtonTriggerCapability == packet.hidReady,
                  packet.revision != .usbPressure || packet.usbPressureCapability == packet.hidReady else {
                throw SCX2CodecError.invalidFields
            }
        case .state, .ack, .stop, .stopped:
            guard packet.sequence > 0, !packet.boot.isZero, !packet.challenge.isZero,
                  packet.hidReady == (packet.kind == .ack) else { throw SCX2CodecError.invalidFields }
            if packet.kind == .state || packet.kind == .ack {
                guard packet.sequence < UInt64.max else { throw SCX2CodecError.invalidFields }
            }
            if packet.kind == .state {
                guard let output = packet.output, output.isValid,
                      output.gamepad.buttons.isSubset(of: Set(supportedButtons)),
                      packet.revision != .legacy || (output.leftTrigger == 0 && output.rightTrigger == 0),
                      packet.revision != .usbButtons || ([0.0, 1.0].contains(output.leftTrigger) && [0.0, 1.0].contains(output.rightTrigger)) else {
                    throw SCX2CodecError.invalidState
                }
            }
        }
    }

    public static func encode(_ packet: SCX2Packet) throws -> Data {
        try validate(packet)
        var bytes: [UInt8] = [83, 67, 88, 50, packet.revision.rawValue, packet.kind.rawValue,
                              packet.hidReady ? 1 : 0, packet.pressureCapability ? 1 : (packet.usbButtonTriggerCapability ? 2 : (packet.usbPressureCapability ? 4 : 0))]
        bytes += packet.session.bytes + packet.boot.bytes + packet.challenge.bytes
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: packet.sequence >> shift)) }
        if let output = packet.output {
            let state = output.gamepad
            var buttons: UInt16 = 0
            for (index, button) in supportedButtons.enumerated() where state.buttons.contains(button) { buttons |= 1 << index }
            append(buttons, to: &bytes)
            bytes += [UInt8(hats.firstIndex(of: state.dpad)!), 0]
            for axis in [state.leftStick.x, state.leftStick.y, state.rightStick.x, state.rightStick.y] {
                let quantized = Int16((axis * 32767).rounded(.toNearestOrAwayFromZero))
                append(UInt16(bitPattern: quantized), to: &bytes)
            }
            if packet.revision.hasTriggerFields {
                // Fixed 16-bit normalization, independent of a physical DAC/backend resolution.
                for pressure in [output.leftTrigger, output.rightTrigger] {
                    append(UInt16((pressure * 65535).rounded(.toNearestOrAwayFromZero)), to: &bytes)
                }
            }
        }
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> SCX2Packet {
        guard [64, 76, 80].contains(data.count) else { throw SCX2CodecError.invalidSize }
        let bytes = Array(data)
        guard Array(bytes[0..<4]) == [83, 67, 88, 50], let revision = SCX2Revision(rawValue: bytes[4]),
              let kind = SCX2Packet.Kind(rawValue: bytes[5]), bytes[6] <= 1, [0, 1, 2, 4].contains(bytes[7]) else {
            throw SCX2CodecError.invalidHeader
        }
        guard data.count == (kind == .state ? (revision.hasTriggerFields ? 80 : 76) : 64) else {
            throw SCX2CodecError.invalidSize
        }
        var sequence: UInt64 = 0
        for byte in bytes[56..<64] { sequence = (sequence << 8) | UInt64(byte) }
        var output: BridgeOutputState?
        if kind == .state {
            let bits = read16(bytes, at: 64)
            guard bits & 0xfc00 == 0, bytes[66] <= 8, bytes[67] == 0 else { throw SCX2CodecError.invalidState }
            var axes: [Double] = []
            for offset in stride(from: 68, through: 74, by: 2) {
                let axis = Int16(bitPattern: read16(bytes, at: offset))
                guard axis != Int16.min else { throw SCX2CodecError.invalidState }
                axes.append(Double(axis) / 32767)
            }
            let buttons = Set(supportedButtons.enumerated().compactMap { index, button in
                bits & (1 << index) != 0 ? button : nil
            })
            output = .init(gamepad: GamepadState(buttons: buttons, leftStick: .init(x: axes[0], y: axes[1]),
                                                rightStick: .init(x: axes[2], y: axes[3]), dpad: hats[Int(bytes[66])]),
                           leftTrigger: revision.hasTriggerFields ? Double(read16(bytes, at: 76)) / 65535 : 0,
                           rightTrigger: revision.hasTriggerFields ? Double(read16(bytes, at: 78)) / 65535 : 0)
        }
        var packet = SCX2Packet(kind: kind, session: .init(bytes: Array(bytes[8..<24])),
                                boot: .init(bytes: Array(bytes[24..<40])), challenge: .init(bytes: Array(bytes[40..<56])),
                                sequence: sequence, hidReady: bytes[6] == 1,
                                revision: revision, pressureCapability: bytes[7] == 1, usbButtonTriggerCapability: bytes[7] == 2,
                                usbPressureCapability: bytes[7] == 4)
        packet.output = output
        try validate(packet)
        return packet
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes += [UInt8(value >> 8), UInt8(value & 255)]
    }
    private static func read16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }
}

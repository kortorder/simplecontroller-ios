import Foundation
import CoreFoundation

/// SCX1 is a new prototype protocol. It is not the downloaded CBv0 or Windows protocol.
public struct BridgePacket: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case hello, ready, state, ack, stop, stopped
    }

    public let protocolName: String
    public let version: Int
    public let kind: Kind
    public let session: String
    public let sequence: UInt64
    public let state: GamepadState?
    public let hidReady: Bool?

    public init(
        kind: Kind,
        session: String,
        sequence: UInt64,
        state: GamepadState? = nil,
        hidReady: Bool? = nil
    ) {
        self.protocolName = "SCX1"
        self.version = 1
        self.kind = kind
        self.session = session
        self.sequence = sequence
        self.state = state
        self.hidReady = hidReady
    }

    private enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case version, kind, session, sequence, state, hidReady
    }
}

public enum BridgeCodecError: Error, Equatable, Sendable {
    case packetTooLarge
    case malformedJSON
    case invalidProtocol
    case unsupportedVersion
    case invalidSession
    case invalidSequence
    case invalidFields
    case invalidState
}

public enum BridgeCodec {
    public static let maximumDatagramBytes = 1_024

    public static func encode(_ packet: BridgePacket) throws -> Data {
        try validate(packet)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(packet)
        guard data.count <= maximumDatagramBytes else { throw BridgeCodecError.packetTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> BridgePacket {
        guard data.count <= maximumDatagramBytes else { throw BridgeCodecError.packetTooLarge }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw BridgeCodecError.malformedJSON }
        guard let object = value as? [String: Any] else { throw BridgeCodecError.malformedJSON }
        guard object["protocol"] as? String == "SCX1" else { throw BridgeCodecError.invalidProtocol }
        guard let version = number(object["version"]), version.intValue == 1,
              version.doubleValue == 1 else { throw BridgeCodecError.unsupportedVersion }
        guard let session = object["session"] as? String, UUID(uuidString: session) != nil else {
            throw BridgeCodecError.invalidSession
        }
        guard number(object["sequence"]) != nil else { throw BridgeCodecError.invalidSequence }
        guard let kindName = object["kind"] as? String,
              let kind = BridgePacket.Kind(rawValue: kindName) else { throw BridgeCodecError.invalidFields }

        var keys: Set<String> = ["protocol", "version", "kind", "session", "sequence"]
        switch kind {
        case .state:
            keys.insert("state")
            guard let state = object["state"] as? [String: Any],
                  Set(state.keys) == ["buttons", "leftStick", "rightStick", "dpad"],
                  let buttons = state["buttons"] as? [String],
                  buttons.count <= PadButton.allCases.count,
                  Set(buttons).count == buttons.count,
                  buttons.allSatisfy({ PadButton(rawValue: $0) != nil }),
                  let dpad = state["dpad"] as? String, DPadDirection(rawValue: dpad) != nil,
                  validStick(state["leftStick"]), validStick(state["rightStick"]) else {
                throw BridgeCodecError.invalidState
            }
        case .ready, .ack:
            keys.insert("hidReady")
            guard let ready = object["hidReady"] as? NSNumber,
                  CFGetTypeID(ready) == CFBooleanGetTypeID() else {
                throw BridgeCodecError.invalidFields
            }
        case .hello, .stop, .stopped:
            break
        }
        guard Set(object.keys) == keys else { throw BridgeCodecError.invalidFields }
        let packet: BridgePacket
        do { packet = try JSONDecoder().decode(BridgePacket.self, from: data) }
        catch { throw BridgeCodecError.malformedJSON }
        try validate(packet)
        return packet
    }

    public static func validate(_ packet: BridgePacket) throws {
        guard packet.protocolName == "SCX1" else { throw BridgeCodecError.invalidProtocol }
        guard packet.version == 1 else { throw BridgeCodecError.unsupportedVersion }
        guard UUID(uuidString: packet.session) != nil else { throw BridgeCodecError.invalidSession }
        switch packet.kind {
        case .hello:
            guard packet.sequence == 0 else { throw BridgeCodecError.invalidSequence }
            guard packet.state == nil && packet.hidReady == nil else { throw BridgeCodecError.invalidFields }
        case .ready:
            guard packet.sequence == 0 else { throw BridgeCodecError.invalidSequence }
            guard packet.state == nil && packet.hidReady != nil else { throw BridgeCodecError.invalidFields }
        case .state:
            guard packet.sequence > 0 else { throw BridgeCodecError.invalidSequence }
            guard let state = packet.state, packet.hidReady == nil else { throw BridgeCodecError.invalidFields }
            guard state.isValid else { throw BridgeCodecError.invalidState }
        case .ack:
            guard packet.sequence > 0 else { throw BridgeCodecError.invalidSequence }
            guard packet.state == nil && packet.hidReady != nil else { throw BridgeCodecError.invalidFields }
        case .stop, .stopped:
            guard packet.sequence > 0 else { throw BridgeCodecError.invalidSequence }
            guard packet.state == nil && packet.hidReady == nil else { throw BridgeCodecError.invalidFields }
        }
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    private static func validStick(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any], Set(object.keys) == ["x", "y"],
              let x = number(object["x"]), let y = number(object["y"]) else { return false }
        return StickPosition(x: x.doubleValue, y: y.doubleValue).isValid
    }
}

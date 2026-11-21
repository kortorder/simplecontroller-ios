import Foundation
import XCTest
@testable import ControllerCore

final class BridgeCodecTests: XCTestCase {
    private let session = "73BAFB0B-4B19-48B7-8067-724643716450"

    func testNeutralStateHasNoPressedOutputs() {
        XCTAssertTrue(GamepadState.neutral.isNeutral)
        XCTAssertTrue(GamepadState.neutral.buttons.isEmpty)
        XCTAssertEqual(GamepadState.neutral.leftStick, .zero)
        XCTAssertEqual(GamepadState.neutral.rightStick, .zero)
        XCTAssertEqual(GamepadState.neutral.dpad, .neutral)
    }

    func testHelloMatchesIndependentWireFixture() throws {
        let packet = BridgePacket(kind: .hello, session: session, sequence: 0)
        let expected = "{\"kind\":\"hello\",\"protocol\":\"SCX1\",\"sequence\":0,\"session\":\"\(session)\",\"version\":1}"
        XCTAssertEqual(try BridgeCodec.encode(packet), Data(expected.utf8))
        XCTAssertEqual(try BridgeCodec.decode(Data(expected.utf8)), packet)
    }

    func testCompleteStateRoundTripsDeterministically() throws {
        let state = GamepadState(buttons: [.menu, .a, .rightBumper],
                                 leftStick: .init(x: -1, y: 1),
                                 rightStick: .init(x: 0.5, y: -0.25), dpad: .downLeft)
        let packet = BridgePacket(kind: .state, session: session, sequence: 42, state: state)
        let data = try BridgeCodec.encode(packet)
        XCTAssertEqual(try BridgeCodec.decode(data), packet)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"buttons\":[\"a\",\"menu\",\"rightBumper\"]"))
        XCTAssertLessThan(data.count, BridgeCodec.maximumDatagramBytes)
        XCTAssertEqual(try BridgeCodec.encode(packet), data)
    }

    func testExtendedDigitalButtonsRoundTripWithinPacketLimit() throws {
        let state = GamepadState(buttons: Set(PadButton.allCases),
                                 leftStick: .init(x: -1, y: 1), rightStick: .init(x: 1, y: -1), dpad: .upRight)
        let packet = BridgePacket(kind: .state, session: session, sequence: UInt64.max, state: state)
        let data = try BridgeCodec.encode(packet)
        XCTAssertEqual(try BridgeCodec.decode(data), packet)
        XCTAssertLessThanOrEqual(data.count, BridgeCodec.maximumDatagramBytes)
        for name in ["leftTrigger", "rightTrigger", "guide", "share"] {
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"" + name + "\""))
        }
    }

    func testAllResponseShapesRoundTrip() throws {
        for packet in [
            BridgePacket(kind: .ready, session: session, sequence: 0, hidReady: false),
            BridgePacket(kind: .ready, session: session, sequence: 0, hidReady: true),
            BridgePacket(kind: .ack, session: session, sequence: 3, hidReady: true),
            BridgePacket(kind: .stop, session: session, sequence: 4),
            BridgePacket(kind: .stopped, session: session, sequence: 4)
        ] {
            XCTAssertEqual(try BridgeCodec.decode(BridgeCodec.encode(packet)), packet)
        }
    }

    func testMaximumUInt64SequenceRoundTripsWithoutPrecisionLoss() throws {
        let packet = BridgePacket(kind: .state, session: session,
                                  sequence: UInt64.max, state: .neutral)
        XCTAssertEqual(try BridgeCodec.decode(BridgeCodec.encode(packet)), packet)
    }

    func testRejectsWrongProtocolVersionOrSession() throws {
        for (field, value) in [("protocol", "CBv0" as Any), ("version", 2 as Any),
                               ("version", true as Any), ("session", "not-a-uuid" as Any)] {
            var object = try helloObject()
            object[field] = value
            XCTAssertThrowsError(try decode(object), "accepted invalid \(field)")
        }
    }

    func testRejectsMalformedOversizedAndNonObjectJSON() {
        for text in ["", "{", "null", "[]", "true"] {
            XCTAssertThrowsError(try BridgeCodec.decode(Data(text.utf8)))
        }
        XCTAssertThrowsError(try BridgeCodec.decode(Data(repeating: 32, count: 1_025))) { error in
            XCTAssertEqual(error as? BridgeCodecError, .packetTooLarge)
        }
    }

    func testRejectsUnknownKindAndExtraTopLevelField() throws {
        var object = try helloObject()
        object["kind"] = "restart"
        XCTAssertThrowsError(try decode(object))
        object = try helloObject()
        object["ignored"] = "must not be ignored"
        XCTAssertThrowsError(try decode(object))
    }

    func testRejectsNonIntegralNegativeBooleanOrStringSequence() throws {
        for sequence: Any in [-1, 1.25, true, "0", NSNull()] {
            var object = try helloObject()
            object["sequence"] = sequence
            XCTAssertThrowsError(try decode(object))
        }
    }

    func testRejectsWrongFieldsForKinds() {
        let invalid = [
            BridgePacket(kind: .hello, session: session, sequence: 1),
            BridgePacket(kind: .hello, session: session, sequence: 0, state: .neutral),
            BridgePacket(kind: .hello, session: session, sequence: 0, hidReady: true),
            BridgePacket(kind: .ready, session: session, sequence: 0),
            BridgePacket(kind: .ready, session: session, sequence: 1, hidReady: true),
            BridgePacket(kind: .state, session: session, sequence: 0, state: .neutral),
            BridgePacket(kind: .state, session: session, sequence: 1),
            BridgePacket(kind: .state, session: session, sequence: 1, state: .neutral, hidReady: true),
            BridgePacket(kind: .ack, session: session, sequence: 1),
            BridgePacket(kind: .stop, session: session, sequence: 0),
            BridgePacket(kind: .stopped, session: session, sequence: 1, state: .neutral)
        ]
        for packet in invalid { XCTAssertThrowsError(try BridgeCodec.encode(packet)) }
    }

    func testRejectsInvalidAxisValuesBeforeEncoding() {
        for value in [-1.001, 1.001, .infinity, -.infinity, .nan] {
            let state = GamepadState(leftStick: .init(x: value))
            XCTAssertThrowsError(try BridgeCodec.encode(
                BridgePacket(kind: .state, session: session, sequence: 1, state: state)
            ))
        }
    }

    func testRejectsInvalidStateWireData() throws {
        let base = try stateObject()
        for value: Any in [["a", "a"], ["trigger"], "a"] {
            var object = base
            var state = try XCTUnwrap(object["state"] as? [String: Any])
            state["buttons"] = value
            object["state"] = state
            XCTAssertThrowsError(try decode(object))
        }
        for axes: Any in [["x": 1.1, "y": 0], ["x": true, "y": 0],
                          ["x": 0, "y": 0, "z": 0], ["x": 0]] {
            var object = base
            var state = try XCTUnwrap(object["state"] as? [String: Any])
            state["leftStick"] = axes
            object["state"] = state
            XCTAssertThrowsError(try decode(object))
        }
        var object = base
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        state["dpad"] = "north"
        object["state"] = state
        XCTAssertThrowsError(try decode(object))
        state["dpad"] = "neutral"
        state["triggers"] = [0, 1]
        object["state"] = state
        XCTAssertThrowsError(try decode(object))
    }

    func testReadinessMustBeBooleanNotInteger() throws {
        var object = try helloObject()
        object["kind"] = "ready"
        object["hidReady"] = 1
        XCTAssertThrowsError(try decode(object))
        object["hidReady"] = false
        XCTAssertEqual(try decode(object).hidReady, false)
    }

    private func helloObject() throws -> [String: Any] {
        try object(BridgePacket(kind: .hello, session: session, sequence: 0))
    }

    private func stateObject() throws -> [String: Any] {
        try object(BridgePacket(kind: .state, session: session, sequence: 1, state: .neutral))
    }

    private func object(_ packet: BridgePacket) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: BridgeCodec.encode(packet)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> BridgePacket {
        try BridgeCodec.decode(JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
    }
}

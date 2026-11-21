import Foundation
import ControllerCore

// Executable checks are usable with Command Line Tools, which can lack XCTest.
// They exercise the public API; the XCTest suite remains available with full Xcode.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "Check failed") throws {
    guard try condition() else { throw CheckFailure(description: message) }
}

func expectThrows(_ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw CheckFailure(description: "Invalid input was accepted")
}

let session = "73BAFB0B-4B19-48B7-8067-724643716450"
let secondSession = "F1862F1D-2A08-489B-96DC-D5A0C45C9505"
let pressed = GamepadState(buttons: [.a], leftStick: .init(x: 1, y: -0.25))

func hello(_ id: String = session) -> BridgePacket {
    BridgePacket(kind: .hello, session: id, sequence: 0)
}
func state(_ sequence: UInt64, _ output: GamepadState = pressed, _ id: String = session) -> BridgePacket {
    BridgePacket(kind: .state, session: id, sequence: sequence, state: output)
}
func stop(_ sequence: UInt64, _ id: String = session) -> BridgePacket {
    BridgePacket(kind: .stop, session: id, sequence: sequence)
}
func object(_ packet: BridgePacket) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: BridgeCodec.encode(packet)) as? [String: Any] else {
        throw CheckFailure(description: "Expected object")
    }
    return value
}
func decode(_ object: [String: Any]) throws -> BridgePacket {
    try BridgeCodec.decode(JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
}

let checks: [(String, () throws -> Void)] = [
    ("Exact handshake wire fixture", {
        let fixture = "{\"kind\":\"hello\",\"protocol\":\"SCX1\",\"sequence\":0,\"session\":\"\(session)\",\"version\":1}"
        try expect(try BridgeCodec.encode(hello()) == Data(fixture.utf8))
        try expect(try BridgeCodec.decode(Data(fixture.utf8)) == hello())
    }),
    ("Complete state encoding and every D-pad direction", {
        for direction in DPadDirection.allCases {
            let output = GamepadState(buttons: Set(PadButton.allCases),
                                      leftStick: .init(x: -1, y: 1), rightStick: .init(x: 0.5, y: -0.5),
                                      dpad: direction)
            let packet = state(2, output)
            let data = try BridgeCodec.encode(packet)
            try expect(try BridgeCodec.decode(data) == packet)
            try expect(try BridgeCodec.encode(packet) == data)
        }
        let data = try BridgeCodec.encode(state(3, .init(buttons: [.y, .a, .x])))
        try expect(String(decoding: data, as: UTF8.self).contains("\"buttons\":[\"a\",\"x\",\"y\"]"))
    }),
    ("All reply types and honest HID readiness", {
        for packet in [
            BridgePacket(kind: .ready, session: session, sequence: 0, hidReady: false),
            BridgePacket(kind: .ready, session: session, sequence: 0, hidReady: true),
            BridgePacket(kind: .ack, session: session, sequence: 12, hidReady: true),
            stop(13), BridgePacket(kind: .stopped, session: session, sequence: 13)
        ] {
            try expect(try BridgeCodec.decode(BridgeCodec.encode(packet)) == packet)
        }
        var bridge = BridgeSafetyMachine()
        try expect(try bridge.receive(hello(), at: 0)?.hidReady == false)
    }),
    ("Bad common fields and number types rejected", {
        for (key, value) in [("protocol", "other" as Any), ("version", 2 as Any),
                              ("version", true as Any), ("session", "bad-id" as Any),
                              ("sequence", -1 as Any), ("sequence", 0.25 as Any),
                              ("sequence", true as Any), ("sequence", "0" as Any),
                              ("kind", "restart" as Any), ("extra", 1 as Any)] {
            var body = try object(hello())
            body[key] = value
            try expectThrows { _ = try decode(body) }
        }
        var body = try object(BridgePacket(kind: .ready, session: session, sequence: 0, hidReady: true))
        body["hidReady"] = 1
        try expectThrows { _ = try decode(body) }
    }),
    ("Invalid fields for packet kinds rejected", {
        for packet in [
            BridgePacket(kind: .hello, session: session, sequence: 1),
            BridgePacket(kind: .hello, session: session, sequence: 0, state: .neutral),
            BridgePacket(kind: .hello, session: session, sequence: 0, hidReady: true),
            BridgePacket(kind: .ready, session: session, sequence: 0),
            BridgePacket(kind: .ready, session: session, sequence: 1, hidReady: true),
            state(0), BridgePacket(kind: .state, session: session, sequence: 1),
            BridgePacket(kind: .state, session: session, sequence: 1, state: .neutral, hidReady: false),
            BridgePacket(kind: .ack, session: session, sequence: 1), stop(0),
            BridgePacket(kind: .stopped, session: session, sequence: 1, state: .neutral)
        ] { try expectThrows { _ = try BridgeCodec.encode(packet) } }
    }),
    ("Unknown duplicate or incomplete state rejected", {
        for (key, value) in [("buttons", ["a", "a"] as Any), ("buttons", ["trigger"] as Any),
                              ("dpad", "north" as Any), ("trigger", 0.5 as Any),
                              ("leftStick", ["x": 0] as Any),
                              ("rightStick", ["x": 0, "y": 0, "z": 0] as Any)] {
            var body = try object(state(1))
            var output = body["state"] as! [String: Any]
            output[key] = value
            body["state"] = output
            try expectThrows { _ = try decode(body) }
        }
    }),
    ("Nonfinite and out-of-range axes rejected", {
        for axis in [-1.01, 1.01, Double.infinity, -.infinity, .nan] {
            try expectThrows { _ = try BridgeCodec.encode(state(1, .init(leftStick: .init(x: axis)))) }
        }
        for axis: Any in [true, 1.1, "0"] {
            var body = try object(state(1))
            var output = body["state"] as! [String: Any]
            output["leftStick"] = ["x": axis, "y": 0]
            body["state"] = output
            try expectThrows { _ = try decode(body) }
        }
    }),
    ("Malformed and oversized datagrams rejected", {
        for text in ["", "{", "null", "[]", "true"] {
            try expectThrows { _ = try BridgeCodec.decode(Data(text.utf8)) }
        }
        try expectThrows { _ = try BridgeCodec.decode(Data(repeating: 32, count: 1_025)) }
    }),
    ("Unsigned sequence preserves full integer precision", {
        let packet = state(UInt64.max)
        try expect(try BridgeCodec.decode(BridgeCodec.encode(packet)) == packet)
    }),
    ("Neutral startup and no output before handshake", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        try expect(bridge.output.isNeutral && bridge.activeSession == nil)
        try expect(try bridge.receive(state(1), at: 0) == nil)
        try expect(bridge.output.isNeutral)
    }),
    ("Unavailable HID rejects state and cannot renew its lease", {
        var bridge = BridgeSafetyMachine(hidReady: false)
        try expect(try bridge.receive(hello(), at: 0)?.hidReady == false)
        try expect(try bridge.receive(state(1), at: 0.1) == nil)
        try expect(try bridge.receive(state(2, .neutral), at: 0.9) == nil)
        try expect(bridge.output.isNeutral && bridge.lastSequence == 0 && bridge.deadline == 1)
        try expect(try bridge.expire(at: 1))
        try expect(try bridge.receive(state(3), at: 1.1) == nil)
        try expect(bridge.output.isNeutral && bridge.activeSession == nil)
    }),
    ("Full state replacement releases previous output", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1), at: 0.1)
        try expect(bridge.output == pressed)
        _ = try bridge.receive(state(2, .neutral), at: 0.2)
        try expect(bridge.output.isNeutral && bridge.lastSequence == 2)
        try expect(bridge.deadline == 1.2)
    }),
    ("Competing session cannot take over or stop live output", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1), at: 0.1)
        try expect(try bridge.receive(hello(secondSession), at: 0.2) == nil)
        try expect(try bridge.receive(state(99, .neutral, secondSession), at: 0.3) == nil)
        try expect(try bridge.receive(stop(100, secondSession), at: 0.4) == nil)
        try expect(bridge.output == pressed && bridge.activeSession == session)
    }),
    ("Repeated hello neither releases held state nor renews lease", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1), at: 0.1)
        try expect(try bridge.receive(hello(), at: 0.9)?.kind == .ready)
        try expect(bridge.output == pressed && bridge.lastSequence == 1 && bridge.deadline == 1.1)
    }),
    ("Duplicate states cannot change output or extend the lease", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1), at: 0.1)
        try expect(try bridge.receive(state(1, .neutral), at: 0.8)?.kind == .ack)
        try expect(bridge.output == pressed && bridge.deadline == 1.1)
        try expect(try bridge.expire(at: 1.1))
        try expect(bridge.output.isNeutral)
    }),
    ("Reordered input cannot undo a newer release", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(3, .neutral), at: 0.1)
        try expect(try bridge.receive(state(2), at: 0.2) == nil)
        try expect(bridge.output.isNeutral && bridge.deadline == 1.1)
    }),
    ("Expiry boundary blocks late state and old hello", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1), at: 0.1)
        try expect(try !bridge.expire(at: 1.099))
        try expect(try bridge.receive(state(2), at: 1.1) == nil)
        try expect(bridge.output.isNeutral && bridge.activeSession == nil)
        try expect(try bridge.receive(hello(), at: 1.2) == nil)
        try expect(try bridge.receive(hello(secondSession), at: 1.3)?.kind == .ready)
        try expect(try bridge.receive(state(100), at: 1.4) == nil)
    }),
    ("Stop neutralizes, acknowledges retry, and fences stale output", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1), at: 0.1)
        try expect(try bridge.receive(stop(2), at: 0.2)?.kind == .stopped)
        try expect(bridge.output.isNeutral && bridge.activeSession == nil)
        try expect(try bridge.receive(state(3), at: 0.3) == nil)
        try expect(try bridge.receive(stop(2), at: 0.4)?.kind == .stopped)
        try expect(try bridge.receive(hello(), at: 0.5) == nil)
    }),
    ("Stale stop cannot cancel newer output", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(3), at: 0.1)
        try expect(try bridge.receive(stop(2), at: 0.2) == nil)
        try expect(try bridge.receive(stop(3), at: 0.3) == nil)
        try expect(bridge.output == pressed)
    }),
    ("Dropped stop still times out to neutral", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1), at: 0.1)
        try expect(try bridge.expire(at: 1.2))
        try expect(bridge.output.isNeutral)
    }),
    ("UUID case cannot bypass retired-session fence", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(stop(1), at: 0.1)
        try expect(try bridge.receive(hello(session.lowercased()), at: 0.2) == nil)
    }),
    ("Reply packets cannot control output or renew a lease", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1), at: 0.1)
        let response = BridgePacket(kind: .ack, session: session, sequence: 99, hidReady: true)
        try expect(try bridge.receive(response, at: 0.8) == nil)
        try expect(bridge.output == pressed && bridge.deadline == 1.1)
    }),
    ("Malformed state and backwards time cannot mutate live output", {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 1)
        _ = try bridge.receive(state(1), at: 1.1)
        try expectThrows { _ = try bridge.receive(state(2, .init(leftStick: .init(x: .nan))), at: 1.2) }
        for time in [1.0, -1, .nan, .infinity] {
            try expectThrows { _ = try bridge.expire(at: time) }
        }
        try expect(bridge.output == pressed && bridge.deadline == 2.1)
        try expect(try bridge.expire(at: 2.1))
    })
]

var passed = 0
for (name, check) in checks {
    do {
        try check()
        passed += 1
        print("PASS: \(name)")
    } catch {
        fputs("FAIL: \(name): \(error)\n", stderr)
        exit(1)
    }
}
print("\(passed) ControllerCore checks passed. No iPhone, USB, or Xbox hardware was exercised.")

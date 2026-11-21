import Foundation
import XCTest
@testable import ControllerCore

final class SCX2PressureTests: XCTestCase {
    private let boot = SCX2Token(bytes: Array(repeating: 1, count: 16))
    private let challenge = SCX2Token(bytes: Array(repeating: 2, count: 16))

    private func packet(_ output: BridgeOutputState = .neutral) -> SCX2Packet {
        .init(kind: .state, session: .init(uuid: UUID()), boot: boot, challenge: challenge,
              sequence: 2, output: output)
    }
    private func offer(_ machine: SCX2ClientMachine, available: Bool = true) -> SCX2Packet {
        .init(kind: .ready, session: machine.session, boot: boot, challenge: available ? challenge : .zero,
              hidReady: available, revision: .pressure, pressureCapability: available)
    }
    private func ack(_ packet: SCX2Packet) -> SCX2Packet {
        .init(kind: .ack, session: packet.session, boot: packet.boot, challenge: packet.challenge,
              sequence: packet.sequence, hidReady: true, revision: packet.revision)
    }
    private func armed(at time: TimeInterval = 0) -> SCX2ClientMachine {
        var machine = SCX2ClientMachine(revision: .pressure, at: time)
        _ = machine.socketDidBecomeReady(at: time)
        let neutral = machine.receive(offer(machine), at: time).first!
        _ = machine.receive(ack(neutral), at: time)
        return machine
    }

    func testAllSharedCppPressureGoldenVectorsDecodeAndReencodeExactly() throws {
        struct Vector: Decodable {
            var name: String; var format: UInt8; var capabilities: UInt8; var kind: UInt8
            var session: String; var boot: String; var challenge: String
            var sequenceDecimal: String; var hidReady: Bool; var hex: String; var state: WireState?
            struct WireState: Decodable {
                var buttonMask: UInt16; var hat: UInt8; var axes: [Int16]
                var leftPressure: UInt16; var rightPressure: UInt16
            }
        }
        struct File: Decodable { var vectors: [Vector] }
        func bytes(_ hex: String) -> [UInt8] {
            stride(from: 0, to: hex.count, by: 2).map {
                let start = hex.index(hex.startIndex, offsetBy: $0)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let fixtures = try JSONDecoder().decode(File.self, from: Data(contentsOf: url.appendingPathComponent("bridge/fixtures/scx2-pressure-wire.json"))).vectors
        XCTAssertEqual(fixtures.count, 9)
        let hats: [DPadDirection] = [.up, .upRight, .right, .downRight, .down, .downLeft, .left, .upLeft, .neutral]
        for fixture in fixtures {
            let wire = Data(bytes(fixture.hex))
            let decoded = try SCX2Codec.decode(wire)
            XCTAssertEqual(decoded.revision.rawValue, fixture.format, fixture.name)
            XCTAssertEqual(decoded.pressureCapability, fixture.capabilities == 1, fixture.name)
            XCTAssertEqual(decoded.kind.rawValue, fixture.kind, fixture.name)
            XCTAssertEqual(decoded.session.bytes, bytes(fixture.session), fixture.name)
            XCTAssertEqual(decoded.boot.bytes, bytes(fixture.boot), fixture.name)
            XCTAssertEqual(decoded.challenge.bytes, bytes(fixture.challenge), fixture.name)
            XCTAssertEqual(decoded.sequence, UInt64(fixture.sequenceDecimal), fixture.name)
            XCTAssertEqual(decoded.hidReady, fixture.hidReady, fixture.name)
            if let expected = fixture.state, let output = decoded.output {
                let expectedButtons = Set(SCX2Codec.supportedButtons.enumerated().compactMap { index, button in
                    expected.buttonMask & (1 << index) != 0 ? button : nil
                })
                XCTAssertEqual(output.gamepad.buttons, expectedButtons, fixture.name)
                XCTAssertEqual(output.gamepad.dpad, hats[Int(expected.hat)], fixture.name)
                XCTAssertEqual([output.gamepad.leftStick.x, output.gamepad.leftStick.y,
                                output.gamepad.rightStick.x, output.gamepad.rightStick.y], expected.axes.map { Double($0) / 32767 }, fixture.name)
                XCTAssertEqual(output.leftTrigger, Double(expected.leftPressure) / 65535, fixture.name)
                XCTAssertEqual(output.rightTrigger, Double(expected.rightPressure) / 65535, fixture.name)
            } else { XCTAssertNil(decoded.output, fixture.name) }
            XCTAssertEqual(try SCX2Codec.encode(decoded), wire, fixture.name)
        }
    }

    func testSnapshotValidityAndNeutralIncludeBothPressures() {
        XCTAssertTrue(BridgeOutputState.neutral.isValid)
        XCTAssertTrue(BridgeOutputState.neutral.isNeutral)
        XCTAssertFalse(BridgeOutputState(leftTrigger: 0.1).isNeutral)
        XCTAssertFalse(BridgeOutputState(rightTrigger: 0.1).isNeutral)
        XCTAssertFalse(BridgeOutputState(gamepad: .init(buttons: [.a])).isNeutral)
        for value in [Double.nan, .infinity, -.infinity, -0.001, 1.001] {
            XCTAssertFalse(BridgeOutputState(leftTrigger: value).isValid)
            XCTAssertFalse(BridgeOutputState(rightTrigger: value).isValid)
        }
    }

    func testPressureWireKeepsOriginalButtonAndAxisBytesAndAddsIndependentValues() throws {
        let gamepad = GamepadState(buttons: [.a, .x, .leftBumper], leftStick: .init(x: 1, y: -1), dpad: .upRight)
        let value = packet(.init(gamepad: gamepad, leftTrigger: 0.1, rightTrigger: 0.5))
        let wire = try SCX2Codec.encode(value)
        XCTAssertEqual(wire.count, 80)
        XCTAssertEqual(wire[4], 3); XCTAssertEqual(wire[7], 0)
        XCTAssertEqual(Array(wire[76..<80]), [0x19, 0x9a, 0x80, 0x00])
        let legacy = SCX2Packet(kind: .state, session: value.session, boot: boot, challenge: challenge,
                                sequence: 2, state: gamepad)
        XCTAssertEqual(Array(wire[64..<76]), Array(try SCX2Codec.encode(legacy)[64..<76]))
        let decoded = try SCX2Codec.decode(wire)
        XCTAssertEqual(decoded.state, gamepad)
        XCTAssertEqual(decoded.output!.leftTrigger, 6554.0 / 65535)
        XCTAssertEqual(decoded.output!.rightTrigger, 32768.0 / 65535)
        XCTAssertEqual(try SCX2Codec.encode(decoded), wire)
    }

    func testPressureQuantizationHasBoundedErrorAndExactZeroFullScale() throws {
        for value in [0.0, 0.00000001, 0.1, 0.2, 0.3, 0.5, 0.75, 0.9, 1.0] {
            let output = try SCX2Codec.decode(SCX2Codec.encode(packet(.init(leftTrigger: value, rightTrigger: 1 - value)))).output!
            XCTAssertEqual(output.leftTrigger, value, accuracy: 0.5 / 65535)
            XCTAssertEqual(output.rightTrigger, 1 - value, accuracy: 0.5 / 65535)
        }
        let wire = try SCX2Codec.encode(packet(.init(leftTrigger: 0, rightTrigger: 1)))
        XCTAssertEqual(Array(wire[76..<80]), [0, 0, 255, 255])
    }

    func testRevisionAndPacketSpecificLengthsAreStrict() throws {
        let valid = try SCX2Codec.encode(packet(.init(rightTrigger: 0.8)))
        for count in [64, 75, 76, 77, 78, 79] {
            XCTAssertThrowsError(try SCX2Codec.decode(valid.prefix(count)))
        }
        XCTAssertThrowsError(try SCX2Codec.decode(valid + Data([0])))
        var wrong = valid; wrong[4] = 2
        XCTAssertThrowsError(try SCX2Codec.decode(wrong))
        wrong[4] = 4
        XCTAssertThrowsError(try SCX2Codec.decode(wrong))
        wrong = valid; wrong[5] = SCX2Packet.Kind.ack.rawValue; wrong[6] = 1
        XCTAssertThrowsError(try SCX2Codec.decode(wrong))
    }

    func testCapabilityIsRequiredOnlyOnPressureHelloAndAvailableReady() throws {
        let machine = SCX2ClientMachine(revision: .pressure, at: 0)
        var hello = SCX2Packet(kind: .hello, session: machine.session, revision: .pressure, pressureCapability: true)
        XCTAssertEqual(try SCX2Codec.encode(hello).count, 64)
        XCTAssertEqual(try SCX2Codec.encode(hello)[7], 1)
        hello.pressureCapability = false
        XCTAssertThrowsError(try SCX2Codec.encode(hello))
        hello.revision = .legacy; hello.pressureCapability = true
        XCTAssertThrowsError(try SCX2Codec.encode(hello))
        XCTAssertNoThrow(try SCX2Codec.encode(offer(machine)))
        XCTAssertNoThrow(try SCX2Codec.encode(offer(machine, available: false)))
        var bad = offer(machine); bad.pressureCapability = false
        XCTAssertThrowsError(try SCX2Codec.encode(bad))
        bad = offer(machine, available: false); bad.pressureCapability = true
        XCTAssertThrowsError(try SCX2Codec.encode(bad))
        for kind in [SCX2Packet.Kind.state, .ack, .stop, .stopped] {
            var value = packet(); value.kind = kind; value.hidReady = kind == .ack
            if kind != .state { value.output = nil }
            value.pressureCapability = true
            XCTAssertThrowsError(try SCX2Codec.encode(value))
        }
        var bytes = try SCX2Codec.encode(offer(machine)); bytes[7] = 3
        XCTAssertThrowsError(try SCX2Codec.decode(bytes))
    }

    func testNoPressureOrUnsupportedButtonsCanLeakIntoLegacyPackets() throws {
        var value = packet(.init(leftTrigger: 0.1)); value.revision = .legacy
        XCTAssertThrowsError(try SCX2Codec.encode(value))
        for button in [PadButton.leftTrigger, .rightTrigger, .guide, .share] {
            XCTAssertThrowsError(try SCX2Codec.encode(packet(.init(gamepad: .init(buttons: [button]), rightTrigger: 0.5))))
        }
        for pressure in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertThrowsError(try SCX2Codec.encode(packet(.init(leftTrigger: pressure))))
            XCTAssertThrowsError(try SCX2Codec.encode(packet(.init(rightTrigger: pressure))))
        }
    }

    func testPressureSessionRequiresBothCapabilityAndNeutralAcknowledgment() {
        var machine = SCX2ClientMachine(revision: .pressure, at: 0)
        let hello = machine.socketDidBecomeReady(at: 0).first!
        XCTAssertEqual(hello.revision, .pressure); XCTAssertTrue(hello.pressureCapability)
        XCTAssertTrue(machine.updateOutput(.init(rightTrigger: 1), at: 0).isEmpty)
        let neutral = machine.receive(offer(machine), at: 0).first!
        XCTAssertEqual(neutral.revision, .pressure); XCTAssertFalse(neutral.pressureCapability)
        XCTAssertTrue(neutral.output!.isNeutral); XCTAssertEqual(neutral.sequence, 1)
        XCTAssertFalse(machine.controlsEnabled)
        XCTAssertTrue(machine.updateOutput(.init(leftTrigger: 0.5), at: 0).isEmpty)
        _ = machine.receive(ack(neutral), at: 0)
        XCTAssertTrue(machine.controlsEnabled); XCTAssertTrue(machine.currentOutput.isNeutral)
    }

    func testUnavailableBackendFailsClosedWithoutDowngrading() {
        var machine = SCX2ClientMachine(revision: .pressure, at: 0)
        XCTAssertTrue(machine.receive(offer(machine, available: false), at: 0).isEmpty)
        XCTAssertEqual(machine.phase, .stopped(.pressureUnavailable))
        XCTAssertTrue(machine.currentOutput.isNeutral)
        XCTAssertTrue(machine.receive(offer(machine), at: 0).isEmpty)
        XCTAssertTrue(machine.updateOutput(.init(rightTrigger: 1), at: 0).isEmpty)
    }

    func testOldRevisionOfferCannotArmPressureSession() {
        var machine = SCX2ClientMachine(revision: .pressure, at: 0)
        var old = offer(machine); old.revision = .legacy; old.pressureCapability = false
        XCTAssertTrue(machine.receive(old, at: 0).isEmpty)
        XCTAssertFalse(machine.controlsEnabled)
        _ = machine.tick(at: 3)
        XCTAssertEqual(machine.phase, .stopped(.helloTimeout))
    }

    func testWrongRevisionAckCannotArmOrRenewPressureSession() {
        var machine = SCX2ClientMachine(revision: .pressure, at: 0)
        let neutral = machine.receive(offer(machine), at: 0).first!
        var old = ack(neutral); old.revision = .legacy
        XCTAssertTrue(machine.receive(old, at: 0.7).isEmpty)
        XCTAssertFalse(machine.controlsEnabled)
        _ = machine.tick(at: 0.75)
        XCTAssertEqual(machine.phase, .stopped(.neutralTimeout))
    }

    func testFractionalChangesAndReleaseStayOrderedDespiteIdenticalGamepad() {
        var machine = armed()
        let low = machine.updateOutput(.init(rightTrigger: 0.2), at: 0).first!
        XCTAssertTrue(machine.updateOutput(.init(rightTrigger: 0.8), at: 0.01).isEmpty)
        XCTAssertTrue(machine.updateOutput(.init(leftTrigger: 0.3, rightTrigger: 0.8), at: 0.02).isEmpty)
        XCTAssertTrue(machine.updateOutput(.neutral, at: 0.03).isEmpty)
        XCTAssertEqual(machine.queuedCount, 3)
        XCTAssertEqual(machine.tick(at: 0.1), [low])
        let high = machine.receive(ack(low), at: 0.11).first!
        XCTAssertEqual(high.output?.rightTrigger, 0.8); XCTAssertTrue(high.state!.isNeutral)
        let both = machine.receive(ack(high), at: 0.12).first!
        XCTAssertEqual(both.output, .init(leftTrigger: 0.3, rightTrigger: 0.8))
        let zero = machine.receive(ack(both), at: 0.13).first!
        XCTAssertTrue(zero.output!.isNeutral)
        _ = machine.receive(ack(zero), at: 0.14)
        XCTAssertEqual(machine.queuedCount, 0)
    }

    func testIdenticalPressureDoesNotDuplicateAndHeartbeatRetainsPressure() {
        var machine = armed()
        let state = BridgeOutputState(leftTrigger: 0.4, rightTrigger: 0.7)
        let first = machine.updateOutput(state, at: 0).first!
        _ = machine.receive(ack(first), at: 0)
        XCTAssertTrue(machine.updateOutput(state, at: 0.01).isEmpty)
        XCTAssertEqual(machine.queuedCount, 0)
        XCTAssertEqual(machine.tick(at: 0.1).first?.output, state)
    }

    func testPressureStopDropsQueueAndStaleAcknowledgmentCannotRestoreIt() {
        var machine = armed()
        let first = machine.updateOutput(.init(leftTrigger: 0.2), at: 0).first!
        _ = machine.updateOutput(.init(leftTrigger: 0.8), at: 0)
        let stop = machine.stop()!
        XCTAssertEqual(stop.revision, .pressure); XCTAssertFalse(stop.pressureCapability)
        XCTAssertNil(stop.output); XCTAssertGreaterThan(stop.sequence, first.sequence)
        XCTAssertTrue(machine.currentOutput.isNeutral); XCTAssertEqual(machine.queuedCount, 0)
        XCTAssertTrue(machine.receive(ack(first), at: 0.1).isEmpty)
        XCTAssertTrue(machine.tick(at: 1).isEmpty)
    }

    func testBackendLossClearsHeldPressureAndQueuedPressure() {
        var machine = armed()
        let first = machine.updateOutput(.init(rightTrigger: 0.5), at: 0).first!
        _ = machine.updateOutput(.init(leftTrigger: 0.4, rightTrigger: 0.5), at: 0.01)
        let stop = machine.receive(offer(machine, available: false), at: 0.02).first!
        XCTAssertEqual(stop.kind, .stop); XCTAssertEqual(stop.revision, .pressure)
        XCTAssertEqual(machine.phase, .stopped(.pressureUnavailable))
        XCTAssertTrue(machine.currentOutput.isNeutral); XCTAssertEqual(machine.queuedCount, 0)
        XCTAssertTrue(machine.receive(ack(first), at: 0.03).isEmpty)
    }

    func testPressureOverflowFailsNeutralInsteadOfCoalescing() {
        var machine = armed()
        _ = machine.updateOutput(.init(rightTrigger: 0.1), at: 0)
        for index in 0..<16 { _ = machine.updateOutput(.init(rightTrigger: index % 2 == 0 ? 0.2 : 0.3), at: 0) }
        XCTAssertEqual(machine.queuedCount, 16)
        XCTAssertEqual(machine.updateOutput(.init(rightTrigger: 0.4), at: 0).first?.kind, .stop)
        XCTAssertEqual(machine.phase, .stopped(.queueOverflow)); XCTAssertTrue(machine.currentOutput.isNeutral)
    }

    func testInvalidPressureAndClockFailureReleaseWholeOutput() {
        for pressure in [Double.nan, .infinity, -0.01, 1.01] {
            var machine = armed()
            _ = machine.updateOutput(.init(gamepad: .init(buttons: [.a]), leftTrigger: 1), at: 0)
            _ = machine.updateOutput(.init(rightTrigger: pressure), at: 0.1)
            XCTAssertEqual(machine.phase, .stopped(.invalidState)); XCTAssertTrue(machine.currentOutput.isNeutral)
        }
        var machine = armed(at: 100)
        let state = machine.updateOutput(.init(leftTrigger: 0.2), at: 100.1).first!
        _ = machine.receive(ack(state), at: 100)
        XCTAssertEqual(machine.phase, .stopped(.invalidTime)); XCTAssertTrue(machine.currentOutput.isNeutral)
    }

    func testExpiryWinsBeforeLatePressureAckOrNewPressure() {
        for reply in [false, true] {
            var machine = armed(at: 100)
            let first = machine.updateOutput(.init(rightTrigger: 0.2), at: 100).first!
            if reply { _ = machine.receive(ack(first), at: 100.75) }
            else { _ = machine.updateOutput(.init(rightTrigger: 0.8), at: 100.75) }
            XCTAssertEqual(machine.phase, .stopped(.acknowledgmentTimeout))
            XCTAssertTrue(machine.currentOutput.isNeutral); XCTAssertEqual(machine.queuedCount, 0)
        }
    }

    func testLegacyClientRejectsPressureInsteadOfSilentlyDiscardingIt() {
        var machine = SCX2ClientMachine(at: 0)
        var ready = offer(machine); ready.revision = .legacy; ready.pressureCapability = false
        let neutral = machine.receive(ready, at: 0).first!
        _ = machine.receive(ack(neutral), at: 0)
        _ = machine.updateOutput(.init(rightTrigger: 0.5), at: 0)
        XCTAssertEqual(machine.phase, .stopped(.invalidState)); XCTAssertTrue(machine.currentOutput.isNeutral)
    }

    func testResolvedPayloadPressureRestoresLowerOwnerAndSurvivesWire() throws {
        let low = ProfileControl(name: "Low", payload: "RT:0.2")
        let high = ProfileControl(name: "High pulse", payload: "RT:0.8P0.1")
        let placements = [low, high].map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        let profile = try ControllerProfile(controls: [low, high], portrait: placements, landscape: placements)
        var engine = try ProfileInputEngine(profile: profile)
        try engine.begin(contact: 1, control: low.id, at: 0)
        try engine.begin(contact: 2, control: high.id, at: 0)
        try engine.end(contact: 2, at: 0.01)
        func snapshot() -> BridgeOutputState {
            var gamepad = engine.state
            gamepad.buttons.subtract([.leftTrigger, .rightTrigger, .guide, .share])
            return .init(gamepad: gamepad, leftTrigger: engine.practiceState.leftTrigger,
                         rightTrigger: engine.practiceState.rightTrigger)
        }
        XCTAssertEqual(snapshot().rightTrigger, 0.8)
        var machine = armed()
        let pulse = machine.updateOutput(snapshot(), at: 0.01).first!
        XCTAssertEqual(try SCX2Codec.decode(SCX2Codec.encode(pulse)).output!.rightTrigger, 0.8, accuracy: 0.5 / 65535)
        _ = machine.receive(ack(pulse), at: 0.02)
        try engine.tick(at: 0.1)
        XCTAssertEqual(engine.practiceState.rightTrigger, 0.2)
        let restored = machine.updateOutput(snapshot(), at: 0.1).first!
        XCTAssertEqual(restored.output!.rightTrigger, 0.2)
        _ = machine.receive(ack(restored), at: 0.11)
        engine.releaseAll()
        XCTAssertTrue(machine.updateOutput(snapshot(), at: 0.12).first!.output!.isNeutral)
    }
}

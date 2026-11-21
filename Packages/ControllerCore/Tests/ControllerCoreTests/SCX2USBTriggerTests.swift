import XCTest
@testable import ControllerCore

final class SCX2USBTriggerTests: XCTestCase {
    let session = SCX2Token(uuid: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
    let boot = SCX2Token(uuid: UUID(uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f")!)
    let challenge = SCX2Token(uuid: UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")!)
    func ready(_ session: SCX2Token, available: Bool = true) -> SCX2Packet {
        .init(kind: .ready, session: session, boot: boot, challenge: available ? challenge : .zero,
              hidReady: available, revision: .usbButtons, usbButtonTriggerCapability: available)
    }
    func state(left: Double, right: Double, revision: SCX2Revision = .usbButtons) -> SCX2Packet {
        .init(kind: .state, session: session, boot: boot, challenge: challenge, sequence: 2,
              output: .init(gamepad: .init(buttons: [.a], leftStick: .init(x: 0.5), rightStick: .init(y: -1)),
                            leftTrigger: left, rightTrigger: right), revision: revision)
    }
    func testAllSharedCppUSBTriggerGoldenVectorsDecodeAndReencodeExactly() throws {
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
        let fixtures = try JSONDecoder().decode(File.self, from: Data(contentsOf: url.appendingPathComponent("bridge/fixtures/scx2-usb-trigger-wire.json"))).vectors
        XCTAssertEqual(fixtures.count, 10)
        let hats: [DPadDirection] = [.up, .upRight, .right, .downRight, .down, .downLeft, .left, .upLeft, .neutral]
        for fixture in fixtures {
            let wire = Data(bytes(fixture.hex))
            let decoded = try SCX2Codec.decode(wire)
            XCTAssertEqual(decoded.revision.rawValue, fixture.format, fixture.name)
            XCTAssertEqual(decoded.usbButtonTriggerCapability, fixture.capabilities == 2, fixture.name)
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

    func testHelloExplicitCapabilityAndExactBytes() throws {
        let p = SCX2Packet(kind: .hello, session: session, revision: .usbButtons, usbButtonTriggerCapability: true)
        let data = try SCX2Codec.encode(p)
        XCTAssertEqual(data.count, 64)
        XCTAssertEqual(Array(data.prefix(8)), [83, 67, 88, 50, 4, 1, 0, 2])
        XCTAssertEqual(try SCX2Codec.decode(data), p)
        var invalid = p; invalid.usbButtonTriggerCapability = false
        XCTAssertThrowsError(try SCX2Codec.encode(invalid))
        invalid.pressureCapability = true
        XCTAssertThrowsError(try SCX2Codec.encode(invalid))
    }
    func testBothTriggersAndSticksRoundTrip() throws {
        for left in [0.0, 1.0] { for right in [0.0, 1.0] {
            let wire = try SCX2Codec.encode(state(left: left, right: right))
            XCTAssertEqual(wire.count, 80)
            XCTAssertEqual(wire[4], 4); XCTAssertEqual(wire[7], 0)
            XCTAssertEqual(Array(wire.suffix(4)), [left == 0 ? 0 : 255, left == 0 ? 0 : 255,
                                                   right == 0 ? 0 : 255, right == 0 ? 0 : 255])
            let output = try XCTUnwrap(SCX2Codec.decode(wire).output)
            XCTAssertEqual(output.leftTrigger, left); XCTAssertEqual(output.rightTrigger, right)
            XCTAssertEqual(output.gamepad.buttons, [.a]); XCTAssertEqual(output.gamepad.rightStick.y, -1)
        } }
    }
    func testFractionalUSBTriggerStateRejectedAtBothBoundaries() throws {
        for fraction in [0.00001, 0.1, 0.5, 0.99999] {
            XCTAssertThrowsError(try SCX2Codec.encode(state(left: fraction, right: 0)))
            var wire = try SCX2Codec.encode(state(left: fraction, right: 0, revision: .pressure))
            wire[4] = 4
            XCTAssertThrowsError(try SCX2Codec.decode(wire))
        }
        var short = try SCX2Codec.encode(state(left: 0, right: 0)); short.removeLast(4)
        XCTAssertThrowsError(try SCX2Codec.decode(short))
    }
    func testCapabilityCannotLeakAcrossRevisionsOrKinds() throws {
        for revision in [SCX2Revision.legacy, .pressure] {
            var p = ready(session); p.revision = revision
            XCTAssertThrowsError(try SCX2Codec.encode(p))
        }
        var p = state(left: 1, right: 1); p.usbButtonTriggerCapability = true
        XCTAssertThrowsError(try SCX2Codec.encode(p))
        var wire = try SCX2Codec.encode(ready(session)); wire[7] = 3
        XCTAssertThrowsError(try SCX2Codec.decode(wire))
    }
    func testMatchingNeutralAcknowledgmentRequired() throws {
        var client = SCX2ClientMachine(revision: .usbButtons, at: 0)
        let hello = try XCTUnwrap(client.socketDidBecomeReady(at: 0).first)
        XCTAssertTrue(hello.usbButtonTriggerCapability)
        let neutral = try XCTUnwrap(client.receive(ready(client.session), at: 0.01).first)
        XCTAssertFalse(client.controlsEnabled); XCTAssertTrue(neutral.output!.isNeutral)
        XCTAssertEqual(try SCX2Codec.encode(neutral).count, 80)
        var ack = SCX2Packet(kind: .ack, session: client.session, boot: boot, challenge: challenge,
                             sequence: 1, hidReady: true, revision: .pressure)
        XCTAssertTrue(client.receive(ack, at: 0.02).isEmpty); XCTAssertFalse(client.controlsEnabled)
        ack.revision = .usbButtons
        _ = client.receive(ack, at: 0.03); XCTAssertTrue(client.controlsEnabled)
        let pressed = client.updateOutput(.init(leftTrigger: 1, rightTrigger: 1), at: 0.04)
        XCTAssertEqual(pressed.first?.output?.leftTrigger, 1)
        _ = client.updateOutput(.neutral, at: 0.05)
        XCTAssertEqual(client.queuedCount, 1)
        let stop = client.stop()
        XCTAssertEqual(stop?.revision, .usbButtons); XCTAssertEqual(client.queuedCount, 0)
        XCTAssertTrue(client.currentOutput.isNeutral)
    }
    func testUnavailableUSBModeNeverFallsBack() {
        var client = SCX2ClientMachine(revision: .usbButtons, at: 0)
        _ = client.socketDidBecomeReady(at: 0)
        _ = client.receive(ready(client.session, available: false), at: 0.1)
        XCTAssertEqual(client.phase, .stopped(.usbButtonTriggersUnavailable))
        XCTAssertTrue(client.currentOutput.isNeutral)
    }
    func testClientRejectsFractionalUSBOutput() {
        var client = SCX2ClientMachine(revision: .usbButtons, at: 0)
        _ = client.socketDidBecomeReady(at: 0)
        _ = client.receive(ready(client.session), at: 0.01)
        _ = client.receive(.init(kind: .ack, session: client.session, boot: boot, challenge: challenge,
                                sequence: 1, hidReady: true, revision: .usbButtons), at: 0.02)
        _ = client.updateOutput(.init(rightTrigger: 0.7), at: 0.03)
        XCTAssertEqual(client.phase, .stopped(.invalidState))
    }
}

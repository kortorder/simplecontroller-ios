import XCTest
@testable import ControllerCore

final class SCX2USBPressureTests: XCTestCase {
    let session = SCX2Token(uuid: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!)
    let boot = SCX2Token(uuid: UUID(uuidString: "10213243-5465-7687-98a9-bacbdcedfe0f")!)
    let challenge = SCX2Token(uuid: UUID(uuidString: "ffeeddcc-bbaa-9988-7766-554433221100")!)
    func ready(_ token: SCX2Token, available: Bool = true) -> SCX2Packet {
        .init(kind: .ready, session: token, boot: boot, challenge: available ? challenge : .zero,
              hidReady: available, revision: .usbPressure, usbPressureCapability: available)
    }
    func testExplicitModeAndCapability() throws {
        let hello = SCX2Packet(kind: .hello, session: session, revision: .usbPressure, usbPressureCapability: true)
        let data = try SCX2Codec.encode(hello)
        XCTAssertEqual(data.count, 64)
        XCTAssertEqual(Array(data.prefix(8)), [83, 67, 88, 50, 5, 1, 0, 4])
        XCTAssertEqual(try SCX2Codec.decode(data), hello)
        for flag: UInt8 in [0, 1, 2, 3, 5, 6, 7, 255] {
            var bad = data; bad[7] = flag
            XCTAssertThrowsError(try SCX2Codec.decode(bad))
        }
        for revision: UInt8 in [2, 3, 4] {
            var bad = data; bad[4] = revision
            XCTAssertThrowsError(try SCX2Codec.decode(bad))
        }
    }
    func testIndependentPressureRetainedWithAllOtherControls() throws {
        for left in [0.0, 0.1, 0.5, 0.7, 1.0] {
            for right in [0.0, 0.1, 0.5, 0.7, 1.0] {
                let output = BridgeOutputState(gamepad: .init(buttons: Set(SCX2Codec.supportedButtons),
                    leftStick: .init(x: 0.5, y: -1), rightStick: .init(x: -0.75, y: 1), dpad: .upRight),
                    leftTrigger: left, rightTrigger: right)
                let p = SCX2Packet(kind: .state, session: session, boot: boot, challenge: challenge,
                    sequence: 2, output: output, revision: .usbPressure)
                let wire = try SCX2Codec.encode(p)
                XCTAssertEqual(wire.count, 80); XCTAssertEqual(wire[7], 0)
                let decoded = try XCTUnwrap(SCX2Codec.decode(wire).output)
                XCTAssertEqual(decoded.leftTrigger, left, accuracy: 1.0/65535)
                XCTAssertEqual(decoded.rightTrigger, right, accuracy: 1.0/65535)
                XCTAssertEqual(decoded.gamepad.buttons, output.gamepad.buttons)
                XCTAssertEqual(decoded.gamepad.dpad, .upRight)
                XCTAssertEqual(decoded.gamepad.rightStick.y, 1)
                var leak = wire; leak[7] = 4
                XCTAssertThrowsError(try SCX2Codec.decode(leak))
            }
        }
    }
    func testWrongRevisionCannotArmAndNeutralMustComplete() throws {
        var c = SCX2ClientMachine(revision: .usbPressure, at: 0)
        XCTAssertTrue(try XCTUnwrap(c.socketDidBecomeReady(at: 0).first).usbPressureCapability)
        for revision in [SCX2Revision.legacy, .pressure, .usbButtons] {
            let old = SCX2Packet(kind: .ready, session: c.session, boot: boot, challenge: challenge,
                hidReady: true, revision: revision, pressureCapability: revision == .pressure,
                usbButtonTriggerCapability: revision == .usbButtons)
            XCTAssertTrue(c.receive(old, at: 0.01).isEmpty)
            XCTAssertFalse(c.controlsEnabled)
        }
        let first = try XCTUnwrap(c.receive(ready(c.session), at: 0.02).first)
        XCTAssertTrue(first.output!.isNeutral); XCTAssertFalse(c.controlsEnabled)
        _ = c.receive(.init(kind: .ack, session: c.session, boot: boot, challenge: challenge,
            sequence: 1, hidReady: true, revision: .usbPressure), at: 0.03)
        XCTAssertTrue(c.controlsEnabled)
        let fire = try XCTUnwrap(c.updateOutput(.init(leftTrigger: 0.5, rightTrigger: 0.7), at: 0.04).first)
        XCTAssertEqual(fire.output?.leftTrigger, 0.5); XCTAssertEqual(fire.output?.rightTrigger, 0.7)
        _ = c.updateOutput(.neutral, at: 0.05)
        XCTAssertEqual(c.queuedCount, 1)
        let stop = try XCTUnwrap(c.stop())
        XCTAssertEqual(stop.revision, .usbPressure); XCTAssertEqual(c.queuedCount, 0)
        XCTAssertTrue(c.currentOutput.isNeutral); XCTAssertFalse(c.controlsEnabled)
    }
    func testUnavailableOrLostUSBPressureDoesNotFallBack() {
        var unavailable = SCX2ClientMachine(revision: .usbPressure, at: 0)
        _ = unavailable.socketDidBecomeReady(at: 0)
        _ = unavailable.receive(ready(unavailable.session, available: false), at: 0.1)
        XCTAssertEqual(unavailable.phase, .stopped(.usbPressureUnavailable))
        var live = SCX2ClientMachine(revision: .usbPressure, at: 0)
        _ = live.socketDidBecomeReady(at: 0)
        _ = live.receive(ready(live.session), at: 0.01)
        _ = live.receive(.init(kind: .ack, session: live.session, boot: boot, challenge: challenge,
            sequence: 1, hidReady: true, revision: .usbPressure), at: 0.02)
        _ = live.updateOutput(.init(leftTrigger: 0.5, rightTrigger: 0.7), at: 0.03)
        XCTAssertEqual(live.tick(at: 0.8).first?.kind, .stop)
        XCTAssertTrue(live.currentOutput.isNeutral)
        XCTAssertEqual(live.phase, .stopped(.acknowledgmentTimeout))
    }
    func testSharedCppUSBPressureGoldenVectors() throws {
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
        let fixtures = try JSONDecoder().decode(File.self, from: Data(contentsOf: url.appendingPathComponent("bridge/fixtures/scx2-usb-pressure-wire.json"))).vectors
        XCTAssertEqual(fixtures.count, 10)
        let hats: [DPadDirection] = [.up, .upRight, .right, .downRight, .down, .downLeft, .left, .upLeft, .neutral]
        for fixture in fixtures {
            let wire = Data(bytes(fixture.hex))
            let decoded = try SCX2Codec.decode(wire)
            XCTAssertEqual(decoded.revision.rawValue, fixture.format, fixture.name)
            XCTAssertEqual(decoded.usbPressureCapability, fixture.capabilities == 4, fixture.name)
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

}

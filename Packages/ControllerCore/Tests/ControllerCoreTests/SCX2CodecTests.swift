import Foundation
import XCTest
@testable import ControllerCore

final class SCX2CodecTests: XCTestCase {
    private struct Fixture: Decodable {
        var name: String; var kind: UInt8; var session: String; var boot: String; var challenge: String
        var sequenceDecimal: String; var hidReady: Bool; var hex: String; var state: WireState?
        struct WireState: Decodable { var buttonMask: UInt16; var hat: UInt8; var axes: [Int16] }
    }
    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
    private func fixtureURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("bridge/fixtures/scx2-wire.json")
    }
    private func packet() -> SCX2Packet {
        .init(kind: .state, session: .init(uuid: UUID()), boot: .init(bytes: Array(repeating: 1, count: 16)),
              challenge: .init(bytes: Array(repeating: 2, count: 16)), sequence: 1, state: .neutral)
    }

    func testAllCppGoldenVectorsDecodeAndReencodeExactly() throws {
        struct File: Decodable { var vectors: [Fixture] }
        let fixtures = try JSONDecoder().decode(File.self, from: Data(contentsOf: fixtureURL())).vectors
        XCTAssertEqual(fixtures.count, 8)
        let hats: [DPadDirection] = [.up, .upRight, .right, .downRight, .down, .downLeft, .left, .upLeft, .neutral]
        for fixture in fixtures {
            let wire = Data(bytes(fixture.hex))
            let decoded = try SCX2Codec.decode(wire)
            XCTAssertEqual(decoded.kind.rawValue, fixture.kind, fixture.name)
            XCTAssertEqual(decoded.session.bytes, bytes(fixture.session), fixture.name)
            XCTAssertEqual(decoded.boot.bytes, bytes(fixture.boot), fixture.name)
            XCTAssertEqual(decoded.challenge.bytes, bytes(fixture.challenge), fixture.name)
            XCTAssertEqual(decoded.sequence, UInt64(fixture.sequenceDecimal), fixture.name)
            XCTAssertEqual(decoded.hidReady, fixture.hidReady, fixture.name)
            if let expected = fixture.state, let state = decoded.state {
                let expectedButtons = Set(SCX2Codec.supportedButtons.enumerated().compactMap { index, button in
                    expected.buttonMask & (1 << index) != 0 ? button : nil
                })
                XCTAssertEqual(state.buttons, expectedButtons, fixture.name)
                XCTAssertEqual(state.dpad, hats[Int(expected.hat)], fixture.name)
                XCTAssertEqual([state.leftStick.x, state.leftStick.y, state.rightStick.x, state.rightStick.y],
                               expected.axes.map { Double($0) / 32767 }, fixture.name)
            } else { XCTAssertNil(decoded.state, fixture.name) }
            XCTAssertEqual(try SCX2Codec.encode(decoded), wire, fixture.name)
        }
    }

    func testUUIDUsesCanonicalBytes() throws {
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
        XCTAssertEqual(SCX2Token(uuid: uuid).bytes, bytes("00112233445566778899aabbccddeeff"))
    }

    func testStrictSizeHeaderReservedFlagsAndRanges() throws {
        let valid = try SCX2Codec.encode(packet())
        XCTAssertThrowsError(try SCX2Codec.decode(valid.dropLast()))
        XCTAssertThrowsError(try SCX2Codec.decode(valid + Data([0])))
        for (offset, replacement) in [(0, 0), (4, 3), (5, 7), (6, 2), (7, 1), (64, 0xfc), (66, 9), (67, 1)] {
            var invalid = valid; invalid[offset] = UInt8(replacement)
            XCTAssertThrowsError(try SCX2Codec.decode(invalid), "byte \(offset)")
        }
        for offset in [68, 70, 72, 74] {
            var invalid = valid; invalid[offset] = 0x80; invalid[offset + 1] = 0
            XCTAssertThrowsError(try SCX2Codec.decode(invalid))
        }
        var zeroSession = valid
        zeroSession.replaceSubrange(8..<24, with: Array(repeating: 0, count: 16))
        XCTAssertThrowsError(try SCX2Codec.decode(zeroSession))
    }

    func testUnsupportedOutputsAndNonfiniteAxesCannotEncode() {
        for button in [PadButton.leftTrigger, .rightTrigger, .guide, .share] {
            var invalid = packet(); invalid.state = .init(buttons: [button])
            XCTAssertThrowsError(try SCX2Codec.encode(invalid))
        }
        for value in [Double.nan, .infinity, -.infinity, 1.01, -1.01] {
            var invalid = packet(); invalid.state = .init(leftStick: .init(x: value))
            XCTAssertThrowsError(try SCX2Codec.encode(invalid))
        }
    }

    func testSequenceBoundsReserveFinalValueForStopOnly() throws {
        var value = packet(); value.sequence = UInt64.max
        XCTAssertThrowsError(try SCX2Codec.encode(value))
        value.kind = .ack; value.hidReady = true; value.state = nil
        XCTAssertThrowsError(try SCX2Codec.encode(value))
        value.kind = .stop; value.hidReady = false
        XCTAssertEqual(try SCX2Codec.decode(SCX2Codec.encode(value)).sequence, UInt64.max)
        value.sequence = 0
        XCTAssertThrowsError(try SCX2Codec.encode(value))
    }

    func testAxisQuantizationAndEverySupportedHatButton() throws {
        for direction in DPadDirection.allCases {
            var value = packet()
            value.state = .init(buttons: Set(SCX2Codec.supportedButtons),
                                leftStick: .init(x: 1, y: -1), rightStick: .init(x: 0.5, y: -0.5), dpad: direction)
            let decoded = try SCX2Codec.decode(SCX2Codec.encode(value)).state!
            XCTAssertEqual(decoded.buttons, Set(SCX2Codec.supportedButtons))
            XCTAssertEqual(decoded.dpad, direction)
            XCTAssertEqual(decoded.leftStick, .init(x: 1, y: -1))
            XCTAssertEqual(decoded.rightStick.x, 16384.0 / 32767)
            XCTAssertEqual(decoded.rightStick.y, -16384.0 / 32767)
        }
    }
}

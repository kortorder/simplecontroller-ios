import XCTest
@testable import ControllerCore

final class SCX2RecoveryHandshakeTests: XCTestCase {
    func testAutomaticAvailabilityWaitRetainsOriginalDeadlineAndNeutralAckGate() {
        for revision: SCX2Revision in [.legacy, .pressure] {
            var machine = SCX2ClientMachine(revision: revision, at: 0, waitForAvailability: true)
            let hello = machine.socketDidBecomeReady(at: 0).first!
            let boot = SCX2Token(bytes: Array(repeating: 1, count: 16))
            let unavailable = SCX2Packet(kind: .ready, session: hello.session, boot: boot, revision: revision)
            XCTAssertTrue(machine.receive(unavailable, at: 0.1).isEmpty)
            XCTAssertEqual(machine.phase, .connecting)
            XCTAssertEqual(machine.tick(at: 0.25).first?.session, hello.session)
            XCTAssertTrue(machine.updateOutput(.init(gamepad: .init(buttons: [.a])), at: 0.3).isEmpty)
            let ready = SCX2Packet(kind: .ready, session: hello.session, boot: boot,
                challenge: .init(bytes: Array(repeating: 2, count: 16)), hidReady: true,
                revision: revision, pressureCapability: revision == .pressure)
            let neutral = machine.receive(ready, at: 0.4).first!
            XCTAssertEqual(neutral.sequence, 1); XCTAssertEqual(neutral.output, .neutral)
            XCTAssertFalse(machine.controlsEnabled)
            _ = machine.receive(.init(kind: .ack, session: neutral.session, boot: neutral.boot,
                challenge: neutral.challenge, sequence: 1, hidReady: true, revision: revision), at: 0.5)
            XCTAssertTrue(machine.controlsEnabled); XCTAssertEqual(machine.currentOutput, .neutral)
        }
    }
    func testUnreadyRepliesCannotExtendAutomaticThreeSecondBound() {
        var machine = SCX2ClientMachine(at: 0, waitForAvailability: true)
        _ = machine.socketDidBecomeReady(at: 0)
        let reply = SCX2Packet(kind: .ready, session: machine.session,
                              boot: .init(bytes: Array(repeating: 1, count: 16)))
        _ = machine.receive(reply, at: 2.99)
        _ = machine.receive(reply, at: 3)
        XCTAssertEqual(machine.phase, .stopped(.helloTimeout))
        XCTAssertEqual(machine.currentOutput, .neutral)
    }
    func testManualUnavailableReplyStillFailsAndAutomaticWrongRevisionCannotArm() {
        var manual = SCX2ClientMachine(at: 0)
        _ = manual.receive(.init(kind: .ready, session: manual.session,
            boot: .init(bytes: Array(repeating: 1, count: 16))), at: 0)
        XCTAssertEqual(manual.phase, .stopped(.usbUnavailable))
        var automatic = SCX2ClientMachine(revision: .pressure, at: 0, waitForAvailability: true)
        let wrong = SCX2Packet(kind: .ready, session: automatic.session,
            boot: .init(bytes: Array(repeating: 1, count: 16)),
            challenge: .init(bytes: Array(repeating: 2, count: 16)), hidReady: true)
        XCTAssertTrue(automatic.receive(wrong, at: 0).isEmpty)
        XCTAssertEqual(automatic.phase, .connecting)
        _ = automatic.tick(at: 3)
        XCTAssertEqual(automatic.phase, .stopped(.helloTimeout))
    }
    func testAutomaticWaitDoesNotIgnoreUnavailableAfterUsableOffer() {
        var machine = SCX2ClientMachine(at: 0, waitForAvailability: true)
        let boot = SCX2Token(bytes: Array(repeating: 1, count: 16))
        _ = machine.receive(.init(kind: .ready, session: machine.session, boot: boot,
            challenge: .init(bytes: Array(repeating: 2, count: 16)), hidReady: true), at: 0)
        _ = machine.receive(.init(kind: .ready, session: machine.session, boot: boot), at: 0.1)
        XCTAssertEqual(machine.phase, .stopped(.usbUnavailable))
        XCTAssertFalse(machine.controlsEnabled)
    }
}

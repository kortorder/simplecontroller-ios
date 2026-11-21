import Foundation
import XCTest
@testable import ControllerCore

final class SCX2ClientMachineTests: XCTestCase {
    private let boot = SCX2Token(bytes: Array(repeating: 1, count: 16))
    private let challenge = SCX2Token(bytes: Array(repeating: 2, count: 16))
    private func offer(_ machine: SCX2ClientMachine) -> SCX2Packet {
        .init(kind: .ready, session: machine.session, boot: boot, challenge: challenge, hidReady: true)
    }
    private func ack(_ state: SCX2Packet) -> SCX2Packet {
        .init(kind: .ack, session: state.session, boot: state.boot, challenge: state.challenge,
              sequence: state.sequence, hidReady: true)
    }
    private func armed() -> SCX2ClientMachine {
        var machine = SCX2ClientMachine(at: 0)
        _ = machine.socketDidBecomeReady(at: 0)
        let neutral = machine.receive(offer(machine), at: 0).first!
        _ = machine.receive(ack(neutral), at: 0)
        return machine
    }

    func testNeutralUsbAckIsRequiredBeforeAnyInput() {
        var machine = SCX2ClientMachine(at: 0)
        XCTAssertEqual(machine.socketDidBecomeReady(at: 0).first?.kind, .hello)
        XCTAssertFalse(machine.controlsEnabled)
        XCTAssertTrue(machine.update(.init(buttons: [.a]), at: 0).isEmpty)
        let neutral = machine.receive(offer(machine), at: 0).first!
        XCTAssertEqual(neutral.sequence, 1); XCTAssertTrue(neutral.state!.isNeutral)
        XCTAssertFalse(machine.controlsEnabled)
        XCTAssertTrue(machine.update(.init(buttons: [.b]), at: 0).isEmpty)
        _ = machine.receive(ack(neutral), at: 0)
        XCTAssertTrue(machine.controlsEnabled); XCTAssertTrue(machine.currentState.isNeutral)
    }

    func testPressAndReleaseRemainOrderedAcrossDelayedAck() {
        var machine = armed()
        let down = machine.update(.init(buttons: [.a]), at: 0).first!
        XCTAssertTrue(machine.update(.neutral, at: 0.01).isEmpty)
        XCTAssertEqual(machine.queuedCount, 1)
        let retry = machine.tick(at: 0.11).first!
        XCTAssertEqual(retry, down)
        let up = machine.receive(ack(down), at: 0.12).first!
        XCTAssertTrue(up.state!.isNeutral); XCTAssertEqual(up.sequence, down.sequence + 1)
        XCTAssertTrue(machine.receive(ack(down), at: 0.13).isEmpty)
        XCTAssertEqual(machine.acknowledgedPackets, 2)
        _ = machine.receive(ack(up), at: 0.14)
        XCTAssertEqual(machine.acknowledgedPackets, 3)
    }

    func testWrongTokensAndUnsentAckDoNotArmOrRenew() {
        var machine = SCX2ClientMachine(at: 0)
        let neutral = machine.receive(offer(machine), at: 0).first!
        var wrong = ack(neutral); wrong.boot = .init(bytes: Array(repeating: 9, count: 16))
        _ = machine.receive(wrong, at: 0.6)
        wrong = ack(neutral); wrong.challenge = .init(bytes: Array(repeating: 9, count: 16))
        _ = machine.receive(wrong, at: 0.6)
        wrong = ack(neutral); wrong.session = .init(uuid: UUID())
        _ = machine.receive(wrong, at: 0.6)
        wrong = ack(neutral); wrong.sequence = 2
        _ = machine.receive(wrong, at: 0.6)
        XCTAssertFalse(machine.controlsEnabled)
        XCTAssertEqual(machine.tick(at: 0.75).first?.kind, .stop)
        XCTAssertEqual(machine.phase, .stopped(.neutralTimeout))
    }

    func testDuplicateAckAndHelloCannotExtendReadyLease() {
        var machine = armed()
        let heartbeat = machine.tick(at: 0.1).first!
        _ = machine.receive(ack(heartbeat), at: 0.2)
        _ = machine.receive(offer(machine), at: 0.8)
        _ = machine.receive(ack(heartbeat), at: 0.8)
        _ = machine.tick(at: 1)
        XCTAssertEqual(machine.phase, .stopped(.acknowledgmentTimeout))
    }

    func testOverflowStopsInsteadOfCoalescingTransitions() {
        var machine = armed()
        _ = machine.update(.init(buttons: [.a]), at: 0)
        for index in 0..<16 {
            XCTAssertTrue(machine.update(.init(buttons: [index % 2 == 0 ? .b : .a]), at: 0).isEmpty)
        }
        XCTAssertEqual(machine.queuedCount, 16)
        let output = machine.update(.init(buttons: [.b]), at: 0)
        XCTAssertEqual(output.first?.kind, .stop)
        XCTAssertEqual(machine.phase, .stopped(.queueOverflow))
        XCTAssertEqual(machine.queuedCount, 0); XCTAssertTrue(machine.currentState.isNeutral)
    }

    func testStopDropsQueuedPressesAndCannotBeRevived() {
        var machine = armed()
        let down = machine.update(.init(buttons: [.a]), at: 0).first!
        _ = machine.update(.init(buttons: [.b]), at: 0)
        let stop = machine.stop()!
        XCTAssertGreaterThan(stop.sequence, down.sequence)
        XCTAssertEqual(machine.queuedCount, 0)
        XCTAssertTrue(machine.receive(ack(down), at: 0).isEmpty)
        XCTAssertTrue(machine.tick(at: 10).isEmpty)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testExpiredOrBackwardTimeWinsBeforeInputOrReply() {
        var machine = armed()
        let output = machine.update(.init(buttons: [.a]), at: 0.75)
        XCTAssertEqual(output.first?.kind, .stop)
        XCTAssertEqual(machine.phase, .stopped(.acknowledgmentTimeout))
        machine = armed()
        let down = machine.update(.init(buttons: [.a]), at: 0.5).first!
        _ = machine.receive(ack(down), at: 0.4)
        XCTAssertEqual(machine.phase, .stopped(.invalidTime))
        XCTAssertTrue(machine.currentState.isNeutral)
    }

    func testMalformedPacketStillAdvancesDeadline() {
        var machine = armed()
        var invalid = offer(machine); invalid.session = .zero
        _ = machine.receive(invalid, at: 0.75)
        XCTAssertEqual(machine.phase, .stopped(.acknowledgmentTimeout))
    }

    func testNewBootOrUnavailableUsbRequiresNewSession() {
        var machine = armed()
        var changed = offer(machine); changed.boot = .init(bytes: Array(repeating: 9, count: 16))
        XCTAssertEqual(machine.receive(changed, at: 0).first?.kind, .stop)
        XCTAssertEqual(machine.phase, .stopped(.bridgeChanged))
        machine = armed()
        var unavailable = offer(machine); unavailable.hidReady = false; unavailable.challenge = .zero
        _ = machine.receive(unavailable, at: 0)
        XCTAssertEqual(machine.phase, .stopped(.usbUnavailable))
    }

    func testHelloRetriesAndThreeSecondLimit() {
        var machine = SCX2ClientMachine(at: 0)
        XCTAssertTrue(machine.tick(at: 0).isEmpty)
        let first = machine.socketDidBecomeReady(at: 0).first!
        XCTAssertTrue(machine.tick(at: 0.24).isEmpty)
        XCTAssertEqual(machine.tick(at: 0.25), [first])
        _ = machine.receive(offer(machine), at: 3)
        XCTAssertEqual(machine.phase, .stopped(.helloTimeout))
    }

    func testInvalidInitialClockAndUnsupportedStateStayNeutral() {
        for now in [Double.nan, .infinity, -1, .greatestFiniteMagnitude] {
            XCTAssertEqual(SCX2ClientMachine(at: now).phase, .stopped(.invalidTime))
        }
        var machine = armed()
        _ = machine.update(.init(buttons: [.rightTrigger]), at: 0)
        XCTAssertEqual(machine.phase, .stopped(.invalidState))
        XCTAssertTrue(machine.currentState.isNeutral)
    }
}

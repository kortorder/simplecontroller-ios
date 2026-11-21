import Foundation
import XCTest
@testable import ControllerCore

final class BridgeSafetyMachineTests: XCTestCase {
    private let session = "73BAFB0B-4B19-48B7-8067-724643716450"
    private let otherSession = "F1862F1D-2A08-489B-96DC-D5A0C45C9505"
    private let held = GamepadState(buttons: [.a], leftStick: .init(x: 1))

    func testStartsNeutralAndRejectsOutputBeforeHandshake() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        XCTAssertTrue(bridge.output.isNeutral)
        XCTAssertNil(bridge.activeSession)
        XCTAssertNil(try bridge.receive(state(1, held), at: 0))
        XCTAssertTrue(bridge.output.isNeutral)
    }

    func testHandshakeAcknowledgesSimulatorWithoutClaimingHID() throws {
        var bridge = BridgeSafetyMachine()
        let response = try XCTUnwrap(bridge.receive(hello(), at: 0))
        XCTAssertEqual(response.kind, .ready)
        XCTAssertEqual(response.sequence, 0)
        XCTAssertEqual(response.hidReady, false)
        XCTAssertEqual(bridge.activeSession, session)
        XCTAssertEqual(bridge.deadline, 1)
    }

    func testUnavailableHIDRejectsStateWithoutRenewingLease() throws {
        var bridge = BridgeSafetyMachine(hidReady: false)
        XCTAssertEqual(try bridge.receive(hello(), at: 0)?.hidReady, false)
        XCTAssertNil(try bridge.receive(state(1, held), at: 0.1))
        XCTAssertNil(try bridge.receive(state(2, .neutral), at: 0.9))
        XCTAssertTrue(bridge.output.isNeutral)
        XCTAssertEqual(bridge.lastSequence, 0)
        XCTAssertEqual(bridge.deadline, 1)
        XCTAssertTrue(try bridge.expire(at: 1))
        XCTAssertNil(try bridge.receive(state(3, held), at: 1.1))
        XCTAssertTrue(bridge.output.isNeutral)
        XCTAssertNil(bridge.activeSession)
    }

    func testNewFullStateReplacesPreviousOutputsAndRenewsLease() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        let response = try bridge.receive(state(1, held), at: 0.5)
        XCTAssertEqual(response?.hidReady, true)
        XCTAssertEqual(bridge.output, held)
        XCTAssertEqual(bridge.deadline, 1.5)
        _ = try bridge.receive(state(2, .neutral), at: 1)
        XCTAssertTrue(bridge.output.isNeutral)
        XCTAssertEqual(bridge.lastSequence, 2)
    }

    func testReorderedHeldPacketCannotUndoNewerRelease() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(3, .neutral), at: 0.1)
        XCTAssertNil(try bridge.receive(state(2, held), at: 0.2))
        XCTAssertTrue(bridge.output.isNeutral)
        XCTAssertEqual(bridge.deadline, 1.1)
    }

    func testDuplicateStateDoesNotChangeOutputOrExtendLease() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1, held), at: 0.1)
        let response = try bridge.receive(state(1, .neutral), at: 0.8)
        XCTAssertEqual(response?.kind, .ack)
        XCTAssertEqual(bridge.output, held)
        XCTAssertEqual(bridge.deadline, 1.1)
        XCTAssertTrue(try bridge.expire(at: 1.1))
        XCTAssertTrue(bridge.output.isNeutral)
    }

    func testDuplicateHelloPreservesHeldStateAndDoesNotRenewLease() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1, held), at: 0.1)
        XCTAssertEqual(try bridge.receive(hello(), at: 0.9)?.kind, .ready)
        XCTAssertEqual(bridge.output, held)
        XCTAssertEqual(bridge.lastSequence, 1)
        XCTAssertEqual(bridge.deadline, 1.1)
    }

    func testCompetingSessionCannotTakeOverOrStopLiveOutput() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1, held), at: 0.1)
        XCTAssertNil(try bridge.receive(hello(otherSession), at: 0.2))
        XCTAssertNil(try bridge.receive(state(99, .neutral, otherSession), at: 0.3))
        XCTAssertNil(try bridge.receive(stop(100, otherSession), at: 0.4))
        XCTAssertEqual(bridge.activeSession, session)
        XCTAssertEqual(bridge.output, held)
        XCTAssertEqual(bridge.deadline, 1.1)
    }

    func testDeadlineExpiresAtBoundaryAndRetiresUUID() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1, held), at: 0.1)
        XCTAssertFalse(try bridge.expire(at: 1.099))
        XCTAssertTrue(try bridge.expire(at: 1.1))
        XCTAssertNil(bridge.activeSession)
        XCTAssertTrue(bridge.output.isNeutral)
        XCTAssertNil(try bridge.receive(state(2, held), at: 1.2))
        XCTAssertNil(try bridge.receive(hello(), at: 1.3))
        XCTAssertNotNil(try bridge.receive(hello(otherSession), at: 1.4))
        XCTAssertNil(try bridge.receive(state(999, held), at: 1.5))
        XCTAssertTrue(bridge.output.isNeutral)
    }

    func testStateArrivingAtDeadlineCannotRefreshExpiredSession() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        XCTAssertNil(try bridge.receive(state(1, held), at: 1))
        XCTAssertTrue(bridge.output.isNeutral)
        XCTAssertNil(bridge.activeSession)
    }

    func testStopNeutralizesAndDelayedTrafficCannotRevive() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1, held), at: 0.1)
        XCTAssertEqual(try bridge.receive(stop(2), at: 0.2)?.kind, .stopped)
        XCTAssertTrue(bridge.output.isNeutral)
        XCTAssertNil(bridge.activeSession)
        XCTAssertNil(try bridge.receive(state(3, held), at: 0.3))
        XCTAssertNil(try bridge.receive(hello(), at: 0.4))
        XCTAssertEqual(try bridge.receive(stop(2), at: 0.5)?.kind, .stopped)
    }

    func testStaleStopCannotCancelNewerInput() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(3, held), at: 0.1)
        XCTAssertNil(try bridge.receive(stop(2), at: 0.2))
        XCTAssertNil(try bridge.receive(stop(3), at: 0.3))
        XCTAssertEqual(bridge.output, held)
        XCTAssertEqual(bridge.deadline, 1.1)
    }

    func testDroppedStopStillExpiresOutput() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1, held), at: 0.1)
        // No stop packet is delivered.
        XCTAssertTrue(try bridge.expire(at: 1.2))
        XCTAssertTrue(bridge.output.isNeutral)
    }

    func testEquivalentUUIDLetterCaseCannotBypassRetirement() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(stop(1), at: 0.1)
        XCTAssertNil(try bridge.receive(hello(session.lowercased()), at: 0.2))
    }

    func testRepliesCannotAffectOutputOrKeepItAlive() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1, held), at: 0.1)
        let reply = BridgePacket(kind: .ack, session: session, sequence: 100, hidReady: true)
        XCTAssertNil(try bridge.receive(reply, at: 0.8))
        XCTAssertEqual(bridge.output, held)
        XCTAssertEqual(bridge.deadline, 1.1)
    }

    func testInvalidStateDoesNotMutateLiveOutput() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 0)
        _ = try bridge.receive(state(1, held), at: 0.1)
        let invalid = GamepadState(leftStick: .init(x: .nan))
        XCTAssertThrowsError(try bridge.receive(state(2, invalid), at: 0.9))
        XCTAssertEqual(bridge.output, held)
        XCTAssertEqual(bridge.deadline, 1.1)
    }

    func testNonMonotonicAndNonfiniteTimesAreRejected() throws {
        var bridge = BridgeSafetyMachine(hidReady: true)
        _ = try bridge.receive(hello(), at: 1)
        for time in [0.9, -1, .nan, .infinity] {
            XCTAssertThrowsError(try bridge.expire(at: time)) { error in
                XCTAssertEqual(error as? BridgeSafetyError, .invalidTime)
            }
        }
        XCTAssertEqual(bridge.deadline, 2)
        XCTAssertTrue(try bridge.expire(at: 2))
    }

    private func hello(_ id: String? = nil) -> BridgePacket {
        BridgePacket(kind: .hello, session: id ?? session, sequence: 0)
    }

    private func state(_ sequence: UInt64, _ state: GamepadState, _ id: String? = nil) -> BridgePacket {
        BridgePacket(kind: .state, session: id ?? session, sequence: sequence, state: state)
    }

    private func stop(_ sequence: UInt64, _ id: String? = nil) -> BridgePacket {
        BridgePacket(kind: .stop, session: id ?? session, sequence: sequence)
    }
}

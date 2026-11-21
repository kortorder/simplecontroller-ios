import XCTest
@testable import ControllerCore

final class WindowsPCProtocolTests: XCTestCase {
    let token = UUID().uuidString
    func ready(_ machine: inout WindowsPCClientMachine) throws {
        let hello = machine.socketDidBecomeReady(at: 0)
        XCTAssertEqual(hello.first?.kind, .hello)
        let initial = machine.receive(.init(kind: .ready, session: machine.session, token: token), at: 0.01)
        XCTAssertEqual(initial.first?.output, .neutral)
        XCTAssertFalse(machine.controlsEnabled)
        let response = WindowsPCPacket(kind: .ack, session: machine.session, sequence: 1, token: token)
        XCTAssertEqual(machine.receive(response, at: 0.02), [])
        XCTAssertTrue(machine.controlsEnabled)
    }
    func testNeutralHandshakeAndCompleteDesktopRoundTrip() throws {
        var machine = WindowsPCClientMachine(at: 0)
        try ready(&machine)
        let desktop = PracticeOutputState(heldKeys: [.w,.leftControl], heldMouseButtons: [.left], pointerOffset: .init(dx: 2.5,dy: -3), scrollOffset: 40)
        let output = WindowsPCOutput(gamepad: .init(buttons: [.a],leftStick:.init(x:0.2,y:0.3),rightStick:.init(x:-0.8,y:1),dpad:.downLeft),leftTrigger:0.5,rightTrigger:0.7,desktop:desktop)
        let packet = try XCTUnwrap(machine.update(output,at:0.03).first)
        XCTAssertEqual(packet.kind,.state); XCTAssertEqual(packet.sequence,2)
        XCTAssertEqual(try WindowsPCCodec.decode(WindowsPCCodec.encode(packet)),packet)
        XCTAssertEqual(packet.output?.keys,["LCTRL","W"])
        XCTAssertEqual(packet.output?.pointer,[2.5,-3])
    }
    func testQueuedPulseKeepsPressBeforeReleaseAndRetriesSameIdentity() throws {
        var machine=WindowsPCClientMachine(at:0);try ready(&machine)
        let held=WindowsPCOutput(gamepad:.init(buttons:[.a]),rightTrigger:1)
        let press=try XCTUnwrap(machine.update(held,at:0.03).first)
        XCTAssertEqual(machine.update(.neutral,at:0.04),[])
        XCTAssertEqual(machine.tick(at:0.09),[press])
        let next=try XCTUnwrap(machine.receive(.init(kind:.ack,session:machine.session,sequence:press.sequence,token:token),at:0.1).first)
        XCTAssertEqual(next.output,.neutral);XCTAssertEqual(next.sequence,3)
        XCTAssertEqual(machine.receive(.init(kind:.ack,session:machine.session,sequence:2,token:token),at:0.11),[])
    }
    func testOldAckAndHelloNeverExtendLiveness() throws {
        var machine=WindowsPCClientMachine(at:0);try ready(&machine)
        _=machine.tick(at:0.1)
        _=machine.receive(.init(kind:.ack,session:machine.session,sequence:1,token:token),at:0.3)
        _=machine.receive(.init(kind:.ready,session:machine.session,token:token),at:0.39)
        let packets=machine.tick(at:0.421)
        XCTAssertEqual(packets.last?.kind,.stop);XCTAssertFalse(machine.controlsEnabled)
        XCTAssertEqual(machine.update(.neutral,at:0.43),[])
    }
    func testLateMatchingAckCannotRearm() throws {
        var machine=WindowsPCClientMachine(at:0);try ready(&machine)
        let packet=try XCTUnwrap(machine.tick(at:0.1).first)
        let returned=machine.receive(.init(kind:.ack,session:machine.session,sequence:packet.sequence,token:token),at:0.421)
        XCTAssertEqual(returned.last?.kind,.stop);XCTAssertFalse(machine.controlsEnabled)
    }
    func testStopDiscardsPendingInputs() throws {
        var machine=WindowsPCClientMachine(at:0);try ready(&machine)
        _=machine.update(.init(rightTrigger:1),at:0.03)
        _=machine.update(.init(leftTrigger:1),at:0.04)
        XCTAssertEqual(machine.stop()?.kind,.stop)
        XCTAssertEqual(machine.tick(at:0.05),[])
        XCTAssertEqual(machine.phase,.idle)
    }
    func testInvalidDesktopValuesAndUnsupportedButtonsFailClosed() throws {
        for output in [WindowsPCOutput(gamepad:.init(buttons:[.guide])),WindowsPCOutput(leftTrigger:1.1),WindowsPCOutput(desktop:.init(pointerOffset:.init(dx:.nan,dy:0)))] {
            var machine=WindowsPCClientMachine(at:0);try ready(&machine)
            XCTAssertEqual(machine.update(output,at:0.03).last?.kind,.stop)
            XCTAssertFalse(machine.controlsEnabled)
        }
    }
    func testReceiverRestartAndWrongToken() throws {
        var machine=WindowsPCClientMachine(at:0);try ready(&machine)
        let packet=try XCTUnwrap(machine.tick(at:0.1).first)
        XCTAssertEqual(machine.receive(.init(kind:.ack,session:machine.session,sequence:packet.sequence,token:UUID().uuidString),at:0.11),[])
        XCTAssertEqual(machine.receive(.init(kind:.ready,session:machine.session,token:UUID().uuidString),at:0.12).last?.kind,.stop)
    }
    func testQueueLimitAndInvalidClock() throws {
        var machine=WindowsPCClientMachine(at:0);try ready(&machine)
        for i in 0...131 { _=machine.update(.init(rightTrigger:Double(i%2)),at:0.03+Double(i)/10000) }
        XCTAssertFalse(machine.controlsEnabled)
        var clock=WindowsPCClientMachine(at:1)
        _=clock.tick(at:0.5)
        if case .stopped=clock.phase {} else { XCTFail("Backwards clock did not stop") }
    }
    func testOnlyCurrentHandshakeCanArmAndDefaultPortIsDistinct() throws {
        var machine=WindowsPCClientMachine(at:0)
        XCTAssertEqual(machine.receive(.init(kind:.ready,session:UUID().uuidString,token:token),at:0.1),[])
        XCTAssertFalse(machine.controlsEnabled)
        _=machine.tick(at:3)
        if case .stopped=machine.phase {} else { XCTFail("Missing receiver did not stop") }
        XCTAssertEqual(BridgeProtocolVersion.windowsPC.defaultPort,42734)
        XCTAssertEqual(BridgeProtocolVersion.scx2.defaultPort,42736)
    }
    func testCodecRejectsInvalidIdentitiesAndHugeData() throws {
        XCTAssertThrowsError(try WindowsPCCodec.encode(.init(kind:.hello,session:"not-a-session")))
        XCTAssertThrowsError(try WindowsPCCodec.decode(Data(repeating:32,count:8193)))
        var bad=WindowsPCPacket(kind:.hello,session:UUID().uuidString);bad.protocolVersion="SCX2"
        XCTAssertThrowsError(try WindowsPCCodec.encode(bad))
    }
}

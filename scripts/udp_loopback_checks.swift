import Foundation

private enum CheckFailure: Error { case failed(String) }
private final class LoopbackPeer {
    let process = Process(), input = Pipe(), output = Pipe()
    let port: UInt16
    init(path: String) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.standardInput = input; process.standardOutput = output
        try process.run()
        let greeting = try Self.line(output.fileHandleForReading)
        guard greeting.hasPrefix("PORT "), let value = UInt16(greeting.dropFirst(5)), value > 0 else { throw CheckFailure.failed("No loopback peer port") }
        port = value
    }
    deinit { if process.isRunning { process.terminate() } }
    static func line(_ handle: FileHandle) throws -> String {
        var data = Data()
        while data.count < 4096 {
            let value = handle.readData(ofLength: 1)
            guard !value.isEmpty else { throw CheckFailure.failed("Peer closed before replying") }
            if value[0] == 10 { return String(decoding: data, as: UTF8.self) }
            data.append(value)
        }
        throw CheckFailure.failed("Peer response exceeded bound")
    }
    func call(_ command: String) throws -> String {
        try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        return try Self.line(output.fileHandleForReading)
    }
    func status() throws -> [Int] { try call("status").split(separator: " ").compactMap { Int($0) } }
    func finish() throws { _ = try call("quit"); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CheckFailure.failed("Peer failed") } }
}

@MainActor private final class ActualUDPClient {
    let transport = UDPBridgeTransport()
    var machine = SCX2ClientMachine(at: ProcessInfo.processInfo.systemUptime)
    var sent: [SCX2Packet] = [], received: [SCX2Packet] = []
    var callbacks = 0, socketReady = false, failure: String?
    var now: Double { ProcessInfo.processInfo.systemUptime }
    init() {
        transport.onReady = { [weak self] in
            guard let self else { return }; self.socketReady = true
            self.send(self.machine.socketDidBecomeReady(at: self.now))
        }
        transport.onMessage = { [weak self] data in
            guard let self else { return }; self.callbacks += 1
            guard let packet = try? SCX2Codec.decode(data) else { return }
            self.received.append(packet); self.send(self.machine.receive(packet, at: self.now))
        }
        transport.onFailure = { [weak self] error in self?.failure = error }
    }
    func open(_ port: UInt16) { machine = .init(at: now); sent = []; received = []; socketReady = false; failure = nil; transport.open(host: "127.0.0.1", port: port) }
    func send(_ packets: [SCX2Packet]) { for packet in packets { sent.append(packet); transport.send(try! SCX2Codec.encode(packet)) } }
    func update(_ state: GamepadState) { send(machine.update(state, at: now)) }
    func tick() { send(machine.tick(at: now)) }
    func stop() { let stop = machine.stop(); transport.close(afterSending: stop.flatMap { try? SCX2Codec.encode($0) }) }
}

@main struct UDPBridgeLoopbackChecks {
    @MainActor static func main() async throws {
        let peer = try LoopbackPeer(path: CommandLine.arguments[1]), client = ActualUDPClient()
        var checks = 0
        func require(_ ok: Bool, _ message: String) throws { guard ok else { throw CheckFailure.failed(message) }; checks += 1 }
        func eventually(_ message: String, timeout: Double = 2, ticking: Bool = true, _ predicate: () throws -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < end {
                if try predicate() { return }
                if ticking { client.tick() }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CheckFailure.failed(message)
        }
        func hex(_ packet: SCX2Packet) throws -> String { try SCX2Codec.encode(packet).map { String(format: "%02x", $0) }.joined() }
        client.open(peer.port)
        try await eventually("Actual NWConnection did not exchange Hello/Ready", ticking: false) { client.machine.phase == .waitingForNeutral }
        try require(client.socketReady && !client.machine.controlsEnabled, "Socket readiness or READY cannot arm controls")
        let neutral = client.sent.last!
        let forged = SCX2Packet(kind: .ack, session: neutral.session, boot: neutral.boot, challenge: neutral.challenge, sequence: 1, hidReady: true)
        let beforeForeign = client.callbacks
        _ = try peer.call("foreign \(hex(forged))")
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(client.callbacks == beforeForeign && !client.machine.controlsEnabled, "Connected UDP must reject a different source port")
        _ = try peer.call("complete")
        try await eventually("Neutral fake USB completion did not arm") { client.machine.controlsEnabled }
        try require(client.machine.lastAcknowledgedSequence == 1, "Only neutral completion ACK1 arms")

        client.update(.init(buttons: [.a])); client.update(.neutral)
        try await eventually("A packet did not reach receiver", ticking: false) { try peer.status()[6] > 0 }
        _ = try peer.call("complete")
        try await eventually("Press ACK did not release queued lift", ticking: false) { client.sent.count >= 4 }
        try require(try peer.call("output") == "10800000000000000000", "Actual UDP press reaches fake HID A")
        try await eventually("Lift did not reach receiver", ticking: false) { try peer.status()[6] > 0 }
        _ = try peer.call("complete")
        try await eventually("Lift ACK missing", ticking: false) { client.machine.lastAcknowledgedSequence >= 3 }
        try require(try peer.call("output") == "00800000000000000000", "Queued release follows press without coalescing")

        _ = try peer.call("drop_ack"); _ = try peer.call("auto on")
        let ackBefore = client.machine.lastAcknowledgedSequence
        client.update(.init(buttons: [.b])); let held = client.sent.last!
        try await eventually("Lost ACK did not recover through retry") { client.machine.lastAcknowledgedSequence > ackBefore }
        try require(client.sent.filter { $0 == held }.count >= 2, "Lost ACK retries identical bytes and sequence")
        let reports = try peer.call("reports").split(separator: ",").compactMap { Int($0) }
        try require(reports.filter { $0 == 2 }.count == 1, "Retry does not apply held B twice")

        let other = UDPBridgeTransport(); var otherReady = false, otherMessages = 0
        other.onReady = { otherReady = true }; other.onMessage = { _ in otherMessages += 1 }
        other.open(host: "127.0.0.1", port: peer.port)
        try await eventually("Second loopback socket did not open") { otherReady }
        other.send(try SCX2Codec.encode(.init(kind: .hello, session: .init(uuid: UUID()))))
        try await eventually("Receiver did not fence other source endpoint") { try peer.status()[3] > 0 }
        try require(otherMessages == 0, "A second endpoint cannot take over an active lease"); other.close()

        _ = try peer.call("discard on")
        try await eventually("Client no-ACK progress timeout failed", timeout: 2) { if case .stopped = client.machine.phase { true } else { false } }
        try require(!client.machine.controlsEnabled && client.machine.queuedCount == 0, "ACK timeout stops and discards local state")
        try await eventually("Receiver did not independently expire/neutralize", timeout: 2, ticking: false) { try peer.status()[0] == 0 && peer.call("output") == "00800000000000000000" }
        try require(try peer.call("output") == "00800000000000000000", "Receiver lease neutralizes without a received Stop")
        _ = try peer.call("discard off"); client.stop(); client.open(peer.port)
        try await eventually("Fresh session did not rearm") { client.machine.controlsEnabled }
        client.transport.send(try SCX2Codec.encode(held))
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(try peer.call("output") == "00800000000000000000", "Old-session replay cannot restore old B")

        // Keep the old socket alive briefly via best-effort Stop, reopen the same actual transport,
        // then send an old-endpoint malformed marker while that socket may still receive.
        client.stop(); try await eventually("Stop was not neutralized", ticking: false) { try peer.status()[0] == 0 }
        client.open(peer.port); try await eventually("Reconnect failed", ticking: false) { client.machine.controlsEnabled }
        let callbacks = client.callbacks
        _ = try peer.call("send_old ff")
        try await Task.sleep(nanoseconds: 40_000_000)
        try require(client.callbacks == callbacks, "Late callback from replaced connection must be fenced")
        client.update(.init(buttons: [.a])); try await eventually("Final press missing") { try peer.call("output") == "10800000000000000000" }
        client.stop(); try await eventually("Final Stop did not neutralize", ticking: false) { try peer.status()[0] == 0 && peer.call("output") == "00800000000000000000" }
        try require(client.failure == nil, "No unexpected actual transport failure")
        try peer.finish()
        print("PASS: \(checks) actual UDPBridgeTransport loopback checks with portable SCX2 receiver and fake USB.")
        print("Only 127.0.0.1 ephemeral ports were used. No board, radio, physical USB, XAC or Xbox was tested.")
    }
}

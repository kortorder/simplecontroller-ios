import Foundation
import CoreFoundation
import ControllerCore

private enum PressureUDPFailure: Error { case failed(String) }
private final class PressureUDPPeer {
    let process = Process(), input = Pipe(), output = Pipe()
    let port: UInt16
    init(path: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output
        try process.run()
        let greeting = try Self.line(output.fileHandleForReading)
        guard greeting.hasPrefix("PORT "), let port = UInt16(greeting.dropFirst(5)), port > 0 else {
            throw PressureUDPFailure.failed("Peer did not report an ephemeral loopback port")
        }
        self.port = port
    }
    deinit { if process.isRunning { process.terminate() } }
    static func line(_ handle: FileHandle) throws -> String {
        var data = Data()
        while data.count < 16384 {
            let byte = handle.readData(ofLength: 1)
            guard !byte.isEmpty else { throw PressureUDPFailure.failed("Peer ended before response") }
            if byte[0] == 10 { return String(decoding: data, as: UTF8.self) }
            data.append(byte)
        }
        throw PressureUDPFailure.failed("Peer response exceeded bound")
    }
    func call(_ command: String) throws -> String {
        try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        return try Self.line(output.fileHandleForReading)
    }
    func status() throws -> [Int] { try call("status").split(separator: " ").compactMap { Int($0) } }
    func pressure() throws -> [Int] { try call("pressure").split(separator: " ").compactMap { Int($0) } }
    func finish() throws {
        _ = try call("quit"); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PressureUDPFailure.failed("Peer failed") }
    }
}

/// Records bytes around the real NWConnection transport; it never synthesizes replies.
@MainActor private final class RecordingUDPTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    private let real = UDPBridgeTransport()
    var sent: [Data] = [], received: [Data] = [], closed: [Data] = []
    init() {
        real.onReady = { [weak self] in self?.onReady?() }
        real.onMessage = { [weak self] data in self?.received.append(data); self?.onMessage?(data) }
        real.onFailure = { [weak self] error in self?.onFailure?(error) }
    }
    func open(host: String, port: UInt16) { real.open(host: host, port: port) }
    func send(_ data: Data) { sent.append(data); real.send(data) }
    func close(afterSending data: Data?) { if let data { closed.append(data) }; real.close(afterSending: data) }
    var packets: [SCX2Packet] { sent.compactMap { try? SCX2Codec.decode($0) } }
}

@main struct PressureUDPLoopbackChecks {
    // A command-line async main does not itself drive Foundation Timer's main
    // CFRunLoop. Use the same run-loop machinery as the app for the automatic
    // heartbeat test, rather than masking timer issues with explicit tick calls.
    @MainActor static func main() {
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        CFRunLoopRun()
    }

    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw PressureUDPFailure.failed("Pass the loopback peer executable") }
        let peerPath = CommandLine.arguments[1]
        var checks = 0, suites: [String] = []
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw PressureUDPFailure.failed(label) }; checks += 1
        }
        func defaults() -> UserDefaults {
            let name = "SimpleController.PressureUDP.\(UUID())"; suites.append(name)
            return UserDefaults(suiteName: name)!
        }
        func eventually(_ label: String, timeout: Double = 3, tick: () -> Void = {},
                        _ condition: () throws -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < end {
                if try condition() { return }
                tick()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw PressureUDPFailure.failed(label)
        }
        func quantized(_ pressure: Double) -> Int { Int((pressure * 65535).rounded(.toNearestOrAwayFromZero)) }
        func configure(_ model: ControllerViewModel, _ peer: PressureUDPPeer) {
            model.setBridgeTriggerPressureEnabled(true); model.setMode(.bridge)
            model.host = "127.0.0.1"; model.portText = String(peer.port); model.connect()
        }

        let peer = try PressureUDPPeer(path: peerPath, arguments: ["--pressure-backend"])
        let transport = RecordingUDPTransport()
        let connection = ControllerViewModel(defaults: defaults(), transport: transport, automaticTimer: false)
        configure(connection, peer)
        try await eventually("Actual pressure Hello/Ready exchange missing", tick: connection.tick) { try peer.status()[6] > 0 }
        try require(!connection.isReady && transport.packets.first?.revision == .pressure && transport.packets.first?.pressureCapability == true,
                    "Real UDP capability response does not arm before neutral completion")
        try require(try peer.pressure() == [0, 0], "Fake analog output remains released before ACK1")
        _ = try peer.call("complete")
        try await eventually("Neutral completion did not arm app model", tick: connection.tick) { connection.isReady }
        try require(connection.acknowledgedPackets == 1, "Only matching neutral completion arms actual model")
        _ = try peer.call("auto on")
        for pressure in [0.1, 0.5, 1.0, 0.2, 0.8, 0.0] {
            let acknowledged = connection.acknowledgedPackets
            connection.updateOutput(.init(gamepad: .init(buttons: [.a, .rightTrigger]), leftTrigger: 0.5, rightTrigger: pressure), epoch: connection.inputEpoch)
            try await eventually("Pressure \(pressure) did not complete", tick: connection.tick) {
                try connection.acknowledgedPackets > acknowledged && peer.pressure() == [quantized(0.5), quantized(pressure)]
            }
            try require(try peer.pressure() == [quantized(0.5), quantized(pressure)], "Independent fractional pressure \(pressure) crosses actual UDP")
        }
        try require(try peer.call("output") == "10800000000000000000", "Pressure channels never steal A or USB stick fields")
        try require(transport.sent.filter { $0.count == 80 }.count >= 7, "Actual UDP sends pressure-bearing 80-byte states")

        // Force delayed completions: changing only pressure still queues each transition.
        _ = try peer.call("auto off")
        for value in [0.2, 0.8, 0.0] { connection.updateOutput(.init(rightTrigger: value), epoch: connection.inputEpoch) }
        for value in [0.2, 0.8, 0.0] {
            try await eventually("Ordered fractional state missing", tick: connection.tick) { try peer.status()[6] > 0 }
            let acknowledged = connection.acknowledgedPackets
            _ = try peer.call("complete")
            try await eventually("Ordered fractional ACK missing", tick: connection.tick) { connection.acknowledgedPackets > acknowledged }
            try require(try peer.pressure() == [0, quantized(value)], "Same-button pressure transition \(value) remains ordered")
        }
        _ = try peer.call("auto on")
        connection.updateOutput(.init(leftTrigger: 0.4, rightTrigger: 0.9), epoch: connection.inputEpoch)
        try await eventually("Pre-stop pressure missing", tick: connection.tick) { try peer.pressure() == [quantized(0.4), quantized(0.9)] }
        connection.releaseAll()
        try await eventually("Release all did not automatically return neutral", tick: connection.tick) { try connection.isReady && peer.pressure() == [0, 0] }
        try require(connection.outputState.isNeutral && (try? SCX2Codec.decode(transport.closed.last!))?.revision == .pressure,
                    "Release all retires old pressure commands and automatically restores a neutral session")
        try require(connection.connectionRequested && connection.isReady, "Release all needs no manual reconnect")
        connection.updateOutput(.init(rightTrigger: 0.7), epoch: connection.inputEpoch)
        try await eventually("Pre-loss pressure missing", tick: connection.tick) { try peer.pressure()[1] == quantized(0.7) }
        _ = try peer.call("discard on")
        try await eventually("No-ACK cutoff did not clear local pressure", timeout: 2, tick: connection.tick) { !connection.isReady }
        try require(connection.outputState.isNeutral, "Actual network loss clears app pressure")
        try await eventually("Independent receiver lease failed to release", timeout: 2) { try peer.pressure() == [0, 0] && peer.status()[0] == 0 }
        try require(try peer.pressure() == [0, 0], "Receiver expires even when STOP datagrams are discarded")
        _ = try peer.call("discard off")
        connection.connect()
        try await eventually("Backend-loss setup did not rearm", tick: connection.tick) { connection.isReady }
        connection.updateOutput(.init(leftTrigger: 0.5), epoch: connection.inputEpoch)
        try await eventually("Backend-loss pressure missing", tick: connection.tick) { try peer.pressure()[0] == quantized(0.5) }
        _ = try peer.call("backend off")
        try require(try peer.pressure() == [0, 0] && peer.status()[0] == 0, "Backend readiness loss immediately releases before client timeout")
        try await eventually("Backend loss did not stop app", timeout: 2, tick: connection.tick) { !connection.isReady }
        try require(connection.outputState.isNeutral, "Backend failure cannot preserve local trigger hold")
        try peer.finish()

        let noBackend = try PressureUDPPeer(path: peerPath, arguments: ["--auto"])
        let unavailable = ControllerViewModel(defaults: defaults(), transport: RecordingUDPTransport(), automaticTimer: false)
        configure(unavailable, noBackend)
        try await eventually("USB-only peer did not decline pressure", tick: unavailable.tick) {
            if case .stopped = unavailable.phase { return true }; return false
        }
        try require(!unavailable.isReady && unavailable.statusDetail.contains("trigger") && unavailable.outputState.isNeutral,
                    "Real USB-only peer declines unsupported proportional capability")
        try noBackend.finish()

        let oldPeer = try PressureUDPPeer(path: peerPath, arguments: ["--legacy-only", "--auto"])
        let oldClient = ControllerViewModel(defaults: defaults(), transport: RecordingUDPTransport(), automaticTimer: false)
        configure(oldClient, oldPeer)
        try await eventually("Old receiver did not time out safely", timeout: 4, tick: oldClient.tick) {
            if case .stopped = oldClient.phase { return true }; return false
        }
        try require(!oldClient.isReady && oldClient.statusDetail.contains("pressure-capable") && (try oldPeer.status()[0]) == 0,
                    "Actual UDP old-peer silence cannot arm or downgrade pressure")
        try oldPeer.finish()

        let timerPeer = try PressureUDPPeer(path: peerPath, arguments: ["--pressure-backend", "--auto"])
        let timed = ControllerViewModel(defaults: defaults(), transport: RecordingUDPTransport(), automaticTimer: true)
        configure(timed, timerPeer)
        try await eventually("Automatic-timer model did not arm") { timed.isReady }
        let sustainedStart = ProcessInfo.processInfo.systemUptime
        let sustainedAcknowledged = timed.acknowledgedPackets
        let sustainedValues = [0.0, 0.1, 0.2, 0.5, 0.8, 1.0]
        var lastPhase = -1, observedPressures: Set<Int> = []
        while ProcessInfo.processInfo.systemUptime - sustainedStart < 18 {
            let phase = Int((ProcessInfo.processInfo.systemUptime - sustainedStart) / 0.15) % sustainedValues.count
            if phase != lastPhase {
                timed.updateOutput(.init(leftTrigger: 0.5, rightTrigger: sustainedValues[phase]), epoch: timed.inputEpoch)
                lastPhase = phase
            }
            guard timed.isReady else { throw PressureUDPFailure.failed("Automatic heartbeat lost readiness during sustained pressure updates") }
            observedPressures.insert(try timerPeer.pressure()[1])
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(timed.acknowledgedPackets - sustainedAcknowledged >= 200,
                    "Automatic Foundation Timer sustains actual UDP for 18 seconds without manual ticks")
        try require(Set(sustainedValues.map(quantized)).isSubset(of: observedPressures),
                    "Every sustained fractional pressure reaches the simulated analog backend")
        let idleAcknowledged = timed.acknowledgedPackets
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let idleCompletions = timed.acknowledgedPackets - idleAcknowledged
        try require(timed.isReady && idleCompletions >= 10,
                    "Automatic heartbeat continues during two seconds with no input activity")
        print("Automatic main-run-loop timer: \(timed.acknowledgedPackets - sustainedAcknowledged) completions over 20 seconds, including \(idleCompletions) during two idle seconds; ready throughout.")
        timed.stop()
        try await eventually("Automatic session cleanup did not release") { try timerPeer.pressure() == [0, 0] && timerPeer.status()[0] == 0 }
        try timerPeer.finish()

        // Real profile ownership, pulse expiry, page cancellation and Camera exclusion.
        let profilePeer = try PressureUDPPeer(path: peerPath, arguments: ["--pressure-backend", "--auto"])
        let low = ProfileControl(name: "Low RT", payload: "RT:0.2")
        let high = ProfileControl(name: "Pulse RT", payload: "RT:0.8P0.2")
        let left = ProfileControl(name: "LT", payload: "LT:0.5")
        let camera = ProfileControl(name: "Camera", payload: "CAMERA_FOLLOW")
        let stick = ProfileControl(name: "Move", kind: .leftStick)
        let controls = [low, high, left, camera, stick]
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        var profile = try ControllerProfile(name: "Local UDP pressure", controls: controls, portrait: positions, landscape: positions)
        let secondPage = try profile.addPage(name: "Other")
        let store = defaults()
        let bytes = try ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile]))
        store.set(bytes, forKey: ProfileControllerViewModel.libraryKey)
        let profileTransport = RecordingUDPTransport()
        let model = ProfileControllerViewModel(defaults: store, transport: profileTransport, automaticTimer: true)
        model.setBridgeTriggerPressureEnabled(true)
        model.setCameraFollowEnabled(true)
        _ = model.handleInput(.beginStick(contact: 50, control: stick.id, travel: .init(x: 1, y: 0)), epoch: model.inputEpoch)
        try await eventually("Practice Camera never generated the pre-switch test output") {
            model.state.rightStick.x > 0
        }
        try require(profileTransport.sent.isEmpty, "Generated Practice Camera emits no UDP packets")
        model.setMode(.bridge); model.host = "127.0.0.1"; model.portText = String(profilePeer.port); model.connect()
        try await eventually("Profile model did not arm over UDP") { model.isReady }
        try require(model.cameraFollowSnapshot?.requestedEnabled == false && model.state.rightStick == .zero,
                    "Switching Practice Camera to pressure bridge remains neutral")
        func input(_ event: ProfileInputEvent) { _ = model.handleInput(event, epoch: model.inputEpoch) }
        input(.begin(contact: 1, control: low.id, position: .zero))
        try await eventually("Profile low owner missing") { try profilePeer.pressure()[1] == quantized(0.2) }
        input(.begin(contact: 2, control: high.id, position: .zero)); input(.end(contact: 2))
        try await eventually("Profile pulse did not retain after lift", timeout: 0.18) { try profilePeer.pressure()[1] == quantized(0.8) }
        try require(try profilePeer.pressure()[1] == quantized(0.8), "Started pressure pulse survives ordinary finger lift")
        input(.begin(contact: 3, control: left.id, position: .zero))
        try await eventually("Pulse did not restore independent lower owner") {
            try profilePeer.pressure() == [quantized(0.5), quantized(0.2)]
        }
        try require(abs(model.practiceState.rightTrigger - 0.2) < 0.000001, "Profile retains precise local pressure while wire is quantized")
        try require(!model.handleInput(.accessibilityActivate(camera.id), epoch: model.inputEpoch), "Pressure mode does not enable Camera command")
        try require(profileTransport.packets.compactMap(\.state).allSatisfy { $0.rightStick == .zero }, "No generated Camera right stick crosses actual UDP")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try require(model.isReady && (try profilePeer.pressure()) == [quantized(0.5), quantized(0.2)],
                    "Profile automatic timers preserve independent pressure holds without manual ticks")
        model.selectPage(secondPage)
        try await eventually("Page change did not restore neutral pressure") { try model.isReady && profilePeer.pressure() == [0, 0] }
        try require(model.practiceState == .neutral && profileTransport.closed.last.flatMap({ try? SCX2Codec.decode($0) })?.kind == .stop,
                    "Profile page transition retires old pressure commands and resumes neutral automatically")
        try require(store.data(forKey: ProfileControllerViewModel.libraryKey) == bytes, "Networking never rewrites saved profile bytes")
        model.stop()
        try profilePeer.finish()
        print("PASS: \(checks) actual app-model pressure UDP checks with explicit fake USB/analog backend.")
        print("Only 127.0.0.1 ephemeral sockets were used; no board, Wi-Fi, electrical output, XAC or Xbox was tested.")
    }
}

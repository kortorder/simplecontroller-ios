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

@main struct PersistentConnectionUDPLoopbackChecks {
    @MainActor static func main() {
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        CFRunLoopRun()
    }
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw PressureUDPFailure.failed("Pass the C++ loopback peer") }
        var checks = 0
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw PressureUDPFailure.failed(label) }; checks += 1
        }
        func eventually(_ label: String, timeout: Double = 6, _ predicate: () throws -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < end {
                if try predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw PressureUDPFailure.failed(label)
        }
        for proportional in [false, true] {
            let args = proportional ? ["--pressure-backend", "--auto"] : ["--auto"]
            let peer = try PressureUDPPeer(path: CommandLine.arguments[1], arguments: args)
            let suite = "SimpleController.ConnectionUDP.\(UUID())"
            let store = UserDefaults(suiteName: suite)!
            defer { store.removePersistentDomain(forName: suite) }
            let a = ProfileControl(name: "A", actions: [.a])
            let b = ProfileControl(name: "B", actions: [.b])
            var macro = ProfileControl(name: "Delayed macro", payload: "X360X(D500)(U200)")
            macro.macroModeEnabled = true
            let pressure = ProfileControl(name: "Pressure", payload: "LT:0.5,RT:0.7")
            var profile = try ControllerProfile(name: "Walk")
            for control in [a,b,macro,pressure] { try profile.addControl(control, toPage: profile.homePageID) }
            let drive = try profile.addPage(name: "Drive")
            let extras = try profile.addPage(name: "Extras")
            var other = try ControllerProfile(name: "Other profile")
            let y = ProfileControl(name: "Y", actions: [.y])
            try other.addControl(y, toPage: other.homePageID)
            let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile, other])
            let original = try ControllerProfileLibraryCodec.encode(library)
            store.set(original, forKey: ProfileControllerViewModel.libraryKey)
            let transport = RecordingUDPTransport()
            let model = ProfileControllerViewModel(defaults: store, transport: transport, automaticTimer: true)
            model.setBridgeTriggerPressureEnabled(proportional)
            model.setMode(.bridge); model.host = "127.0.0.1"; model.portText = String(peer.port); model.connect()
            try await eventually("Initial neutral handshake failed") { model.isReady && model.controlsEnabled }
            func input(_ event: ProfileInputEvent, epoch: Int? = nil) {
                _ = model.handleInput(event, epoch: epoch ?? model.inputEpoch)
            }
            input(.begin(contact: 1, control: a.id, position: .zero))
            if proportional { input(.begin(contact: 2, control: pressure.id, position: .zero)) }
            try await eventually("Initial held A was not delivered") { try peer.call("output") == "10800000000000000000" }
            if proportional {
                try await eventually("Initial pressure did not reach fake backend") { try peer.pressure()[1] > 40000 }
            }
            let oldPress = transport.sent.last(where: { data in
                guard let packet = try? SCX2Codec.decode(data) else { return false }
                return packet.kind == .state && packet.state?.buttons.contains(.a) == true
            })!
            let oldSession = try SCX2Codec.decode(oldPress).session
            let oldEpoch = model.inputEpoch
            _ = try peer.call("auto off")
            input(.begin(contact: 3, control: b.id, position: .zero))
            input(.begin(contact: 4, control: macro.id, position: .zero)); input(.end(contact: 4))
            model.selectPage(drive)
            model.selectPage(extras)
            try require(model.connectionRequested && !model.controlsEnabled && model.state.isNeutral,
                        "Page changes retain intent but pause new input and clear old owners")
            try await eventually("STOP did not release receiver session while neutral completion was blocked", timeout: 1) { try peer.status()[0] == 0 }
            if proportional { try require(try peer.pressure() == [0,0], "Page transition releases analog before delayed USB completes") }
            try await Task.sleep(nanoseconds: 300_000_000)
            try require(model.connectionRequested && !model.isReady,
                        "Unready READY during delayed USB neutral does not abandon connection intent")
            let reportsBefore = try peer.call("reports").split(separator: ",").count
            _ = try peer.call("auto on")
            try await eventually("Page did not automatically rearm after neutral completion") { model.isReady && model.controlsEnabled }
            try require(model.currentPageID == extras, "Rapid page changes keep the last selected page")
            try require(transport.packets.last?.session != oldSession, "Page transition uses a fresh session")
            input(.begin(contact: 5, control: a.id, position: .zero), epoch: oldEpoch)
            transport.send(oldPress)
            try await Task.sleep(nanoseconds: 600_000_000)
            let afterReports = try peer.call("reports").split(separator: ",").compactMap { Int($0) }.dropFirst(reportsBefore)
            try require(afterReports.allSatisfy { $0 == 0 } && model.state.isNeutral,
                        "Old packet, stale UIKit epoch, queued B and delayed macro cannot replay after page switch")
            try require(try peer.call("output") == "00800000000000000000", "Page ends with neutral actual receiver output")
            try require(store.data(forKey: ProfileControllerViewModel.libraryKey) == original,
                        "Page networking does not rewrite saved layouts")
            model.beginProfileManagement()
            try require(model.selectProfile(other.id), "Profile selection succeeds during bridge pause")
            model.finishProfileManagement()
            try await eventually("Profile selection did not automatically rearm") { model.isReady && model.controlsEnabled }
            try require(model.library.profiles == library.profiles && model.profile.id == other.id,
                        "Selecting another profile preserves all saved control models")
            input(.begin(contact: 6, control: y.id, position: .zero))
            try await eventually("Fresh profile Y did not work") { try peer.call("output") == "00880000000000000000" }
            model.releaseAll()
            try await eventually("Release all did not rearm neutral") { try model.isReady && peer.call("output") == "00800000000000000000" }
            try require(model.connectionRequested && model.state.isNeutral, "Release all keeps connection intent with no held output")
            model.beginLayoutEditing(); model.cancelLayoutEditing()
            model.prepareSettings(); model.finishSettings()
            try await eventually("Editing/settings cleanup required manual reconnect") { model.isReady && model.controlsEnabled }
            input(.begin(contact: 7, control: y.id, position: .zero))
            try await eventually("Held output before network loss missing") { try peer.call("output") == "00880000000000000000" }
            _ = try peer.call("discard on")
            try await eventually("Network loss did not pause and clear app state", timeout: 3) { !model.isReady && model.state.isNeutral }
            try await eventually("Receiver lease did not independently clear output", timeout: 3) { try peer.call("output") == "00800000000000000000" }
            try require(model.connectionRequested, "Temporary transport failure keeps intent")
            _ = try peer.call("discard off")
            try await eventually("Recovery after lost STOP/datagrams required manual connect", timeout: 10) { model.isReady && model.controlsEnabled }
            try require(model.state.isNeutral && (try peer.call("output")) == "00800000000000000000",
                        "Automatic fault recovery never restores old held Y")
            model.setForeground(false)
            try await eventually("Background did not neutralize receiver", timeout: 2) { try peer.status()[0] == 0 }
            try require(model.connectionRequested && !model.controlsEnabled, "Brief background keeps intent and disables input")
            model.setForeground(true)
            try await eventually("Brief foreground return did not reconnect automatically") { model.isReady && model.controlsEnabled }
            model.releaseAll(); model.stop()
            let packetCount = transport.sent.count
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try require(!model.connectionRequested && !model.isReady && transport.sent.count == packetCount,
                        "Deliberate Disconnect cancels an in-flight resync and future retries")
            try require(try peer.call("output") == "00800000000000000000", "Explicit disconnect leaves receiver neutral")
            try peer.finish()
            print("PASS: actual app/UDP/C++ receiver connection persistence, format \(proportional ? 3 : 2).")
        }
        print("PASS: \(checks) actual UDP connection checks; only localhost ephemeral ports, fake USB and fake analog output.")
    }
}

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

@main struct USBTriggerUDPLoopbackChecks {
    @MainActor static func main() {
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        CFRunLoopRun()
    }
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw PressureUDPFailure.failed("Pass C++ loopback peer") }
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
        let peer = try PressureUDPPeer(path: CommandLine.arguments[1], arguments: ["--auto"])
        let suite = "SimpleController.USBTriggerUDP.\(UUID())"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let a = ProfileControl(name: "A", actions: [.a])
        let lt = ProfileControl(name: "LT half", payload: "LT:0.5")
        let rt = ProfileControl(name: "RT seventy", payload: "RT:0.7")
        let tiny = ProfileControl(name: "Tiny LT", payload: "LT:0.000001")
        let digital = ProfileControl(name: "Digital triggers", actions: [.leftTrigger, .rightTrigger])
        var macro = ProfileControl(name: "Delayed RT", payload: "RT:0.7(D500)(U200)")
        macro.macroModeEnabled = true
        var profile = try ControllerProfile(name: "USB test")
        for control in [a,lt,rt,tiny,digital,macro] { try profile.addControl(control, toPage: profile.homePageID) }
        let drive = try profile.addPage(name: "Drive"), extras = try profile.addPage(name: "Extras")
        let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile])
        let original = try ControllerProfileLibraryCodec.encode(library)
        store.set(original, forKey: ProfileControllerViewModel.libraryKey)
        let transport = RecordingUDPTransport()
        let model = ProfileControllerViewModel(defaults: store, transport: transport, automaticTimer: true)
        model.setForeground(true)
        model.setBridgeTriggerMode(.usbButtons)
        model.setMode(.bridge); model.host = "127.0.0.1"; model.portText = String(peer.port); model.connect()
        try await eventually("Format4 neutral handshake failed") { model.isReady && model.controlsEnabled }
        try require(transport.packets.allSatisfy { $0.revision == .usbButtons }, "USB mode uses format4 only")
        try require(transport.sent.filter { $0.count > 7 && $0[5] == 1 }.allSatisfy { $0[7] == 2 }, "HELLO requests capability2")
        func input(_ event: ProfileInputEvent, epoch: Int? = nil) { _ = model.handleInput(event, epoch: epoch ?? model.inputEpoch) }
        func expect(_ hex: String, _ label: String) async throws {
            try await eventually(label) { try peer.call("output") == hex }; checks += 1
        }
        input(.begin(contact: 1, control: a.id, position: .zero))
        input(.begin(contact: 2, control: lt.id, position: .zero))
        try await expect("11800000000000000000", "A and LT reach distinct physical HID slots")
        input(.begin(contact: 3, control: rt.id, position: .zero))
        try await expect("13800000000000000000", "A plus both partial requests produce full USB triggers")
        let oldPress = transport.sent.last(where: { $0.count == 80 && $0[76] == 255 && $0[78] == 255 })!
        input(.end(contact: 2))
        try await expect("12800000000000000000", "Releasing LT retains A and RT")
        input(.end(contact: 3)); input(.end(contact: 1))
        try await expect("00800000000000000000", "All triggers release independently")
        input(.begin(contact: 4, control: tiny.id, position: .zero))
        try await expect("01800000000000000000", "Tiny positive request maps to full LT before wire rounding")
        input(.end(contact: 4))
        input(.begin(contact: 5, control: digital.id, position: .zero))
        try await expect("03800000000000000000", "Digital LT and RT buttons use both spare slots")
        try require(try peer.pressure() == [0,0], "USB triggers never activate analog backend")
        let oldEpoch = model.inputEpoch
        _ = try peer.call("auto off")
        input(.begin(contact: 6, control: macro.id, position: .zero)); input(.end(contact: 6))
        model.selectPage(drive); model.selectPage(extras)
        try require(model.connectionRequested && !model.controlsEnabled, "Rapid pages pause for neutral but retain connection")
        try await eventually("Page transition did not retire old session") { try peer.status()[0] == 0 }
        try await Task.sleep(nanoseconds: 300_000_000)
        let count = try peer.call("hid_reports").split(separator: ",").count
        _ = try peer.call("auto on")
        try await eventually("USB mode failed to rearm after page transition") { model.isReady && model.controlsEnabled }
        input(.begin(contact: 7, control: digital.id, position: .zero), epoch: oldEpoch)
        transport.send(oldPress)
        try await Task.sleep(nanoseconds: 650_000_000)
        let reports = try peer.call("hid_reports").split(separator: ",").dropFirst(count)
        try require(!reports.isEmpty && reports.allSatisfy { $0 == "00800000000000000000" }, "Queued trigger, delayed macro, stale touch and old packet cannot replay")
        try require(model.currentPageID == extras, "Latest page survives reconnect")
        try require(store.data(forKey: ProfileControllerViewModel.libraryKey) == original, "Saved pressure payloads and layouts remain byte-identical")
        model.selectPage(profile.homePageID)
        try await eventually("Return to Walk failed") { model.isReady && model.controlsEnabled }
        input(.begin(contact: 8, control: digital.id, position: .zero))
        try await expect("03800000000000000000", "Fresh trigger input works after page change")
        model.releaseAll()
        try await expect("00800000000000000000", "Release all clears both USB triggers")
        try await eventually("Release all failed automatic neutral reconnect") { model.isReady && model.controlsEnabled }
        input(.begin(contact: 9, control: digital.id, position: .zero))
        try await expect("03800000000000000000", "Triggers active before packet loss")
        _ = try peer.call("discard on")
        try await eventually("Lost Wi-Fi did not clear receiver triggers", timeout: 3) { try peer.call("output") == "00800000000000000000" }
        try require(model.connectionRequested, "Packet loss retains connection request")
        _ = try peer.call("discard off")
        try await eventually("Packet recovery failed", timeout: 10) { model.isReady && model.controlsEnabled }
        try await expect("00800000000000000000", "Network recovery never resumes previous trigger holds")
        input(.begin(contact: 10, control: digital.id, position: .zero))
        try await expect("03800000000000000000", "Triggers active before background")
        model.setForeground(false)
        try await expect("00800000000000000000", "Background clears USB triggers")
        model.setForeground(true)
        try await eventually("Short background did not resume") { model.isReady && model.controlsEnabled }
        model.stop()
        try await expect("00800000000000000000", "Explicit disconnect is neutral")
        try require(!model.connectionRequested, "Explicit disconnect cancels USB auto-reconnect")
        try peer.finish()
        print("PASS: \(checks) format4 actual Swift app/UDP/C++ receiver USB trigger checks; only localhost/fake USB.")
    }
}

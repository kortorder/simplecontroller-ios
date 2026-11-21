import Foundation
import Combine
import ControllerCore

@MainActor
final class IntentCheckClock {
    var uptime: Double = 1000
    var wall: Double = 1_800_000_000
    func advance(_ amount: Double) { uptime += amount; wall += amount }
}
@MainActor
final class IntentCheckTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var sent: [SCX2Packet] = []
    var legacySent: [BridgePacket] = []
    var closed: [SCX2Packet] = []
    var opened: [(String, UInt16)] = []
    func open(host: String, port: UInt16) { opened.append((host, port)); onReady?() }
    func send(_ data: Data) {
        if let packet = try? SCX2Codec.decode(data) { sent.append(packet) }
        else { legacySent.append(try! BridgeCodec.decode(data)) }
    }
    func close(afterSending data: Data?) { if let data, let packet = try? SCX2Codec.decode(data) { closed.append(packet) } }
    func reply(_ packet: SCX2Packet) { onMessage?(try! SCX2Codec.encode(packet)) }
    var hello: SCX2Packet { sent.last(where: { $0.kind == .hello })! }
    func offer(unavailable: Bool = false) {
        let request = hello
        reply(.init(kind: .ready, session: request.session,
                    boot: .init(bytes: Array(repeating: 11, count: 16)),
                    challenge: unavailable ? .zero : .init(bytes: Array(repeating: 12, count: 16)),
                    hidReady: !unavailable, revision: request.revision,
                    pressureCapability: !unavailable && request.revision == .pressure))
    }
    func acknowledge(_ state: SCX2Packet) {
        reply(.init(kind: .ack, session: state.session, boot: state.boot, challenge: state.challenge,
                    sequence: state.sequence, hidReady: true, revision: state.revision))
    }
    func arm() { offer(); acknowledge(sent.last!) }
}

@main
struct ConnectionIntentClientChecks {
    @MainActor
    static func main() throws {
        var checks = 0
        var domains: [String] = []
        func require(_ value: @autoclosure () -> Bool, _ explanation: String) {
            guard value() else { fatalError("Connection intent check failed: \(explanation)") }
            checks += 1
        }
        func defaults() -> UserDefaults {
            let name = "connection-intent-check-\(UUID().uuidString)"; domains.append(name)
            return UserDefaults(suiteName: name)!
        }
        defer { for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) } }
        func model(_ store: UserDefaults, _ link: IntentCheckTransport, _ clock: IntentCheckClock) -> ControllerViewModel {
            ControllerViewModel(defaults: store, transport: link, clock: { clock.uptime }, wallClock: { clock.wall }, resumeClock: { clock.uptime }, automaticTimer: false)
        }
        func connect(_ model: ControllerViewModel, _ link: IntentCheckTransport, pressure: Bool = false) {
            model.host = "192.168.1.80"; model.portText = "42736"
            model.setBridgeTriggerPressureEnabled(pressure); model.setMode(.bridge); model.connect(); link.arm()
        }
        // Practice has no network/phase publication on return. Its active gate must
        // independently notify SwiftUI/UIKit so a fresh or reopened canvas is usable.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock)
            subject.setForeground(false)
            var notifications = 0
            let observation = subject.objectWillChange.sink { notifications += 1 }
            subject.setForeground(true)
            require(notifications > 0 && subject.controlsEnabled,
                    "Practice foreground transition publishes a canvas redraw")
            require(subject.state.isNeutral && subject.outputState == .neutral && link.opened.isEmpty,
                    "Practice redraw enables neutral local controls without opening a socket")
            let stableNotifications = notifications
            subject.setForeground(true)
            require(notifications == stableNotifications,
                    "Repeated active callbacks do not cause redundant redraws")
            withExtendedLifetime(observation) {}
        }
        for pressure in [false, true] {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock)
            connect(subject, link, pressure: pressure)
            require(subject.isReady && subject.connectionRequested, "Explicit Connect creates live intent")
            subject.updateOutput(.init(gamepad: .init(buttons: [.a]), leftTrigger: pressure ? 0.4 : 0,
                                       rightTrigger: pressure ? 0.8 : 0), epoch: subject.inputEpoch)
            let down = link.sent.last!, oldReply = link.onMessage, oldFailure = link.onFailure
            subject.updateOutput(.init(gamepad: .init(buttons: [.b])), epoch: subject.inputEpoch)
            subject.updateOutput(.neutral, epoch: subject.inputEpoch)
            let oldEpoch = subject.inputEpoch, oldSession = link.hello.session
            subject.cancelQueuedInput(reason: "Page changed")
            require(subject.connectionRequested && !subject.controlsEnabled && subject.state.isNeutral,
                    "Navigation pauses old input while retaining intent")
            require(link.closed.last?.kind == .stop && link.hello.session != oldSession,
                    "Navigation retires queued presses and starts a fresh session")
            let latestCount = link.sent.count, currentSession = link.hello.session
            oldReply?(try SCX2Codec.encode(.init(kind: .ack, session: down.session, boot: down.boot,
                       challenge: down.challenge, sequence: down.sequence, hidReady: true, revision: down.revision)))
            oldFailure?("old socket error")
            subject.updateOutput(.init(gamepad: .init(buttons: [.x])), epoch: oldEpoch)
            require(link.sent.count == latestCount && link.hello.session == currentSession,
                    "Old replies, failures and fingers cannot disturb the replacement")
            subject.cancelQueuedInput(reason: "Next page")
            require(link.hello.session == currentSession, "Rapid pages retain one bounded neutral attempt")
            link.offer(unavailable: true)
            require(subject.isConnecting && !subject.isReady, "Automatic retry waits through receiver neutral barrier")
            link.offer()
            let neutral = link.sent.last!
            require(neutral.sequence == 1 && neutral.output == .neutral && !subject.controlsEnabled,
                    "Both protocol revisions require fresh neutral USB acknowledgement")
            subject.updateOutput(.init(gamepad: .init(buttons: [.y])), epoch: subject.inputEpoch)
            link.acknowledge(neutral)
            require(subject.isReady && subject.outputState == .neutral, "Touches while paused never replay after acknowledgement")
            subject.releaseAll()
            require(subject.connectionRequested && !subject.controlsEnabled, "Release all preserves connection intent")
            link.arm()
            subject.stop()
            let stoppedCount = link.opened.count
            clock.advance(10); subject.tick(); link.offer()
            require(!subject.connectionRequested && !subject.isReady && link.opened.count == stoppedCount,
                    "Explicit Disconnect prevents every later retry")
            require(store.data(forKey: ControllerViewModel.connectionIntentKey) == nil, "Disconnect removes resumable intent")
        }
        // Retry deadlines are bounded and don't renew on page changes or unready replies.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock); connect(subject, link)
            subject.cancelQueuedInput(reason: "Page changed")
            let first = link.hello.session
            clock.advance(2.99); link.offer(unavailable: true); subject.cancelQueuedInput(reason: "Another page")
            clock.advance(0.01); subject.tick()
            require(subject.connectionRequested && !subject.isReady && link.hello.session == first,
                    "Availability waiting expires at its original deadline")
            let count = link.opened.count
            clock.advance(0.99); subject.tick(); require(link.opened.count == count, "Recovery honors backoff")
            clock.advance(0.01); subject.tick()
            require(link.opened.count == count + 1 && link.hello.session != first,
                    "A failed bounded attempt automatically starts a fresh attempt")
            subject.setMode(.practice); clock.advance(20); subject.tick()
            require(!subject.connectionRequested && subject.mode == .practice, "Practice deliberately cancels connection intent")
        }
        // Every genuine app opening reconnects, including extended absence, without restoring holds.
        for elapsed in [0.5, 299.99, 300, 400] {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock); connect(subject, link)
            subject.updateInput(.init(buttons: [.a]), epoch: subject.inputEpoch)
            subject.setForeground(false)
            let saved = store.data(forKey: ControllerViewModel.connectionIntentKey)
            clock.advance(elapsed / 2); subject.setForeground(false); subject.tick()
            require(store.data(forKey: ControllerViewModel.connectionIntentKey) == saved,
                    "Repeated background callbacks never renew the absence timestamp")
            clock.advance(elapsed / 2); subject.setForeground(true)
            require(subject.connectionRequested, "Returning after any duration starts a fresh bridge connection")
            require(!subject.controlsEnabled && subject.state.isNeutral, "Returning cannot restore old held input")
            link.arm(); require(subject.isReady && subject.state.isNeutral, "Every return resumes neutral automatically")
            subject.stop()
        }
        for elapsed in [1.0, 299.0, 300.0] {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let old = model(store, link, clock); connect(old, link)
            let profileBytes = Data("layout unchanged".utf8)
            store.set(profileBytes, forKey: "controller.profiles.v1")
            clock.advance(elapsed)
            let replacementLink = IntentCheckTransport(), replacement = model(store, replacementLink, clock)
            require(replacementLink.opened.isEmpty, "Process restoration does not open transport before foreground confirmation")
            replacement.setForeground(true)
            require(replacement.connectionRequested, "Short and extended process closures reopen the remembered bridge")
            require(store.data(forKey: "controller.profiles.v1") == profileBytes, "Intent restoration does not rewrite saved layouts")
            replacementLink.arm(); require(replacement.isReady && replacement.state.isNeutral, "Relaunch is neutral-ACK gated")
            replacement.stop(); old.stop()
        }
        // Input uptime may stop during phone sleep; intent expiry uses a separate continuous clock.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            var continuous: TimeInterval = 2000
            let subject = ControllerViewModel(defaults: store, transport: link, clock: { clock.uptime },
                wallClock: { clock.wall }, resumeClock: { continuous }, automaticTimer: false)
            connect(subject, link); subject.setForeground(false)
            clock.wall += 30; continuous += 30 // The gesture clock intentionally stays unchanged.
            subject.setForeground(true)
            require(subject.connectionRequested && subject.isConnecting, "Thirty seconds of phone sleep resumes with the continuous clock")
            link.arm(); require(subject.isReady && subject.state.isNeutral, "Sleep resume remains neutral-ACK gated")
            subject.stop()
        }
        for rollback in [true, false] {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let original = model(store, link, clock); connect(original, link)
            if rollback { clock.wall -= 1 } else { clock.uptime = 1 }
            let restoredLink = IntentCheckTransport(), restored = model(store, restoredLink, clock)
            restored.setForeground(true)
            require(restored.connectionRequested && restoredLink.opened.count == 1 && !restored.controlsEnabled, "Clock rollback or reboot starts a new neutral-gated connection, not an old session")
            restoredLink.arm(); require(restored.isReady && restored.state.isNeutral, "Reboot/clock changes never restore held controls")
            restored.stop()
            original.stop()
        }
        // Foreground retries keep crash recovery fresh, with bounded preference writes.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock); connect(subject, link)
            let original = store.data(forKey: ControllerViewModel.connectionIntentKey)
            clock.advance(0.5); subject.tick()
            require(store.data(forKey: ControllerViewModel.connectionIntentKey) == original,
                    "Fifty-millisecond heartbeats do not rewrite intent on every tick")
            clock.advance(0.5); subject.tick()
            require(store.data(forKey: ControllerViewModel.connectionIntentKey) != original,
                    "Intent metadata refreshes at the bounded one-second cadence")
            clock.advance(310); subject.tick() // Still foreground, but no bridge replies.
            let replacementLink = IntentCheckTransport(), replacement = model(store, replacementLink, clock)
            replacement.setForeground(true)
            require(replacement.connectionRequested && replacement.isConnecting,
                    "Foreground retry waiting does not make a quick process relaunch look like a long absence")
            replacement.stop(); subject.stop()
        }
        // Form edits cannot move the live connection until explicit Save.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock); connect(subject, link)
            subject.host = "192.168.1.90"; subject.portText = "43000"
            subject.cancelQueuedInput(reason: "Profile changed")
            require(link.opened.last?.0 == "192.168.1.80" && link.opened.last?.1 == 42736,
                    "Resynchronization uses the connected endpoint rather than unsaved settings")
            link.arm(); subject.saveSettings()
            require(link.opened.last?.0 == "192.168.1.90" && link.opened.last?.1 == 43000,
                    "Explicit Save applies the new validated endpoint")
            subject.host = "invalid"; subject.saveSettings()
            let count = link.opened.count; clock.advance(10); subject.tick()
            require(subject.connectionRequested && !subject.isReady && link.opened.count == count,
                    "Invalid saved target pauses instead of reconnecting to the old address")
            subject.stop()
        }
        // Navigation, profile changes and sheets preserve intent and clear macro/touch owners.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            var profile = try ControllerProfile(name: "Connection checks")
            let home = profile.homePageID, second = try profile.addPage(name: "Drive")
            let macro = ProfileControl(name: "Macro", payload: "X360A(U500),X360B(D700)", macroModeEnabled: true)
            let back = ProfileControl(name: "Back", kind: .pageButton, pageNavigation: .goTo(home))
            try profile.addControl(macro, toPage: home); try profile.addControl(back, toPage: second)
            let another = try ControllerProfile(name: "Other")
            let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile, another])
            let bytes = try ControllerProfileLibraryCodec.encode(library)
            store.set(bytes, forKey: ProfileControllerViewModel.libraryKey)
            let subject = ProfileControllerViewModel(defaults: store, transport: link, clock: { clock.uptime },
                wallClock: { clock.wall }, resumeClock: { clock.uptime }, automaticTimer: false)
            subject.host = "192.168.1.80"; subject.setMode(.bridge); subject.connect(); link.arm()
            let oldEpoch = subject.inputEpoch
            subject.handleInput(.begin(contact: 1, control: macro.id, position: .zero), epoch: oldEpoch)
            subject.handleInput(.end(contact: 1), epoch: oldEpoch)
            subject.selectPage(second)
            require(subject.currentPageID == second && subject.connectionRequested && subject.state.isNeutral,
                    "Header page selection releases running macros without losing connection intent")
            link.arm(); subject.tickInput(epoch: oldEpoch)
            require(subject.currentPageID == second && subject.state.isNeutral, "Neutral ACK preserves the selected page and fences old timers")
            subject.handleInput(.begin(contact: 2, control: back.id, position: .zero), epoch: subject.inputEpoch)
            require(subject.currentPageID == home && subject.connectionRequested && !subject.controlsEnabled,
                    "On-canvas page buttons use the same automatic neutral resynchronization")
            link.arm()
            require(store.data(forKey: ProfileControllerViewModel.libraryKey) == bytes,
                    "Changing pages preserves exact saved library bytes")
            subject.beginProfileManagement(); require(subject.connectionRequested && !subject.controlsEnabled, "Profile manager retains intent")
            require(subject.selectProfile(another.id), "A different profile can be selected")
            subject.finishProfileManagement(); link.arm()
            require(subject.profile.id == another.id && subject.isReady && subject.state.isNeutral,
                    "Selected profile resumes neutral automatically")
            subject.beginLayoutEditing(); link.arm()
            require(subject.connectionRequested && !subject.controlsEnabled, "Editing remains paused even after network recovery")
            subject.cancelLayoutEditing(); link.arm()
            subject.prepareSettings(); link.arm()
            require(!subject.controlsEnabled && subject.connectionRequested, "Settings retains the connection but disables controls")
            subject.finishSettings(); link.arm()
            require(subject.isReady && subject.controlsEnabled, "Leaving settings resumes through a neutral handshake")
            require(subject.library.profiles == library.profiles, "Profile contents are unchanged across all navigation and modal transitions")
            subject.stop()
        }
        // Manual Disconnect pauses this visit, not the next genuine opening.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock); connect(subject, link)
            subject.stop(); let count = link.opened.count
            subject.setForeground(true); subject.tick()
            subject.setForeground(false); subject.setForeground(true) // A transient system prompt.
            clock.advance(50); subject.tick()
            require(link.opened.count == count && !subject.connectionRequested,
                    "Disconnect does not bounce after duplicate active events or transient inactive")
            subject.setForeground(false)
            subject.setForeground(false, didEnterBackground: true) // inactive then true background.
            subject.setForeground(true)
            require(link.opened.count == count + 1 && subject.connectionRequested && !subject.controlsEnabled,
                    "A genuine leave and reopen reconnects after manual Disconnect")
            link.arm(); require(subject.isReady && subject.state.isNeutral, "Reopen after Disconnect starts neutral")
            subject.stop()
            let reopenedLink = IntentCheckTransport(), reopened = model(store, reopenedLink, clock)
            require(reopenedLink.opened.isEmpty, "Cold reopening after Disconnect still waits for an active scene")
            reopened.setForeground(true); require(reopenedLink.opened.count == 1, "A fresh process reopens the last bridge after Disconnect")
            reopened.stop()
        }
        // Practice is an explicit durable opt-out and wins over any old intent.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock); connect(subject, link)
            let oldIntent = store.data(forKey: ControllerViewModel.connectionIntentKey)!
            subject.setMode(.practice)
            store.set(oldIntent, forKey: ControllerViewModel.connectionIntentKey)
            subject.setMode(.practice) // Explicit no-op must also preserve opt-out.
            subject.setForeground(false, didEnterBackground: true); subject.setForeground(true)
            let restoredLink = IntentCheckTransport(), restored = model(store, restoredLink, clock)
            restored.setForeground(true)
            require(restored.mode == .practice && !restored.connectionRequested && restoredLink.opened.isEmpty,
                    "Practice stays local across return/relaunch despite stale legacy intent")
            restored.setMode(.bridge); restored.connect(); restoredLink.arm()
            require(restored.isReady, "Explicit Connect leaves Practice opt-out")
            restored.stop()
        }
        // A first install has no target; explicit Save opts a validated target into later reopening.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock)
            subject.setForeground(true)
            require(link.opened.isEmpty && subject.mode == .practice, "No settings means no automatic connection")
            subject.host = "192.168.1.90"; subject.portText = "43000"
            let freshLink = IntentCheckTransport(), fresh = model(store, freshLink, clock)
            fresh.setForeground(true)
            require(freshLink.opened.isEmpty, "Uncommitted first-run form text is never a saved bridge")
            subject.saveSettings()
            let configuredLink = IntentCheckTransport(), configured = model(store, configuredLink, clock)
            configured.setForeground(true)
            require(configuredLink.opened.count == 1 && configuredLink.opened.last?.0 == "192.168.1.90", "Explicit Save remembers the intended bridge for the next opening")
            configured.stop()
        }
        // Upgrade uses validated old saved settings once, retaining exact transport capabilities.
        for trigger in [BridgeTriggerMode.off, .adjustable, .usbButtons, .cronusZen] {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            store.set("192.168.1.80", forKey: "bridge.host"); store.set("42736", forKey: "bridge.port")
            store.set(BridgeProtocolVersion.scx2.rawValue, forKey: "bridge.protocol")
            store.set(trigger.rawValue, forKey: "bridge.triggerMode")
            store.set(trigger == .adjustable, forKey: "bridge.triggerPressure")
            let protected = Data("existing profile and layout".utf8); store.set(protected, forKey: "controller.profiles.v1")
            let subject = model(store, link, clock)
            require(link.opened.isEmpty && !subject.controlsEnabled, "Legacy settings restore without connecting during construction")
            subject.setForeground(true)
            require(link.hello.revision == trigger.revision && subject.bridgeTriggerMode == trigger,
                    "Legacy trigger revision is retained on automatic first opening")
            require(store.data(forKey: "controller.profiles.v1") == protected, "Legacy upgrade preserves profile bytes")
            subject.stop()
        }
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            store.set("192.168.1.81", forKey: "bridge.host"); store.set("42735", forKey: "bridge.port")
            // Missing protocol is an older SCX1 preference, not permission to upgrade it.
            let subject = model(store, link, clock); subject.setForeground(true)
            require(subject.bridgeProtocol == .scx1 && link.legacySent.last?.kind == .hello && link.sent.isEmpty,
                    "Legacy SCX1 stays SCX1 on automatic opening")
            subject.stop()
        }
        // Explicit invalid Save blocks the old remembered address, including a fresh process.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock); connect(subject, link)
            subject.host = "invalid"; subject.saveSettings()
            let count = link.opened.count
            subject.setForeground(false, didEnterBackground: true); subject.setForeground(true)
            let restoredLink = IntentCheckTransport(), restored = model(store, restoredLink, clock)
            restored.setForeground(true)
            require(link.opened.count == count && restoredLink.opened.isEmpty,
                    "Invalid saved settings block old-address resurrection after return or relaunch")
            subject.stop()
        }
        // Explicitly saving an offline new target must not resurrect the previous bridge.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = model(store, link, clock); connect(subject, link)
            subject.host = "192.168.1.99"; subject.portText = "43000"; subject.saveSettings()
            require(link.opened.last?.0 == "192.168.1.99", "Explicit save tries the newly configured endpoint")
            let restoredLink = IntentCheckTransport(), restored = model(store, restoredLink, clock)
            restored.setForeground(true)
            require(restoredLink.opened.last?.0 == "192.168.1.99" && restoredLink.opened.last?.1 == 43000,
                    "Cold opening keeps the latest explicitly saved endpoint even while offline")
            restored.stop(); subject.stop()
        }
        // Missing, malformed, unknown or unsafe records never open a network socket.
        for value: Any in [Data("not JSON".utf8), Data(repeating: 32, count: 4097), "not Data",
                          try JSONSerialization.data(withJSONObject: ["version": 9, "practiceSelected": false])] {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            store.set("192.168.1.80", forKey: "bridge.host"); store.set("42736", forKey: "bridge.port")
            store.set(value, forKey: ControllerViewModel.automaticConnectionKey)
            let subject = model(store, link, clock); subject.setForeground(true)
            require(link.opened.isEmpty, "Bad new record does not fall back to older saved settings")
        }
        for host in ["", "invalid", "0.1.2.3", "224.0.0.1", "255.255.255.255"] {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            store.set(host, forKey: "bridge.host"); store.set("42736", forKey: "bridge.port")
            let subject = model(store, link, clock); subject.setForeground(true)
            require(link.opened.isEmpty, "Invalid legacy address is never automatically used")
        }
        for port in ["0", "65536", "not a port"] {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            store.set("192.168.1.80", forKey: "bridge.host"); store.set(port, forKey: "bridge.port")
            let subject = model(store, link, clock); subject.setForeground(true)
            require(link.opened.isEmpty, "Invalid legacy port is never automatically used")
        }
        for key in ["bridge.protocol", "bridge.triggerMode"] {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            store.set("192.168.1.80", forKey: "bridge.host"); store.set("42736", forKey: "bridge.port")
            store.set("unknown future option", forKey: key)
            let subject = model(store, link, clock); subject.setForeground(true)
            require(link.opened.isEmpty, "Unknown saved protocol/trigger setting is not guessed")
        }
        // Old valid but expired intent upgrades independently of old clock timestamps.
        do {
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let original = model(store, link, clock); connect(original, link)
            store.removeObject(forKey: ControllerViewModel.automaticConnectionKey)
            clock.advance(86_400)
            let restoredLink = IntentCheckTransport(), restored = model(store, restoredLink, clock)
            require(restoredLink.opened.isEmpty, "Old expired intent still waits for active foreground")
            restored.setForeground(true)
            require(restoredLink.opened.count == 1 && !restored.controlsEnabled, "Upgrade can use a valid old endpoint after a day away")
            restored.stop(); original.stop()
        }
        // The production file path stays independent of large legacy profile preferences.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoconnect-files-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("automatic-connection.json")
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let protected = Data(repeating: 17, count: 18 * 1024 * 1024)
            store.set(protected, forKey: "controller.profiles.v1")
            func fileModel(_ link: IntentCheckTransport) -> ControllerViewModel {
                ControllerViewModel(defaults: store, transport: link, clock: { clock.uptime },
                    wallClock: { clock.wall }, resumeClock: { clock.uptime }, automaticTimer: false,
                    automaticConnectionStorageURL: url)
            }
            let subject = fileModel(link); connect(subject, link)
            require(FileManager.default.fileExists(atPath: url.path) && subject.automaticConnectionIssue == nil,
                    "Connection choice writes a separately verified native file")
            require(store.data(forKey: ControllerViewModel.automaticConnectionKey) == nil &&
                    store.data(forKey: "controller.profiles.v1") == protected,
                    "Native connection persistence does not grow or rewrite large legacy profile preferences")
            let bytes = try Data(contentsOf: url)
            let restoreLink = IntentCheckTransport(), restored = fileModel(restoreLink)
            let restoredBytes = try Data(contentsOf: url)
            require(restoreLink.opened.isEmpty && restoredBytes == bytes,
                    "Ordinary file-backed construction neither connects nor rewrites the existing file")
            restored.setForeground(true); require(restoreLink.opened.count == 1, "Fresh file-backed model opens the remembered bridge")
            restored.setMode(.practice)
            let practiceBytes = try Data(contentsOf: url)
            let practiceLink = IntentCheckTransport(), practice = fileModel(practiceLink)
            practice.setForeground(true)
            require(practiceLink.opened.isEmpty && practice.mode == .practice && practiceBytes != bytes,
                    "Explicit Practice persists durably in the native file")
            let corrupt = Data("do not replace without explicit choice".utf8)
            try corrupt.write(to: url)
            let brokenLink = IntentCheckTransport(), broken = fileModel(brokenLink)
            broken.setForeground(true)
            let retainedCorrupt = try Data(contentsOf: url)
            require(brokenLink.opened.isEmpty && broken.automaticConnectionIssue != nil && retainedCorrupt == corrupt,
                    "A corrupt native record blocks fallback and preserves exact bytes")
            broken.setMode(.practice)
            let recoveries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("automatic-connection-recovery-") }
            let recoveryBytes = recoveries.count == 1 ? try Data(contentsOf: recoveries[0]) : Data()
            require(recoveries.count == 1 && recoveryBytes == corrupt && broken.automaticConnectionIssue == nil,
                    "Explicit replacement preserves corrupt native bytes before saving a new Practice choice")
            subject.stop(); restored.stop()
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoconnect-write-failure-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let blocker = directory.appendingPathComponent("not-a-directory")
            let original = Data("preserve this file".utf8); try original.write(to: blocker)
            let store = defaults(), link = IntentCheckTransport(), clock = IntentCheckClock()
            let subject = ControllerViewModel(defaults: store, transport: link, clock: { clock.uptime },
                automaticTimer: false, automaticConnectionStorageURL: blocker.appendingPathComponent("settings.json"))
            subject.setMode(.practice)
            require(subject.automaticConnectionIssue != nil && subject.statusDetail.contains("could not be saved"),
                    "Failed native save is published visibly instead of claiming durable Practice")
            let blockerBytes = try Data(contentsOf: blocker)
            require(blockerBytes == original && link.opened.isEmpty,
                    "Failed native save preserves existing files and sends no traffic")
        }
        print("PASS: \(checks) persistent connection and automatic-opening app checks; no hardware output.")
    }
}

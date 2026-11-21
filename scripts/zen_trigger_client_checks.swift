import Foundation
import ControllerCore

@MainActor final class USBTriggerTestTransport: BridgeTransporting {
    var onReady: (() -> Void)?; var onMessage: ((Data) -> Void)?; var onFailure: ((String) -> Void)?
    var sent: [SCX2Packet] = []; var stopped: [SCX2Packet] = []
    func open(host: String, port: UInt16) { onReady?() }
    func send(_ data: Data) { sent.append(try! SCX2Codec.decode(data)) }
    func close(afterSending data: Data?) { if let data { stopped.append(try! SCX2Codec.decode(data)) } }
    func ready(available: Bool = true) {
        let h = sent.last!
        onMessage?(try! SCX2Codec.encode(.init(kind: .ready, session: h.session, boot: .init(uuid: UUID()),
            challenge: available ? .init(uuid: UUID()) : .zero, hidReady: available, revision: h.revision,
            pressureCapability: available && h.revision == .pressure,
            usbButtonTriggerCapability: available && h.revision == .usbButtons,
            usbPressureCapability: available && h.revision == .usbPressure)))
    }
    func ack() {
        let p = sent.last!
        onMessage?(try! SCX2Codec.encode(.init(kind: .ack, session: p.session, boot: p.boot, challenge: p.challenge,
                                            sequence: p.sequence, hidReady: true, revision: p.revision)))
    }
}
@MainActor final class USBTriggerTestClock { var now = 100.0; var wall = 1_000.0 }
@main struct ZenTriggerClientChecks {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ ok: @autoclosure () -> Bool, _ label: String) {
            checks += 1; if !ok() { fatalError("FAIL: \(label)") }
        }
        let suite = "ZenTriggerChecks.\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let aim = ProfileControl(name: "Aim + fire", payload: "LT:0.5,RT:0.7")
        var profile = try ControllerProfile(name: "Existing GTA", controls: [aim],
            portrait: [.init(id: aim.id, position: .init(x: 0.2, y: 0.6))],
            landscape: [.init(id: aim.id, position: .init(x: 0.1, y: 0.4))])
        let drive = ProfilePage(name: "Drive")
        profile.pages.append(drive)
        let saved = try ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile]))
        prefs.set(saved, forKey: ProfileControllerViewModel.libraryKey)
        prefs.set("usbButtons", forKey: "bridge.triggerMode")
        prefs.set("127.0.0.1", forKey: "bridge.host")
        prefs.set("scx2", forKey: "bridge.protocol")
        let clock = USBTriggerTestClock(), link = USBTriggerTestTransport()
        let p = ProfileControllerViewModel(defaults: prefs, transport: link, clock: { clock.now }, automaticTimer: false)
        check(p.bridgeTriggerMode == .usbButtons, "existing XAC mode is not silently changed")
        check(prefs.data(forKey: ProfileControllerViewModel.libraryKey) == saved, "loading preserves exact saved profile")
        p.setBridgeTriggerMode(.cronusZen); p.setMode(.bridge); p.connect()
        check(link.sent.last?.revision == .usbPressure && link.sent.last?.usbPressureCapability == true, "Zen negotiates revision5 capability4")
        link.ready(); check(!p.isReady && link.sent.last?.output?.isNeutral == true, "neutral report precedes enable")
        link.ack(); check(p.isReady && p.allowsTriggerControls && p.usesTriggerPressure, "Zen enables fractional trigger controls")
        _ = p.handleInput(.begin(contact: 1, control: aim.id, position: .zero), epoch: p.inputEpoch); link.ack()
        check(abs((link.sent.last?.output?.leftTrigger ?? -1) - 0.5) < 0.00002, "existing LT50 percent retained")
        check(abs((link.sent.last?.output?.rightTrigger ?? -1) - 0.7) < 0.00002, "existing RT70 percent retained")
        _ = p.handleInput(.end(contact: 1), epoch: p.inputEpoch); link.ack()
        check(link.sent.last?.output?.isNeutral == true, "lift releases both independently encoded triggers")
        p.selectPage(drive.id)
        check(p.connectionRequested && p.bridgeTriggerMode == .cronusZen, "page transition keeps Zen connection intent")
        link.ready(); link.ack()
        p.releaseAll()
        check(p.connectionRequested && p.practiceState == .neutral, "release all preserves intended Zen connection")
        link.ready(); link.ack()
        check(prefs.data(forKey: ProfileControllerViewModel.libraryKey) != nil, "profile remains present after page transition")
        // Page selection legitimately updates activePageID; every control, placement and payload stays identical.
        let restoredLibrary = try ControllerProfileLibraryCodec.decode(prefs.data(forKey: ProfileControllerViewModel.libraryKey)!)
        let restored = restoredLibrary.profiles[0]
        check(restored.controls == profile.controls && restored.portrait == profile.portrait && restored.landscape == profile.landscape,
              "Zen preserves all controls and both orientation mappings")
        p.stop()
        let c = ControllerViewModel(defaults: prefs, transport: link, clock: { clock.now }, wallClock: { clock.wall },
            resumeClock: { clock.now }, automaticTimer: false)
        c.setForeground(true) // New instances wait for scene activation before opening a saved bridge.
        c.setMode(.bridge); c.connect(); link.ready(); link.ack()
        check(c.isReady, "restored Zen fixture completes its own neutral handshake")
        c.updateOutput(.init(leftTrigger: 0.1, rightTrigger: 0.9), epoch: c.inputEpoch); link.ack()
        c.setForeground(false); clock.now += 10; clock.wall += 10
        let returnedLink = USBTriggerTestTransport()
        let returned = ControllerViewModel(defaults: prefs, transport: returnedLink, clock: { clock.now }, wallClock: { clock.wall },
            resumeClock: { clock.now }, automaticTimer: false)
        check(returned.connectionRequested, "brief relaunch retains Zen connection intent")
        returned.setForeground(true)
        check(returnedLink.sent.last?.revision == .usbPressure, "resume cannot fall back to circuit or binary mode")
        returnedLink.ready(); returnedLink.ack()
        check(returned.outputState.isNeutral, "resume never restores held trigger values")
        returned.setBridgeTriggerMode(.usbButtons); returned.saveSettings()
        check(returnedLink.sent.last?.revision == .usbButtons, "existing XAC full-press path remains selectable")
        returnedLink.ready(); returnedLink.ack()
        returned.updateOutput(.init(leftTrigger: 0.5, rightTrigger: 0.7), epoch: returned.inputEpoch)
        check(returned.outputState.leftTrigger == 1 && returned.outputState.rightTrigger == 1, "XAC retains its accepted full-press behavior")
        returned.stop()
        let absent = ControllerViewModel(defaults: prefs, transport: returnedLink, clock: { clock.now }, automaticTimer: false)
        absent.setForeground(true) // Install this instance's transport callbacks before the peer replies.
        absent.setBridgeTriggerMode(.cronusZen); absent.setMode(.bridge); absent.connect(); returnedLink.ready(available: false)
        check(!absent.isReady && absent.statusDetail.contains("Cronus Zen"), "unavailable Zen output stays paused with actionable message")
        absent.stop()
        print("PASS: \(checks) Cronus Zen app-client checks; no physical output.")
    }
}

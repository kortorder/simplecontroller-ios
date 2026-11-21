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
@main struct USBTriggerClientChecks {
    @MainActor static func main() throws {
        var count = 0
        func check(_ ok: @autoclosure () -> Bool, _ label: String) {
            count += 1; if !ok() { fatalError("FAIL: \(label)") }
        }
        let suite = "USBTriggerChecks.\(UUID())"
        let prefs = UserDefaults(suiteName: suite)!
        let domain = suite + ".profile", profilePrefs = UserDefaults(suiteName: domain)!
        defer { prefs.removePersistentDomain(forName: suite); profilePrefs.removePersistentDomain(forName: domain) }
        let clock = USBTriggerTestClock(), link = USBTriggerTestTransport()
        func model(_ defaults: UserDefaults = prefs, transport: USBTriggerTestTransport? = nil) -> ControllerViewModel {
            ControllerViewModel(defaults: defaults, transport: transport ?? USBTriggerTestTransport(), clock: { clock.now }, wallClock: { clock.wall },
                                resumeClock: { clock.now }, automaticTimer: false)
        }
        let c = model(transport: link)
        check(c.bridgeTriggerMode == .off && !c.allowsTriggerControls, "fresh setting defaults off")
        check(prefs.object(forKey: "bridge.triggerMode") == nil, "loading does not write a new mode setting")
        prefs.set(true, forKey: "bridge.triggerPressure")
        check(model().bridgeTriggerMode == .adjustable, "old enabled pressure migrates in memory")
        prefs.set(false, forKey: "bridge.triggerPressure")
        check(model().bridgeTriggerMode == .off, "old disabled pressure stays off")
        c.setBridgeTriggerMode(.usbButtons); c.host = "127.0.0.1"; c.setMode(.bridge); c.connect()
        check(link.sent.last?.revision == .usbButtons && link.sent.last?.usbButtonTriggerCapability == true,
              "USB output explicitly negotiates format4cap2")
        check(prefs.string(forKey: "bridge.triggerMode") == "usbButtons", "explicit USB selection saved")
        link.ready(); check(!c.controlsEnabled && link.sent.last?.output?.isNeutral == true, "neutral first before controls")
        link.ack(); check(c.controlsEnabled && c.allowsTriggerControls && !c.usesTriggerPressure, "USB triggers enabled only after ACK")
        for positive in [0.000001, 0.1, 0.5, 0.7, 1.0] {
            c.updateOutput(.init(gamepad: .init(leftStick: .init(x: 0.4), rightStick: .init(y: 0.5)),
                                 leftTrigger: positive, rightTrigger: positive), epoch: c.inputEpoch)
            check(c.outputState.leftTrigger == 1 && c.outputState.rightTrigger == 1, "positive pressure \(positive) becomes full")
            check(c.outputState.gamepad.leftStick.x == 0.4 && c.outputState.gamepad.rightStick.y == 0.5, "sticks retained")
            link.ack()
            c.updateOutput(.neutral, epoch: c.inputEpoch); link.ack()
            check(c.outputState.isNeutral, "zero releases both")
        }
        c.updateOutput(.init(gamepad: .init(buttons: [.leftTrigger, .rightTrigger, .a])), epoch: c.inputEpoch)
        check(c.outputState.leftTrigger == 1 && c.outputState.rightTrigger == 1 && c.outputState.gamepad.buttons == [.a],
              "digital trigger commands join pressure without leaking into button mask")
        link.ack()
        let oldEpoch = c.inputEpoch
        c.releaseAll()
        check(c.connectionRequested && !c.controlsEnabled && c.outputState.isNeutral, "release all rearms neutral USB mode")
        check(link.sent.last?.revision == .usbButtons, "rearm retains USB mode")
        c.updateOutput(.init(rightTrigger: 1), epoch: oldEpoch)
        check(c.outputState.isNeutral, "stale touches cannot refill USB trigger")
        link.ready(); link.ack()
        c.setForeground(false); clock.now += 10; clock.wall += 10
        let returnedLink = USBTriggerTestTransport(), returned = model(transport: returnedLink)
        check(returned.connectionRequested && returnedLink.sent.isEmpty, "relaunch waits for real foreground")
        returned.setForeground(true)
        check(returnedLink.sent.last?.revision == .usbButtons, "brief relaunch preserves USB capability")
        returnedLink.ready(); returnedLink.ack()
        check(returned.outputState.isNeutral, "brief relaunch never restores triggers")
        returned.setBridgeTriggerMode(.adjustable); returned.saveSettings()
        check(returnedLink.sent.last?.revision == .pressure && returned.outputState.isNeutral, "settingchange negotiates proportional independently")
        returnedLink.ready(); returnedLink.ack()
        returned.updateOutput(.init(rightTrigger: 0.7), epoch: returned.inputEpoch)
        check(returned.outputState.rightTrigger == 0.7, "adjustable mode preserves original pressure")
        returned.stop(); check(!returned.connectionRequested, "explicit stop cancels USB or pressure request")

        let unavailableLink = USBTriggerTestTransport(), unavailable = model(transport: unavailableLink)
        unavailable.setForeground(true) // A saved bridge is restored only after scene activation.
        unavailable.stop() // This separate scenario tests a fresh manual Connect, not automatic availability waiting.
        unavailable.setBridgeTriggerMode(.usbButtons); unavailable.setMode(.bridge); unavailable.host = "127.0.0.1"; unavailable.connect()
        unavailableLink.ready(available: false)
        check(!unavailable.isReady && unavailable.statusDetail.contains("USB trigger"), "missing USB firmware does not downgrade")
        unavailable.stop()
        let oldLink = USBTriggerTestTransport(), old = model(transport: oldLink)
        old.setForeground(true) // Exercise the new instance, not an inactive restored connection.
        old.setBridgeTriggerMode(.usbButtons); old.setMode(.bridge); old.connect()
        clock.now += 3.1; clock.wall += 3.1; old.tick()
        check(old.statusDetail.contains("matching phone Pico update"), "old peer timeout gives actionable USB firmware advice")
        old.stop()
        // Existing layouts and requested pressure remain byte-identical while real profile output is binary.
        let lt = ProfileControl(name: "Aim", payload: "LT:0.5"), rt = ProfileControl(name: "Fire", payload: "RT:0.7")
        let leftStick = ProfileControl(kind: .leftStick)
        var aim = ProfileControl(name: "Direct Aim + fire", payload: "LT:0.5,RT:0.7", controlWidth: 180, controlHeight: 100)
        aim.buttonAim.enabled = true
        aim.buttonAim.tuning = .init(output: .rightStick, fullDisplacement: 108, deadzone: 8)
        let controls = [lt, rt, leftStick, aim], placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        var profile = try ControllerProfile(name: "USB full press", controls: controls, portrait: placements, landscape: placements)
        var ringConfig = FloatingRingConfig(startRole: .aim)
        ringConfig.aim.tuning.output = .rightStick
        ringConfig.knobs[0].fire = .init(mode: .hold, adsPayload: "LT:0.5", firePayload: "RT:0.7",
                                        retainADSOnLift: true, retainFireOnLift: true)
        let ring = FloatingRingZone(portraitGeometry: .init(canvasWidth: 700, canvasHeight: 900,
            zone: .init(x: 0, y: 0, width: 700, height: 900)), config: ringConfig)
        profile.pages[0].floatingRingZones = [ring]
        let bytes = try ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile]))
        profilePrefs.set(bytes, forKey: ProfileControllerViewModel.libraryKey)
        let pl = USBTriggerTestTransport()
        let p = ProfileControllerViewModel(defaults: profilePrefs, transport: pl, clock: { clock.now }, automaticTimer: false)
        p.setBridgeTriggerMode(.usbButtons); p.setMode(.bridge); p.host = "127.0.0.1"; p.connect(); pl.ready(); pl.ack()
        _ = p.handleInput(.begin(contact: 1, control: leftStick.id, position: .init(x: 0.4)), epoch: p.inputEpoch); pl.ack()
        _ = p.handleInput(.begin(contact: 2, control: lt.id, position: .zero), epoch: p.inputEpoch); pl.ack()
        _ = p.handleInput(.begin(contact: 3, control: rt.id, position: .zero), epoch: p.inputEpoch); pl.ack()
        check(pl.sent.last?.output?.leftTrigger == 1 && pl.sent.last?.output?.rightTrigger == 1, "profile Aim and Fire coexist")
        check(pl.sent.last?.output?.gamepad.leftStick.x ?? 0 > 0, "trigger input coexists with movement")
        check(p.practiceState.leftTrigger == 0.5 && p.practiceState.rightTrigger == 0.7, "requested pressure remains original")
        _ = p.handleInput(.end(contact: 2), epoch: p.inputEpoch); pl.ack()
        check(pl.sent.last?.output?.leftTrigger == 0 && pl.sent.last?.output?.rightTrigger == 1, "independent trigger release")
        p.releaseAll(); check(p.connectionRequested && p.practiceState == .neutral, "profile release all clears full triggers")
        pl.ready(); pl.ack()
        _ = p.handleInput(.beginButton(contact: 4, control: aim.id,
            sample: .init(x: 90, y: 50, width: 180, height: 100)), epoch: p.inputEpoch); pl.ack()
        check(pl.sent.last?.output?.leftTrigger == 1 && pl.sent.last?.output?.rightTrigger == 1,
              "existing direct Aim + fire activates both USB triggers")
        _ = p.handleInput(.moveButtonBatch(contact: 4,
            samples: [.init(x: 148, y: 50, width: 180, height: 100)]), epoch: p.inputEpoch); pl.ack()
        check((pl.sent.last?.output?.gamepad.rightStick.x ?? 0) > 0.4 && pl.sent.last?.output?.rightTrigger == 1,
              "direct aim movement retains fire; external chair arbitration happens at XAC")
        _ = p.handleInput(.endButton(contact: 4,
            finalSamples: [.init(x: 148, y: 50, width: 180, height: 100)]), epoch: p.inputEpoch); pl.ack()
        check(pl.sent.last?.output?.isNeutral == true, "lifting direct Aim + fire releases its sticks and USB triggers")
        let ringSession = UUID(), ringEpoch = p.inputEpoch
        _ = p.handleInput(.begin(contact: 5, control: leftStick.id, position: .init(x: 0.4)), epoch: ringEpoch); pl.ack()
        let ringAccepted = p.handleInput(.beginFloatingRing(contact: 6, zoneID: ring.id, sessionID: ringSession,
            point: .init(x: 300, y: 300), usable: .init(x: 0, y: 0, width: 700, height: 900)), epoch: ringEpoch); pl.ack()
        check(ringAccepted && p.floatingRingStates[ring.id]?.visible == true &&
              pl.sent.last?.output?.leftTrigger == 1 && pl.sent.last?.output?.rightTrigger == 1,
              "floating Aim + fire ring activates both full USB triggers")
        _ = p.handleInput(.endFloatingRing(contact: 6, sessionID: ringSession, samples: []), epoch: ringEpoch); pl.ack()
        check(pl.sent.last?.output?.leftTrigger == 1 && pl.sent.last?.output?.rightTrigger == 1,
              "ring retains configured aim and fire after lift")
        _ = p.handleInput(.floatingRingAction(zoneID: ring.id, sessionID: ringSession, action: .finish), epoch: ringEpoch); pl.ack()
        check(pl.sent.last?.output?.leftTrigger == 0 && pl.sent.last?.output?.rightTrigger == 0 &&
              (pl.sent.last?.output?.gamepad.leftStick.x ?? 0) > 0,
              "Finish ring clears USB triggers without cancelling independent movement")
        p.releaseAll(); check(p.floatingRingStates.isEmpty && p.practiceState == .neutral && p.connectionRequested,
                             "Release all clears remaining ring state and preserves USB connection")
        check(profilePrefs.data(forKey: ProfileControllerViewModel.libraryKey) == bytes, "USB mode never rewrites saved profile")
        p.stop()
        // Corrupt, conflicting, or unknown modes cannot revive an old connection intent.
        c.stop()
        for mode in ["unsupported", "adjustable"] {
            let bad: [String: Any] = ["endpoint": ["host": "127.0.0.1", "port": 42736, "protocolVersion": "scx2", "pressure": false, "triggerMode": mode],
                                      "uptime": clock.now, "wallTime": clock.wall]
            prefs.set(try JSONSerialization.data(withJSONObject: bad), forKey: ControllerViewModel.connectionIntentKey)
            // Build 38's automatic choice is authoritative over the legacy intent.
            // Corrupt the same endpoint in that record to retain this rejection test.
            let automatic: [String: Any] = ["version": 1, "lastEndpoint": bad["endpoint"]!, "practiceSelected": false]
            prefs.set(try JSONSerialization.data(withJSONObject: automatic), forKey: ControllerViewModel.automaticConnectionKey)
            check(!model().connectionRequested, "invalid/conflicting stored mode rejected: \(mode)")
        }
        print("PASS: \(count) USB-trigger app-client checks; no physical output.")
    }
}

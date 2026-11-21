import Foundation
import ControllerCore

@MainActor
final class TriggerCheckTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var sent: [SCX2Packet] = []
    var closed: [SCX2Packet] = []
    func open(host: String, port: UInt16) { onReady?() }
    func send(_ data: Data) { sent.append(try! SCX2Codec.decode(data)) }
    func close(afterSending data: Data?) { if let data { closed.append(try! SCX2Codec.decode(data)) } }
    func reply(_ packet: SCX2Packet) { onMessage?(try! SCX2Codec.encode(packet)) }
    func ack() {
        let p = sent.last!
        reply(.init(kind: .ack, session: p.session, boot: p.boot, challenge: p.challenge,
                    sequence: p.sequence, hidReady: true, revision: p.revision))
    }
    func offer(pressure: Bool = true, revision: SCX2Revision = .pressure) {
        let p = sent.last!
        reply(.init(kind: .ready, session: p.session, boot: .init(uuid: UUID()), challenge: pressure ? .init(uuid: UUID()) : .zero,
                    hidReady: pressure, revision: revision, pressureCapability: pressure && revision == .pressure))
    }
}
@MainActor final class TriggerCheckClock { var now: TimeInterval = 10 }
@MainActor final class LegacyTriggerCheckTransport: BridgeTransporting {
    var onReady: (() -> Void)?; var onMessage: ((Data) -> Void)?; var onFailure: ((String) -> Void)?
    var sent: [BridgePacket] = []
    func open(host: String, port: UInt16) { onReady?() }
    func send(_ data: Data) { sent.append(try! BridgeCodec.decode(data)) }
    func close(afterSending data: Data?) {}
}

@main struct TriggerClientChecks {
    @MainActor static func main() throws {
        var checks = 0, failures = 0
        func check(_ ok: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            if !ok() { failures += 1; print("FAIL: \(label)") }
        }
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) <= 1.0 / 65535 } ?? false }
        let suite = "SimpleController.TriggerChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let link = TriggerCheckTransport(), clock = TriggerCheckClock()
        let connection = ControllerViewModel(defaults: defaults, transport: link, clock: { clock.now }, automaticTimer: false)
        check(!connection.bridgeTriggerPressureEnabled, "old settings default to legacy output")
        connection.setBridgeTriggerPressureEnabled(true)
        connection.setMode(.bridge); connection.host = "127.0.0.1"; connection.connect()
        check(link.sent.last?.revision == .pressure && link.sent.last?.pressureCapability == true, "explicit pressure handshake")
        link.offer()
        check(!connection.isReady && link.sent.last?.output?.isNeutral == true, "neutral output precedes enabling controls")
        link.ack()
        check(connection.isReady, "both-output acknowledgement enables pressure client")
        for pressure in [0.1, 0.5, 1.0, 0.2, 0.8, 0.0] {
            connection.updateOutput(.init(gamepad: .init(buttons: [.a, .rightTrigger]), leftTrigger: 0.5,
                                          rightTrigger: pressure), epoch: connection.inputEpoch)
            check(near(link.sent.last?.output?.rightTrigger, pressure), "fractional update \(pressure) reaches the wire")
            check(link.sent.last?.output?.gamepad.buttons == [.a], "trigger pressure is separate from USB buttons")
            link.ack()
        }
        let staleEpoch = connection.inputEpoch
        connection.setBridgeTriggerPressureEnabled(false)
        check(!connection.isReady && connection.outputState.isNeutral && link.closed.last?.revision == .pressure,
              "changing capability sends STOP and clears complete output")
        connection.updateOutput(.init(rightTrigger: 1), epoch: staleEpoch)
        check(connection.outputState.isNeutral, "old input cannot restore pressure")
        connection.setBridgeTriggerPressureEnabled(true); connection.connect(); link.offer(pressure: false)
        check(!connection.isReady && connection.statusDetail.contains("trigger"), "missing analog backend fails closed")
        connection.connect(); link.offer(revision: .legacy)
        check(!connection.isReady, "old revision never arms adjustable output")
        clock.now += 3.1; connection.tick()
        check(connection.statusDetail.contains("pressure-capable"), "old peer timeout explains required firmware")
        connection.connect(); link.offer(); link.ack()
        connection.updateOutput(.init(rightTrigger: 0.7), epoch: connection.inputEpoch); link.ack()
        clock.now += 0.8; connection.tick()
        check(!connection.isReady && connection.outputState.isNeutral, "lost acknowledgements clear trigger state")
        connection.connect(); link.offer(); link.ack()
        connection.updateOutput(.init(rightTrigger: .nan), epoch: connection.inputEpoch)
        check(!connection.isReady && connection.outputState.isNeutral, "invalid pressure stops rather than preserving a hold")
        connection.saveSettings()
        let restored = ControllerViewModel(defaults: defaults, transport: TriggerCheckTransport(), automaticTimer: false)
        check(restored.bridgeTriggerPressureEnabled && restored.outputState.isNeutral, "saved option never restores held pressure")

        // Exercise actual profile ownership and delayed Pulse through the new connection.
        let low = ProfileControl(name: "Low", payload: "RT:0.2")
        let pulse = ProfileControl(name: "Pulse", payload: "RT:0.8P0.2")
        let left = ProfileControl(name: "Left", payload: "LT:0.5")
        let movement = ProfileControl(kind: .leftStick)
        let camera = ProfileControl(payload: "CAMERA_FOLLOW")
        let controls = [low, pulse, left, movement, camera]
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        let profile = try ControllerProfile(name: "Trigger checks", controls: controls, portrait: positions, landscape: positions)
        let bytes = try ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile]))
        defaults.set(bytes, forKey: ProfileControllerViewModel.libraryKey)
        let profileLink = TriggerCheckTransport()
        let model = ProfileControllerViewModel(defaults: defaults, transport: profileLink, clock: { clock.now }, automaticTimer: false)
        model.setForeground(true) // A restored connection must wait for the real scene activation.
        model.setMode(.bridge); model.connect(); profileLink.offer(); profileLink.ack()
        check(model.isReady, "profile model negotiates pressure output")
        func input(_ event: ProfileInputEvent) { _ = model.handleInput(event, epoch: model.inputEpoch) }
        input(.begin(contact: 1, control: low.id, position: .zero)); profileLink.ack()
        check(near(profileLink.sent.last?.output?.rightTrigger, 0.2), "profile pressure reaches transport")
        input(.begin(contact: 2, control: pulse.id, position: .zero)); profileLink.ack()
        check(near(profileLink.sent.last?.output?.rightTrigger, 0.8), "stronger pulse overrides lower independent owner")
        input(.end(contact: 2))
        input(.begin(contact: 3, control: left.id, position: .zero)); profileLink.ack()
        check(near(profileLink.sent.last?.output?.leftTrigger, 0.5), "left and right pressure coexist")
        clock.now += 0.21; model.tickInput(); profileLink.ack()
        check(near(profileLink.sent.last?.output?.rightTrigger, 0.2) && near(profileLink.sent.last?.output?.leftTrigger, 0.5),
              "pulse expiry restores weaker right owner while preserving left")
        check(abs(model.practiceState.rightTrigger - 0.2) < 0.000001, "local pressure keeps original precision")
        model.setForeground(false)
        check(!model.isReady && model.practiceState == .neutral && profileLink.closed.last?.kind == .stop,
              "background cancels pulse/hold and connection")
        check(defaults.data(forKey: ProfileControllerViewModel.libraryKey) == bytes, "new transport never rewrites saved layouts")
        model.setForeground(true); model.setMode(.practice); model.setCameraFollowEnabled(true)
        input(.begin(contact: 4, control: movement.id, position: .init(x: 1)))
        clock.now += 0.201; model.tickInput(); clock.now += 0.2; model.tickInput()
        check(model.state.rightStick.x > 0, "fixture generates Practice camera motion")
        model.setMode(.bridge); model.connect(); profileLink.offer(); profileLink.ack()
        check(model.state.isNeutral && model.cameraFollowSnapshot?.requestedEnabled == false, "pressure connection clears Practice camera owner")
        input(.begin(contact: 5, control: movement.id, position: .init(x: 1))); profileLink.ack()
        input(.begin(contact: 6, control: left.id, position: .zero)); profileLink.ack()
        check(profileLink.sent.last?.output?.gamepad.rightStick == .zero && near(profileLink.sent.last?.output?.leftTrigger, 0.5),
              "adjustable trigger snapshot excludes generated Camera right stick")
        check(!model.handleInput(.accessibilityActivate(camera.id), epoch: model.inputEpoch), "pressure mode still rejects Camera actions")
        input(.begin(contact: 7, control: low.id, position: .zero)) // Leave one pressure update unacknowledged.
        model.beginLayoutEditing()
        check(!model.isReady && model.practiceState == .neutral && profileLink.closed.last?.kind == .stop,
              "editing discards pending pressure without draining its queue")
        model.cancelLayoutEditing()
        let legacyLink = LegacyTriggerCheckTransport()
        let legacy = ControllerViewModel(defaults: defaults, transport: legacyLink, clock: { clock.now }, automaticTimer: false)
        legacy.stop(); legacy.setForeground(true) // Deliberately switch this separate fixture from the saved pressure target.
        legacy.setBridgeProtocol(.scx1); legacy.setMode(.bridge); legacy.connect()
        let hello = legacyLink.sent.last!
        legacyLink.onMessage?(try BridgeCodec.encode(.init(kind: .ready, session: hello.session, sequence: 0, hidReady: true)))
        legacy.updateOutput(.init(gamepad: .init(buttons: [.a, .rightTrigger]), rightTrigger: 0.5), epoch: legacy.inputEpoch)
        check(legacy.isReady && legacyLink.sent.last?.state?.buttons == [.a] && legacy.outputState.rightTrigger == 0,
              "saved pressure option never changes SCX1's supported outputs")
        guard failures == 0 else { fatalError("\(failures) of \(checks) trigger client checks failed") }
        print("PASS: \(checks) adjustable-trigger app client checks (fake transport; no hardware output).")
    }
}

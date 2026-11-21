import Foundation
import Combine
import ControllerCore

@MainActor
final class FakeTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var sent: [BridgePacket] = []
    var closed: [BridgePacket] = []
    var opens = 0

    func open(host: String, port: UInt16) { opens += 1; onReady?() }
    func send(_ data: Data) { sent.append(try! BridgeCodec.decode(data)) }
    func close(afterSending stop: Data?) {
        if let stop { closed.append(try! BridgeCodec.decode(stop)) }
    }
    func reply(_ packet: BridgePacket) { onMessage?(try! BridgeCodec.encode(packet)) }
}

@MainActor
final class TestClock { var time: TimeInterval = 10 }

@MainActor
final class SCX2CheckTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var sent: [SCX2Packet] = []
    var closed: [SCX2Packet] = []
    var openedPort: UInt16?
    func open(host: String, port: UInt16) { openedPort = port; onReady?() }
    func send(_ data: Data) { sent.append(try! SCX2Codec.decode(data)) }
    func close(afterSending data: Data?) { if let data { closed.append(try! SCX2Codec.decode(data)) } }
    func reply(_ packet: SCX2Packet) { onMessage?(try! SCX2Codec.encode(packet)) }
    func acknowledge(_ packet: SCX2Packet) {
        reply(.init(kind: .ack, session: packet.session, boot: packet.boot, challenge: packet.challenge,
                    sequence: packet.sequence, hidReady: true))
    }
}

@main
struct ClientChecks {
    @MainActor
    static func main() throws {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("Client check failed: \(message)") }
            checks += 1
        }
        let link = FakeTransport()
        let clock = TestClock()
        let model = ControllerViewModel(transport: link, clock: { clock.time },
                                        automaticTimer: false, persistSettings: false)
        model.setBridgeProtocol(.scx1) // Keep the original compatibility checks explicit.
        let pressed = GamepadState(buttons: [.a])
        model.updateInput(pressed, epoch: model.inputEpoch)
        require(model.state == pressed && link.sent.isEmpty, "Practice never emits network output")
        let oldPracticeEpoch = model.inputEpoch
        model.releaseAll()
        model.updateInput(pressed, epoch: oldPracticeEpoch)
        require(model.state.isNeutral, "Release rejects a late gesture callback")
        model.setMode(.bridge)
        model.host = "not-an-address"
        model.connect()
        require(link.opens == 0 && !model.controlsEnabled, "Bad address cannot open a connection")
        model.host = "192.168.1.80"
        model.portText = "42735"
        model.connect()
        let session = link.sent.last!.session
        require(link.sent.last!.kind == .hello && !model.isReady, "Socket readiness is not bridge readiness")
        link.reply(BridgePacket(kind: .ready, session: UUID().uuidString, sequence: 0, hidReady: true))
        require(!model.isReady, "Wrong session cannot activate controls")
        link.reply(BridgePacket(kind: .ready, session: session, sequence: 0, hidReady: true))
        require(model.isReady && link.sent.last!.state!.isNeutral, "First accepted output is neutral")
        model.updateInput(pressed, epoch: model.inputEpoch)
        let firstPress = link.sent.last!
        require(firstPress.state == pressed, "Active touch emits the requested state")
        let oldLiveEpoch = model.inputEpoch
        model.releaseAll()
        let release = link.sent.last!
        require(release.state!.isNeutral && release.sequence > firstPress.sequence, "Release is newer than held input")
        model.updateInput(pressed, epoch: oldLiveEpoch)
        require(model.state.isNeutral, "Released canvas cannot reapply a held command")
        link.reply(BridgePacket(kind: .ack, session: session, sequence: release.sequence, hidReady: true))
        require(model.acknowledgedPackets == 1, "A valid ACK is counted")
        clock.time += 0.5
        link.reply(BridgePacket(kind: .ack, session: session, sequence: release.sequence, hidReady: true))
        require(model.acknowledgedPackets == 1, "Duplicate ACK cannot renew liveness")
        link.reply(BridgePacket(kind: .ack, session: session, sequence: 999, hidReady: true))
        require(model.acknowledgedPackets == 1, "Unsent sequence cannot renew liveness")
        clock.time += 0.26
        model.tick()
        require(!model.isReady && model.state.isNeutral && link.closed.last?.kind == .stop,
                "Missing fresh ACK stops and releases the session")
        link.reply(BridgePacket(kind: .ready, session: session, sequence: 0, hidReady: true))
        require(!model.isReady, "Late reply cannot restart a stopped session")
        model.connect()
        let secondSession = link.sent.last!.session
        require(secondSession != session, "Reconnect gets a new session")
        link.reply(BridgePacket(kind: .ready, session: secondSession, sequence: 0, hidReady: false))
        require(!model.isReady && !model.controlsEnabled, "Unready USB output cannot activate controls")
        model.connect()
        let thirdSession = link.sent.last!.session
        link.reply(BridgePacket(kind: .ready, session: thirdSession, sequence: 0, hidReady: true))
        model.updateInput(pressed, epoch: model.inputEpoch)
        model.setForeground(false)
        require(!model.controlsEnabled && model.state.isNeutral, "App interruption clears all input")
        model.setForeground(true)
        require(!model.isReady, "Returning to foreground never resumes a hold")
        model.connect()
        clock.time += 3.1
        model.tick()
        require(model.connectionRequested && !model.isReady, "Handshake timeout pauses output and schedules a fresh attempt")
        model.connect()
        let lateSession = link.sent.last!.session
        clock.time += 3.1
        link.reply(BridgePacket(kind: .ready, session: lateSession, sequence: 0, hidReady: true))
        require(!model.isReady, "Late READY cannot win a race against the timer")
        model.connect()
        let lateAckSession = link.sent.last!.session
        link.reply(BridgePacket(kind: .ready, session: lateAckSession, sequence: 0, hidReady: true))
        let lateSequence = link.sent.last!.sequence
        clock.time += 0.8
        link.reply(BridgePacket(kind: .ack, session: lateAckSession, sequence: lateSequence, hidReady: true))
        require(!model.isReady, "Late ACK cannot revive an expired hold before tick")
        model.connect()
        let lateInputSession = link.sent.last!.session
        link.reply(BridgePacket(kind: .ready, session: lateInputSession, sequence: 0, hidReady: true))
        let beforeLateInput = link.sent.count
        clock.time += 0.8
        model.updateInput(pressed, epoch: model.inputEpoch)
        require(!model.isReady && model.state.isNeutral && link.sent.count == beforeLateInput,
                "Touch callback cannot send input after liveness expires before tick")
        model.setMode(.practice)
        let sentCount = link.sent.count
        model.updateInput(pressed, epoch: model.inputEpoch)
        require(link.sent.count == sentCount, "Practice remains offline after a real session")
        model.stop()

        let suite = "SimpleControllerLayoutChecks.\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: suite)!
        defer { settings.removePersistentDomain(forName: suite) }
        let editLink = FakeTransport()
        let editor = ControllerViewModel(defaults: settings, transport: editLink,
                                         clock: { clock.time }, automaticTimer: false)
        editor.setBridgeProtocol(.scx1)
        editor.updateInput(pressed, epoch: editor.inputEpoch)
        let priorEpoch = editor.inputEpoch
        editor.beginLayoutEditing()
        require(editor.isEditingLayout && editor.state.isNeutral && !editor.controlsEnabled,
                "Editing releases held input and pauses gameplay")
        editor.updateInput(pressed, epoch: priorEpoch)
        editor.updateInput(pressed, epoch: editor.inputEpoch)
        require(editor.state.isNeutral, "Editing rejects both old and current gameplay callbacks")
        var custom = editor.layout
        for (index, id) in ControllerControlID.allCases.enumerated() {
            try custom.move(id, to: .init(x: Double(index + 1) / 22, y: 0.4), orientation: .portrait)
        }
        let editEpoch = editor.inputEpoch
        editor.updateLayout(custom, epoch: editEpoch - 1)
        require(editor.layout == .default, "Old edit callback cannot change layout")
        editor.updateLayout(custom, epoch: editEpoch)
        require(editor.layout == custom && custom.landscape == ControllerLayout.default.landscape,
                "Every control can move independently without changing the other orientation")
        editor.cancelLayoutEditing()
        require(editor.layout == .default && !editor.isEditingLayout && settings.data(forKey: "controller.layout.v1") == nil,
                "Cancel restores the original positions without saving")
        editor.beginLayoutEditing()
        editor.updateLayout(custom, epoch: editor.inputEpoch)
        editor.saveLayoutEditing()
        let restored = ControllerViewModel(defaults: settings, transport: FakeTransport(), automaticTimer: false)
        require(restored.layout == custom && !restored.isEditingLayout && restored.state.isNeutral,
                "Save persists all positions across model recreation without persisting input")
        editor.updateLayout(.default, epoch: editEpoch)
        require(editor.layout == custom, "A completed editor cannot overwrite a saved layout")

        editor.setMode(.bridge)
        editor.host = "192.168.1.80"
        editor.connect()
        let editSession = editLink.sent.last!.session
        editLink.reply(BridgePacket(kind: .ready, session: editSession, sequence: 0, hidReady: true))
        editor.updateInput(GamepadState(buttons: [.a, .leftTrigger, .rightTrigger, .guide, .share]), epoch: editor.inputEpoch)
        require(editor.state.buttons == [.a] && editLink.sent.last!.state!.buttons == [.a],
                "Unverified trigger, guide and share mappings cannot reach bridge output")
        editor.beginLayoutEditing()
        let connectionsBeforeEditing = editLink.opens
        editor.connect()
        require(editor.isReady && !editor.controlsEnabled && editor.connectionRequested && editor.state.isNeutral && editLink.sent.last?.state?.isNeutral == true && editLink.opens == connectionsBeforeEditing,
                "Legacy editing preserves the neutral connection while pausing touch input")
        editor.setForeground(false)
        editor.updateLayout(.default, epoch: editor.inputEpoch)
        require(editor.layout == custom, "Background edit callbacks cannot move controls")
        editor.setForeground(true)
        editor.cancelLayoutEditing()
        require(!editor.isReady, "Closing an editor never silently resumes bridge input")

        editor.stop()
        // These independent persistence/input scenarios deliberately run in Practice.
        // Disconnect now only pauses this visit; choose Practice to persist that intent.
        editor.setMode(.practice)
        let futureData = Data("{\"version\":99,\"futureField\":\"preserve me\"}".utf8)
        settings.set(futureData, forKey: "controller.layout.v1")
        let future = ControllerViewModel(defaults: settings, transport: FakeTransport(), automaticTimer: false)
        future.beginLayoutEditing()
        require(!future.canEditLayout && !future.isEditingLayout && settings.data(forKey: "controller.layout.v1") == futureData,
                "Unreadable or newer saved data is retained and cannot be overwritten by ordinary editing")
        future.resetLayout()
        require(future.canEditLayout && future.layout == .default && settings.data(forKey: "controller.layout.recovery") == futureData,
                "Explicit reset preserves original bytes in a recovery copy")

        let behaviorLink = FakeTransport()
        let behaviorClock = TestClock()
        let behaviorModel = ControllerViewModel(defaults: settings, transport: behaviorLink,
                                                clock: { behaviorClock.time }, automaticTimer: false)
        behaviorModel.setForeground(true) // Match the real scene activation before testing local input.
        behaviorModel.setBridgeProtocol(.scx1)
        var behaviorSettings = ControllerBehaviors.default
        try behaviorSettings.setButton(ButtonBehavior(holdToggle: true, holdMilliseconds: 500), for: .b)
        var leftBehavior = StickBehavior(autoCenter: false, stickPlusEnabled: true)
        leftBehavior.directions[.up] = StickDirectionMapping(boostControls: [.leftStickClick], superBoostControls: [.a])
        try behaviorSettings.setStick(leftBehavior, for: .leftStick)
        behaviorModel.saveBehaviors(behaviorSettings)
        let restoredBehavior = ControllerViewModel(defaults: settings, transport: FakeTransport(), automaticTimer: false)
        require(restoredBehavior.behaviors == behaviorSettings && restoredBehavior.state.isNeutral,
                "Control behaviors persist across restart, but held state never does")
        func input(_ event: ControllerInputEvent) { behaviorModel.handleInput(event, epoch: behaviorModel.inputEpoch) }
        input(.begin(contact: 1, control: .b, position: .zero))
        behaviorClock.time += 0.25
        behaviorModel.tickInput()
        require(behaviorModel.state.isNeutral, "A short Hold Toggle touch does not send a premature press")
        behaviorClock.time += 0.26
        behaviorModel.tickInput()
        input(.end(contact: 1))
        require(behaviorModel.state.buttons == [.b] && behaviorModel.latchedControls == [.b],
                "Timer advances a hold and lifting retains the button")
        input(.begin(contact: 2, control: .leftStick, position: .init(x: 0, y: 0.7)))
        input(.end(contact: 2))
        require(behaviorModel.state.leftStick.y == 0.7 && behaviorModel.state.buttons == [.b, .leftStick],
                "Retained stick and boost action coexist with a separately latched button")
        behaviorModel.recenterSticks()
        require(behaviorModel.state.leftStick == .zero && behaviorModel.state.buttons == [.b],
                "Re-center releases stick-owned actions without releasing an independent held button")
        input(.begin(contact: 3, control: .b, position: .zero))
        input(.end(contact: 3))
        require(behaviorModel.state.isNeutral, "A second tap turns a latched button off")
        input(.begin(contact: 4, control: .leftStick, position: .init(x: 0, y: 1)))
        input(.end(contact: 4))
        require(behaviorModel.state.buttons == [.a], "Super Boost replaces the lower stage")
        let retainedEpoch = behaviorModel.inputEpoch
        behaviorModel.releaseAll()
        behaviorModel.handleInput(.move(contact: 4, position: .init(x: 0, y: 1)), epoch: retainedEpoch)
        behaviorModel.tickInput(epoch: retainedEpoch)
        require(behaviorModel.state.isNeutral && behaviorModel.retainedSticks.isEmpty,
                "Release All rejects delayed touch and hold-timer callbacks")
        input(.accessibilityActivate(.b))
        behaviorModel.beginLayoutEditing()
        require(behaviorModel.state.isNeutral && behaviorModel.latchedControls.isEmpty,
                "Layout editing clears retained toggle state")
        behaviorModel.cancelLayoutEditing()
        input(.begin(contact: 5, control: .leftStick, position: .init(x: 0, y: 1)))
        input(.end(contact: 5))
        behaviorModel.beginControlConfiguration()
        input(.accessibilityActivate(.b))
        require(behaviorModel.state.isNeutral && !behaviorModel.controlsEnabled,
                "Behavior settings clear input and block gestures behind their sheet")
        behaviorModel.finishControlConfiguration()
        input(.accessibilityActivate(.b))
        behaviorModel.setForeground(false)
        behaviorModel.setForeground(true)
        require(behaviorModel.state.isNeutral && behaviorModel.latchedControls.isEmpty,
                "Backgrounding clears latched actions and never resumes them on return")
        input(.begin(contact: 6, control: .b, position: .zero))
        input(.cancelAll)
        behaviorClock.time += 1
        behaviorModel.tickInput()
        require(behaviorModel.state.isNeutral, "Touch cancellation prevents a pending hold from firing later")
        behaviorModel.setMode(.bridge)
        behaviorModel.host = "192.168.1.80"
        behaviorModel.connect()
        let behaviorSession = behaviorLink.sent.last!.session
        behaviorLink.reply(BridgePacket(kind: .ready, session: behaviorSession, sequence: 0, hidReady: true))
        input(.begin(contact: 7, control: .b, position: .zero))
        behaviorClock.time += 0.8
        let sentBeforeExpiredHold = behaviorLink.sent.count
        behaviorModel.tickInput()
        require(!behaviorModel.isReady && behaviorModel.state.isNeutral && behaviorLink.sent.count == sentBeforeExpiredHold,
                "A delayed hold timer cannot emit input into an expired bridge session")
        let futureBehaviorData = Data("{\"version\":99,\"futureFeature\":true}".utf8)
        settings.set(futureBehaviorData, forKey: "controller.behaviors.v1")
        let futureBehavior = ControllerViewModel(defaults: settings, transport: FakeTransport(), automaticTimer: false)
        futureBehavior.saveBehaviors(.default)
        require(!futureBehavior.canEditBehaviors && settings.data(forKey: "controller.behaviors.v1") == futureBehaviorData,
                "Unsupported future behavior settings survive without a silent overwrite")

        let binarySuite = "SimpleControllerSCX2Checks.\(UUID().uuidString)"
        let binaryDefaults = UserDefaults(suiteName: binarySuite)!
        defer { binaryDefaults.removePersistentDomain(forName: binarySuite) }
        let binaryLink = SCX2CheckTransport()
        let binaryClock = TestClock()
        let binary = ControllerViewModel(defaults: binaryDefaults, transport: binaryLink,
                                         clock: { binaryClock.time }, automaticTimer: false)
        require(binary.bridgeProtocol == .scx2 && binary.portText == "42736",
                "Fresh connection settings select the candidate SCX2 protocol and its distinct port")
        binary.setBridgeProtocol(.scx1)
        require(binary.portText == "42735", "Switching protocol follows the default port")
        binary.portText = "45000"
        binary.setBridgeProtocol(.scx2)
        require(binary.portText == "45000", "A deliberate custom port survives protocol changes")
        binary.portText = "42736"; binary.host = "192.168.1.80"; binary.saveSettings()
        let restoredBinary = ControllerViewModel(defaults: binaryDefaults, transport: SCX2CheckTransport(), automaticTimer: false)
        require(restoredBinary.bridgeProtocol == .scx2 && restoredBinary.portText == "42736",
                "The selected protocol and port persist without storing any session token")
        require(binaryDefaults.string(forKey: "bridge.protocol") == "scx2" && binary.state.isNeutral,
                "Protocol settings save explicitly while startup remains neutral")
        let legacySuite = "SimpleControllerLegacyConnection.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set("192.168.1.90", forKey: "bridge.host")
        legacyDefaults.set("45001", forKey: "bridge.port")
        let legacyConnection = ControllerViewModel(defaults: legacyDefaults, transport: FakeTransport(), automaticTimer: false)
        require(legacyConnection.bridgeProtocol == .scx1 && legacyConnection.portText == "45001" &&
                legacyDefaults.string(forKey: "bridge.protocol") == nil,
                "Existing unversioned connection settings retain SCX1 and are not rewritten on load")

        let binaryBoot = SCX2Token(bytes: Array(repeating: 7, count: 16))
        let binaryChallenge = SCX2Token(bytes: Array(repeating: 8, count: 16))
        func offerBinary() -> SCX2Packet {
            let hello = binaryLink.sent.last!
            let offer = SCX2Packet(kind: .ready, session: hello.session, boot: binaryBoot,
                                   challenge: binaryChallenge, hidReady: true)
            binaryLink.reply(offer)
            return offer
        }
        func activateBinary() -> SCX2Packet {
            binary.setMode(.bridge); binary.connect()
            _ = offerBinary()
            let neutral = binaryLink.sent.last!
            binaryLink.acknowledge(neutral)
            return neutral
        }
        binary.updateInput(pressed, epoch: binary.inputEpoch)
        require(binaryLink.sent.isEmpty && binary.state == pressed, "SCX2 selection does not send Practice input")
        binary.setMode(.bridge); binary.connect()
        let binaryHello = binaryLink.sent.last!
        require(binaryHello.kind == .hello && binaryLink.openedPort == 42736 && !binary.controlsEnabled,
                "SCX2 socket readiness only emits Hello; controls stay paused")
        _ = offerBinary()
        let firstNeutral = binaryLink.sent.last!
        require(firstNeutral.kind == .state && firstNeutral.sequence == 1 && firstNeutral.state!.isNeutral && !binary.isReady,
                "SCX2 READY sends neutral sequence one but cannot yet enable controls")
        binary.updateInput(pressed, epoch: binary.inputEpoch)
        require(binary.state.isNeutral && binaryLink.sent.last == firstNeutral,
                "Touch input before USB-neutral ACK1 cannot leak into the pending handshake")
        var wrongAck = SCX2Packet(kind: .ack, session: firstNeutral.session, boot: binaryBoot,
                                  challenge: .init(bytes: Array(repeating: 9, count: 16)), sequence: 1, hidReady: true)
        binaryLink.reply(wrongAck)
        require(!binary.isReady, "An ACK with a stale challenge cannot enable the app")
        binaryLink.acknowledge(firstNeutral)
        require(binary.isReady && binary.controlsEnabled && binary.acknowledgedPackets == 1,
                "Only the matching USB-neutral ACK1 enables controls")
        binary.updateInput(.init(buttons: [.a, .leftTrigger, .rightTrigger, .guide, .share]), epoch: binary.inputEpoch)
        let binaryDown = binaryLink.sent.last!
        require(binaryDown.state?.buttons == [.a] && binary.state.buttons == [.a],
                "SCX2 filters unsupported controller outputs before encoding")
        binary.updateInput(.neutral, epoch: binary.inputEpoch)
        require(binaryLink.sent.last == binaryDown, "Ordinary lift waits behind the unacknowledged press")
        binaryClock.time += 0.11; binary.tick()
        require(binaryLink.sent.last == binaryDown, "SCX2 retry preserves the exact held packet and sequence")
        binaryLink.acknowledge(binaryDown)
        let binaryUp = binaryLink.sent.last!
        require(binaryUp.state!.isNeutral && binaryUp.sequence == binaryDown.sequence + 1,
                "USB ACK of press releases the queued lift with the next sequence")
        let binaryAcknowledgments = binary.acknowledgedPackets
        binaryLink.acknowledge(binaryDown)
        require(binary.acknowledgedPackets == binaryAcknowledgments, "Duplicate USB ACK cannot count twice or skip the queued release")
        binaryLink.acknowledge(binaryUp)
        binary.updateInput(pressed, epoch: binary.inputEpoch)
        let beforeBinaryRelease = binary.inputEpoch
        binary.updateInput(.init(buttons: [.b]), epoch: binary.inputEpoch)
        binary.releaseAll()
        require(!binary.isReady && binary.state.isNeutral && binaryLink.closed.last?.kind == .stop &&
                binary.connectionRequested && binary.isConnecting,
                "SCX2 Release all discards delayed presses and automatically prepares a neutral connection")
        let stoppedCount = binaryLink.sent.count
        binary.updateInput(pressed, epoch: beforeBinaryRelease)
        binaryLink.acknowledge(binaryDown)
        binary.tick()
        require(binary.state.isNeutral && binaryLink.sent.count == stoppedCount,
                "Stopped SCX2 input, delayed ACKs and old gesture callbacks cannot replay queued state")

        let reconnectedNeutral = activateBinary()
        require(reconnectedNeutral.session != firstNeutral.session, "SCX2 reconnect uses a fresh UUID")
        wrongAck = .init(kind: .ack, session: firstNeutral.session, boot: binaryBoot,
                         challenge: binaryChallenge, sequence: 2, hidReady: true)
        binaryLink.reply(wrongAck)
        require(binary.acknowledgedPackets == 1, "A former session's ACK cannot affect the reconnected session")
        binary.updateInput(pressed, epoch: binary.inputEpoch)
        binary.cancelQueuedInput(reason: "Page changed. Connect again to resume.")
        require(!binary.isReady && binary.state.isNeutral && binary.connectionRequested && binary.isConnecting,
                "Page cancellation discards SCX2 queued input and automatically prepares a neutral session")

        _ = activateBinary()
        binary.updateInput(pressed, epoch: binary.inputEpoch)
        binaryClock.time += 0.8
        binaryLink.onMessage?(Data([0, 1, 2]))
        require(!binary.isReady && binary.state.isNeutral && binaryLink.closed.last?.kind == .stop,
                "Even malformed traffic checks ACK expiry before a delayed timer fires")
        _ = activateBinary()
        binary.updateInput(pressed, epoch: binary.inputEpoch)
        for index in 0..<17 {
            binary.updateInput(.init(buttons: [index % 2 == 0 ? .b : .a]), epoch: binary.inputEpoch)
        }
        require(!binary.isReady && binary.state.isNeutral && binary.statusDetail.contains("could not keep up"),
                "Queue overflow stops clearly instead of silently dropping press/release transitions")

        _ = activateBinary()
        binary.updateInput(pressed, epoch: binary.inputEpoch)
        let oldBinaryEpoch = binary.inputEpoch
        binary.setForeground(false); binary.setForeground(true)
        binary.updateInput(pressed, epoch: oldBinaryEpoch)
        require(!binary.controlsEnabled && binary.state.isNeutral, "Foreground return never resumes a stopped SCX2 hold")
        _ = activateBinary()
        binary.beginLayoutEditing()
        binary.connect()
        require(!binary.isReady && binary.isEditingLayout && binary.state.isNeutral,
                "Layout editing stops SCX2 and blocks reconnect")
        binary.cancelLayoutEditing()
        _ = activateBinary()
        binary.beginControlConfiguration()
        binary.connect()
        require(!binary.isReady && !binary.controlsEnabled, "Behavior settings stop SCX2 and block behind-sheet input")
        binary.finishControlConfiguration()
        _ = activateBinary()
        binary.updateInput(pressed, epoch: binary.inputEpoch)
        binary.setBridgeProtocol(.scx1)
        require(!binary.isReady && binary.state.isNeutral && binaryLink.closed.last?.kind == .stop,
                "Changing protocol stops the old SCX2 session before changing codecs")
        binary.setBridgeProtocol(.scx2)
        _ = activateBinary()
        let latest = binaryLink.sent.last!
        binaryLink.reply(.init(kind: .ready, session: latest.session,
                               boot: .init(bytes: Array(repeating: 4, count: 16)),
                               challenge: binaryChallenge, hidReady: true))
        require(!binary.isReady && binary.state.isNeutral && binary.statusDetail.contains("restarted"),
                "Changed boot tokens stop the session instead of silently rearming")

        binary.connect(); _ = offerBinary()
        binaryClock.time += 0.8; binary.tick()
        require(!binary.isReady && binary.statusDetail.contains("neutral USB"),
                "A missing initial neutral USB completion times out without enabling controls")
        binary.stop(); binary.connect()
        let unavailableSession = binaryLink.sent.last!.session
        binaryLink.reply(.init(kind: .ready, session: unavailableSession, boot: binaryBoot, hidReady: false))
        require(!binary.isReady && binary.statusDetail.contains("unavailable"),
                "SCX2 reports unready USB as a hardware connection problem")
        _ = activateBinary()
        binary.updateInput(pressed, epoch: binary.inputEpoch)
        binaryClock.time -= 0.1; binary.tick()
        require(!binary.isReady && binary.state.isNeutral, "Backward clock faults stop SCX2 before state can persist")

        binaryClock.time += 1
        var binaryHold = ControllerBehaviors.default
        try binaryHold.setButton(.init(holdToggle: true, holdMilliseconds: 500), for: .b)
        binary.saveBehaviors(binaryHold)
        _ = activateBinary()
        binary.handleInput(.begin(contact: 99, control: .b, position: .zero), epoch: binary.inputEpoch)
        binaryClock.time += 0.8; binary.tickInput()
        require(!binary.isReady && binary.state.isNeutral && binary.latchedControls.isEmpty,
                "SCX2 lease expiry wins before an overdue Hold Toggle timer")

        let menuHandshake = activateBinary()
        var menuRedraws = 0
        let menuObservation = binary.objectWillChange.sink { menuRedraws += 1 }
        var observedPhases: [ControllerViewModel.Phase] = []
        let phaseObservation = binary.$phase.dropFirst().sink { observedPhases.append($0) }
        let previousAckCount = binary.acknowledgedPackets
        let alreadySent = binaryLink.sent.count
        binaryClock.time += 0.11
        binary.tick()
        let heartbeat = binaryLink.sent.last!
        binaryClock.time += 0.11
        binary.tick()
        require(binaryLink.sent.count == alreadySent + 2 && binaryLink.sent.last == heartbeat &&
                heartbeat.sequence == menuHandshake.sequence + 1 && heartbeat.state?.isNeutral == true,
                "An established idle bridge sends a neutral heartbeat and retries the same packet")
        binaryLink.acknowledge(heartbeat)
        require(binary.isReady && binary.acknowledgedPackets == previousAckCount + 1 && menuRedraws == 0,
                "Heartbeat retries and USB acknowledgments update diagnostics without redrawing the open Bridge menu")
        binary.stop()
        require(observedPhases == [.idle] && menuRedraws > 0,
                "Disconnecting the bridge still notifies the screen to replace its active connection actions")
        phaseObservation.cancel()
        menuObservation.cancel()
        print("PASS: \(checks) app client checks on macOS with fake transport and clock.")
        print("This does not validate UIKit, iOS networking, a USB bridge, or Xbox hardware.")
    }
}

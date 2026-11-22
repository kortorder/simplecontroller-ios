import Combine
import Foundation
import Darwin
import Network
import ControllerCore

@MainActor
final class ControllerViewModel: ObservableObject {
    enum Mode: String, CaseIterable {
        case practice = "Practice", bridge = "Xbox bridge"
    }

    enum Phase: Equatable {
        case idle, connecting, ready, stopped(String)
    }

    @Published private(set) var automaticConnectionIssue: String?
    @Published private(set) var connectionRequested = false
    @Published private(set) var mode: Mode = .practice
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var state: GamepadState = .neutral
    @Published private(set) var inputEpoch = 0
    // Diagnostic counter only. Publishing every heartbeat makes an open native
    // menu rebuild while the user is trying to select Disconnect or Details.
    private(set) var acknowledgedPackets: UInt64 = 0
    @Published var host: String
    @Published var portText: String
    @Published private(set) var bridgeProtocol: BridgeProtocolVersion
    @Published private(set) var bridgeTriggerMode: BridgeTriggerMode
    var bridgeTriggerPressureEnabled: Bool { bridgeTriggerMode == .adjustable }
    private var triggerModeExplicitlySelected = false
    private(set) var outputState: BridgeOutputState = .neutral
    @Published private(set) var layout = ControllerLayout.default
    @Published private(set) var isEditingLayout = false
    @Published private(set) var layoutMessage: String?
    @Published private(set) var behaviors = ControllerBehaviors.default
    @Published private(set) var behaviorMessage: String?
    @Published private(set) var isConfiguringControl = false
    @Published private(set) var latchedControls: Set<ControllerControlID> = []
    @Published private(set) var retainedSticks: Set<ControllerControlID> = []

    private var inputEngine = ControllerInputEngine()
    private var behaviorTimer: Timer?
    private var protectedBehaviorData: Data?
    private static let behaviorKey = "controller.behaviors.v1"

    private var layoutBeforeEditing: ControllerLayout?
    private var protectedLayoutData: Data?
    private static let layoutKey = "controller.layout.v1"

    private let defaults: UserDefaults
    private let automaticConnectionStorageURL: URL?
    private let transport: any BridgeTransporting
    private let clock: () -> TimeInterval
    private let wallClock: () -> TimeInterval
    private let resumeClock: () -> TimeInterval
    private let automaticTimer: Bool
    private let persistSettings: Bool
    private var timer: Timer?
    private var session: String?
    private var sequence: UInt64 = 0
    private var lastAcknowledged: UInt64 = 0
    private var lastResponse: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    private var lastHello: TimeInterval = -.infinity
    private var socketReady = false
    // The canvas must redraw when Practice returns from an inactive scene, too.
    // A foreground transition may be the only observable state change.
    @Published private var foreground = true
    private var scx2: SCX2ClientMachine?
    private var windowsPC: WindowsPCClientMachine?
    private var pcOutputState: WindowsPCOutput = .neutral
    static let connectionIntentKey = "bridge.connection-intent.v1"
    static let automaticConnectionKey = "bridge.automatic-connection.v1"
    private struct Endpoint: Codable, Equatable {
        var host: String
        var port: UInt16
        var protocolVersion: BridgeProtocolVersion
        var pressure: Bool
        var triggerMode: BridgeTriggerMode? = nil
        var resolvedTriggerMode: BridgeTriggerMode { triggerMode ?? (pressure ? .adjustable : .off) }
        var valid: Bool {
            guard let address = IPv4Address(host), let first = address.rawValue.first else { return false }
            return first > 0 && first < 224 && port > 0 && pressure == (resolvedTriggerMode == .adjustable) &&
                (protocolVersion == .scx2 || resolvedTriggerMode == .off)
        }
    }
    // Legacy short-lived intent is still written for compatible older builds,
    // but reopening now makes a new connection instead of resuming old input.
    private struct ResumeRecord: Codable {
        var endpoint: Endpoint
        var uptime: TimeInterval
        var wallTime: TimeInterval
    }
    private struct AutomaticConnection: Codable, Equatable {
        var version = 1
        var lastEndpoint: Endpoint?
        var practiceSelected: Bool
        var invalidSettings: Bool? = nil
        var valid: Bool { version == 1 && (lastEndpoint == nil || lastEndpoint?.valid == true) }
    }
    private var rememberedEndpoint: Endpoint?
    private var practiceSelected = false
    private var invalidAutomaticSettings = false
    private var returnedFromBackground = false
    private var endpoint: Endpoint?
    private var backgroundRecord: ResumeRecord?
    private var nextRetry: TimeInterval?
    private var failureCount = 0
    private var connectionGeneration = 0
    private var lastIntentWrite: TimeInterval = -.infinity
    /// Unlike gesture uptime, the persisted absence clock advances while the phone sleeps.
    nonisolated private static func continuousTime() -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
    private var wireProtocol: BridgeProtocolVersion { endpoint?.protocolVersion ?? bridgeProtocol }


    init(defaults: UserDefaults = .standard,
         transport: (any BridgeTransporting)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         resumeClock: (() -> TimeInterval)? = nil,
         automaticTimer: Bool = true,
         persistSettings: Bool = true,
         automaticConnectionStorageURL: URL? = nil) {
        self.defaults = defaults
        self.automaticConnectionStorageURL = automaticConnectionStorageURL ?? (defaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("SimpleController", isDirectory: true).appendingPathComponent("automatic-connection.json")
            : nil)
        self.transport = transport ?? UDPBridgeTransport()
        self.clock = clock
        self.wallClock = wallClock
        self.resumeClock = resumeClock ?? { ControllerViewModel.continuousTime() }
        self.automaticTimer = automaticTimer
        self.persistSettings = persistSettings
        host = defaults.string(forKey: "bridge.host") ?? ""
        let selectedProtocol: BridgeProtocolVersion
        if let saved = defaults.string(forKey: "bridge.protocol"), let version = BridgeProtocolVersion(rawValue: saved) {
            selectedProtocol = version
        } else if defaults.object(forKey: "bridge.protocol") == nil &&
                    (defaults.object(forKey: "bridge.host") != nil || defaults.object(forKey: "bridge.port") != nil) {
            selectedProtocol = .scx1 // Preserve explicit earlier connection settings, without silently upgrading the peer.
        } else {
            selectedProtocol = .scx2
        }
        bridgeProtocol = selectedProtocol
        if let savedMode = defaults.string(forKey: "bridge.triggerMode") {
            bridgeTriggerMode = BridgeTriggerMode(rawValue: savedMode) ?? .off
        } else { bridgeTriggerMode = defaults.bool(forKey: "bridge.triggerPressure") ? .adjustable : .off }
        portText = defaults.string(forKey: "bridge.port") ?? String(selectedProtocol.defaultPort)
        if let saved = defaults.data(forKey: Self.layoutKey) {
            do { layout = try ControllerLayoutCodec.decode(saved) }
            catch {
                protectedLayoutData = saved
                layoutMessage = "Your saved layout could not be opened. It has been kept unchanged. Reset the layout in settings to start over."
            }
        }
        if let saved = defaults.data(forKey: Self.behaviorKey) {
            do { behaviors = try ControllerBehaviorsCodec.decode(saved) }
            catch {
                protectedBehaviorData = saved
                behaviorMessage = "Your saved control settings could not be opened. They have been kept unchanged. Reset control behaviors in Settings to start over."
            }
        }
        inputEngine.apply(configuration: behaviors)
        restoreAutomaticConnection()

    }

    var controlsEnabled: Bool { foreground && !isEditingLayout && !isConfiguringControl && (mode == .practice || phase == .ready) }
    var canEditLayout: Bool { protectedLayoutData == nil }
    var canEditBehaviors: Bool { protectedBehaviorData == nil }
    var keepsScreenAwake: Bool { foreground && ((mode == .bridge && phase == .ready) || !state.isNeutral) }
    var isConnecting: Bool { phase == .connecting || (connectionRequested && foreground && nextRetry != nil) }
    var isReady: Bool { phase == .ready }
    private var activeTriggerMode: BridgeTriggerMode { endpoint?.resolvedTriggerMode ?? bridgeTriggerMode }
    var usesWindowsPC: Bool { wireProtocol == .windowsPC }
    var usesMacPC: Bool { wireProtocol == .macPC }
    var usesPCReceiver: Bool { wireProtocol.isDesktopReceiver }
    var allowsDesktopControls: Bool { mode == .practice || usesPCReceiver }
    var usesCronusZen: Bool { wireProtocol == .scx2 && activeTriggerMode == .cronusZen }
    var usesTriggerPressure: Bool { usesWindowsPC || (wireProtocol == .scx2 && (activeTriggerMode == .adjustable || activeTriggerMode == .cronusZen)) }
    var usesUSBButtonTriggers: Bool { wireProtocol == .scx2 && activeTriggerMode == .usbButtons }
    var allowsTriggerControls: Bool { usesTriggerPressure || usesUSBButtonTriggers || usesMacPC }

    var statusTitle: String {
        if isEditingLayout { return "Editing layout • controls paused" }
        if mode == .practice { return "Practice • nothing is sent" }
        switch phase {
        case .idle where usesPCReceiver: return "Computer not connected"
        case .connecting where usesPCReceiver: return usesMacPC ? "Waiting for Mac receiver" : "Waiting for Windows receiver"
        case .ready where usesPCReceiver: return usesMacPC ? "Mac receiver connected" : "Windows receiver connected"
        case .idle: return "Bridge not connected"
        case .connecting: return "Waiting for the bridge"
        case .ready: return "Bridge is responding"
        case .stopped: return connectionRequested ? "Controls paused" : "Controls stopped"
        }
    }

    var statusDetail: String {
        if let automaticConnectionIssue { return automaticConnectionIssue }
        if isEditingLayout { return "Drag to move. Hold a control to change its behavior. Rotate to arrange the other orientation, then tap Save." }
        if mode == .practice { return "Try the touch controls here. Nothing is sent to a PC or console." }
        if usesPCReceiver {
            switch phase {
            case .idle: return "Start the free receiver on your computer, then enter its IP address and port in Bridge settings."
            case .connecting: return "Waiting for the receiver and its neutral acknowledgment. Check the receiver window and private-network firewall access."
            case .ready: return usesMacPC
                ? "Mac keyboard and mouse output is active. Controller layouts map to keys and mouse: left stick moves, right stick aims, LT/RT click. No analog gamepad or trigger pressure. Keep the receiver running."
                : "Controller, adjustable triggers, keyboard and mouse use Wi-Fi. No Pico is needed. Keep the receiver running; game recognition depends on its virtual-controller driver."
            case .stopped(let reason): return reason
            }
        }
        switch phase {
        case .idle:
            return "Connect the Pico using the hardware and firmware selected in Bridge settings."
        case .connecting:
            if usesCronusZen { return "Waiting for the Cronus Zen Pico firmware and released USB stick and trigger outputs. Controls stay paused." }
            if usesUSBButtonTriggers { return "Waiting for updated USB-trigger Pico firmware and released controls. Map X1 to LT and X2 to RT in Xbox Accessories." }
            if usesTriggerPressure { return "Waiting for a pressure-capable Pico and neutral stick and trigger outputs. Controls stay paused." }
            return bridgeProtocol == .scx2
                ? "Waiting for the candidate bridge and a completed neutral USB report. Controls stay paused."
                : "Waiting for the legacy SCX1 prototype. Its readiness reply is not physical Xbox verification."
        case .ready:
            if usesCronusZen { return "The Pico accepted adjustable USB triggers. Verify the actual trigger values and chair joystick together on Xbox." }
            if usesUSBButtonTriggers { return "USB triggers are full press or release. In Xbox Accessories, map X1 to LT and X2 to RT. Saved pressure values are unchanged. Check the actual Xbox response." }
            if usesTriggerPressure { return "The Pico accepted controller and adjustable trigger output. Actual Xbox response still needs hardware verification." }
            return bridgeProtocol == .scx2
                ? "The candidate bridge acknowledged USB transfers. Xbox input and hardware compatibility still need physical verification."
                : "The legacy bridge reports USB readiness. This does not verify Xbox input."
        case .stopped(let reason):
            return reason
        }
    }

    func setMode(_ newMode: Mode) {
        guard !isEditingLayout, !isConfiguringControl else { return }
        // An explicit Practice choice is an opt-out even when already in Practice.
        practiceSelected = newMode == .practice
        persistAutomaticConnection()
        guard newMode != mode else { return }
        stop()
        mode = newMode
        phase = .idle
    }

    func setBridgeProtocol(_ version: BridgeProtocolVersion) {
        guard version != bridgeProtocol else { return }
        let previousDefault = String(bridgeProtocol.defaultPort)
        cancelQueuedInput(reason: "Bridge settings changed. Controls released.")
        bridgeProtocol = version
        if portText.trimmingCharacters(in: .whitespacesAndNewlines) == previousDefault || portText.isEmpty {
            portText = String(version.defaultPort)
        }
    }

    func updateInput(_ newState: GamepadState, epoch: Int) {
        updateOutput(.init(gamepad: newState,
                           leftTrigger: newState.buttons.contains(.leftTrigger) ? 1 : 0,
                           rightTrigger: newState.buttons.contains(.rightTrigger) ? 1 : 0), epoch: epoch)
    }

    func setBridgeTriggerPressureEnabled(_ enabled: Bool) {
        setBridgeTriggerMode(enabled ? .adjustable : .off)
    }

    func setBridgeTriggerMode(_ value: BridgeTriggerMode) {
        guard value != bridgeTriggerMode else { return }
        cancelQueuedInput(reason: "Trigger settings changed. Controls released.")
        bridgeTriggerMode = value
        triggerModeExplicitlySelected = true
    }

    func updateOutput(_ output: BridgeOutputState, desktop: PracticeOutputState = .neutral, epoch: Int) {
        guard epoch == inputEpoch, controlsEnabled else { return }
        guard output.isValid else { pauseAfterFailure(reason: "Invalid trigger or controller input. All controls were released."); return }
        if mode == .bridge && !liveSessionIsFresh() { return }
        var accepted = output.gamepad
        if mode == .bridge {
            accepted.buttons.subtract([.guide, .share])
            if !allowsTriggerControls { accepted.buttons.subtract([.leftTrigger, .rightTrigger]) }
        }
        state = accepted
        var wireGamepad = accepted
        wireGamepad.buttons.subtract([.leftTrigger, .rightTrigger])
        func trigger(_ pressure: Double, button: PadButton) -> Double {
            if mode == .practice || usesTriggerPressure || usesMacPC { return pressure }
            if usesUSBButtonTriggers { return pressure > 0 || accepted.buttons.contains(button) ? 1 : 0 }
            return 0
        }
        outputState = .init(gamepad: wireGamepad,
                            leftTrigger: trigger(output.leftTrigger, button: .leftTrigger),
                            rightTrigger: trigger(output.rightTrigger, button: .rightTrigger))
        pcOutputState = WindowsPCOutput(gamepad: wireGamepad,
                                        leftTrigger: outputState.leftTrigger, rightTrigger: outputState.rightTrigger,
                                        desktop: desktop)
        if mode == .bridge && usesPCReceiver && !pcOutputState.isValid { pauseAfterFailure(reason: "Invalid desktop input. Controls released."); return }
        if isReady { sendState() }
    }

    func releaseAll() {
        cancelQueuedInput(reason: "All controls released. Preparing fresh controls…")
    }

    /// Retire queued old presses before a page, profile, editor or Release all.
    /// The user's connection intent survives; only a new neutral ACK permits input.
    func cancelQueuedInput(reason: String) {
        if mode == .bridge, (wireProtocol == .scx2 || wireProtocol.isDesktopReceiver), connectionRequested {
            if phase == .connecting || nextRetry != nil {
                clearLocalInput() // The existing attempt contains neutral only; don't extend it.
            } else if foreground, endpoint != nil {
                startAttempt(automatic: true)
            } else { clearLocalInput() }
            return
        }
        clearLocalInput()
        if isReady { sendState() }
    }

    func handleInput(_ event: ControllerInputEvent, epoch: Int) {
        guard epoch == inputEpoch, controlsEnabled else { return }
        if mode == .bridge && !liveSessionIsFresh() { return }
        do { try inputEngine.handle(event, at: now) }
        catch { releaseAll(); return }
        publishEngineState()
        refreshBehaviorTimer()
    }

    func tickInput(epoch: Int? = nil) {
        guard epoch == nil || epoch == inputEpoch, controlsEnabled else { return }
        if mode == .bridge && !liveSessionIsFresh() { return }
        do { try inputEngine.tick(at: now) }
        catch { releaseAll(); return }
        publishEngineState()
        refreshBehaviorTimer()
    }

    private func publishEngineState() {
        latchedControls = inputEngine.latchedControls
        retainedSticks = Set(inputEngine.retainedSticks.keys)
        updateInput(inputEngine.state, epoch: inputEpoch)
    }

    private func refreshBehaviorTimer() {
        guard automaticTimer, controlsEnabled, inputEngine.nextDeadline != nil else {
            behaviorTimer?.invalidate()
            behaviorTimer = nil
            return
        }
        guard behaviorTimer == nil else { return }
        let epoch = inputEpoch
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickInput(epoch: epoch) }
        }
        behaviorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func recenterSticks() {
        guard controlsEnabled else { return }
        inputEngine.recenterSticks()
        publishEngineState()
        refreshBehaviorTimer()
    }

    func beginControlConfiguration() {
        guard canEditBehaviors else { return }
        cancelQueuedInput(reason: "Controls released for editing.")
        isConfiguringControl = true
    }

    func finishControlConfiguration() {
        isConfiguringControl = false
        clearLocalInput()
    }

    func saveBehaviors(_ updated: ControllerBehaviors) {
        guard canEditBehaviors else { return }
        do {
            let data = try ControllerBehaviorsCodec.encode(updated)
            cancelQueuedInput(reason: "Controls released for editing.")
            behaviors = updated
            inputEngine.apply(configuration: updated)
            if persistSettings { defaults.set(data, forKey: Self.behaviorKey) }
            behaviorMessage = "Control behavior saved. All held input was released."
        } catch {
            behaviorMessage = "Control settings could not be saved. Your previous settings are unchanged."
        }
    }

    func resetBehaviors() {
        cancelQueuedInput(reason: "Controls released for editing.")
        if persistSettings, let original = protectedBehaviorData {
            defaults.set(original, forKey: "controller.behaviors.recovery.\(UUID().uuidString)")
        }
        protectedBehaviorData = nil
        behaviors = .default
        inputEngine.apply(configuration: .default)
        if persistSettings, let data = try? ControllerBehaviorsCodec.encode(behaviors) {
            defaults.set(data, forKey: Self.behaviorKey)
        }
        behaviorMessage = "Default control behaviors restored. Button positions are unchanged."
    }

    func prepareSettings() {
        if isEditingLayout { cancelLayoutEditing() }
        cancelQueuedInput(reason: "Controls released for editing.")
    }

    func beginLayoutEditing() {
        guard canEditLayout, !isEditingLayout else { return }
        cancelQueuedInput(reason: "Controls released for editing.")
        layoutBeforeEditing = layout
        isEditingLayout = true
        layoutMessage = nil
    }

    func updateLayout(_ newLayout: ControllerLayout, epoch: Int) {
        guard foreground, isEditingLayout, epoch == inputEpoch else { return }
        // Encoding validates a layout before accepting callbacks from the UI.
        guard (try? ControllerLayoutCodec.encode(newLayout)) != nil else { return }
        layout = newLayout
    }

    func saveLayoutEditing() {
        guard isEditingLayout, canEditLayout else { return }
        do {
            let data = try ControllerLayoutCodec.encode(layout)
            if persistSettings { defaults.set(data, forKey: Self.layoutKey) }
            isEditingLayout = false
            layoutBeforeEditing = nil
            clearLocalInput()
            layoutMessage = "Layout saved for portrait and landscape."
        } catch {
            layoutMessage = "The layout could not be saved. Your previous saved layout is unchanged."
        }
    }

    func cancelLayoutEditing() {
        if let original = layoutBeforeEditing { layout = original }
        layoutBeforeEditing = nil
        isEditingLayout = false
        clearLocalInput()
    }

    func resetLayout() {
        cancelQueuedInput(reason: "Controls released for editing.")
        // Retain unreadable source bytes separately when the user explicitly
        // resets, so recovery never silently destroys a newer layout format.
        if persistSettings, let original = protectedLayoutData {
            defaults.set(original, forKey: "controller.layout.recovery")
        }
        layout = .default
        protectedLayoutData = nil
        layoutBeforeEditing = nil
        isEditingLayout = false
        if persistSettings, let data = try? ControllerLayoutCodec.encode(layout) {
            defaults.set(data, forKey: Self.layoutKey)
        }
        layoutMessage = "Default layout restored."
    }

    private func settingsEndpoint() -> Endpoint? {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let value = Endpoint(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                             protocolVersion: bridgeProtocol, pressure: bridgeProtocol == .scx2 && bridgeTriggerPressureEnabled,
                             triggerMode: bridgeProtocol == .scx2 && (bridgeTriggerMode == .usbButtons || bridgeTriggerMode == .cronusZen) ? bridgeTriggerMode : nil)
        return value.valid ? value : nil
    }
    private func persistConnectionSettings() {
        guard persistSettings else { return }
        defaults.set(host, forKey: "bridge.host")
        defaults.set(portText, forKey: "bridge.port")
        defaults.set(bridgeProtocol.rawValue, forKey: "bridge.protocol")
        defaults.set(bridgeTriggerPressureEnabled, forKey: "bridge.triggerPressure")
        if triggerModeExplicitlySelected { defaults.set(bridgeTriggerMode.rawValue, forKey: "bridge.triggerMode") }
    }
    func saveSettings() {
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        portText = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        persistConnectionSettings()
        let savedTarget = settingsEndpoint()
        invalidAutomaticSettings = savedTarget == nil
        if let savedTarget { rememberedEndpoint = savedTarget }
        persistAutomaticConnection()
        guard connectionRequested else { return }
        guard let target = savedTarget else {
            endpoint = nil; nextRetry = nil
            if persistSettings { defaults.removeObject(forKey: Self.connectionIntentKey) }
            closeSession(reason: "The saved bridge address or port is invalid. Correct it in Bridge settings to resume.")
            ensureHeartbeat()
            return
        }
        guard target != endpoint else { return }
        endpoint = target; writeConnectionIntent(force: true)
        if foreground { startAttempt(automatic: true) }
    }

    func setForeground(_ active: Bool, didEnterBackground: Bool = false) {
        // Inactive may only be a notification or permission prompt. A deliberate
        // Disconnect must not bounce back until the app really leaves and opens.
        if didEnterBackground { returnedFromBackground = true }
        guard active != foreground else { return }
        foreground = active
        if !active {
            if connectionRequested, let endpoint {
                backgroundRecord = ResumeRecord(endpoint: endpoint, uptime: resumeClock(), wallTime: wallClock())
                writeConnectionIntent(force: true)
            }
            nextRetry = nil
            closeSession(reason: connectionRequested
                ? "Controls paused while the app is away. The bridge will reconnect when you return." : nil)
        } else {
            let mayReopen = returnedFromBackground
            returnedFromBackground = false
            backgroundRecord = nil
            if connectionRequested, endpoint?.valid == true {
                startAttempt(automatic: true)
            } else if mayReopen, mode == .bridge, !practiceSelected, !invalidAutomaticSettings, let rememberedEndpoint {
                prepareAutomaticConnection(to: rememberedEndpoint)
                startAttempt(automatic: true)
            }
        }
    }

    func connect() {
        guard mode == .bridge, foreground, !isEditingLayout, !isConfiguringControl else { return }
        guard let target = settingsEndpoint() else {
            stop(reason: "Open Bridge menu → Bridge settings. Enter the receiver’s IPv4 address and a port from 1 to 65535, then tap Save and connect.")
            return
        }
        host = target.host; portText = String(target.port)
        persistConnectionSettings()
        practiceSelected = false; invalidAutomaticSettings = false; rememberedEndpoint = target
        persistAutomaticConnection()
        let automatic = connectionRequested
        endpoint = target; connectionRequested = true; failureCount = 0
        writeConnectionIntent(force: true)
        startAttempt(automatic: automatic)
    }

    private func startAttempt(automatic: Bool) {
        guard connectionRequested, foreground, let endpoint, endpoint.valid else { return }
        nextRetry = nil
        closeSession()
        if endpoint.protocolVersion == .scx2 {
            scx2 = SCX2ClientMachine(revision: endpoint.resolvedTriggerMode.revision, at: now,
                                     waitForAvailability: automatic)
        } else if endpoint.protocolVersion.isDesktopReceiver {
            windowsPC = WindowsPCClientMachine(at: now)
        } else { session = UUID().uuidString }
        sequence = 0; lastAcknowledged = 0; acknowledgedPackets = 0
        startedAt = now; lastHello = -.infinity
        phase = .connecting
        installTransportCallbacks()
        ensureHeartbeat()
        writeConnectionIntent(force: false)
        transport.open(host: endpoint.host, port: endpoint.port)
    }
    private func installTransportCallbacks() {
        let generation = connectionGeneration
        transport.onReady = { [weak self] in
            guard let self, self.connectionGeneration == generation, self.phase == .connecting else { return }
            self.socketReady = true; self.tick()
        }
        transport.onMessage = { [weak self] data in
            guard let self, self.connectionGeneration == generation else { return }
            self.receive(data)
        }
        transport.onFailure = { [weak self] message in
            guard let self, self.connectionGeneration == generation else { return }
            self.pauseAfterFailure(reason: "Check Wi-Fi and Local Network access. \(message)")
        }
    }
    private func ensureHeartbeat() {
        guard automaticTimer, foreground, connectionRequested, timer == nil else { return }
        let heartbeat = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = heartbeat; RunLoop.main.add(heartbeat, forMode: .common)
    }
    /// Disconnect cancels this foreground visit. A later genuine app opening may reconnect.
    /// Practice also persists an explicit opt-out from automatic opening.
    func stop(reason: String? = nil) {
        connectionRequested = false; nextRetry = nil; endpoint = nil
        backgroundRecord = nil; returnedFromBackground = false
        if persistSettings { defaults.removeObject(forKey: Self.connectionIntentKey) }
        closeSession(reason: reason)
    }
    private func closeSession(reason: String? = nil, finalPacket override: Data? = nil) {
        timer?.invalidate(); timer = nil
        var finalPacket = override
        if finalPacket == nil {
            if var machine = windowsPC, let stop = machine.stop() { finalPacket = try? WindowsPCCodec.encode(stop) }
            else if var machine = scx2, let stop = machine.stop() { finalPacket = try? SCX2Codec.encode(stop) }
            else if let session, sequence < UInt64.max {
                finalPacket = try? BridgeCodec.encode(BridgePacket(kind: .stop, session: session, sequence: sequence + 1))
            }
        }
        connectionGeneration += 1
        session = nil; scx2 = nil; windowsPC = nil; socketReady = false
        clearLocalInput()
        transport.close(afterSending: finalPacket)
        phase = reason.map(Phase.stopped) ?? .idle
    }
    private func pauseAfterFailure(reason: String, finalPacket: Data? = nil) {
        closeSession(reason: connectionRequested ? reason + " Controls are paused; reconnecting automatically." : reason,
                     finalPacket: finalPacket)
        if connectionRequested, foreground, endpoint != nil, now.isFinite, now >= 0 {
            failureCount = min(failureCount + 1, 4)
            nextRetry = now + min(8, pow(2, Double(failureCount - 1)))
            ensureHeartbeat()
        }
    }
    private func writeConnectionIntent(force: Bool) {
        guard persistSettings, connectionRequested, let endpoint, endpoint.valid else { return }
        let time = resumeClock(), wall = wallClock()
        guard time.isFinite, time >= 0, wall.isFinite else { return }
        guard force || (foreground && time - lastIntentWrite >= 1) else { return }
        let record = backgroundRecord ?? ResumeRecord(endpoint: endpoint, uptime: time, wallTime: wall)
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.connectionIntentKey); lastIntentWrite = time
        }
    }
    private func persistAutomaticConnection() {
        guard persistSettings else { return }
        let record = AutomaticConnection(lastEndpoint: rememberedEndpoint, practiceSelected: practiceSelected,
                                         invalidSettings: invalidAutomaticSettings ? true : nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard record.valid, let data = try? encoder.encode(record) else { return }
        do {
            if let url = automaticConnectionStorageURL {
                let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                if previous != data {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Keep a damaged or newer document before an explicit choice replaces it.
                    if let previous, decodeAutomaticConnection(previous) == nil {
                        let recovery = url.deletingLastPathComponent().appendingPathComponent("automatic-connection-recovery-\(UUID().uuidString).json")
                        try previous.write(to: recovery, options: .atomic)
                        guard try Data(contentsOf: recovery) == previous else { throw automaticSaveError() }
                    }
                    do {
                        try data.write(to: url, options: .atomic)
                        guard try Data(contentsOf: url) == data else { throw automaticSaveError() }
                    } catch {
                        if let previous { try? previous.write(to: url, options: .atomic) }
                        else { try? FileManager.default.removeItem(at: url) }
                        throw error
                    }
                }
            } else {
                if defaults.data(forKey: Self.automaticConnectionKey) != data {
                    defaults.set(data, forKey: Self.automaticConnectionKey)
                }
                guard defaults.data(forKey: Self.automaticConnectionKey) == data else { throw automaticSaveError() }
            }
            automaticConnectionIssue = nil
        } catch {
            automaticConnectionIssue = "The automatic connection setting could not be saved. Your choice applies while this app stays open, but may not survive reopening. Free some storage and select Practice or Connect again."
        }
    }

    private func automaticSaveError() -> NSError {
        NSError(domain: "SimpleController.AutomaticConnection", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The saved connection setting could not be verified."])
    }

    private func decodeAutomaticConnection(_ data: Data) -> AutomaticConnection? {
        guard data.count <= 4096, let record = try? JSONDecoder().decode(AutomaticConnection.self, from: data), record.valid else { return nil }
        return record
    }

    private func rememberSuccessfulConnection() {
        guard let endpoint, endpoint.valid else { return }
        rememberedEndpoint = endpoint
        practiceSelected = false; invalidAutomaticSettings = false
        persistAutomaticConnection()
    }

    private func prepareAutomaticConnection(to target: Endpoint) {
        guard target.valid else { return }
        endpoint = target; connectionRequested = true; mode = .bridge
        host = target.host; portText = String(target.port)
        bridgeProtocol = target.protocolVersion
        // The PC endpoint has no console trigger mode. Keep the saved Pico choice
        // so returning to SCX2 does not silently turn off the user's USB triggers.
        if target.protocolVersion == .scx2 { bridgeTriggerMode = target.resolvedTriggerMode }
        failureCount = 0
    }

    private func restoreAutomaticConnection() {
        guard persistSettings else { return }
        let storedData: Data?
        let hasStoredRecord: Bool
        if let url = automaticConnectionStorageURL, FileManager.default.fileExists(atPath: url.path) {
            hasStoredRecord = true
            storedData = try? Data(contentsOf: url)
        } else {
            hasStoredRecord = defaults.object(forKey: Self.automaticConnectionKey) != nil
            storedData = defaults.data(forKey: Self.automaticConnectionKey)
        }
        if hasStoredRecord {
            // An unknown/corrupt new record must not fall back to older settings.
            guard let storedData, let record = decodeAutomaticConnection(storedData) else {
                automaticConnectionIssue = "The saved automatic connection setting could not be read. It has been kept unchanged. Select Practice or connect to the intended bridge to save a new choice."
                return
            }
            rememberedEndpoint = record.lastEndpoint; practiceSelected = record.practiceSelected
            invalidAutomaticSettings = record.invalidSettings == true
            // On production upgrade, move small preference records to verified file storage.
            if let url = automaticConnectionStorageURL, !FileManager.default.fileExists(atPath: url.path) {
                persistAutomaticConnection()
            }
        } else {
            // One-time upgrade: older versions only retained short-lived intent
            // and explicit saved bridge settings. Neither stores held controls.
            if let data = defaults.data(forKey: Self.connectionIntentKey), data.count <= 4096,
               let record = try? JSONDecoder().decode(ResumeRecord.self, from: data), record.endpoint.valid {
                rememberedEndpoint = record.endpoint
            } else if let savedHost = defaults.string(forKey: "bridge.host"), !savedHost.isEmpty,
                      let savedPort = defaults.string(forKey: "bridge.port"), UInt16(savedPort) != nil,
                      defaults.object(forKey: "bridge.protocol") == nil ||
                        defaults.string(forKey: "bridge.protocol").flatMap(BridgeProtocolVersion.init(rawValue:)) != nil,
                      defaults.object(forKey: "bridge.triggerMode") == nil ||
                        defaults.string(forKey: "bridge.triggerMode").flatMap(BridgeTriggerMode.init(rawValue:)) != nil {
                rememberedEndpoint = settingsEndpoint()
            }
            if rememberedEndpoint != nil { persistAutomaticConnection() }
        }
        guard !practiceSelected, !invalidAutomaticSettings, let rememberedEndpoint else { return }
        prepareAutomaticConnection(to: rememberedEndpoint)
        // Construction can happen while inactive: no socket or heartbeat until
        // the scene explicitly becomes active. All restored output is neutral.
        foreground = false
    }

    private var now: TimeInterval { clock() }

    private func clearLocalInput() {
        inputEpoch += 1
        behaviorTimer?.invalidate()
        behaviorTimer = nil
        inputEngine.releaseAll()
        latchedControls = []
        retainedSticks = []
        state = .neutral
        outputState = .neutral
        pcOutputState = .neutral
    }

    func tick() {
        guard foreground else { return }
        writeConnectionIntent(force: false)
        if let retry = nextRetry {
            if now >= retry { startAttempt(automatic: true) }
            return
        }
        if var machine = windowsPC {
            let packets = socketReady ? machine.socketDidBecomeReady(at: now) : machine.tick(at: now)
            windowsPC = machine; applyWindowsPC(packets); return
        }
        if var machine = scx2 {
            guard foreground else { return }
            let packets = socketReady ? machine.socketDidBecomeReady(at: now) : machine.tick(at: now)
            scx2 = machine
            applySCX2(packets)
            return
        }
        guard foreground, let session else { return }
        switch phase {
        case .connecting:
            guard now - startedAt < 3 else {
                pauseAfterFailure(reason: "No bridge replied. Check its address, power, Wi-Fi, and iPhone Local Network permission.")
                return
            }
            if socketReady && now - lastHello >= 0.25 {
                lastHello = now
                send(BridgePacket(kind: .hello, session: session, sequence: 0))
            }
        case .ready:
            guard now - lastResponse < 0.75 else {
                pauseAfterFailure(reason: "The bridge stopped replying. All local controls were released. Check the connection.")
                return
            }
            sendState()
        default:
            break
        }
    }

    private func sendState() {
        if var machine = windowsPC {
            guard isReady, foreground else { return }
            let packets = machine.update(pcOutputState, at: now)
            windowsPC = machine; applyWindowsPC(packets); return
        }
        if var machine = scx2 {
            guard isReady, foreground else { return }
            let packets = machine.updateOutput(outputState, at: now)
            scx2 = machine
            applySCX2(packets)
            return
        }
        guard isReady, foreground, let session, sequence < UInt64.max else { return }
        guard liveSessionIsFresh() else { return }
        sequence += 1
        send(BridgePacket(kind: .state, session: session, sequence: sequence, state: state))
    }

    private func send(_ packet: BridgePacket) {
        do { transport.send(try BridgeCodec.encode(packet)) }
        catch { pauseAfterFailure(reason: "A controller message could not be sent.") }
    }

    private func receive(_ data: Data) {
        if var machine = windowsPC {
            guard foreground else { return }
            var packets = machine.tick(at: now)
            if let packet = try? WindowsPCCodec.decode(data) { packets += machine.receive(packet, at: now) }
            windowsPC = machine; applyWindowsPC(packets); return
        }
        if var machine = scx2 {
            guard foreground else { return }
            // Malformed traffic also checks the deadline; a delayed timer cannot preserve a hold.
            var packets = machine.tick(at: now)
            if let packet = try? SCX2Codec.decode(data) { packets += machine.receive(packet, at: now) }
            scx2 = machine
            applySCX2(packets)
            return
        }
        guard foreground, let session,
              let packet = try? BridgeCodec.decode(data), packet.session == session else { return }
        // Timers can be delayed by main-thread work. A late response must not
        // revive a session merely because the next timer callback has not run.
        if phase == .connecting && now - startedAt >= 3 {
            pauseAfterFailure(reason: "The bridge replied too late. Check the connection.")
            return
        }
        if isReady && !liveSessionIsFresh() { return }
        if phase == .connecting && packet.kind == .ready && packet.sequence == 0 {
            guard packet.hidReady == true else {
                pauseAfterFailure(reason: "The bridge replied, but its USB output is not ready. Check its connection to the Adaptive Controller.")
                return
            }
            lastResponse = now
            phase = .ready; failureCount = 0
            rememberSuccessfulConnection()
            clearLocalInput()
            sendState() // Start with a neutral report, never a held practice control.
        } else if isReady && packet.kind == .ack && packet.sequence > lastAcknowledged && packet.sequence <= sequence {
            guard packet.hidReady == true else {
                pauseAfterFailure(reason: "The bridge’s USB output stopped. Check the Adaptive Controller connection.")
                return
            }
            lastAcknowledged = packet.sequence
            acknowledgedPackets += 1
            lastResponse = now
        }
    }

    private func liveSessionIsFresh() -> Bool {
        if scx2 != nil || windowsPC != nil {
            tick()
            return isReady
        }
        guard isReady else { return false }
        guard now - lastResponse < 0.75 else {
            pauseAfterFailure(reason: "The bridge stopped replying. All local controls were released. Check the connection.")
            return false
        }
        return true
    }

    private func applyWindowsPC(_ packets: [WindowsPCPacket]) {
        guard let machine = windowsPC else { return }
        if case .stopped(let message) = machine.phase {
            let stop = packets.last(where: { $0.kind == .stop }).flatMap { try? WindowsPCCodec.encode($0) }
            pauseAfterFailure(reason: message, finalPacket: stop); return
        }
        if machine.controlsEnabled && !isReady {
            clearLocalInput(); phase = .ready; failureCount = 0
            rememberSuccessfulConnection()
        }
        acknowledgedPackets = machine.acknowledgedPackets
        for packet in packets {
            do { transport.send(try WindowsPCCodec.encode(packet)) }
            catch { pauseAfterFailure(reason: "A PC message could not be sent."); return }
        }
    }

    private func applySCX2(_ packets: [SCX2Packet]) {
        guard let machine = scx2 else { return }
        if case .stopped(let failure) = machine.phase {
            let stop = packets.last(where: { $0.kind == .stop }).flatMap { try? SCX2Codec.encode($0) }
            let explanation: String
            if failure == .helloTimeout && usesCronusZen {
                explanation = "No Cronus Zen Pico replied. Install the matching Zen firmware on the phone Pico and check its USB connection to Zen. Controls stayed paused."
            } else if failure == .helloTimeout && usesUSBButtonTriggers {
                explanation = "No USB-trigger-capable Pico replied. Install the matching phone Pico update, then map X1 to LT and X2 to RT in Xbox Accessories. Controls stayed paused."
            } else if failure == .helloTimeout && usesTriggerPressure {
                explanation = "No pressure-capable Pico replied. This option requires matching firmware and the analog trigger circuit."
            } else { explanation = Self.message(for: failure) }
            pauseAfterFailure(reason: explanation, finalPacket: stop)
            return
        }
        if machine.controlsEnabled && !isReady {
            clearLocalInput() // ACK1 is the only point that arms SCX2 controls.
            phase = .ready; failureCount = 0
            rememberSuccessfulConnection()
        }
        acknowledgedPackets = machine.acknowledgedPackets
        for packet in packets {
            do { transport.send(try SCX2Codec.encode(packet)) }
            catch { pauseAfterFailure(reason: "A controller message could not be sent."); return }
        }
    }

    private static func message(for failure: SCX2ClientMachine.Failure) -> String {
        switch failure {
        case .helloTimeout:
            "No SCX2 bridge replied. Check its address, power, Wi-Fi, and iPhone Local Network access."
        case .neutralTimeout:
            "The bridge did not confirm a neutral USB report. Controls stayed paused. Check the candidate hardware."
        case .acknowledgmentTimeout:
            "USB acknowledgments stopped arriving. All controls were released locally. Check the bridge."
        case .usbUnavailable:
            "The candidate bridge reports USB output unavailable. Check its connection and power."
        case .usbButtonTriggersUnavailable:
            "USB trigger output is unavailable. Use the updated phone Pico firmware and check its USB connection. Controls stayed paused."
        case .usbPressureUnavailable:
            "Adjustable USB output is unavailable. Use the Cronus Zen firmware on the phone Pico and check its USB connection to Zen. Controls stayed paused."
        case .pressureUnavailable:
            "The Pico's adjustable trigger output is unavailable. Check the analog trigger circuit and matching firmware. Controls stayed paused."
        case .bridgeChanged:
            "The bridge restarted or changed its connection token. All controls were released."
        case .queueOverflow:
            "The bridge could not keep up with control changes. Input stopped and its pending queue was cleared. Check the connection."
        case .sequenceExhausted:
            "This bridge session reached its message limit. All controls were released."
        case .invalidTime, .invalidSession, .invalidState:
            "The controller connection stopped because its state could not be validated. All controls were released."
        }
    }
}

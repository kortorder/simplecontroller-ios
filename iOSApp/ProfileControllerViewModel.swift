import Combine
import Foundation
import ControllerCore
#if DEBUG
import CryptoKit
#endif

enum GameStarter: String, CaseIterable, Identifiable {
    case shooter = "Shooter"
    case racing = "Racing"
    case sports = "Sports"
    case openWorld = "Open World"
    case palworld = "Palworld"
    var id: Self { self }
}

struct AndroidImportPreview: Identifiable, Sendable {
    let id = UUID()
    let archiveID: UUID
    let data: Data
    let displayName: String
    let plan: AndroidProfileImportPlan

    static func prepare(_ data: Data, displayName: String) throws -> Self {
        let cleaned = displayName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        let name = String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        let safeName = name.isEmpty ? "Android profile" : name
        let document = try AndroidProfileDocument.parse(data, fallbackName: String(safeName.prefix(64)))
        let archiveID = UUID()
        return .init(archiveID: archiveID, data: data, displayName: safeName,
                     plan: try .prepare(document, archiveID: archiveID))
    }
}

struct AndroidEditedExportReview: Identifiable, Sendable {
    let id = UUID()
    let profileName: String
    let preview: AndroidEditedExportPreview
}

/// Exact local recovery bytes. Only profile-related keys are exposed, never account/connection settings.
struct ProfileRecoveryDocument: Identifiable, Sendable {
    let id: String
    let title: String
    let data: Data
    let profileNames: [String]?
    let validationIssue: String?
}

/// Profile editing and input ownership sit above the existing tested bridge client.
/// The bridge still accepts only complete gamepad states, never editor operations.
@MainActor
final class ProfileControllerViewModel: ObservableObject {
    typealias Mode = ControllerViewModel.Mode
    @Published private(set) var library: ControllerProfileLibrary
    @Published private(set) var draft: ControllerProfile?
    @Published private(set) var currentPageID: UUID
    @Published private(set) var message: String?
    @Published private(set) var inputEpoch = 0
    @Published private(set) var isConfiguringControl = false
    @Published private(set) var isManagingProfiles = false
    @Published private(set) var isShowingSettings = false
    @Published private(set) var presentation = ControllerPresentationPreferences.default
    @Published private(set) var editorOrientation = ControllerDisplayOrientation.automatic
    @Published private(set) var presentationIssue: String?
    @Published private(set) var latchedControls: Set<UUID> = []
    @Published private(set) var retainedSticks: Set<UUID> = []
    @Published private(set) var activeControls: Set<UUID> = []
    @Published private(set) var stickPositions: [UUID: StickPosition] = [:]
    @Published private(set) var buttonAimStates: [UUID: ButtonAimVisualState] = [:]
    @Published private(set) var buttonDirectionalSelections: [UUID: ButtonDirectionalSelection] = [:]
    @Published private(set) var buttonFeedbackGeneration = 0
    private(set) var latestButtonFeedback: [ButtonFeedback] = []
    @Published private(set) var touchAimStates: [UUID: TouchAimState] = [:]
    @Published private(set) var touchAimScores: [UUID: Double] = [:]
    @Published private(set) var touchAimIssues: [UUID: String] = [:]
    @Published private(set) var activeTouchAims: Set<UUID> = []
    @Published private(set) var floatingRingStates: [UUID: FloatingRingState] = [:]
    @Published private(set) var dismissedFloatingButtonSessions: [UUID: UUID] = [:]
    @Published private(set) var fixedStickIssues: [UUID: String] = [:]
    @Published private(set) var cameraFollowSnapshot: CameraFollowPracticeSnapshot?
    @Published private(set) var autoCenterOverride: Bool?
    @Published private(set) var allSticksAutoCenterEnabled = false
    @Published private(set) var autoCenterMixed = false
    @Published private(set) var activeTouchpads: Set<UUID> = []
    @Published private(set) var lockedTouchpads: Set<UUID> = []
    @Published private(set) var pendingTouchpadLocks: Set<UUID> = []
    @Published private(set) var practiceState = PracticeOutputState.neutral
    @Published private(set) var recentPracticeEvents: [PracticeOutputEvent] = []
    @Published private(set) var practiceEventsOmittedCount = 0

    private let connection: ControllerViewModel
    private let defaults: UserDefaults
    private let androidArchiveStore: AndroidProfileArchiveStore
    private let nativeProfileStore: NativeProfileFileStore?
    private var profileStorageReadIssue: String?
    private let clock: () -> TimeInterval
    private let automaticTimer: Bool
    private let persistSettings: Bool
    private var engine: ProfileInputEngine
    private var behaviorTimer: Timer?
    private var behaviorTimerGeneration = 0
    private var observations: Set<AnyCancellable> = []
    private var protectedData: [String: Data] = [:]
    private var offerStarterWelcome = false
    private var foreground = true
    private var capabilityProfile: ControllerProfile?
    private var capabilityPageID: UUID?
    private var pageBeforeEditing: UUID?
    private var cachedDesktopOutputs = false
    private var cachedPointerOutputs = false
    private var cachedCameraFollowOutputs = false
    private var measuredCanvasProfile: ControllerProfile?
    private var measuredCanvasPage: UUID?
    private var measuredCanvasSnapshots: [ControllerOrientation: FloatingCanvasSnapshot] = [:]
    static let libraryKey = "controller.profiles.v1"
    static let presentationKey = "controller.presentation.v1"
    private var protectedPresentation: Data?
#if DEBUG
    private var didProcessProfileUpdateLaunch = false
    private var didProcessButtonSwipeUpdateLaunch = false
    private var didProcessApprovedGTA6LiveStickUpdateLaunch = false
    private var didProcessApprovedGTA6DrivingUpdateLaunch = false
    private var didProcessApprovedGTA6WalkUpdateLaunch = false
#endif

    init(defaults: UserDefaults = .standard,
         transport: (any BridgeTransporting)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         resumeClock: (() -> TimeInterval)? = nil,
         automaticTimer: Bool = true, persistSettings: Bool = true,
         androidArchiveDirectory: URL? = nil,
         profileStorageDirectory: URL? = nil) {
        self.defaults = defaults
        let nativeDirectory = profileStorageDirectory ?? (defaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SimpleController", isDirectory: true).appendingPathComponent("Profiles", isDirectory: true)
            : nil)
        self.nativeProfileStore = nativeDirectory.map { NativeProfileFileStore(directory: $0) }
        let archiveDirectory = androidArchiveDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimpleController", isDirectory: true).appendingPathComponent("AndroidOriginals", isDirectory: true)
        self.androidArchiveStore = AndroidProfileArchiveStore(directory: archiveDirectory)
        self.clock = clock
        self.automaticTimer = automaticTimer
        self.persistSettings = persistSettings
        connection = ControllerViewModel(defaults: defaults, transport: transport, clock: clock, wallClock: wallClock, resumeClock: resumeClock,
                                         automaticTimer: automaticTimer, persistSettings: persistSettings)
        var loaded = ControllerProfileLibrary.default
        var protected: [String: Data] = [:]
        var loadMessage: String?
        var savedRaw: Data?
        do { savedRaw = try nativeProfileStore?.loadLibrary() ?? defaults.data(forKey: Self.libraryKey) }
        catch {
            profileStorageReadIssue = "The saved profile file could not be read. It is kept unchanged. Open Profiles and recovery to export a recovery copy before trying again."
            loadMessage = profileStorageReadIssue
        }
        if profileStorageReadIssue != nil {
            // An existing unreadable file is authoritative. Never replace it with stale
            // preferences or create a fresh library over it during an ordinary launch.
        } else if let raw = savedRaw {
            do { loaded = try ControllerProfileLibraryCodec.decode(raw) }
            catch {
                protected[Self.libraryKey] = raw
                loadMessage = "Your saved profiles could not be opened. They are kept unchanged. Open Profiles and recovery → Recovery documents to export the saved data or restore a valid copy."
            }
        } else {
            let layoutRaw = defaults.data(forKey: "controller.layout.v1")
            let behaviorsRaw = defaults.data(forKey: "controller.behaviors.v1")
            do {
                let layout = try layoutRaw.map(ControllerLayoutCodec.decode) ?? .default
                let behaviors = try behaviorsRaw.map(ControllerBehaviorsCodec.decode) ?? .default
                var migrated = try ControllerProfile.migrating(layout: layout, behaviors: behaviors)
                // Legacy phone layouts retain their existing button-slide gesture. A first
                // launch without saved user data starts with deliberate direct touches.
                if layoutRaw == nil && behaviorsRaw == nil {
                    migrated.swipeMode = .off
                    offerStarterWelcome = true
                }
                loaded = try ControllerProfileLibrary(activeProfileID: migrated.id, profiles: [migrated])
                if persistSettings {
                    let bytes = try ControllerProfileLibraryCodec.encode(loaded)
                    if let nativeProfileStore { try nativeProfileStore.saveLibrary(bytes, previousData: nil) }
                    else { defaults.set(bytes, forKey: Self.libraryKey) }
                }
                // Keep both old documents intact as a migration recovery source.
            } catch {
                if let layoutRaw { protected["controller.layout.v1"] = layoutRaw }
                if let behaviorsRaw { protected["controller.behaviors.v1"] = behaviorsRaw }
                loadMessage = "Your earlier layout or settings could not be opened. They are kept unchanged. Open Profiles and recovery → Recovery documents to export the saved data or restore a valid copy."
            }
        }
        library = loaded
        currentPageID = loaded.activeProfile.homePageID
        protectedData = protected
        message = loadMessage
        engine = try! ProfileInputEngine(profile: loaded.activeProfile, allowCameraFollowPractice: true)
        cameraFollowSnapshot = engine.cameraFollowSnapshot
        publishAutoCenterState()
        connection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
        connection.$inputEpoch.dropFirst().sink { [weak self] _ in self?.clearEngine() }
            .store(in: &observations)
        if let bytes = defaults.data(forKey: Self.presentationKey) {
            do { presentation = try ControllerPresentationCodec.decode(bytes) }
            catch {
                protectedPresentation = bytes
                presentationIssue = "Saved display settings could not be read. Defaults are shown. Saving new display settings keeps a recovery copy of the old data."
            }
        }
    }

    var profile: ControllerProfile { draft ?? library.activeProfile }
    var currentPage: ProfilePage { profile.page(for: currentPageID) ?? profile.page(for: profile.homePageID)! }
    var currentPageControls: [ProfileControl] { profile.controls(on: currentPage.id) }
    var currentControlPage: (UUID) -> UUID? { { id in self.profile.pages.first { $0.controlIDs.contains(id) }?.id } }
    var hasDesktopOutputs: Bool { refreshCapabilities(); return cachedDesktopOutputs }
    var hasPointerOutputs: Bool { refreshCapabilities(); return cachedPointerOutputs }
    var hasCameraFollowOutputs: Bool { refreshCapabilities(); return cachedCameraFollowOutputs }
    private func refreshCapabilities() {
        let current = profile
        guard capabilityProfile != current || capabilityPageID != currentPageID else { return }
        capabilityProfile = current; capabilityPageID = currentPageID
        let rings = currentPage.floatingRingZones.filter(\.enabled)
        // Capability, not the live toggle, reserves the output row. A camera
        // update must never resize the canvas or cancel the active finger.
        cachedCameraFollowOutputs = currentPageControls.contains { control in
            if control.isCameraFollowAction { return true }
            guard !control.excludeFromCameraFollow else { return false }
            if control.logicalStick == .leftStick && !control.isDirectional { return true }
            if control.isTouchAim && control.touchAim.aim.output == .leftStick { return true }
            if control.buttonAim.enabled && (control.buttonAim.tuning.output == .leftStick ||
                (control.buttonAim.alternate.enabled && control.buttonAim.alternate.tuning.output == .leftStick)) { return true }
            return control.outputTargets.contains(.leftStick)
        } || rings.contains { ring in
            let movement = ring.config.movement
            if movement.enabled && movement.output == .leftStick && !movement.excludeFromCameraFollow { return true }
            // Movement-layer exclusion must not hide independent ADS/fire/boost
            // fixed-left-stick commands on the same ring.
            var otherLayers = ring.config
            otherLayers.movement.enabled = false
            return otherLayers.outputTargets.contains(.leftStick)
        }
        cachedDesktopOutputs = currentPageControls.contains { $0.hasKeyboardOrMouseOutputs } || rings.contains { $0.config.hasDesktopOutputs }
        cachedPointerOutputs = currentPageControls.contains { control in
            control.kind == .touchpad || (control.isTouchAim && control.touchAim.aim.output.isMouse) || (control.buttonAim.enabled && (control.buttonAim.tuning.output.isMouse ||
                (control.buttonAim.alternate.enabled && control.buttonAim.alternate.tuning.output.isMouse))) || ((try? control.payloadProgram().steps.contains {
                if case .scrollModeToggle = $0 { true } else { false }
            }) ?? false)
        } || rings.contains { $0.config.aim.enabled && $0.config.aim.tuning.output.isMouse }
    }
    var isEditingLayout: Bool { draft != nil }
    var requestedOrientation: ControllerDisplayOrientation {
        ControllerPresentationPolicy.orientation(preferences: presentation, isEditing: isEditingLayout, editorOrientation: editorOrientation)
    }
    @discardableResult
    func savePresentation(_ value: ControllerPresentationPreferences, editorOrientation: ControllerDisplayOrientation) -> Bool {
        do {
            let bytes = try ControllerPresentationCodec.encode(value)
            releaseAll() // Neutralize before UIKit changes the screen geometry or the editor exits.
            if persistSettings {
                if let protectedPresentation {
                    defaults.set(protectedPresentation, forKey: "controller.presentation.recovery.\(UUID().uuidString)")
                }
                defaults.set(bytes, forKey: Self.presentationKey)
            }
            presentation = value
            self.editorOrientation = isEditingLayout ? editorOrientation : .automatic
            protectedPresentation = nil; presentationIssue = nil
            return true
        } catch { presentationIssue = error.localizedDescription; return false }
    }
    var canEditLayout: Bool { protectedData.isEmpty && profileStorageReadIssue == nil }
    var canEditBehaviors: Bool { canEditLayout }
    var layoutMessage: String? { message }
    var mode: Mode { connection.mode }
    var state: GamepadState { mode == .practice ? practiceState.gamepad : connection.state }
    var host: String { get { connection.host } set { connection.host = newValue } }
    var portText: String { get { connection.portText } set { connection.portText = newValue } }
    var bridgeProtocol: BridgeProtocolVersion { connection.bridgeProtocol }
    func setBridgeProtocol(_ value: BridgeProtocolVersion) { connection.setBridgeProtocol(value) }
    var bridgeTriggerPressureEnabled: Bool { connection.bridgeTriggerPressureEnabled }
    var usesTriggerPressure: Bool { connection.usesTriggerPressure }
    var bridgeTriggerMode: BridgeTriggerMode { connection.bridgeTriggerMode }
    var usesUSBButtonTriggers: Bool { connection.usesUSBButtonTriggers }
    var usesCronusZen: Bool { connection.usesCronusZen }
    var usesWindowsPC: Bool { connection.usesWindowsPC }
    var allowsDesktopControls: Bool { connection.allowsDesktopControls }
    var allowsTriggerControls: Bool { connection.allowsTriggerControls }
    func setBridgeTriggerMode(_ value: BridgeTriggerMode) { connection.setBridgeTriggerMode(value) }
    func setBridgeTriggerPressureEnabled(_ value: Bool) { connection.setBridgeTriggerPressureEnabled(value) }
    var connectionRequested: Bool { connection.connectionRequested }
    var isReady: Bool { connection.isReady }
    var isConnecting: Bool { connection.isConnecting }
    var bridgeMenuStatus: String {
        if isEditingLayout { return "Editing layout" }
        if mode == .practice { return "Practice" }
        switch connection.phase {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting…"
        case .ready: return "Connected"
        case .stopped: return connection.connectionRequested ? "Reconnecting…" : "Disconnected"
        }
    }
    var controlsEnabled: Bool {
        connection.controlsEnabled && !isEditingLayout && !isConfiguringControl && !isManagingProfiles && !isShowingSettings
    }
    var keepsScreenAwake: Bool { connection.keepsScreenAwake }
    var statusTitle: String { isEditingLayout ? "Editing profile • controls paused" : connection.statusTitle }
    var statusDetail: String {
        isEditingLayout ? "Drag to move. Hold a control to change its size, actions or behavior. Save keeps every change in this profile." : connection.statusDetail
    }

    func setMode(_ mode: Mode) {
        guard !isEditingLayout, !isConfiguringControl, !isManagingProfiles, !isShowingSettings else { return }
        let changed = mode != self.mode
        connection.setMode(mode)
        if changed {
            do { try engine.setCameraFollowPracticeAllowed(connection.allowsDesktopControls, at: clock()) }
            catch { releaseAll() }
            publishEngine(); clearPracticeHistory()
        }
    }
    func connect() {
        guard !isEditingLayout, !isConfiguringControl, !isManagingProfiles, !isShowingSettings else { return }
        connection.connect()
    }
    func stop() { connection.stop() }
    private func pauseConnection() { connection.cancelQueuedInput(reason: "Controls released. Preparing the bridge…") }
    func saveSettings() { connection.saveSettings() }
    func setForeground(_ active: Bool, didEnterBackground: Bool = false) {
        foreground = active
        connection.setForeground(active, didEnterBackground: didEnterBackground)
    }
    func tick() { connection.tick() }
    func releaseAll() { connection.releaseAll() }

    @discardableResult
    func handleInput(_ event: ProfileInputEvent, epoch: Int) -> Bool {
        guard controlsEnabled, epoch == inputEpoch else { return false }
        // Local Release all must stop transport queues and invalidate UIKit callbacks as well as the engine.
        let directID: UUID?
        switch event {
        case .begin(_, let id, _), .beginButton(_, let id, _), .accessibilityActivate(let id): directID = id
        default: directID = nil
        }
        if let id = directID, currentPage.controlIDs.contains(id), profile.control(for: id)?.isReleaseAllAction == true {
            releaseAll(); return true
        }
        if let id = directID, !connection.allowsDesktopControls, profile.control(for: id)?.isCameraFollowAction == true { return false }
        // Sensor surfaces require a real direct touch; reject a semantic tap without canceling other owners.
        if case .accessibilityActivate(let id) = event, profile.control(for: id)?.isTouchAim == true { return false }
        // Check the bridge lease before advancing any hold timers or owners.
        if mode == .bridge { connection.tick(); guard controlsEnabled, epoch == inputEpoch else { return false } }
        let previousPage = engine.currentPageID
        do {
            let now = clock()
            try engine.setCameraFollowPracticeAllowed(connection.allowsDesktopControls, at: now)
            try engine.handle(event, at: now)
        }
        catch { releaseAll(); return false }
        if engine.currentPageID != previousPage {
            currentPageID = engine.currentPageID
            inputEpoch += 1 // The old page's callbacks must never reach its replacement.
            connection.cancelQueuedInput(reason: "Page changed. Preparing fresh controls…")
        }
        publishEngine()
        refreshTimer()
        switch event {
        case let .registerFloatingButtonSession(zoneID, sessionID):
            return engine.floatingButtonSessions[zoneID] == sessionID
        case let .beginButton(contact, _, _), let .beginStick(contact, _, _), let .beginTouchAim(contact, _, _), let .beginTouchpad(contact, _), let .beginFloatingRing(contact, _, _, _, _):
            return engine.isCapturedInputOwner(for: contact)
        case let .begin(contact, destination, _):
            return profile.control(for: destination)?.isLocalAction == true || engine.isCapturedInputOwner(for: contact)
        case let .handoff(contact, destination, _, _, _),
             let .handoffTravel(contact, destination, _, _, _),
             let .handoffFloatingButton(contact, _, destination):
            return engine.capturedControl(for: contact) == destination
        default: break
        }
        return true
    }
    func tickInput(epoch: Int? = nil) {
        guard controlsEnabled, epoch == nil || epoch == inputEpoch else { return }
        if mode == .bridge { connection.tick(); guard controlsEnabled else { return } }
        do {
            let now = clock()
            try engine.setCameraFollowPracticeAllowed(connection.allowsDesktopControls, at: now)
            try engine.tick(at: now)
        }
        catch { releaseAll(); return }
        publishEngine()
        refreshTimer()
    }
    func recenterSticks() {
        guard controlsEnabled else { return }
        engine.recenterSticks()
        publishEngine()
        refreshTimer()
    }
    func setCameraFollowEnabled(_ enabled: Bool) { updateCameraFollow(enabled: enabled, strength: nil) }
    func setCameraFollowStrength(_ strength: Double) { updateCameraFollow(enabled: cameraFollowSnapshot?.requestedEnabled ?? false, strength: strength) }
    private func updateCameraFollow(enabled: Bool, strength: Double?) {
        guard connection.allowsDesktopControls, controlsEnabled else { return }
        do {
            let now = clock()
            try engine.setCameraFollowPracticeAllowed(true, at: now)
            try engine.setCameraFollowEnabled(enabled, strengthPercent: strength, at: now)
            publishEngine(); refreshTimer()
        } catch { releaseAll(); message = error.localizedDescription }
    }
    private func publishAutoCenterState() {
        autoCenterOverride = engine.autoCenterOverride
        allSticksAutoCenterEnabled = engine.allSticksAutoCenterEnabled
        autoCenterMixed = engine.autoCenterSettingsMixed
    }
    private func publishEngine() {
        publishAutoCenterState()
        latchedControls = engine.latchedControls
        retainedSticks = Set(engine.retainedSticks.keys)
        activeControls = engine.outputControls
        stickPositions = engine.stickPositions
        buttonAimStates = engine.buttonAimStates
        buttonDirectionalSelections = engine.buttonDirectionalSelections
        let feedback = engine.drainButtonFeedback()
        if !feedback.isEmpty { latestButtonFeedback = feedback; buttonFeedbackGeneration += 1 }
        touchAimStates = engine.touchAimStates; touchAimScores = engine.touchAimScores
        touchAimIssues = engine.touchAimIssues; activeTouchAims = engine.activeTouchAims
        floatingRingStates = engine.floatingRingStates
        dismissedFloatingButtonSessions = engine.dismissedFloatingButtonSessions
        fixedStickIssues = engine.fixedStickIssues
        cameraFollowSnapshot = engine.cameraFollowSnapshot
        activeTouchpads = engine.activeTouchpads
        lockedTouchpads = engine.lockedTouchpads
        pendingTouchpadLocks = engine.pendingTouchpadLocks
        practiceState = engine.practiceState
        collectPracticeEvents()
        connection.updateOutput(.init(gamepad: connection.usesWindowsPC ? practiceState.gamepad : engine.state,
                                      leftTrigger: practiceState.leftTrigger,
                                      rightTrigger: practiceState.rightTrigger), desktop: practiceState, epoch: connection.inputEpoch)
    }
    private func clearEngine() {
        inputEpoch += 1
        behaviorTimerGeneration += 1
        behaviorTimer?.invalidate(); behaviorTimer = nil
        engine.releaseAll()
        _ = engine.drainButtonFeedback(); latestButtonFeedback = []
        buttonAimStates = [:]; buttonDirectionalSelections = [:]
        latchedControls = []; retainedSticks = []; activeControls = []; stickPositions = [:]
        touchAimStates = [:]; touchAimScores = [:]; touchAimIssues = [:]; activeTouchAims = []
        floatingRingStates = [:]
        dismissedFloatingButtonSessions = [:]
        fixedStickIssues = [:]; cameraFollowSnapshot = engine.cameraFollowSnapshot
        publishAutoCenterState()
        activeTouchpads = []; lockedTouchpads = []; pendingTouchpadLocks = []
        practiceState = .neutral
        collectPracticeEvents()
    }
    private func collectPracticeEvents() {
        let batch = engine.drainPracticeEvents()
        practiceEventsOmittedCount += batch.omittedCount
        recentPracticeEvents.append(contentsOf: batch.events)
        let excess = max(0, recentPracticeEvents.count - 32)
        if excess > 0 {
            recentPracticeEvents.removeFirst(excess)
            practiceEventsOmittedCount += excess
        }
    }
    func clearPracticeHistory() {
        _ = engine.drainPracticeEvents()
        recentPracticeEvents = []
        practiceEventsOmittedCount = 0
    }
    private func refreshTimer() {
        behaviorTimer?.invalidate(); behaviorTimer = nil
        behaviorTimerGeneration += 1
        guard automaticTimer, controlsEnabled, let deadline = engine.nextDeadline else { return }
        let epoch = inputEpoch
        let generation = behaviorTimerGeneration
        let timer = Timer(timeInterval: max(0.001, deadline - clock()), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.inputEpoch == epoch, self.behaviorTimerGeneration == generation else { return }
                self.behaviorTimer = nil
                self.tickInput(epoch: epoch)
            }
        }
        behaviorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func beginLayoutEditing() {
        guard canEditLayout, !isEditingLayout, !isShowingSettings, !isManagingProfiles else { return }
        pageBeforeEditing = currentPageID
        pauseConnection(); editorOrientation = .automatic; draft = library.activeProfile; message = nil
    }
    func updateProfile(_ value: ControllerProfile, epoch: Int) {
        guard foreground, isEditingLayout, !isConfiguringControl, epoch == inputEpoch,
              value.id == draft?.id, (try? value.validate()) != nil else { return }
        draft = value
    }
    func saveLayoutEditing() {
        guard let draft, canEditLayout else { return }
        var candidate = library
        guard let index = candidate.profiles.firstIndex(where: { $0.id == draft.id }) else { return }
        candidate.profiles[index] = draft
        if saveLibrary(candidate, selectedPageID: currentPageID) { self.draft = nil; pageBeforeEditing = nil; message = "Profile saved, including all pages and both orientations." }
    }
    func cancelLayoutEditing() {
        draft = nil; isConfiguringControl = false; pauseConnection()
        try? engine.apply(profile: library.activeProfile)
        if let page = pageBeforeEditing, library.activeProfile.page(for: page) != nil {
            _ = try? engine.selectPage(page, at: clock())
        }
        currentPageID = engine.currentPageID; pageBeforeEditing = nil
        publishAutoCenterState()
    }

    /// Page selection releases old input; the bridge resumes after a fresh neutral handshake.
    func selectPage(_ id: UUID) {
        guard foreground, canEditLayout, !isConfiguringControl, !isShowingSettings, !isManagingProfiles,
              profile.page(for: id) != nil, id != currentPageID else { return }
        if isEditingLayout {
            clearEngine(); currentPageID = id
        } else {
            do {
                guard try engine.selectPage(id, at: clock()) else { return }
                currentPageID = engine.currentPageID; inputEpoch += 1
                connection.cancelQueuedInput(reason: "Page changed. Preparing fresh controls…")
                publishEngine(); refreshTimer()
            } catch { releaseAll() }
        }
    }

    func savePages(_ updated: ControllerProfile, selectedPageID: UUID) {
        guard isEditingLayout, updated.id == draft?.id, (try? updated.validate()) != nil else { return }
        draft = updated
        currentPageID = updated.page(for: selectedPageID) == nil ? updated.homePageID : selectedPageID
        clearEngine()
    }

    func moveControl(_ id: UUID, toPage page: UUID) {
        guard var next = draft else { return }
        do { try next.moveControl(id, toPage: page); draft = next }
        catch { message = "This control could not be moved to that page." }
    }

    func beginControlConfiguration() {
        guard canEditLayout, isEditingLayout else { return }
        pauseConnection(); isConfiguringControl = true
    }
    func finishControlConfiguration() { isConfiguringControl = false; releaseAll() }

    @discardableResult
    func addControl(kind: ProfileControlKind) -> UUID? {
        guard var next = draft, next.controls.count < ControllerProfile.maximumControls else { return nil }
        let label: String
        switch kind {
        case .button: label = "A"
        case .leftStick: label = "Left stick"
        case .rightStick: label = "Right stick"
        case .recenter: label = "Re-center"
        case .touchpad: label = "Touchpad"
        case .touchAim: label = "Touch Aim"
        case .pageButton: label = "Home"
        }
        var control = ProfileControl(name: label, kind: kind,
                                     actions: kind == .button ? [.a] : [],
                                     diameter: kind.isStick ? 104 : 60)
        if kind == .touchAim { control.touchAim.requiresLocalSetup = true }
        do { try next.addControl(control, toPage: currentPage.id) }
        catch { message = "This control could not be added."; return nil }
        draft = next
        return control.id
    }
    @discardableResult
    func addAutoCenterControl() -> UUID? {
        guard var next = draft, next.controls.count < ControllerProfile.maximumControls else { return nil }
        var control = ProfileControl(name: "Auto-center", kind: .button, actions: [], diameter: 44)
        control.payload = "AUTO_CENTER_TOGGLE"
        do { try next.addControl(control, toPage: currentPage.id) }
        catch { message = "The auto-center button could not be added."; return nil }
        draft = next
        return control.id
    }
    func saveControl(_ control: ProfileControl, onPage page: UUID? = nil) {
        guard var next = draft, let index = next.controls.firstIndex(where: { $0.id == control.id }) else { return }
        next.controls[index] = control
        if let page {
            do { try next.moveControl(control.id, toPage: page) }
            catch { message = "These control settings could not be applied."; return }
        }
        guard (try? next.validate()) != nil else { message = "These control settings could not be applied."; return }
        draft = next
    }
    func saveProfileOptions(_ updated: ControllerProfile) {
        guard var next = draft, next.id == updated.id else { return }
        next.name = updated.name
        next.turboEnabled = updated.turboEnabled
        next.turboIntervalMilliseconds = updated.turboIntervalMilliseconds
        next.swipeMode = updated.swipeMode
        next.globalHoldEnabled = updated.globalHoldEnabled
        for index in next.controls.indices {
            guard let edited = updated.control(for: next.controls[index].id), edited.kind == next.controls[index].kind else { continue }
            if next.controls[index].kind.isStick { next.controls[index].stickBehavior.autoCenter = edited.stickBehavior.autoCenter }
            if next.controls[index].buttonAim.enabled {
                next.controls[index].buttonAim.tuning.autoCenter = edited.buttonAim.tuning.autoCenter
                next.controls[index].buttonAim.alternate.tuning.autoCenter = edited.buttonAim.alternate.tuning.autoCenter
            }
        }
        guard (try? next.validate()) != nil else { message = "These profile options could not be applied."; return }
        draft = next
    }

    var floatingCanvasSnapshots: [ControllerOrientation: FloatingCanvasSnapshot] {
        measuredCanvasProfile == profile && measuredCanvasPage == currentPageID ? measuredCanvasSnapshots : [:]
    }
    func recordCanvasSnapshot(_ snapshot: FloatingCanvasSnapshot, profile measuredProfile: ControllerProfile,
                              pageID: UUID, orientation: ControllerOrientation) {
        guard profile == measuredProfile, currentPageID == pageID, (try? snapshot.validate()) != nil else { return }
        if measuredCanvasProfile != measuredProfile || measuredCanvasPage != pageID { measuredCanvasSnapshots = [:] }
        measuredCanvasProfile = measuredProfile; measuredCanvasPage = pageID
        measuredCanvasSnapshots[orientation] = snapshot
    }
    func saveFloatingDraft(_ updated: ControllerProfile) {
        guard isEditingLayout, updated.id == profile.id, (try? updated.validate()) != nil else {
            message = "The floating layout could not be applied. Check its members, sizes and activation areas."; return
        }
        releaseAll(); draft = updated
        message = "Floating controls updated in the draft. Save layout to keep them."
    }
    /// Restores imported source geometry into a returned draft; archive reads never save a layout.
    func restoreFloatingButtons(_ value: ControllerProfile, zoneID: UUID, pageID: UUID) async throws -> ControllerProfile {
        guard isEditingLayout, value.id == profile.id, value.page(for: pageID) != nil else {
            throw FloatingControlError("The layout draft changed. Open the floating control again.")
        }
        try value.validate()
        let sources = value.androidSources.filter { $0.zones.contains { $0.nativeID == zoneID } }
        guard !sources.isEmpty else {
            var restored = value; try restored.unfloatButtons(zoneID, on: pageID); return restored
        }
        guard sources.count == 1, let source = sources.first,
              let reference = library.androidSources.first(where: { $0.id == source.archiveID }) else {
            throw FloatingControlError("The preserved Android original is needed to restore these buttons. Your draft has not changed.")
        }
        let directory = androidArchiveStore.directory, expectedEpoch = inputEpoch
        let restored = try await Task.detached(priority: .userInitiated) {
            let archived = try AndroidProfileArchiveStore(directory: directory).load(reference)
            let original = try AndroidProfileDocument.parse(archived.originalData)
            return try AndroidFloatingRestoration.restore(profile: value, zoneID: zoneID, pageID: pageID, original: original, source: source)
        }.value
        try Task.checkCancellation()
        guard isEditingLayout, value.id == profile.id, inputEpoch == expectedEpoch else {
            throw FloatingControlError("The layout changed while its original was being read. Open the floating control again.")
        }
        return restored
    }
    func duplicateControl(_ control: ProfileControl, toPage requestedPage: UUID? = nil) {
        guard var next = draft, next.controls.count < ControllerProfile.maximumControls,
              next.control(for: control.id) != nil, (try? control.validate()) != nil else { return }
        var copy = control
        copy.id = UUID()
        copy.name = copiedName(control.name)
        func position(_ placements: [ProfilePlacement]) -> NormalizedControlPosition {
            let point = placements.first { $0.id == control.id }!.position
            return .init(x: min(0.95, point.x + 0.06), y: min(0.95, point.y + 0.06))
        }
        let page = requestedPage ?? next.pages.first { $0.controlIDs.contains(control.id) }!.id
        do {
            try next.addControl(copy, toPage: page, portrait: position(next.portrait), landscape: position(next.landscape))
            try next.duplicateSourceBinding(from: control.id, to: copy.id)
        }
        catch { message = "This control could not be copied."; return }
        draft = next
    }
    func deleteControl(_ id: UUID) {
        guard var next = draft else { return }
        do { try next.removeControl(id) }
        catch { message = "This control could not be removed."; return }
        draft = next
    }

    func prepareSettings() { guard !isEditingLayout else { return }; pauseConnection(); isShowingSettings = true }
    func finishSettings() { isShowingSettings = false; releaseAll() }
    func takeStarterWelcome() -> Bool {
        guard offerStarterWelcome else { return false }
        offerStarterWelcome = false
        return true
    }

    @discardableResult
    func useStarter(_ starter: GameStarter, resourceDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Starters")) -> Bool {
        guard !isEditingLayout, canEditLayout else {
            message = "Finish editing or recover your saved profiles before adding a starter."
            return false
        }
        guard library.profiles.count < 32 else {
            message = "Your library has 32 profiles. Remove one from Profiles to make room for a starter."
            return false
        }
        do {
            guard let url = resourceDirectory?.appendingPathComponent(starter.rawValue).appendingPathExtension("json") else {
                throw ControllerProfileError.invalidFormat
            }
            let template = try ControllerProfileLibraryCodec.decode(Data(contentsOf: url))
            guard template.profiles.count == 1, template.activeProfile.name == starter.rawValue,
                  template.androidSources.isEmpty, template.settingsPresets.entries.isEmpty,
                  !template.activeProfile.controls.isEmpty else { throw ControllerProfileError.invalidFormat }
            var name = starter.rawValue
            var number = 1
            while library.profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                number += 1
                name = "\(starter.rawValue) \(number)"
            }
            let copy = try template.activeProfile.cloned(name: name)
            var candidate = library
            candidate.profiles.append(copy)
            candidate.activeProfileID = copy.id
            return saveLibrary(candidate)
        } catch {
            message = "The \(starter.rawValue) starter could not be opened. You can choose another layout."
            return false
        }
    }

    func beginProfileManagement() {
        guard !isEditingLayout else { return }
        pauseConnection(); isManagingProfiles = true
    }
    func finishProfileManagement() { isManagingProfiles = false; releaseAll() }

    @discardableResult
    func selectProfile(_ id: UUID) -> Bool {
        guard !isEditingLayout, canEditLayout, library.profiles.contains(where: { $0.id == id }) else { return false }
        var candidate = library; candidate.activeProfileID = id
        return saveLibrary(candidate)
    }
    @discardableResult
    func createProfile(name: String, standardControls: Bool) -> Bool {
        guard !isEditingLayout, canEditLayout, library.profiles.count < 32 else { return false }
        do {
            var profile = standardControls
                ? try ControllerProfile.migrating(layout: .default, behaviors: .default, name: name)
                : try ControllerProfile(name: name, controls: [], portrait: [], landscape: [])
            profile.swipeMode = .off
            var candidate = library
            candidate.profiles.append(profile); candidate.activeProfileID = profile.id
            return saveLibrary(candidate)
        } catch { message = "Choose a profile name from 1 to 64 characters."; return false }
    }
    @discardableResult
    func renameProfile(_ id: UUID, name: String) -> Bool {
        guard !isEditingLayout, canEditLayout,
              let index = library.profiles.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = library; candidate.profiles[index].name = name
        return saveLibrary(candidate)
    }
    @discardableResult
    func duplicateProfile(_ id: UUID) -> Bool {
        guard !isEditingLayout, canEditLayout, library.profiles.count < 32,
              let original = library.profiles.first(where: { $0.id == id }) else { return false }
        guard let copy = try? original.cloned(name: copiedName(original.name)) else { return false }
        var candidate = library; candidate.profiles.append(copy); candidate.activeProfileID = copy.id
        return saveLibrary(candidate)
    }
    @discardableResult
    func deleteProfile(_ id: UUID) -> Bool {
        guard !isEditingLayout, canEditLayout, library.profiles.count > 1,
              let removed = library.profiles.first(where: { $0.id == id }) else { return false }
        do {
            if persistSettings, let raw = try currentLibraryData() {
                let base = "controller.profiles.before-delete.\(removed.id.uuidString)"
                let key = try recoveryData(for: base).map { $0 == raw ? base : base + "." + UUID().uuidString } ?? base
                try saveRecoveryData(raw, key: key)
            }
            var candidate = library; candidate.profiles.removeAll { $0.id == id }
            if candidate.activeProfileID == id { candidate.activeProfileID = candidate.profiles[0].id }
            return saveLibrary(candidate)
        } catch { message = "The recovery copy could not be saved. Your profiles are unchanged."; return false }
    }
    @discardableResult
    func deleteProfiles(_ ids: Set<UUID>) -> Bool {
        guard !isEditingLayout, canEditLayout else { return false }
        do {
            let plan = try ControllerProfileBulkDeletion.prepare(library: library, selectedIDs: ids)
            _ = try ControllerProfileLibraryCodec.encode(plan.candidate)
            if persistSettings, let raw = try currentLibraryData() {
                try saveRecoveryData(raw, key: "controller.profiles.before-batch-delete.\(UUID().uuidString)")
            }
            guard saveLibrary(plan.candidate) else { return false }
            message = "Deleted \(plan.deletedProfileIDs.count) profiles. Your selected profile is unchanged, and a recovery copy is kept on this phone."
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func restoreProfiles() {
        guard !isEditingLayout else { return }
        do {
            if persistSettings {
                if let raw = try currentLibraryData() { try saveRecoveryData(raw, key: "controller.profiles.recovery.\(UUID().uuidString)") }
                for (_, raw) in protectedData { try saveRecoveryData(raw, key: "controller.profiles.recovery.\(UUID().uuidString)") }
            }
            if saveLibrary(.default) {
                protectedData = [:]; profileStorageReadIssue = nil
                message = "A fresh profile is ready. Previous saved data has a recovery copy."
            }
        } catch { message = "Your saved data could not be backed up. Nothing was replaced." }
    }

    var recoveryDocuments: [ProfileRecoveryDocument] {
        var copies = defaults.dictionaryRepresentation().compactMapValues { $0 as? Data }
            .filter { Self.isProfileRecoveryKey($0.key) }
        if let stored = try? nativeProfileStore?.recoveryDocuments() {
            for (key, data) in stored { copies[key] = data }
        }
        // Keep the old preferences library available after the file store becomes primary.
        if nativeProfileStore != nil, let legacy = defaults.data(forKey: Self.libraryKey),
           (try? nativeProfileStore?.loadLibrary()) != nil {
            copies["controller.profiles.recovery.legacy-preferences"] = legacy
        }
        for (key, data) in protectedData { copies[key] = data }
        return copies.keys.sorted().enumerated().map { index, key in
            let data = copies[key]!
            let title: String
            if protectedData[key] != nil { title = "Unreadable saved profile data" }
            else if key.hasPrefix("controller.profiles.before-format-") {
                title = "Before profile format \(key.replacingOccurrences(of: "controller.profiles.before-format-", with: ""))"
            } else if key == "controller.profiles.recovery.before-storage-expansion" { title = "Before increasing profile storage" }
            else if key.hasPrefix("controller.profiles.before-batch-delete.") { title = "Before deleting several profiles" }
            else if key.hasPrefix("controller.profiles.before-delete.") { title = "Before deleting a profile" }
            else { title = "Saved recovery copy \(index + 1)" }
            do {
                let recovered = try ControllerProfileLibraryCodec.decode(data)
                return .init(id: key, title: title, data: data, profileNames: recovered.profiles.map(\.name), validationIssue: nil)
            } catch {
                return .init(id: key, title: title, data: data, profileNames: nil,
                    validationIssue: "This copy cannot be restored as a supported iPhone profile library. You can still export its exact contents for recovery.")
            }
        }
    }
    private static func isProfileRecoveryKey(_ key: String) -> Bool {
        key.hasPrefix("controller.profiles.before-format-") || key.hasPrefix("controller.profiles.before-delete.") ||
        key.hasPrefix("controller.profiles.before-batch-delete.") || key.hasPrefix("controller.profiles.recovery.")
    }
    @discardableResult
    func restoreRecoveryDocument(_ snapshot: ProfileRecoveryDocument) -> Bool {
        guard !isEditingLayout else { message = "Save or cancel the layout draft before recovering profiles."; return false }
        guard Self.isProfileRecoveryKey(snapshot.id) || protectedData[snapshot.id] != nil,
              (protectedData[snapshot.id] ?? (try? recoveryData(for: snapshot.id))) == snapshot.data else {
            message = "This recovery copy changed or is no longer available. Open Recovery documents again."; return false
        }
        do {
            let recovered = try ControllerProfileLibraryCodec.decode(snapshot.data)
            _ = try ControllerProfileLibraryCodec.encode(recovered)
            if persistSettings {
                if let current = try currentLibraryData() {
                    try saveRecoveryData(current, key: "controller.profiles.recovery.\(UUID().uuidString)")
                }
                for (key, data) in protectedData where key != Self.libraryKey {
                    try saveRecoveryData(data, key: "controller.profiles.recovery.\(UUID().uuidString)")
                }
            }
            guard saveLibrary(recovered) else { return false }
            protectedData = [:]; profileStorageReadIssue = nil
            message = "Restored \(recovered.profiles.count) profiles. The previous saved library is kept in Recovery documents. All controls are released."
            return true
        } catch {
            message = "This recovery copy could not be restored. Your current profiles are unchanged. Export the copy to keep its exact contents."
            return false
        }
    }

    /// Export only the validated native profile document, never settings or runtime owners.
    func exportProfiles() -> Data? {
        guard canEditLayout else {
            message = "Your saved profiles could not be read. Export is unavailable until you recover them or explicitly restore profiles."
            return nil
        }
        guard !isEditingLayout else {
            message = "Save or cancel the layout draft before exporting profiles."
            return nil
        }
        do {
            var backupLibrary = library
            // Include recoverable originals from interrupted imports as well as referenced ones.
            for reference in try androidArchiveStore.list() where !backupLibrary.androidSources.contains(where: { $0.id == reference.id }) {
                backupLibrary.androidSources.append(reference)
            }
            let native = try ControllerProfileLibraryCodec.encode(backupLibrary)
            let data: Data
            if backupLibrary.androidSources.isEmpty { data = native }
            else {
                let archives = try backupLibrary.androidSources.map { try androidArchiveStore.load($0) }
                data = try AndroidPortableBackup(nativeLibraryData: native, archives: archives).encodedData()
            }
            message = nil
            return data
        } catch {
            message = "The profile backup could not be prepared. Your saved profiles are unchanged."
            return nil
        }
    }

    /// Merge validated native backups atomically; existing profiles and selection stay intact.
    @discardableResult
    func importProfiles(_ data: Data) -> Bool {
        guard canEditLayout else {
            message = "Your saved profiles need recovery before importing. They have not been changed."
            return false
        }
        guard !isEditingLayout else {
            message = "Save or cancel the layout draft before importing profiles."
            return false
        }
        do {
            guard data.count <= AndroidPortableBackup.maximumBytes else { throw AndroidArchiveError("This backup exceeds 40 MiB.") }
            let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            var imported: ControllerProfileLibrary
            var bundled: [AndroidArchivedSource] = []
            if header?["fileType"] as? String == "simplecontroller-ios-portable-backup" {
                let portable = try AndroidPortableBackup.decode(data)
                imported = try ControllerProfileLibraryCodec.decode(portable.nativeLibraryData)
                bundled = portable.archives
            } else {
                imported = try ControllerProfileLibraryCodec.decode(data)
                // A bare native document must not strand references to missing originals.
                bundled = try imported.androidSources.map { try androidArchiveStore.load($0) }
            }
            guard library.profiles.count + imported.profiles.count <= 32 else {
                message = "This backup would exceed the 32-profile limit. Nothing was imported; your current profiles are unchanged."
                return false
            }
            // Imported sensor fits need new local validation. Presets merge independently, never replacing local entries.
            imported = try imported.requiringLocalTouchCalibrationValidation()
            var candidate = library
            try candidate.settingsPresets.merge(imported.settingsPresets, at: Int64(Date().timeIntervalSince1970 * 1000))
            let storedSources = try androidArchiveStore.insertVerified(bundled)
            for index in imported.profiles.indices {
                imported.profiles[index].androidSources = imported.profiles[index].androidSources.map { source in
                    source.replacingArchiveID(storedSources[source.archiveID]!.id)
                }
            }
            imported.androidSources = Array(Set(imported.androidSources.compactMap { storedSources[$0.id]?.id })).compactMap { id in
                storedSources.values.first { $0.id == id }
            }
            for reference in imported.androidSources where !candidate.androidSources.contains(where: { $0.id == reference.id }) {
                candidate.androidSources.append(reference)
            }
            var occupiedNames = Set(library.profiles.map { $0.name.lowercased() })
            for original in imported.profiles {
                var copy = try original.cloned()
                let base = original.name.trimmingCharacters(in: .whitespacesAndNewlines)
                var counter = 1
                while true {
                    let suffix = counter == 1 ? " imported" : " imported \(counter)"
                    let name = String(base.prefix(64 - suffix.count)) + suffix
                    if occupiedNames.insert(name.lowercased()).inserted {
                        copy.name = name
                        break
                    }
                    counter += 1
                }
                candidate.profiles.append(copy)
            }
            // saveLibrary validates the whole merged document before stopping input or writing.
            guard saveLibrary(candidate) else { return false }
            let count = imported.profiles.count
            message = "Imported \(count) \(count == 1 ? "profile" : "profiles") as new copies. Your current profile stays selected."
            return true
        } catch let error as SettingsPresetError {
            message = "The reusable settings could not be imported. \(error.localizedDescription) Your profiles and presets are unchanged."
        } catch let error as AndroidArchiveError {
            message = "Import could not finish. \(error.localizedDescription) Your profiles are unchanged; any already-preserved original remains available under Android originals."
        } catch ControllerProfileError.oversizedData {
            message = "The native profiles exceed their 16 MiB limit. Nothing was imported."
        } catch ControllerProfileError.unsupportedVersion {
            message = "This backup uses a newer or unsupported iPhone format. Nothing was imported."
        } catch {
            message = "This is not a valid iPhone profile backup. Use Import Android profiles for Android files. Nothing was imported."
        }
        return false
    }

    /// The preview is prepared before confirmation. Store exact originals before native conversion is saved.
    @discardableResult
    func importAndroid(_ preview: AndroidImportPreview) -> Bool {
        guard canEditLayout, !isEditingLayout else {
            message = "Save or cancel editing and resolve profile recovery before importing."; return false
        }
        do {
            let provisional = try library.androidSources.first(where: {
                $0.sha256 == preview.plan.sourceSHA256 && $0.byteCount == preview.data.count
            }) ?? AndroidSourceArchiveReference(id: preview.archiveID, sha256: preview.plan.sourceSHA256,
                byteCount: preview.data.count, displayName: preview.displayName)
            // Validate capacity, native sizes and references before writing any source file.
            _ = try ControllerProfileLibraryCodec.encode(preview.plan.merged(into: library, source: provisional))
            let reference = try androidArchiveStore.insert(preview.data, displayName: preview.displayName)
            let candidate = try preview.plan.merged(into: library, source: reference)
            guard saveLibrary(candidate) else {
                message = "The original was preserved, but native profiles could not be saved. Your previous profiles remain available."; return false
            }
            message = "Imported \(preview.plan.profiles.count) profiles with \(preview.plan.convertedControlCount) controls and \(preview.plan.convertedPresetCount) reusable settings. \(preview.plan.archivedOnlyControlCount) controls remain in the original only. Your current profile stays selected."
            return true
        } catch {
            message = "Android import could not finish. \(error.localizedDescription) Your current profiles are unchanged."
            return false
        }
    }

    func androidOriginals() -> [AndroidSourceArchiveReference] {
        do { return try androidArchiveStore.list() }
        catch { message = "Android originals could not be listed. \(error.localizedDescription)"; return [] }
    }
    func exportAndroidOriginal(_ reference: AndroidSourceArchiveReference) -> Data? {
        do {
            let original = try androidArchiveStore.load(reference)
            message = "Exporting the unchanged Android original. iPhone edits are in the iPhone profile backup."
            return original.originalData
        } catch {
            message = "The original could not be exported. \(error.localizedDescription)"; return nil
        }
    }

    /// Computes a separate file; neither the native profile nor the immutable archive is changed.
    func prepareEditedAndroidExport(_ profileID: UUID) async -> AndroidEditedExportReview? {
        guard canEditLayout, !isEditingLayout,
              let profile = library.profiles.first(where: { $0.id == profileID }) else {
            message = "Save or cancel the layout draft before exporting Android edits."; return nil
        }
        guard profile.androidSources.count == 1, let source = profile.androidSources.first,
              let reference = library.androidSources.first(where: { $0.id == source.archiveID }) else {
            message = "An edited Android copy needs one original source. Profiles built on iPhone or assembled from multiple Android originals can be saved with Export all profiles."; return nil
        }
        let directory = androidArchiveStore.directory
        do {
            let preview = try await Task.detached(priority: .userInitiated) {
                let archived = try AndroidProfileArchiveStore(directory: directory).load(reference)
                let original = try AndroidProfileDocument.parse(archived.originalData)
                return AndroidEditedExportPreview.prepare(profile: profile, original: original, source: source)
            }.value
            guard !Task.isCancelled, library.profiles.first(where: { $0.id == profileID }) == profile else {
                message = "The profile changed while the export was being prepared. Open its export preview again."; return nil
            }
            return .init(profileName: profile.name, preview: preview)
        } catch {
            message = "The Android export could not be prepared. \(error.localizedDescription)"; return nil
        }
    }

    /// File picker completion and I/O errors share the profile screen's visible status.
    func reportBackupMessage(_ text: String) { message = text }

#if DEBUG
    /// One explicitly requested, independently checked profile update. Both the
    /// original saved bytes and the exact approved package are pinned below.
    /// Ordinary launches, imports, and the older maintenance routes do not use it.
    func applyRequestedApprovedGTA6LiveStickUpdate(arguments: [String] = ProcessInfo.processInfo.arguments,
                                            documentsDirectory: URL? = nil) {
        guard !didProcessApprovedGTA6LiveStickUpdateLaunch else { return }
        didProcessApprovedGTA6LiveStickUpdateLaunch = true
        let indexes = arguments.indices.filter { arguments[$0] == DebugApprovedGTA6LiveStickUpdate.argument }
        guard !indexes.isEmpty else { return }
        let documents = documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent(DebugApprovedGTA6LiveStickUpdate.receiptName)
        var receipt: [String: Any]
        do {
            guard indexes.count == 1, let index = indexes.first, index + 1 < arguments.count,
                  !arguments.contains(DebugButtonSwipeUpdate.argument),
                  !arguments.contains(where: { $0.hasPrefix("--apply-") && $0 != DebugApprovedGTA6LiveStickUpdate.argument }),
                  DebugApprovedGTA6LiveStickUpdate.validBasename(arguments[index + 1]) else {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_launch_argument")
            }
            try DebugApprovedGTA6LiveStickUpdate.validateReceiptLocation(destination)
            let file = documents.appendingPathComponent(arguments[index + 1], isDirectory: false)
            let data = try DebugApprovedGTA6LiveStickUpdate.readPackage(file, documents: documents)
            receipt = applyApprovedGTA6LiveStickUpdate(data)
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            receipt = ["status": "rejected", "reason": rejection.code]
        } catch {
            receipt = ["status": "rejected", "reason": "file_unreadable"]
        }
        receipt["version"] = 1
        do {
            try DebugApprovedGTA6LiveStickUpdate.validateReceiptLocation(destination)
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                .write(to: destination, options: .atomic)
        } catch {
            message = "The GTA stick, aiming and auto-drive update receipt could not be saved. Check the saved profiles before retrying."
        }
    }

    @discardableResult
    func applyApprovedGTA6LiveStickUpdate(_ data: Data) -> [String: Any] {
        guard canEditLayout, !isEditingLayout, persistSettings,
              let raw = try? currentLibraryData() else {
            return ["status": "rejected", "reason": "profile_library_unavailable"]
        }
        do {
            let plan = try DebugApprovedGTA6LiveStickUpdate.prepare(data, currentRaw: raw)
            guard try ControllerProfileLibraryCodec.decode(raw) == library else {
                throw DebugProfileLayoutUpdate.Rejection(code: "model_library_changed")
            }
            let backupKey = "controller.profiles.recovery.\(UUID().uuidString)"
            try saveRecoveryData(raw, key: backupKey)
            guard saveLibrary(plan.candidate, selectedPageID: currentPageID) else {
                return ["status": "rejected", "reason": "save_failed", "backupCreated": true]
            }
            guard let saved = try currentLibraryData(),
                  DebugProfileLayoutUpdate.digest(saved) == plan.encodedSHA256 else {
                return ["status": "verification_failed", "reason": "saved_library_mismatch", "backupKey": backupKey]
            }
            message = "Updated the approved GTA stick, aiming and auto-drive controls. Your earlier library is kept in Recovery documents."
            return ["status": "applied", "profiles": plan.candidate.profiles.count,
                    "controls": plan.candidate.profiles.reduce(0) { $0 + $1.controls.count },
                    "backupKey": backupKey, "librarySHA256": plan.encodedSHA256,
                    "libraryBytes": saved.count, "packageSHA256": DebugApprovedGTA6LiveStickUpdate.approvedPackageSHA256]
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            message = "The GTA stick, aiming and auto-drive update did not match the approved saved profiles. Nothing was changed."
            return ["status": "rejected", "reason": rejection.code]
        } catch {
            message = "The GTA stick, aiming and auto-drive update could not be validated. Nothing was changed."
            return ["status": "rejected", "reason": "invalid_approved_update"]
        }
    }

    func applyRequestedApprovedGTA6DrivingUpdate(arguments: [String] = ProcessInfo.processInfo.arguments,
                                            documentsDirectory: URL? = nil) {
        guard !didProcessApprovedGTA6DrivingUpdateLaunch else { return }
        didProcessApprovedGTA6DrivingUpdateLaunch = true
        let indexes = arguments.indices.filter { arguments[$0] == DebugApprovedGTA6DrivingUpdate.argument }
        guard !indexes.isEmpty else { return }
        let documents = documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent(DebugApprovedGTA6DrivingUpdate.receiptName)
        var receipt: [String: Any]
        do {
            guard indexes.count == 1, let index = indexes.first, index + 1 < arguments.count,
                  !arguments.contains(DebugButtonSwipeUpdate.argument),
                  !arguments.contains(where: { $0.hasPrefix("--apply-") && $0 != DebugApprovedGTA6DrivingUpdate.argument }),
                  DebugApprovedGTA6DrivingUpdate.validBasename(arguments[index + 1]) else {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_launch_argument")
            }
            try DebugApprovedGTA6DrivingUpdate.validateReceiptLocation(destination)
            let file = documents.appendingPathComponent(arguments[index + 1], isDirectory: false)
            let data = try DebugApprovedGTA6DrivingUpdate.readPackage(file, documents: documents)
            receipt = applyApprovedGTA6DrivingUpdate(data)
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            receipt = ["status": "rejected", "reason": rejection.code]
        } catch {
            receipt = ["status": "rejected", "reason": "file_unreadable"]
        }
        receipt["version"] = 1
        do {
            try DebugApprovedGTA6DrivingUpdate.validateReceiptLocation(destination)
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                .write(to: destination, options: .atomic)
        } catch {
            message = "The GTA driving and button update receipt could not be saved. Check the saved profiles before retrying."
        }
    }

    @discardableResult
    func applyApprovedGTA6DrivingUpdate(_ data: Data) -> [String: Any] {
        guard canEditLayout, !isEditingLayout, persistSettings,
              let raw = try? currentLibraryData() else {
            return ["status": "rejected", "reason": "profile_library_unavailable"]
        }
        do {
            let plan = try DebugApprovedGTA6DrivingUpdate.prepare(data, currentRaw: raw)
            guard try ControllerProfileLibraryCodec.decode(raw) == library else {
                throw DebugProfileLayoutUpdate.Rejection(code: "model_library_changed")
            }
            let backupKey = "controller.profiles.recovery.\(UUID().uuidString)"
            try saveRecoveryData(raw, key: backupKey)
            guard saveLibrary(plan.candidate, selectedPageID: currentPageID) else {
                return ["status": "rejected", "reason": "save_failed", "backupCreated": true]
            }
            guard let saved = try currentLibraryData(),
                  DebugProfileLayoutUpdate.digest(saved) == plan.encodedSHA256 else {
                return ["status": "verification_failed", "reason": "saved_library_mismatch", "backupKey": backupKey]
            }
            message = "Updated the approved GTA driving and button controls. Your earlier library is kept in Recovery documents."
            return ["status": "applied", "profiles": plan.candidate.profiles.count,
                    "controls": plan.candidate.profiles.reduce(0) { $0 + $1.controls.count },
                    "backupKey": backupKey, "librarySHA256": plan.encodedSHA256,
                    "libraryBytes": saved.count, "packageSHA256": DebugApprovedGTA6DrivingUpdate.approvedPackageSHA256]
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            message = "The GTA driving and button update did not match the approved saved profiles. Nothing was changed."
            return ["status": "rejected", "reason": rejection.code]
        } catch {
            message = "The GTA driving and button update could not be validated. Nothing was changed."
            return ["status": "rejected", "reason": "invalid_approved_update"]
        }
    }

    /// One explicitly requested, independently checked profile update. Both the
    /// original saved bytes and the exact approved package are pinned below.
    /// Ordinary launches, imports, and the older maintenance routes do not use it.
    func applyRequestedApprovedGTA6WalkUpdate(arguments: [String] = ProcessInfo.processInfo.arguments,
                                            documentsDirectory: URL? = nil) {
        guard !didProcessApprovedGTA6WalkUpdateLaunch else { return }
        didProcessApprovedGTA6WalkUpdateLaunch = true
        let indexes = arguments.indices.filter { arguments[$0] == DebugApprovedGTA6WalkUpdate.argument }
        guard !indexes.isEmpty else { return }
        let documents = documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent(DebugApprovedGTA6WalkUpdate.receiptName)
        var receipt: [String: Any]
        do {
            guard indexes.count == 1, let index = indexes.first, index + 1 < arguments.count,
                  !arguments.contains(DebugButtonSwipeUpdate.argument),
                  !arguments.contains(where: { $0.hasPrefix("--apply-") && $0 != DebugApprovedGTA6WalkUpdate.argument }),
                  DebugApprovedGTA6WalkUpdate.validBasename(arguments[index + 1]) else {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_launch_argument")
            }
            try DebugApprovedGTA6WalkUpdate.validateReceiptLocation(destination)
            let file = documents.appendingPathComponent(arguments[index + 1], isDirectory: false)
            let data = try DebugApprovedGTA6WalkUpdate.readPackage(file, documents: documents)
            receipt = applyApprovedGTA6WalkUpdate(data)
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            receipt = ["status": "rejected", "reason": rejection.code]
        } catch {
            receipt = ["status": "rejected", "reason": "file_unreadable"]
        }
        receipt["version"] = 1
        do {
            try DebugApprovedGTA6WalkUpdate.validateReceiptLocation(destination)
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                .write(to: destination, options: .atomic)
        } catch {
            message = "The GTA Walk update receipt could not be saved. Check the saved profiles before retrying."
        }
    }

    @discardableResult
    func applyApprovedGTA6WalkUpdate(_ data: Data) -> [String: Any] {
        guard canEditLayout, !isEditingLayout, persistSettings,
              let raw = try? currentLibraryData() else {
            return ["status": "rejected", "reason": "profile_library_unavailable"]
        }
        do {
            let plan = try DebugApprovedGTA6WalkUpdate.prepare(data, currentRaw: raw)
            guard try ControllerProfileLibraryCodec.decode(raw) == library else {
                throw DebugProfileLayoutUpdate.Rejection(code: "model_library_changed")
            }
            let backupKey = "controller.profiles.recovery.\(UUID().uuidString)"
            try saveRecoveryData(raw, key: backupKey)
            guard saveLibrary(plan.candidate, selectedPageID: currentPageID) else {
                return ["status": "rejected", "reason": "save_failed", "backupCreated": true]
            }
            guard let saved = try currentLibraryData(),
                  DebugProfileLayoutUpdate.digest(saved) == plan.encodedSHA256 else {
                return ["status": "verification_failed", "reason": "saved_library_mismatch", "backupKey": backupKey]
            }
            message = "Updated the approved GTA Walk controls. Your earlier library is kept in Recovery documents."
            return ["status": "applied", "profiles": plan.candidate.profiles.count,
                    "controls": plan.candidate.profiles.reduce(0) { $0 + $1.controls.count },
                    "backupKey": backupKey, "librarySHA256": plan.encodedSHA256,
                    "libraryBytes": saved.count, "packageSHA256": DebugApprovedGTA6WalkUpdate.approvedPackageSHA256]
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            message = "The GTA Walk update did not match the approved saved profiles. Nothing was changed."
            return ["status": "rejected", "reason": rejection.code]
        } catch {
            message = "The GTA Walk update could not be validated. Nothing was changed."
            return ["status": "rejected", "reason": "invalid_approved_update"]
        }
    }

    /// Enable the existing button-entry switch only when explicitly requested.
    /// A hash of the complete saved library fences this one-time maintenance action.
    func applyRequestedButtonSwipeUpdate(arguments: [String] = ProcessInfo.processInfo.arguments,
                                         documentsDirectory: URL? = nil) {
        guard !didProcessButtonSwipeUpdateLaunch else { return }
        didProcessButtonSwipeUpdateLaunch = true
        let indexes = arguments.indices.filter { arguments[$0] == DebugButtonSwipeUpdate.argument }
        guard !indexes.isEmpty else { return }
        let documents = documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent(DebugButtonSwipeUpdate.receiptName)
        var receipt: [String: Any]
        do {
            guard indexes.count == 1, let index = indexes.first, index + 1 < arguments.count,
                  !arguments.contains("--apply-profile-update"),
                  DebugButtonSwipeUpdate.validHash(arguments[index + 1]) else {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_launch_argument")
            }
            if FileManager.default.fileExists(atPath: destination.path),
               (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_receipt_location")
            }
            receipt = applyDebugButtonSwipeUpdate(expectedCurrentLibrarySHA256: arguments[index + 1])
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            receipt = ["status": "rejected", "reason": rejection.code]
        } catch {
            receipt = ["status": "rejected", "reason": "invalid_receipt_location"]
        }
        receipt["version"] = 1
        do {
            if FileManager.default.fileExists(atPath: destination.path),
               (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_receipt_location")
            }
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]).write(to: destination, options: .atomic)
        } catch {
            message = "The button sliding receipt could not be saved. Check the saved profiles before retrying."
        }
    }

    @discardableResult
    func applyDebugButtonSwipeUpdate(expectedCurrentLibrarySHA256 expected: String) -> [String: Any] {
        guard canEditLayout, !isEditingLayout, persistSettings,
              let raw = try? currentLibraryData() else {
            return ["status": "rejected", "reason": "profile_library_unavailable"]
        }
        do {
            let plan = try DebugButtonSwipeUpdate.prepare(expectedCurrentLibrarySHA256: expected, currentRaw: raw)
            guard try ControllerProfileLibraryCodec.decode(raw) == library else {
                throw DebugProfileLayoutUpdate.Rejection(code: "model_library_changed")
            }
            var receipt: [String: Any] = ["status": "unchanged", "profiles": plan.candidate.profiles.count,
                "buttonsEnabled": plan.buttonsEnabled, "profileModesEnabled": plan.profileModesEnabled,
                "librarySHA256": DebugProfileLayoutUpdate.digest(raw)]
            guard plan.buttonsEnabled > 0 || plan.profileModesEnabled > 0 else { return receipt }
            let backupKey = "controller.profiles.recovery.\(UUID().uuidString)"
            try saveRecoveryData(raw, key: backupKey)
            guard saveLibrary(plan.candidate) else {
                return ["status": "rejected", "reason": "save_failed", "backupCreated": true]
            }
            message = "Button sliding is enabled in every profile. Positions and other settings are unchanged."
            receipt["status"] = "applied"
            receipt["backupKey"] = backupKey
            receipt["librarySHA256"] = DebugProfileLayoutUpdate.digest(try currentLibraryData()!)
            return receipt
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            message = "The button sliding update did not match the saved profiles. Nothing was changed."
            return ["status": "rejected", "reason": rejection.code]
        } catch {
            message = "The button sliding update could not be validated. Nothing was changed."
            return ["status": "rejected", "reason": "invalid_swipe_update"]
        }
    }

    /// No update runs on an ordinary launch. The maintenance request must be explicit,
    /// names one direct Documents child, and executes at most once in this model.
    func applyRequestedProfileUpdate(arguments: [String] = ProcessInfo.processInfo.arguments,
                                     documentsDirectory: URL? = nil) {
        guard !didProcessProfileUpdateLaunch else { return }
        didProcessProfileUpdateLaunch = true
        let indexes = arguments.indices.filter { arguments[$0] == "--apply-profile-update" }
        guard !indexes.isEmpty else { return }
        let documents = documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var receipt: [String: Any]
        do {
            guard indexes.count == 1, let index = indexes.first, index + 1 < arguments.count,
                  DebugProfileLayoutUpdate.validBasename(arguments[index + 1]) else {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_launch_argument")
            }
            let file = documents.appendingPathComponent(arguments[index + 1], isDirectory: false)
            let data = try DebugProfileLayoutUpdate.readPackage(file, documents: documents)
            receipt = applyDebugProfileUpdate(data)
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            receipt = ["status": "rejected", "reason": rejection.code]
        } catch {
            receipt = ["status": "rejected", "reason": "file_unreadable"]
        }
        receipt["version"] = 1
        let destination = documents.appendingPathComponent(DebugProfileLayoutUpdate.receiptName)
        do {
            // Do not follow a planted symlink, even for the non-sensitive receipt.
            if FileManager.default.fileExists(atPath: destination.path),
               (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_receipt_location")
            }
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]).write(to: destination, options: .atomic)
        } catch {
            message = "The layout update receipt could not be saved. Check the saved profiles before retrying."
        }
    }

    /// All profile writes occur inside the app via its existing model save path.
    @discardableResult
    func applyDebugProfileUpdate(_ data: Data) -> [String: Any] {
        guard canEditLayout, !isEditingLayout, persistSettings,
              let raw = try? currentLibraryData() else {
            return ["status": "rejected", "reason": "profile_library_unavailable"]
        }
        do {
            let plan = try DebugProfileLayoutUpdate.prepare(data, currentRaw: raw)
            // Fence the in-memory model too; a different current library must never
            // be overwritten merely because a preference snapshot happened to match.
            guard try ControllerProfileLibraryCodec.decode(raw) == library else {
                throw DebugProfileLayoutUpdate.Rejection(code: "model_library_changed")
            }
            let backupKey = "controller.profiles.recovery.\(UUID().uuidString)"
            try saveRecoveryData(raw, key: backupKey)
            guard saveLibrary(plan.candidate) else {
                return ["status": "rejected", "reason": "save_failed", "backupCreated": true]
            }
            message = "Updated your controller layouts. Protected profiles are unchanged, and the previous library is kept in Recovery documents."
            return ["status": "applied", "profilesBefore": plan.beforeCount,
                    "profilesAfter": plan.candidate.profiles.count, "protectedProfiles": plan.protectedCount,
                    "backupKey": backupKey, "librarySHA256": DebugProfileLayoutUpdate.digest(try currentLibraryData()!)]
        } catch let rejection as DebugProfileLayoutUpdate.Rejection {
            message = "The layout update did not match the saved profiles. Nothing was changed."
            return ["status": "rejected", "reason": rejection.code]
        } catch {
            message = "The layout update was invalid. Nothing was changed."
            return ["status": "rejected", "reason": "invalid_layout_update"]
        }
    }
#endif

    /// Preset edits are an explicit library save and never replace the in-progress control/profile draft.
    @discardableResult
    func saveSettingsPresets(_ presets: SettingsPresetLibrary) -> Bool {
        guard canEditLayout else { message = "Recover the saved profiles before changing presets."; return false }
        do {
            var candidate = library; candidate.settingsPresets = presets
            let data = try ControllerProfileLibraryCodec.encode(candidate)
            try persistLibraryData(data)
            library = candidate
            message = "Saved reusable settings. Your controller draft is unchanged."
            return true
        } catch {
            message = "The preset library could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    /// File storage is authoritative once created; legacy defaults remain an exact
    /// recovery source and are never used to hide a corrupt or unreadable file.
    func currentLibraryData() throws -> Data? {
        if let data = try nativeProfileStore?.loadLibrary() { return data }
        return defaults.data(forKey: Self.libraryKey)
    }
    private func recoveryData(for key: String) throws -> Data? {
        if key == "controller.profiles.recovery.legacy-preferences", nativeProfileStore != nil {
            return defaults.data(forKey: Self.libraryKey)
        }
        if let bytes = try nativeProfileStore?.recoveryData(for: key) { return bytes }
        return defaults.data(forKey: key)
    }
    private func saveRecoveryData(_ data: Data, key: String) throws {
        guard persistSettings else { return }
        if let nativeProfileStore { try nativeProfileStore.saveRecovery(data, key: key) }
        else { defaults.set(data, forKey: key) }
    }
    private func persistLibraryData(_ data: Data) throws {
        guard persistSettings else { return }
        let previous = try currentLibraryData()
        let expansionRecoveryKey = "controller.profiles.recovery.before-storage-expansion"
        if data.count > ControllerProfileLibraryCodec.legacyMaximumBytes,
           let previous, previous.count <= ControllerProfileLibraryCodec.legacyMaximumBytes,
           try recoveryData(for: expansionRecoveryKey) == nil {
            try saveRecoveryData(previous, key: expansionRecoveryKey)
        }
        if let previous, let fields = (try? JSONSerialization.jsonObject(with: previous)) as? [String: Any],
           let version = fields["version"] as? Int, version < ControllerProfileLibrary.currentVersion {
            let recoveryKey = "controller.profiles.before-format-\(version)"
            if try recoveryData(for: recoveryKey) == nil { try saveRecoveryData(previous, key: recoveryKey) }
        }
        if let nativeProfileStore { try nativeProfileStore.saveLibrary(data, previousData: previous) }
        else { defaults.set(data, forKey: Self.libraryKey) }
    }

    private func copiedName(_ name: String) -> String { String(name.prefix(59)) + " copy" }
    private func saveLibrary(_ candidate: ControllerProfileLibrary, selectedPageID: UUID? = nil) -> Bool {
        do {
            let data = try ControllerProfileLibraryCodec.encode(candidate)
            var preparedEngine = engine
            try preparedEngine.apply(profile: candidate.activeProfile)
            if let page = selectedPageID, candidate.activeProfile.page(for: page) != nil {
                _ = try preparedEngine.selectPage(page, at: clock())
            }
            // Commit and independently read back the file before publishing the new model.
            // A failed write leaves the draft, old model, and current engine untouched.
            try persistLibraryData(data)
            pauseConnection()
            engine = preparedEngine
            currentPageID = engine.currentPageID
            publishAutoCenterState()
            clearPracticeHistory()
            library = candidate
            message = nil
            return true
        } catch ControllerProfileError.oversizedData {
            message = "Your profile library has reached its 16 MiB storage limit. Your saved profiles and current edits are unchanged."
            return false
        } catch {
            message = "Changes could not be saved. Check names, control sizes and actions. Your saved profiles are unchanged."
            return false
        }
    }
}

#if DEBUG
/// This is not a general replacement importer: one exact package and one exact
/// pre-update library are allowed. Pins belong only to this authorized update.
enum DebugApprovedGTA6LiveStickUpdate {
    static let argument = "--apply-gta6-live-stick-update"
    static let receiptName = "GTA6-Live-stick-update-receipt.json"
    static let approvedBeforeSHA256 = "c7657fe2ba529fa68c99c72f4ca7184a090cc2267577d7339fc131ab22d1d5f0"
    static let approvedPackageSHA256 = "9c1c6cda4af984d5681fa679666c62f6238b22d85b1d4ac6a35aeb8a87b8851f"
    static let approvedCandidateMetadataSHA256 = "a0340fdb187aac8c135fd47d0586a197dc5c4d1917faceef62fe315ac76a7b5f"
    static let maximumBytes = ControllerProfileLibraryCodec.maximumBytes
    struct Plan {
        let candidate: ControllerProfileLibrary
        let encodedSHA256: String
    }
    private struct LibraryEnvelope: Decodable {
        let library: ControllerProfileLibrary
    }
    static func validBasename(_ name: String) -> Bool {
        name != receiptName && DebugProfileLayoutUpdate.validBasename(name)
    }
    static func validateReceiptLocation(_ url: URL) throws {
        // resourceValues also detects a dangling symlink, unlike fileExists.
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_receipt_location")
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            throw DebugProfileLayoutUpdate.Rejection(code: "invalid_receipt_location")
        }
    }
    static func readPackage(_ url: URL, documents: URL) throws -> Data {
        guard validBasename(url.lastPathComponent) else {
            throw DebugProfileLayoutUpdate.Rejection(code: "invalid_file_location")
        }
        return try DebugProfileLayoutUpdate.readPackage(url, documents: documents)
    }
    static func prepare(_ data: Data, currentRaw: Data) throws -> Plan {
        guard data.count <= maximumBytes, currentRaw.count <= maximumBytes else {
            throw DebugProfileLayoutUpdate.Rejection(code: "file_too_large")
        }
        guard DebugProfileLayoutUpdate.digest(data) == approvedPackageSHA256 else {
            throw DebugProfileLayoutUpdate.Rejection(code: "unapproved_package")
        }
        guard DebugProfileLayoutUpdate.digest(currentRaw) == approvedBeforeSHA256 else {
            throw DebugProfileLayoutUpdate.Rejection(code: "stale_saved_library")
        }
        _ = try ControllerProfileLibraryCodec.decode(currentRaw)
        guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(package.keys) == Set(["fileType", "version", "expectedCurrentLibrarySHA256", "candidateSHA256", "library"]),
              package["fileType"] as? String == "simplecontroller-approved-controls-update",
              package["version"] as? Int == 1,
              package["expectedCurrentLibrarySHA256"] as? String == approvedBeforeSHA256,
              package["candidateSHA256"] as? String == approvedCandidateMetadataSHA256,
              let library = package["library"] as? [String: Any] else {
            throw DebugProfileLayoutUpdate.Rejection(code: "invalid_package")
        }
        // The package hash authenticates the authored candidate. JSON number and
        // slash serialization may differ between tools; record the native codec's
        // byte hash separately instead of comparing unlike JSON encodings.
        // Decode the nested model from the already bounded package directly.
        // JSONSerialization can expand decimal spellings beyond the storage
        // limit even when the native codec's actual saved bytes fit unchanged.
        let candidate = try JSONDecoder().decode(LibraryEnvelope.self, from: data).library
        let encoded = try ControllerProfileLibraryCodec.encode(candidate)
        guard try ControllerProfileLibraryCodec.decode(encoded) == candidate else {
            throw DebugProfileLayoutUpdate.Rejection(code: "candidate_round_trip_changed")
        }
        guard try DebugProfileLayoutUpdate.same(library, JSONSerialization.jsonObject(with: encoded)) else {
            throw DebugProfileLayoutUpdate.Rejection(code: "candidate_normalization_changed")
        }
        return Plan(candidate: candidate, encodedSHA256: DebugProfileLayoutUpdate.digest(encoded))
    }
}

enum DebugApprovedGTA6DrivingUpdate {
    static let argument = "--apply-gta6-driving-update"
    static let receiptName = "GTA6-Driving-update-receipt.json"
    static let approvedBeforeSHA256 = "78eaba1f9dcbd587ad0074959be8f0f2b59c57217baf2fb2afd2b601492e6691"
    static let approvedPackageSHA256 = "0868d22788d409514bac1a7a41448baddd12f3239d77d9049c28b63d9d47169a"
    static let approvedCandidateMetadataSHA256 = "b033af8ca70f2851d2281def8645b68d6dd5c8fa265f57c5ecb8bca689da2457"
    static let maximumBytes = ControllerProfileLibraryCodec.maximumBytes
    struct Plan {
        let candidate: ControllerProfileLibrary
        let encodedSHA256: String
    }
    private struct LibraryEnvelope: Decodable {
        let library: ControllerProfileLibrary
    }
    static func validBasename(_ name: String) -> Bool {
        name != receiptName && DebugProfileLayoutUpdate.validBasename(name)
    }
    static func validateReceiptLocation(_ url: URL) throws {
        // resourceValues also detects a dangling symlink, unlike fileExists.
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_receipt_location")
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            throw DebugProfileLayoutUpdate.Rejection(code: "invalid_receipt_location")
        }
    }
    static func readPackage(_ url: URL, documents: URL) throws -> Data {
        guard validBasename(url.lastPathComponent) else {
            throw DebugProfileLayoutUpdate.Rejection(code: "invalid_file_location")
        }
        return try DebugProfileLayoutUpdate.readPackage(url, documents: documents)
    }
    static func prepare(_ data: Data, currentRaw: Data) throws -> Plan {
        guard data.count <= maximumBytes, currentRaw.count <= maximumBytes else {
            throw DebugProfileLayoutUpdate.Rejection(code: "file_too_large")
        }
        guard DebugProfileLayoutUpdate.digest(data) == approvedPackageSHA256 else {
            throw DebugProfileLayoutUpdate.Rejection(code: "unapproved_package")
        }
        guard DebugProfileLayoutUpdate.digest(currentRaw) == approvedBeforeSHA256 else {
            throw DebugProfileLayoutUpdate.Rejection(code: "stale_saved_library")
        }
        _ = try ControllerProfileLibraryCodec.decode(currentRaw)
        guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(package.keys) == Set(["fileType", "version", "expectedCurrentLibrarySHA256", "candidateSHA256", "library"]),
              package["fileType"] as? String == "simplecontroller-approved-controls-update",
              package["version"] as? Int == 1,
              package["expectedCurrentLibrarySHA256"] as? String == approvedBeforeSHA256,
              package["candidateSHA256"] as? String == approvedCandidateMetadataSHA256,
              let library = package["library"] as? [String: Any] else {
            throw DebugProfileLayoutUpdate.Rejection(code: "invalid_package")
        }
        // The package hash authenticates the authored candidate. JSON number and
        // slash serialization may differ between tools; record the native codec's
        // byte hash separately instead of comparing unlike JSON encodings.
        // Decode the nested model from the already bounded package directly.
        // JSONSerialization can expand decimal spellings beyond the storage
        // limit even when the native codec's actual saved bytes fit unchanged.
        let candidate = try JSONDecoder().decode(LibraryEnvelope.self, from: data).library
        let encoded = try ControllerProfileLibraryCodec.encode(candidate)
        guard try ControllerProfileLibraryCodec.decode(encoded) == candidate else {
            throw DebugProfileLayoutUpdate.Rejection(code: "candidate_round_trip_changed")
        }
        guard try DebugProfileLayoutUpdate.same(library, JSONSerialization.jsonObject(with: encoded)) else {
            throw DebugProfileLayoutUpdate.Rejection(code: "candidate_normalization_changed")
        }
        return Plan(candidate: candidate, encodedSHA256: DebugProfileLayoutUpdate.digest(encoded))
    }
}

enum DebugApprovedGTA6WalkUpdate {
    static let argument = "--apply-gta6-walk-update"
    static let receiptName = "GTA6-Walk-update-receipt.json"
    static let approvedBeforeSHA256 = "4a5f6c194b918aaae409defe6c3ae71bf4116b1220d8fab2a247c0cad4813769"
    static let approvedPackageSHA256 = "d05f470f5032e1871b1856266479d0af90428c5a7e765612d0d96e712dff69cd"
    static let approvedCandidateMetadataSHA256 = "dc86c6dcc81c7548aa5c95a865f4a70e73f1d417377285f8ab3072e516087cbf"
    static let maximumBytes = ControllerProfileLibraryCodec.maximumBytes
    struct Plan {
        let candidate: ControllerProfileLibrary
        let encodedSHA256: String
    }
    private struct LibraryEnvelope: Decodable {
        let library: ControllerProfileLibrary
    }
    static func validBasename(_ name: String) -> Bool {
        name != receiptName && DebugProfileLayoutUpdate.validBasename(name)
    }
    static func validateReceiptLocation(_ url: URL) throws {
        // resourceValues also detects a dangling symlink, unlike fileExists.
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DebugProfileLayoutUpdate.Rejection(code: "invalid_receipt_location")
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            throw DebugProfileLayoutUpdate.Rejection(code: "invalid_receipt_location")
        }
    }
    static func readPackage(_ url: URL, documents: URL) throws -> Data {
        guard validBasename(url.lastPathComponent) else {
            throw DebugProfileLayoutUpdate.Rejection(code: "invalid_file_location")
        }
        return try DebugProfileLayoutUpdate.readPackage(url, documents: documents)
    }
    static func prepare(_ data: Data, currentRaw: Data) throws -> Plan {
        guard data.count <= maximumBytes, currentRaw.count <= maximumBytes else {
            throw DebugProfileLayoutUpdate.Rejection(code: "file_too_large")
        }
        guard DebugProfileLayoutUpdate.digest(data) == approvedPackageSHA256 else {
            throw DebugProfileLayoutUpdate.Rejection(code: "unapproved_package")
        }
        guard DebugProfileLayoutUpdate.digest(currentRaw) == approvedBeforeSHA256 else {
            throw DebugProfileLayoutUpdate.Rejection(code: "stale_saved_library")
        }
        _ = try ControllerProfileLibraryCodec.decode(currentRaw)
        guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(package.keys) == Set(["fileType", "version", "expectedCurrentLibrarySHA256", "candidateSHA256", "library"]),
              package["fileType"] as? String == "simplecontroller-approved-controls-update",
              package["version"] as? Int == 1,
              package["expectedCurrentLibrarySHA256"] as? String == approvedBeforeSHA256,
              package["candidateSHA256"] as? String == approvedCandidateMetadataSHA256,
              let library = package["library"] as? [String: Any] else {
            throw DebugProfileLayoutUpdate.Rejection(code: "invalid_package")
        }
        // The package hash authenticates the authored candidate. JSON number and
        // slash serialization may differ between tools; record the native codec's
        // byte hash separately instead of comparing unlike JSON encodings.
        // Decode the nested model from the already bounded package directly.
        // JSONSerialization can expand decimal spellings beyond the storage
        // limit even when the native codec's actual saved bytes fit unchanged.
        let candidate = try JSONDecoder().decode(LibraryEnvelope.self, from: data).library
        let encoded = try ControllerProfileLibraryCodec.encode(candidate)
        guard try ControllerProfileLibraryCodec.decode(encoded) == candidate else {
            throw DebugProfileLayoutUpdate.Rejection(code: "candidate_round_trip_changed")
        }
        guard try DebugProfileLayoutUpdate.same(library, JSONSerialization.jsonObject(with: encoded)) else {
            throw DebugProfileLayoutUpdate.Rejection(code: "candidate_normalization_changed")
        }
        return Plan(candidate: candidate, encodedSHA256: DebugProfileLayoutUpdate.digest(encoded))
    }
}

/// Builds an exact setting-only update from the current library, without accepting
/// a replacement layout or touching floating group/finish rules or runtime policy.
enum DebugButtonSwipeUpdate {
    static let argument = "--enable-button-swipes"
    static let receiptName = "Button-swipe-update-receipt.json"
    struct Plan {
        let candidate: ControllerProfileLibrary
        let buttonsEnabled: Int
        let profileModesEnabled: Int
    }
    static func validHash(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
    static func prepare(expectedCurrentLibrarySHA256 expected: String, currentRaw: Data) throws -> Plan {
        guard validHash(expected) else { try DebugProfileLayoutUpdate.reject("invalid_expected_hash") }
        guard currentRaw.count <= DebugProfileLayoutUpdate.maximumBytes else { try DebugProfileLayoutUpdate.reject("file_too_large") }
        guard expected == DebugProfileLayoutUpdate.digest(currentRaw) else { try DebugProfileLayoutUpdate.reject("stale_saved_library") }
        // Validate the original before looking at its raw fields. Retain every other
        // JSON value, including exact geometry, pages, source copies and presets.
        _ = try ControllerProfileLibraryCodec.decode(currentRaw)
        guard var object = try JSONSerialization.jsonObject(with: currentRaw) as? [String: Any],
              var profiles = object["profiles"] as? [[String: Any]] else {
            try DebugProfileLayoutUpdate.reject("invalid_saved_library")
        }
        var buttonsEnabled = 0, profileModesEnabled = 0
        for profileIndex in profiles.indices {
            if profiles[profileIndex]["swipeMode"] as? String == "off" {
                profiles[profileIndex]["swipeMode"] = "buttons"
                profileModesEnabled += 1
            }
            guard var controls = profiles[profileIndex]["controls"] as? [[String: Any]] else {
                try DebugProfileLayoutUpdate.reject("invalid_saved_library")
            }
            for controlIndex in controls.indices where controls[controlIndex]["kind"] as? String == "button" {
                if controls[controlIndex]["swipeActivationEnabled"] as? Bool != true {
                    controls[controlIndex]["swipeActivationEnabled"] = true
                    buttonsEnabled += 1
                }
            }
            profiles[profileIndex]["controls"] = controls
        }
        object["profiles"] = profiles
        let candidate = try ControllerProfileLibraryCodec.decode(DebugProfileLayoutUpdate.canonical(object))
        let encoded = try ControllerProfileLibraryCodec.encode(candidate)
        guard try DebugProfileLayoutUpdate.same(object, JSONSerialization.jsonObject(with: encoded)) else {
            try DebugProfileLayoutUpdate.reject("unrelated_profile_data_changed")
        }
        return .init(candidate: candidate, buttonsEnabled: buttonsEnabled, profileModesEnabled: profileModesEnabled)
    }
}

/// Private maintenance package. It is accepted only by the explicit DEBUG launch action.
/// Ordinary profile imports retain their additive-copy behavior.
enum DebugProfileLayoutUpdate {
    static let maximumBytes = ControllerProfileLibraryCodec.maximumBytes
    static let receiptName = "Profile-update-receipt.json"
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    struct Rejection: Error { let code: String }
    struct Plan {
        let candidate: ControllerProfileLibrary
        let protectedCount: Int
        let beforeCount: Int
    }
    static func reject(_ code: String) throws -> Never { throw Rejection(code: code) }
    static func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
    static func same(_ lhs: Any, _ rhs: Any) throws -> Bool { try canonical(lhs) == canonical(rhs) }
    static func objects(_ raw: Any?) throws -> [[String: Any]] {
        guard let result = raw as? [[String: Any]] else { try reject("invalid_structure") }
        return result
    }
    static func byID(_ objects: [[String: Any]]) throws -> [UUID: [String: Any]] {
        var result: [UUID: [String: Any]] = [:]
        for object in objects {
            guard let text = object["id"] as? String, let id = UUID(uuidString: text), result[id] == nil else {
                try reject("invalid_identifiers")
            }
            result[id] = object
        }
        return result
    }
    static func without(_ object: [String: Any], _ keys: Set<String>) -> [String: Any] {
        object.filter { !keys.contains($0.key) }
    }
    static func isAutomaticallyProtected(_ name: String) -> Bool {
        let compact = name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return compact.contains("gta") || compact.contains("touchpadtest") || compact.contains("featurecheck")
    }
    static func prepare(_ data: Data, currentRaw: Data) throws -> Plan {
        guard data.count <= maximumBytes, currentRaw.count <= maximumBytes else { try reject("file_too_large") }
        guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(package.keys) == Set(["fileType", "version", "expectedCurrentLibrarySHA256", "protectedProfileIDs", "library"]),
              package["fileType"] as? String == "simplecontroller-layout-update",
              let version = package["version"] as? Int, version == 1,
              let expected = package["expectedCurrentLibrarySHA256"] as? String,
              expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let protectedStrings = package["protectedProfileIDs"] as? [String],
              let newObject = package["library"] as? [String: Any] else { try reject("invalid_package") }
        guard expected == digest(currentRaw) else { try reject("stale_saved_library") }
        guard let oldObject = try JSONSerialization.jsonObject(with: currentRaw) as? [String: Any] else { try reject("invalid_saved_library") }
        _ = try ControllerProfileLibraryCodec.decode(currentRaw)
        let newBytes = try canonical(newObject)
        let candidate = try ControllerProfileLibraryCodec.decode(newBytes)
        let oldProfiles = try byID(objects(oldObject["profiles"]))
        let newProfiles = try byID(objects(newObject["profiles"]))
        guard oldProfiles.keys.allSatisfy({ newProfiles[$0] != nil }) else { try reject("profile_removed") }
        guard try same(without(oldObject, ["profiles"]), without(newObject, ["profiles"])) else {
            try reject("library_metadata_changed") // Includes active ID, originals, presets and format.
        }
        let explicit = protectedStrings.compactMap(UUID.init(uuidString:))
        guard explicit.count == protectedStrings.count, Set(explicit).count == explicit.count,
              explicit.allSatisfy({ oldProfiles[$0] != nil }) else { try reject("invalid_protected_ids") }
        var protected = Set(explicit)
        for (id, profile) in oldProfiles where isAutomaticallyProtected(profile["name"] as? String ?? "") { protected.insert(id) }
        let geometry: Set<String> = ["diameter", "controlWidth", "controlHeight", "orientationDimensions", "touchpadWidth", "touchpadHeight"]
        for (id, old) in oldProfiles {
            let new = newProfiles[id]!
            if protected.contains(id) {
                guard try same(old, new) else { try reject("protected_profile_changed") }
                continue
            }
            guard try same(without(old, ["controls", "portrait", "landscape", "pages", "homePageID"]),
                           without(new, ["controls", "portrait", "landscape", "pages", "homePageID"])) else { try reject("profile_settings_changed") }
            let oldControls = try byID(objects(old["controls"])), newControls = try byID(objects(new["controls"]))
            for (controlID, control) in oldControls {
                guard let replacement = newControls[controlID] else { try reject("control_removed") }
                var permitted = geometry
                if control["kind"] as? String == "pageButton",
                   control["name"] as? String == "Menus",
                   ["Controls", "All keys"].contains(replacement["name"] as? String ?? "") {
                    permitted.insert("name") // Explicit navigation-label clarification; target is unchanged.
                }
                guard try same(without(control, permitted), without(replacement, permitted)) else { try reject("control_behavior_changed") }
            }
            // Existing pages keep names and floating interactions; membership may move.
            let oldPages = try byID(objects(old["pages"])), newPages = try byID(objects(new["pages"]))
            for (pageID, page) in oldPages {
                guard let replacement = newPages[pageID] else { try reject("existing_page_changed") }
                var permitted: Set<String> = ["controlIDs"]
                if page["name"] as? String == "Menus", replacement["name"] as? String == "Controls" { permitted.insert("name") }
                guard try same(without(page, permitted), without(replacement, permitted)) else { try reject("existing_page_changed") }
            }
        }
        _ = try ControllerProfileLibraryCodec.encode(candidate)
        return Plan(candidate: candidate, protectedCount: protected.count, beforeCount: oldProfiles.count)
    }
    static func validBasename(_ name: String) -> Bool {
        name != receiptName && !name.contains("..") &&
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\\.json$", options: .regularExpression) != nil
    }
    static func readPackage(_ url: URL, documents: URL) throws -> Data {
        guard validBasename(url.lastPathComponent),
              url.deletingLastPathComponent().standardizedFileURL == documents.standardizedFileURL,
              url.resolvingSymlinksInPath().deletingLastPathComponent() == documents.resolvingSymlinksInPath() else {
            try reject("invalid_file_location")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { try reject("invalid_file") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, maximumBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { try reject("file_too_large") }
        return data
    }
}
#endif

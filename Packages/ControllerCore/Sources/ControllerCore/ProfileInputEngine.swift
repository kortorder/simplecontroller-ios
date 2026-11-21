import Foundation

public enum ProfileInputEvent: Equatable, Sendable {
    case beginFloatingRing(contact: Int, zoneID: UUID, sessionID: UUID, point: FloatingPoint, usable: FloatingRect)
    case moveFloatingRing(contact: Int, sessionID: UUID, samples: [FloatingRingSample])
    case endFloatingRing(contact: Int, sessionID: UUID, samples: [FloatingRingSample])
    case cancelFloatingRing(contact: Int, sessionID: UUID)
    case floatingRingAction(zoneID: UUID, sessionID: UUID, action: FloatingLocalAction)
    case handoffFloatingButton(contact: Int, zoneID: UUID, to: UUID)
    case registerFloatingButtonSession(zoneID: UUID, sessionID: UUID)
    case finishFloatingButtonSession(zoneID: UUID, sessionID: UUID)
    case releaseControls(Set<UUID>)
    case begin(contact: Int, control: UUID, position: StickPosition)
    case beginTouchAim(contact: Int, control: UUID, sample: TouchAimSample)
    case moveTouchAimBatch(contact: Int, samples: [TouchAimSample])
    case beginButton(contact: Int, control: UUID, sample: ButtonPointerSample)
    case moveButtonBatch(contact: Int, samples: [ButtonPointerSample])
    case endButton(contact: Int, finalSamples: [ButtonPointerSample])
    case beginStick(contact: Int, control: UUID, travel: StickTravel)
    case moveStick(contact: Int, travel: StickTravel)
    case handoffTravel(contact: Int, to: UUID, departingTravel: StickTravel?, arrivingTravel: StickTravel, finalPadDeltas: [PointerDelta])
    case beginTouchpad(contact: Int, control: UUID)
    case moveTouchpad(contact: Int, delta: PointerDelta)
    case moveTouchpadBatch(contact: Int, deltas: [PointerDelta])
    case endTouchpad(contact: Int, finalDeltas: [PointerDelta])
    case cancel(contact: Int)
    case move(contact: Int, position: StickPosition)
    case transfer(contact: Int, to: UUID?)
    case handoff(contact: Int, to: UUID, departingStickPosition: StickPosition?, arrivingStickPosition: StickPosition, finalPadDeltas: [PointerDelta])
    case end(contact: Int)
    case cancelAll
    case accessibilityActivate(UUID)
}

/// One logical activation per control instance; every timed claim belongs to its run.
/// Timing is derived from absolute phase, so a late tick never emits a catch-up burst.
public struct ProfileInputEngine: Sendable {
    private struct Contact: Sendable {
        var control: UUID?
        var travel: StickTravel = .zero
        var stickChannel: ControllerControlID?
        var ownsStick = false
        var holdDeadline: TimeInterval?
        var suppressToggle = false
        var tapBeganAt: TimeInterval?
        var repeatTapCandidate = false
    }
    private enum RunMode: Sendable { case ordinary, latched, turbo, autoTap }
    private struct TimedStep: Sendable { var offset: TimeInterval; var step: ControllerPayloadStep }
    private struct Pulse: Sendable {
        var channel: TriggerChannel; var amount: Double; var start: TimeInterval
        var duration: TimeInterval; var repeats: Bool
    }
    private struct Run: Sendable {
        var serial: UInt64; var start: TimeInterval; var programStart: TimeInterval; var mode: RunMode; var interval: TimeInterval
        var program: [TimedStep]; var cursor = 0
        var digital: Set<ControllerControlID> = []
        var keys: Set<KeyboardKey> = []
        var mouse: Set<PracticeMouseButton> = []
        var observedCycle: Double?

        var pressure: [TriggerChannel: Double] = [:]
        var pulses: [Int: Pulse] = [:]
    }
    private struct PulseKey: Hashable, Sendable { var control: UUID; var step: Int }
    public private(set) var profile: ControllerProfile
    /// An in-game preference only. Safety cleanup stops output but keeps the chosen
    /// policy for this profile; applying/loading a profile restores its saved settings.
    public private(set) var autoCenterOverride: Bool?
    public func effectiveAutoCenter(for controlID: UUID) -> Bool? {
        guard let control = controls[controlID] else { return nil }
        if control.kind.isStick { return autoCenterOverride ?? control.stickBehavior.autoCenter }
        guard control.kind == .button, control.buttonAim.enabled else { return nil }
        if control.buttonAim.tuning.output.logicalStick != nil { return autoCenterOverride ?? control.buttonAim.tuning.autoCenter }
        if control.buttonAim.alternate.enabled && control.buttonAim.alternate.tuning.output.logicalStick != nil {
            return autoCenterOverride ?? control.buttonAim.alternate.tuning.autoCenter
        }
        return nil
    }
    public var autoCenterSettingsMixed: Bool {
        guard autoCenterOverride == nil else { return false }
        var values: Set<Bool> = []
        for control in controls.values {
            if control.kind.isStick { values.insert(control.stickBehavior.autoCenter) }
            if control.kind == .button && control.buttonAim.enabled {
                if control.buttonAim.tuning.output.logicalStick != nil { values.insert(control.buttonAim.tuning.autoCenter) }
                if control.buttonAim.alternate.enabled && control.buttonAim.alternate.tuning.output.logicalStick != nil { values.insert(control.buttonAim.alternate.tuning.autoCenter) }
            }
        }
        return values.count > 1
    }
    public var allSticksAutoCenterEnabled: Bool {
        if let autoCenterOverride { return autoCenterOverride }
        return controls.values.allSatisfy { control in
            if control.kind.isStick { return control.stickBehavior.autoCenter }
            guard control.kind == .button, control.buttonAim.enabled else { return true }
            let base = control.buttonAim.tuning.output.logicalStick == nil || control.buttonAim.tuning.autoCenter
            let alternate = !control.buttonAim.alternate.enabled || control.buttonAim.alternate.tuning.output.logicalStick == nil || control.buttonAim.alternate.tuning.autoCenter
            return base && alternate
        }
    }
    public private(set) var currentPageID: UUID
    public private(set) var previousPageID: UUID?
    public var visibleControlIDs: Set<UUID> { profile.visibleControlIDs(on: currentPageID) }
    public private(set) var state: GamepadState = .neutral
    public private(set) var practiceState: PracticeOutputState = .neutral
    public private(set) var allowCameraFollowPractice: Bool
    public var cameraFollowSnapshot: CameraFollowPracticeSnapshot { cameraFollow.snapshot }
    private var cameraFollow: CameraFollowPracticeMachine
    private var cameraMouseOwners: Set<UUID> = []
    private var cameraSuppressionBlocked: Set<UUID> = []
    private var ordinaryLatchedControls: Set<UUID> = []
    private var repeatLatchedControls: Set<UUID> = []
    private var firstTapEnds: [UUID: TimeInterval] = [:]
    public var latchedControls: Set<UUID> { ordinaryLatchedControls.union(repeatLatchedControls).union(buttons.latched) }
    private var ordinaryRetainedSticks: [UUID: StickPosition] = [:]
    public var retainedSticks: [UUID: StickPosition] {
        ordinaryRetainedSticks.merging(buttons.analogs.compactMapValues { $0.retained ? $0.position : nil }, uniquingKeysWith: { _, new in new })
    }
    public private(set) var activeControls: Set<UUID> = []
    public private(set) var outputControls: Set<UUID> = []
    public private(set) var stickPositions: [UUID: StickPosition] = [:]
    public private(set) var activeTouchpads: Set<UUID> = []
    public private(set) var lockedTouchpads: Set<UUID> = []
    public private(set) var pendingTouchpadLocks: Set<UUID> = []
    private var touchAims: TouchAimRuntime
    private var rings: [UUID: FloatingRingRuntime] = [:]
    public var floatingRingStates: [UUID: FloatingRingState] { rings.mapValues(\.state) }
    /// UI placement belongs to the canvas; input ownership and scoped dismissal belong here.
    /// Each dictionary is bounded by the profile's zone IDs and is never persisted.
    public private(set) var floatingButtonSessions: [UUID: UUID] = [:]
    public private(set) var dismissedFloatingButtonSessions: [UUID: UUID] = [:]
    public var touchAimStates: [UUID: TouchAimState] { touchAims.states }
    public var touchAimScores: [UUID: Double] { touchAims.scores }
    public var touchAimIssues: [UUID: String] { touchAims.issues }
    public var activeTouchAims: Set<UUID> { touchAims.active }
    private var buttons: ButtonGestureRuntime
    public var buttonAimStates: [UUID: ButtonAimVisualState] { buttons.visuals }
    public var buttonAlternatePhases: [UUID: ButtonAlternatePhase] { buttons.phases }
    public var buttonDirectionalSelections: [UUID: ButtonDirectionalSelection] { buttons.selections }
    public mutating func drainButtonFeedback() -> [ButtonFeedback] { buttons.drainFeedback() }
    private var touchpads: TouchpadRuntime
    private var transientPadClick: UUID?
    private var pointerTotal: PointerDelta = .zero
    private var scrollTotal: Double = 0
    private var scrollMode = false
    private var controls: [UUID: ProfileControl]
    private var programs: [UUID: ControllerPayloadProgram]
    private var stagePrograms: [UUID: [StickDirection: [StickStage: ControllerPayloadProgram]]]
    private var outerPrograms: [UUID: [StickDirection: ControllerPayloadProgram]]
    private var retainedTravel: [UUID: StickTravel] = [:]
    public static let maximumUnreadPracticeEvents = 256
    private var eventQueue: [PracticeOutputEvent] = []
    private var omittedEvents = 0
    private var eventSequence: UInt64 = 0
    private var resolvedKeys: Set<KeyboardKey> = []
    private var resolvedMouse: Set<PracticeMouseButton> = []
    private var contacts: [Int: Contact] = [:]
    private var buttonAccessibility: [Int: TimeInterval] = [:]
    private var accessibilityDeadlines: [UUID: TimeInterval] = [:]
    private var runs: [UUID: Run] = [:]
    private var modifiedButtons = ModifiedPayloadRuntime<UUID>()
    /// Only the initiating contact can arm release actions or cancel its macro.
    private var macroContacts: [UUID: Int] = [:]
    private var modifiedStages = ModifiedPayloadRuntime<MacroStageKey>()
    private var liveModifiedStages: Set<MacroStageKey> = []
    private var fixedSticks = FixedStickClaimLedger()
    /// Ephemeral diagnostics: blocked vectors remain stopped until a new explicit activation.
    public var fixedStickIssues: [UUID: String] {
        var blocked = sustainedMacros.blockedChannels
        for id in runs.keys { blocked[id, default: []].formUnion(fixedSticks.rejectedChannels(owner: id)) }
        return blocked.filter { !$0.value.isEmpty }.reduce(into: [:]) { result, entry in
            let names = entry.value.sorted { $0.rawValue < $1.rawValue }.map { $0 == .left ? "left" : "right" }.joined(separator: " and ")
            let restart = rings[entry.key] == nil ? "Release that input, then start a new touch or stage to use this command." :
                "Release that input, then Finish and reopen this ring to start fresh output ownership."
            result[entry.key] = "The \(names) stick command was blocked or replaced by another input. " + restart
        }
    }
    private var sustainedMacros = SustainedMacroCoordinator()
    private struct MacroStageKey: Hashable, Sendable { let control: UUID; let direction: StickDirection; let stage: String }
    private var macroStageLeases: [MacroStageKey: SustainedMacroLease] = [:]
    private var localStageLatches: [MacroStageKey: Double] = [:]
    private var edgeStageLatches: [MacroStageKey: (ControllerPayloadProgram, Int)] = [:]
    private var stickStageRepeats: [MacroStageKey: StickPlusRepeatClock] = [:]
    // Coalesced by instance/step: repeated equal pulses retain the latest expiry, bounded to maximumControls * 64.
    private var detachedPulses: [PulseKey: Pulse] = [:]
    private var nextSerial: UInt64 = 0
    private var lastTime: TimeInterval?
    private var swipeEnteredAt: [UUID: TimeInterval] = [:]

    public init(profile: ControllerProfile, allowCameraFollowPractice: Bool = false) throws {
        try profile.validate(); self.profile = profile
        self.allowCameraFollowPractice = allowCameraFollowPractice
        cameraFollow = try CameraFollowPracticeMachine()
        currentPageID = profile.homePageID
        touchpads = TouchpadRuntime(profile: profile)
        buttons = ButtonGestureRuntime(profile: profile)
        touchAims = try TouchAimRuntime(configurations: Dictionary(uniqueKeysWithValues: profile.controls.filter(\.isTouchAim).map { ($0.id, $0.touchAim) }))
        controls = Dictionary(uniqueKeysWithValues: profile.controls.map { ($0.id, $0) })
        programs = try Dictionary(uniqueKeysWithValues: profile.controls.map { ($0.id, try $0.payloadProgram()) })
        stagePrograms = try Self.compileStages(profile)
        outerPrograms = try Self.compileOuter(profile)
    }
    /// Permission is explicit and defaults off. A mode boundary disarms assistance and
    /// clears only its suppression metadata; the caller owns broader input cancellation.
    public mutating func setCameraFollowPracticeAllowed(_ allowed: Bool, at time: TimeInterval) throws {
        try validateTime(time)
        guard allowed != allowCameraFollowPractice else { return }
        allowCameraFollowPractice = allowed; lastTime = time
        cameraMouseOwners.removeAll(); cameraSuppressionBlocked.removeAll()
        for id in rings.keys { rings[id]?.localAction(.endSuppression) }
        try cameraFollow.reset(at: time); refreshState()
    }
    /// An explicit global Practice setting, equivalent to the local On/Off button.
    /// It never changes physical ownership or sends generated state to a bridge.
    public mutating func setCameraFollowEnabled(_ enabled: Bool, strengthPercent: Double? = nil,
                                                at time: TimeInterval) throws {
        try validateTime(time)
        if let strengthPercent, !strengthPercent.isFinite || !(0...200).contains(strengthPercent) {
            throw CameraFollowError("Camera Follow strength must be 0 through 200 percent.")
        }
        guard allowCameraFollowPractice else { return }
        if let strengthPercent { try cameraFollow.setStrengthPercent(strengthPercent, at: time) }
        try cameraFollow.setEnabled(enabled, at: time)
        try advance(to: time); settle(at: time)
    }
    private mutating func performCameraFollow(_ command: CameraFollowCommand, control: ProfileControl,
                                              at time: TimeInterval) throws {
        guard allowCameraFollowPractice else { return }
        try cameraFollow.setStrengthPercent(control.cameraFollowStrengthPercent, at: time)
        switch command {
        case .toggle: try cameraFollow.toggle(at: time)
        case .enable: try cameraFollow.setEnabled(true, at: time)
        case .disable: try cameraFollow.setEnabled(false, at: time)
        }
    }
    private mutating func noteCameraMouseOutput(_ id: UUID?) {
        guard allowCameraFollowPractice, let id, !cameraSuppressionBlocked.contains(id), controls[id]?.mouseSuppressCameraFollow == true else { return }
        cameraMouseOwners.insert(id)
    }
    /// Source End suppression keeps this control's active outputs intact. Existing held
    /// claims cannot re-engage it; only a fresh direct Down/AX activation re-arms the owner.
    mutating func endCameraSuppression(for controlID: UUID) {
        cameraMouseOwners.remove(controlID); cameraSuppressionBlocked.insert(controlID)
        refreshState()
    }
    private static func compileStages(_ profile: ControllerProfile) throws -> [UUID: [StickDirection: [StickStage: ControllerPayloadProgram]]] {
        try Dictionary(uniqueKeysWithValues: profile.controls.filter { $0.kind.isStick }.map { control in
            (control.id, try Dictionary(uniqueKeysWithValues: StickDirection.allCases.map { direction in
                (direction, try Dictionary(uniqueKeysWithValues: StickStage.allCases.map { stage in
                    (stage, try control.stageProgram(direction: direction, stage: stage))
                }))
            }))
        })
    }
    private static func compileOuter(_ profile: ControllerProfile) throws -> [UUID: [StickDirection: ControllerPayloadProgram]] {
        try Dictionary(uniqueKeysWithValues: profile.controls.filter { $0.kind.isStick }.map { control in
            (control.id, try Dictionary(uniqueKeysWithValues: StickDirection.allCases.map { ($0, try control.outerProgram(direction: $0)) }))
        })
    }
    public mutating func drainPracticeEvents() -> PracticeEventBatch {
        let batch = PracticeEventBatch(events: eventQueue, omittedCount: omittedEvents)
        eventQueue.removeAll(keepingCapacity: true); omittedEvents = 0
        return batch
    }
    public var pendingHoldDeadline: TimeInterval? { contacts.values.compactMap(\.holdDeadline).min() }
    public var nextDeadline: TimeInterval? {
        let time = lastTime ?? 0
        var deadlines = [allowCameraFollowPractice ? cameraFollow.nextDeadline : nil, pendingHoldDeadline, touchpads.nextDeadline, buttons.nextDeadline(after: time), touchAims.nextDeadline(after: time)].compactMap { $0 } + Array(accessibilityDeadlines.values)
        for run in runs.values {
            if run.cursor < run.program.count { deadlines.append(run.programStart + run.program[run.cursor].offset) }
            if run.mode == .turbo || run.mode == .autoTap { deadlines.append(cycle(run, at: time).next) }
            for pulse in run.pulses.values { if let next = pulseStatus(pulse, at: time).next { deadlines.append(next) } }
        }
        deadlines += [modifiedButtons.nextDeadline(after: time), modifiedStages.nextDeadline(after: time)].compactMap { $0 }
        deadlines += Array(buttonAccessibility.values)
        deadlines += detachedPulses.values.map { $0.start + $0.duration }
        deadlines += rings.values.compactMap(\.nextDeadline)
        deadlines += stickStageRepeats.values.map(\.nextDeadline)
        return deadlines.filter { !deadlineReached($0, at: time) }.min()
    }
    public mutating func apply(profile: ControllerProfile) throws {
        try profile.validate()
        let programs = try Dictionary(uniqueKeysWithValues: profile.controls.map { ($0.id, try $0.payloadProgram()) })
        let stages = try Self.compileStages(profile)
        let outer = try Self.compileOuter(profile)
        releaseAll(); dismissedFloatingButtonSessions.removeAll()
        self.autoCenterOverride = nil
        self.profile = profile; self.programs = programs; stagePrograms = stages; outerPrograms = outer
        currentPageID = profile.homePageID; previousPageID = nil
        touchpads = TouchpadRuntime(profile: profile)
        buttons = ButtonGestureRuntime(profile: profile)
        touchAims = try TouchAimRuntime(configurations: Dictionary(uniqueKeysWithValues: profile.controls.filter(\.isTouchAim).map { ($0.id, $0.touchAim) }))
        controls = Dictionary(uniqueKeysWithValues: profile.controls.map { ($0.id, $0) })
    }
    /// A page transition is a cancellation boundary, never an ordinary finger lift.
    @discardableResult
    public mutating func navigate(_ navigation: ProfilePageNavigation, at time: TimeInterval) throws -> Bool {
        try validateTime(time)
        let target: UUID
        switch navigation {
        case let .goTo(id): target = id
        case let .toggle(id):
            guard profile.page(for: id) != nil else { return false }
            target = id == currentPageID ? (previousPageID ?? profile.homePageID) : id
        case .back: target = previousPageID ?? profile.homePageID
        case .home: target = profile.homePageID
        }
        guard target != currentPageID, profile.page(for: target) != nil else { return false }
        let from = currentPageID
        releaseAll()
        lastTime = time; previousPageID = from; currentPageID = target
        return true
    }
    @discardableResult
    public mutating func selectPage(_ id: UUID, at time: TimeInterval) throws -> Bool {
        try navigate(.goTo(id), at: time)
    }
    public mutating func handle(_ event: ProfileInputEvent, at time: TimeInterval) throws {
        switch event {
        case let .beginFloatingRing(contact, zone, session, point, usable):
            _ = try beginFloatingRing(contact: contact, zoneID: zone, sessionID: session, point: point, usable: usable, at: time)
        case let .moveFloatingRing(contact, session, samples): try moveFloatingRing(contact: contact, sessionID: session, samples: samples, at: time)
        case let .endFloatingRing(contact, session, samples): try endFloatingRing(contact: contact, sessionID: session, samples: samples, at: time)
        case let .cancelFloatingRing(contact, session): try cancelFloatingRing(contact: contact, sessionID: session, at: time)
        case let .floatingRingAction(zone, session, action): try floatingRingAction(zoneID: zone, sessionID: session, action: action, at: time)
        case let .handoffFloatingButton(contact, zone, target): _ = try handoffFloatingButton(contact: contact, zoneID: zone, to: target, at: time)
        case let .registerFloatingButtonSession(zone, session): _ = try registerFloatingButtonSession(zoneID: zone, sessionID: session, at: time)
        case let .finishFloatingButtonSession(zone, session): _ = try finishFloatingButtonSession(zoneID: zone, sessionID: session, at: time)
        case let .releaseControls(ids):
            try validateTime(time); releaseControls(ids); try advance(to: time); settle(at: time)
        case let .beginTouchAim(contact, control, sample): try beginTouchAim(contact: contact, control: control, sample: sample, at: time)
        case let .moveTouchAimBatch(contact, samples): try moveTouchAimBatch(contact: contact, samples: samples, at: time)
        case let .beginButton(contact, control, sample): try beginButton(contact: contact, control: control, sample: sample, at: time)
        case let .moveButtonBatch(contact, samples): try moveButtonBatch(contact: contact, samples: samples, at: time)
        case let .endButton(contact, samples): try endButton(contact: contact, finalSamples: samples, at: time)
        case let .begin(contact, control, position): try begin(contact: contact, control: control, position: position, at: time)
        case let .beginStick(contact, control, travel): try beginStick(contact: contact, control: control, travel: travel, at: time)
        case let .moveStick(contact, travel): try moveStick(contact: contact, travel: travel, at: time)
        case let .handoffTravel(contact, control, departing, arriving, deltas):
            _ = try handoffTravel(contact: contact, to: control, departingTravel: departing, arrivingTravel: arriving, finalPadDeltas: deltas, at: time)
        case let .beginTouchpad(contact, control): try beginTouchpad(contact: contact, control: control, at: time)
        case let .moveTouchpad(contact, delta): try moveTouchpad(contact: contact, delta: delta, at: time)
        case let .moveTouchpadBatch(contact, deltas): try moveTouchpadBatch(contact: contact, deltas: deltas, at: time)
        case let .endTouchpad(contact, deltas): try endTouchpad(contact: contact, finalDeltas: deltas, at: time)
        case let .cancel(contact): try cancel(contact: contact, at: time)
        case let .move(contact, position): try move(contact: contact, position: position, at: time)
        case let .transfer(contact, control): try transfer(contact: contact, to: control, at: time)
        case let .handoff(contact, control, departing, arriving, deltas):
            _ = try handoff(contact: contact, to: control, departingStickPosition: departing,
                            arrivingStickPosition: arriving, finalPadDeltas: deltas, at: time)
        case let .end(contact): try end(contact: contact, at: time)
        case .cancelAll:
            try validateTime(time); lastTime = time; releaseAll() // Cancellation wins before due work.
        case let .accessibilityActivate(control): try activate(control, at: time)
        }
    }
    public mutating func begin(contact: Int, control id: UUID, position: StickPosition = .zero,
                               at time: TimeInterval) throws {
        guard position.isValid else { throw ControllerInputError.invalidPosition }
        try begin(contact: contact, control: id, travel: StickTravel(position), at: time)
    }
    public mutating func beginStick(contact: Int, control id: UUID, travel: StickTravel, at time: TimeInterval) throws {
        guard controls[id]?.kind.isStick == true else { throw ControllerInputError.invalidControl }
        try begin(contact: contact, control: id, travel: travel, at: time)
    }
    private mutating func begin(contact: Int, control id: UUID, travel: StickTravel, direct: Bool = true, at time: TimeInterval) throws {
        guard travel.isValid else { throw ControllerInputError.invalidPosition }
        guard capturedControl(for: contact) == nil else { throw ControllerInputError.duplicateContact }
        guard let control = controls[id], visibleControlIDs.contains(id), !control.isTouchpad, !control.isTouchAim else { throw ControllerInputError.invalidControl }
        try validateTime(time)
        if direct { cameraSuppressionBlocked.remove(id) }
        if control.isReleaseAllAction {
            try validateTime(time); lastTime = time; releaseAll(); return
        }
        if let binding = control.floatingAction {
            guard direct else { return }
            noteAcceptedControl(id)
            let alreadyTouched = contacts.values.contains { $0.control == id }
            contacts[contact] = Contact(control: id)
            // Local cancellation wins over the target's overdue WAIT/Hold/shot work.
            if !alreadyTouched { performFloatingAction(binding) }
            try advance(to: time); settle(at: time); return
        }
        if let command = programs[id]?.autoCenterCommand {
            noteAcceptedControl(id)
            let alreadyTouched = contacts.values.contains { $0.control == id }
            contacts[contact] = Contact(control: id)
            if !alreadyTouched { performAutoCenter(command) }
            try advance(to: time); settle(at: time); return
        }
        if let command = programs[id]?.cameraFollowCommand {
            try validateTime(time)
            guard allowCameraFollowPractice else { return }
            noteAcceptedControl(id)
            let alreadyTouched = contacts.values.contains { $0.control == id }
            contacts[contact] = Contact(control: id)
            if !alreadyTouched { try performCameraFollow(command, control: control, at: time) }
            try advance(to: time); settle(at: time); return
        }
        if control.isAdvancedButton {
            try beginButton(contact: contact, control: id, sample: .init(x: control.resolvedWidth/2, y: control.resolvedHeight/2, width: control.resolvedWidth, height: control.resolvedHeight), at: time)
            return
        }
        if let navigation = control.pageNavigation {
            try validateTime(time)
            noteAcceptedControl(id)
            let alreadyTouched = contacts.values.contains { $0.control == id }
            contacts[contact] = Contact(control: id)
            if !alreadyTouched { _ = try navigate(navigation, at: time) }
            return
        }
        if control.centerLeftStickBeforePress, !control.macroModeEnabled,
           !contacts.values.contains(where: { $0.control == id }), !latchedControls.contains(id),
           !modifiedButtons.slots.contains(id) { recenterLeftStick() }
        try advance(to: time, skipping: latchedControls.contains(id) ? [id] : [])
        if let channel = control.logicalStick {
            let occupied = (!control.isDirectional && buttons.occupiedChannels.union(touchAims.occupiedChannels).union(ringOccupiedChannels).union(fixedSticks.occupiedChannels).contains(channel)) || contacts.values.contains {
                guard $0.ownsStick, let otherID = $0.control else { return false }
                return control.isDirectional ? otherID == id : ($0.stickChannel == channel && controls[otherID]?.isDirectional == false)
            }
            if !occupied {
                if !control.isDirectional { buttons.yieldRetained(channel: channel); yieldRetainedRings(channel: channel); fixedSticks.yieldRetained(channel: channel) }
                ordinaryRetainedSticks = ordinaryRetainedSticks.filter {
                    control.isDirectional ? $0.key != id : (controls[$0.key]?.logicalStick != channel || controls[$0.key]?.isDirectional == true)
                }
            }
            retainedTravel = retainedTravel.filter { retainedSticks[$0.key] != nil }
            contacts[contact] = Contact(control: id, travel: travel, stickChannel: channel, ownsStick: !occupied)
        } else if control.kind == .recenter {
            contacts[contact] = Contact(control: id); recenterSticks(fromControl: true)
        } else if control.isScrollModeToggle {
            noteAcceptedControl(id)
            let alreadyTouched = contacts.values.contains { $0.control == id }
            contacts[contact] = Contact(control: id)
            if !alreadyTouched { toggleScrollMode() }
        } else { enterButton(contact: contact, control: id, time: time, recognizesTap: direct) }
        if control.kind != .button, isCapturedInputOwner(for: contact) { noteAcceptedControl(id) }
        settle(at: time)
    }

    private var occupiedManualChannels: Set<ControllerControlID> {
        Set(contacts.values.compactMap { value in
            guard value.ownsStick, let id=value.control, controls[id]?.isDirectional == false else { return nil }
            return value.stickChannel
        })
    }
    private var retainedManualChannels: Set<ControllerControlID> {
        Set(ordinaryRetainedSticks.keys.compactMap { controls[$0]?.isDirectional == false ? controls[$0]?.logicalStick : nil })
    }
    private mutating func consumeButtonTakeovers() {
        for channel in buttons.consumeTakeovers() {
            fixedSticks.yieldRetained(channel: channel)
            yieldRetainedRings(channel: channel)
            ordinaryRetainedSticks = ordinaryRetainedSticks.filter { controls[$0.key]?.logicalStick != channel || controls[$0.key]?.isDirectional == true }
            retainedTravel = retainedTravel.filter { ordinaryRetainedSticks[$0.key] != nil }
        }
    }
    private func validateButtonSamples(_ samples:[ButtonPointerSample]) throws {
        guard samples.count <= 256, samples.allSatisfy(\.isValid) else { throw ControllerInputError.invalidPosition }
    }
    private mutating func recordAimMovement(_ delta:PointerDelta, owner: UUID? = nil) {
        if delta != .zero { noteCameraMouseOutput(owner) }
        // Button Aim is mouse aiming, independent from the touchpad's global scroll switch.
        pointerTotal.dx = clampedPracticeTotal(pointerTotal.dx, adding:delta.dx)
        pointerTotal.dy = clampedPracticeTotal(pointerTotal.dy, adding:delta.dy)
        appendEvent(.pointerMoved(dx:delta.dx,dy:delta.dy))
    }
    public mutating func beginButton(contact:Int,control id:UUID,sample:ButtonPointerSample,at time:TimeInterval) throws {
        try validateButtonSamples([sample]); try validateTime(time)
        guard capturedControl(for:contact) == nil else { throw ControllerInputError.duplicateContact }
        guard let control=controls[id], control.isAdvancedButton, visibleControlIDs.contains(id) else { throw ControllerInputError.invalidControl }
        // New touch cancels this instance's pending action before overdue deadlines can fire.
        reconcileFixedStickClaims(at: time)
        _ = buttons.begin(contact:contact,id:id,sample:sample,time:time,
                          occupied:occupiedManualChannels.union(touchAims.occupiedChannels).union(ringOccupiedChannels).union(fixedSticks.occupiedChannels),
                          retained:retainedManualChannels.union(buttons.retainedChannels).union(ringRetainedChannels).union(fixedSticks.retainedChannels))
        if buttons.contacts[contact] == id { cameraSuppressionBlocked.remove(id); noteAcceptedControl(id) }
        consumeButtonTakeovers(); try advance(to:time); settle(at:time)
    }
    public mutating func moveButtonBatch(contact:Int,samples:[ButtonPointerSample],at time:TimeInterval) throws {
        try validateButtonSamples(samples); try validateTime(time)
        for delta in buttons.move(contact:contact,samples:samples,time:time,occupied:occupiedManualChannels.union(touchAims.occupiedChannels).union(ringOccupiedChannels).union(fixedSticks.occupiedChannels)) { recordAimMovement(delta, owner: buttons.contacts[contact]) }
        consumeButtonTakeovers(); try advance(to:time); settle(at:time)
    }
    public mutating func endButton(contact:Int,finalSamples:[ButtonPointerSample],at time:TimeInterval) throws {
        try validateButtonSamples(finalSamples); try validateTime(time)
        for delta in buttons.move(contact:contact,samples:finalSamples,time:time,occupied:occupiedManualChannels.union(touchAims.occupiedChannels).union(ringOccupiedChannels).union(fixedSticks.occupiedChannels)) { recordAimMovement(delta, owner: buttons.contacts[contact]) }
        consumeButtonTakeovers()
        buttons.end(contact:contact,time:time,cancelled:false); buttonAccessibility[contact]=nil
        try advance(to:time); settle(at:time)
    }

    public mutating func beginTouchAim(contact:Int,control id:UUID,sample:TouchAimSample,at time:TimeInterval) throws {
        guard sample.isValid, sample.elapsed == 0 else { throw ControllerInputError.invalidPosition }
        try validateTime(time)
        guard capturedControl(for:contact) == nil else { throw ControllerInputError.duplicateContact }
        guard let control=controls[id], control.isTouchAim, visibleControlIDs.contains(id) else { throw ControllerInputError.invalidControl }
        reconcileFixedStickClaims(at: time)
        _ = try touchAims.begin(contact:contact,id:id,sample:sample,time:time,
                               occupied:occupiedManualChannels.union(buttons.occupiedChannels).union(ringOccupiedChannels).union(fixedSticks.occupiedChannels),
                               retained:retainedManualChannels.union(buttons.retainedChannels).union(ringRetainedChannels).union(fixedSticks.retainedChannels))
        if touchAims.contacts[contact] == id { cameraSuppressionBlocked.remove(id); noteAcceptedControl(id) }
        for channel in touchAims.consumeTakeovers() {
            fixedSticks.yieldRetained(channel: channel)
            yieldRetainedRings(channel: channel)
            buttons.yieldRetained(channel:channel)
            ordinaryRetainedSticks=ordinaryRetainedSticks.filter { controls[$0.key]?.logicalStick != channel || controls[$0.key]?.isDirectional == true }
            retainedTravel=retainedTravel.filter { ordinaryRetainedSticks[$0.key] != nil }
        }
        try advance(to:time);settle(at:time)
    }
    public mutating func moveTouchAimBatch(contact:Int,samples:[TouchAimSample],at time:TimeInterval) throws {
        try validateTime(time)
        // Classify the complete observation batch before any delayed confirmation may fire.
        let deltas=try touchAims.move(contact:contact,samples:samples,time:time)
        for delta in deltas { recordAimMovement(delta, owner: touchAims.contacts[contact]) }
        try advance(to:time);settle(at:time)
    }

    public mutating func beginTouchpad(contact: Int, control id: UUID, at time: TimeInterval) throws {
        try beginTouchpad(contact: contact, control: id, at: time, recognizesTap: true)
    }
    private mutating func beginTouchpad(contact: Int, control id: UUID, at time: TimeInterval, recognizesTap: Bool) throws {
        guard controls[id]?.isTouchpad == true, visibleControlIDs.contains(id) else { throw ControllerInputError.invalidControl }
        guard capturedControl(for: contact) == nil else { throw ControllerInputError.duplicateContact }
        try validateTime(time)
        // A second toggle touch cancels its pending lock before any due work advances.
        touchpads.begin(contact: contact, control: id, at: time, recognizesTap: recognizesTap)
        if touchpads.contacts[contact]?.owns == true { noteAcceptedControl(id) }
        if recognizesTap, touchpads.contacts[contact]?.owns == true { cameraSuppressionBlocked.remove(id) }
        try advance(to: time); settle(at: time)
    }
    public mutating func moveTouchpad(contact: Int, delta: PointerDelta, at time: TimeInterval) throws {
        try moveTouchpadBatch(contact: contact, deltas: [delta], at: time)
    }
    public mutating func moveTouchpadBatch(contact: Int, deltas: [PointerDelta], at time: TimeInterval) throws {
        try validateTouchpadBatch(deltas); try validateTime(time)
        // Full coalesced path must invalidate slop before a late lock timer is considered.
        let movement = touchpads.move(contact: contact, deltas: deltas)
        try advance(to: time)
        emitResolvedDesktop()
        for delta in movement { recordMovement(delta, owner: touchpads.contacts[contact]?.id) }
        settle(at: time)
    }
    public mutating func endTouchpad(contact: Int, finalDeltas: [PointerDelta] = [], at time: TimeInterval) throws {
        try validateTouchpadBatch(finalDeltas); try validateTime(time)
        let movement = touchpads.move(contact: contact, deltas: finalDeltas)
        // Final drag motion precedes releasing its mouse owner. No arming advances here.
        for delta in movement { recordMovement(delta, owner: touchpads.contacts[contact]?.id) }
        let click = touchpads.end(contact: contact, at: time, cancelled: false)
        try advance(to: time)
        emitResolvedDesktop()
        if let click {
            noteCameraMouseOutput(click)
            transientPadClick = click; emitResolvedDesktop()
            transientPadClick = nil; emitResolvedDesktop()
        }
        settle(at: time)
    }
    public mutating func cancel(contact: Int, at time: TimeInterval) throws {
        try validateTime(time)
        if let id = ringID(contact: contact) { rings[id]?.cancel() }
        else if touchAims.contacts[contact] != nil { touchAims.end(contact:contact) }
        else if buttons.contacts[contact] != nil { buttons.end(contact: contact, time: time, cancelled: true) }
        else if touchpads.contacts[contact] != nil { _ = touchpads.end(contact: contact, at: time, cancelled: true) }
        else if let removed = contacts.removeValue(forKey: contact), let id = removed.control {
            if controls[id]?.macroModeEnabled == true {
                if macroContacts[id] == contact {
                    modifiedButtons.cancel(id); macroContacts[id] = nil
                    fixedSticks.end(owner: id)
                }
                try advance(to: time); settle(at: time); return
            }
            if removed.ownsStick {
                modifiedStages.cancel { $0.control == id }
                liveModifiedStages = liveModifiedStages.filter { $0.control != id }
            }
            if removed.ownsStick { ordinaryRetainedSticks.removeValue(forKey: id); retainedTravel.removeValue(forKey: id) }
            if controls[id]?.kind == .button, !contacts.values.contains(where: { $0.control == id }) {
                ordinaryLatchedControls.remove(id)
                repeatLatchedControls.remove(id); firstTapEnds[id] = nil
                if accessibilityDeadlines[id] == nil { runs.removeValue(forKey: id); fixedSticks.end(owner: id); modifiedButtons.cancel(id) } // Never detach this canceled run's pulses.
            }
        }
        try advance(to: time); settle(at: time)
    }
    private func validateTouchpadBatch(_ deltas: [PointerDelta]) throws {
        guard deltas.count <= 256, deltas.allSatisfy(\.isValidInput) else { throw ControllerInputError.invalidPosition }
    }
    private mutating func recordMovement(_ delta: PointerDelta, owner: UUID? = nil) {
        if scrollMode {
            let amount = -delta.dy
            guard amount != 0 else { return }
            noteCameraMouseOutput(owner)
            scrollTotal = clampedPracticeTotal(scrollTotal, adding: amount)
            appendEvent(.scrolled(delta: amount))
        } else {
            guard delta != .zero else { return }
            noteCameraMouseOutput(owner)
            pointerTotal.dx = clampedPracticeTotal(pointerTotal.dx, adding: delta.dx)
            pointerTotal.dy = clampedPracticeTotal(pointerTotal.dy, adding: delta.dy)
            appendEvent(.pointerMoved(dx: delta.dx, dy: delta.dy))
        }
    }
    private mutating func toggleScrollMode() {
        scrollMode.toggle(); touchpads.resetFilters()
        appendEvent(.scrollModeChanged(scrollMode))
    }
    public mutating func move(contact: Int, position: StickPosition, at time: TimeInterval) throws {
        guard position.isValid else { throw ControllerInputError.invalidPosition }
        try moveStick(contact: contact, travel: StickTravel(position), at: time)
    }
    public mutating func moveStick(contact: Int, travel: StickTravel, at time: TimeInterval) throws {
        guard travel.isValid else { throw ControllerInputError.invalidPosition }
        try advance(to: time)
        if contacts[contact]?.ownsStick == true { contacts[contact]?.travel = travel }
        settle(at: time)
    }
    /// UI routing must not adopt a contact whose analog/surface ownership was rejected.
    public func isCapturedInputOwner(for contact: Int) -> Bool {
        if ringID(contact: contact) != nil { return true }
        if touchAims.contacts[contact] != nil || buttons.contacts[contact] != nil { return true }
        if let pad = touchpads.contacts[contact] { return pad.owns }
        guard let value = contacts[contact], let id = value.control else { return false }
        return controls[id]?.kind.isStick != true || value.ownsStick
    }
    public func capturedControl(for contact: Int) -> UUID? {
        contacts[contact]?.control ?? touchpads.contacts[contact]?.id ?? buttons.contacts[contact] ?? touchAims.contacts[contact] ?? ringID(contact: contact)
    }
    public func canHandoff(contact: Int, to id: UUID) -> Bool {
        guard profile.swipeMode == .controls, let sourceID = capturedControl(for: contact),
              let source = controls[sourceID], !source.isLocalAction, !source.isAdvancedButton, !source.isTouchAim,
              let target = controls[id], visibleControlIDs.contains(id), target.acceptsSwipeEntry else { return false }
        if sourceID == id { return true }
        if target.isTouchpad { return !touchpads.contacts.contains { $0.key != contact && $0.value.owns && $0.value.id == id } }
        if target.kind.isStick {
            if !target.isDirectional, let channel = target.logicalStick {
                let sourceWillEnd = !ordinaryLatchedControls.contains(sourceID) && accessibilityDeadlines[sourceID] == nil &&
                    !contacts.contains { $0.key != contact && $0.value.control == sourceID }
                let macroChannels = Set(fixedSticks.claims.filter {
                    !$0.value.retained && !(sourceWillEnd && $0.value.owner == sourceID)
                }.keys.map(\.control))
                if buttons.occupiedChannels.union(touchAims.occupiedChannels).union(ringOccupiedChannels).union(macroChannels).contains(channel) { return false }
            }
            return !contacts.contains { token, existing in
                guard token != contact, existing.ownsStick, let otherID = existing.control else { return false }
                if target.isDirectional { return otherID == id }
                return controls[otherID]?.isDirectional == false && existing.stickChannel == target.logicalStick
            }
        }
        return true
    }
    /// Group-local sliding is independent of global Swipe mode and has no 120 ms entry
    /// cooldown. It still honors destination eligibility and never enters local/advanced actions.
    @discardableResult
    public mutating func handoffFloatingButton(contact: Int, zoneID: UUID, to id: UUID,
                                              at time: TimeInterval) throws -> Bool {
        try validateTime(time)
        guard let zone = profile.page(for: currentPageID)?.floatingButtonZones.first(where: { $0.id == zoneID }),
              zone.enabled, zone.kind == .buttonGroup, zone.groupSwipe,
              let source = contacts[contact]?.control, let current = controls[source], let target = controls[id],
              zone.memberIDs.contains(source), zone.memberIDs.contains(id),
              current.kind == .button, !current.isLocalAction, !current.isAdvancedButton,
              target.kind == .button, target.acceptsSwipeEntry else { return false }
        if source == id { return true }
        contacts[contact]?.holdDeadline = nil; contacts[contact]?.suppressToggle = true
        let skip = Set([source, latchedControls.contains(id) ? id : nil].compactMap { $0 })
        finishOrdinaryButtonSource(contact, at: time)
        try advance(to: time, skipping: skip)
        finishMacroContact(contact, at: time)
        contacts.removeValue(forKey: contact)
        try begin(contact: contact, control: id, travel: .zero, direct: false, at: time)
        return capturedControl(for: contact) == id
    }
    @discardableResult
    public mutating func handoff(contact: Int, to id: UUID, departingStickPosition: StickPosition? = nil,
                                 arrivingStickPosition: StickPosition = .zero, finalPadDeltas: [PointerDelta] = [],
                                 at time: TimeInterval) throws -> Bool {
        guard arrivingStickPosition.isValid, departingStickPosition?.isValid ?? true else { throw ControllerInputError.invalidPosition }
        return try handoffTravel(contact: contact, to: id, departingTravel: departingStickPosition.map(StickTravel.init),
                                 arrivingTravel: StickTravel(arrivingStickPosition), finalPadDeltas: finalPadDeltas, at: time)
    }
    @discardableResult
    public mutating func handoffTravel(contact: Int, to id: UUID, departingTravel: StickTravel? = nil,
                                       arrivingTravel: StickTravel = .zero, finalPadDeltas: [PointerDelta] = [],
                                       at time: TimeInterval) throws -> Bool {
        guard arrivingTravel.isValid, departingTravel?.isValid ?? true else { throw ControllerInputError.invalidPosition }
        try validateTouchpadBatch(finalPadDeltas); try validateTime(time)
        guard canHandoff(contact: contact, to: id), let source = capturedControl(for: contact) else { return false }
        if source == id { return true }
        guard swipeEnteredAt[id].map({ time + 1e-10 >= $0 + 0.120 }) ?? true else { return false }
        // All acceptance checks precede path, output, and ownership changes.
        if touchpads.contacts[contact] != nil {
            for delta in touchpads.move(contact: contact, deltas: finalPadDeltas) { recordMovement(delta, owner: touchpads.contacts[contact]?.id) }
            touchpads.handoff(contact: contact)
        } else if let travel = departingTravel, contacts[contact]?.ownsStick == true {
            contacts[contact]?.travel = travel
        }
        // Departure wins over this contact's unobserved hold deadline; other fingers and
        // already established latches keep their independent ownership.
        contacts[contact]?.holdDeadline = nil
        contacts[contact]?.suppressToggle = true
        let skip = Set([source, latchedControls.contains(id) ? id : nil].compactMap { $0 })
        finishOrdinaryButtonSource(contact, at: time)
        try advance(to: time, skipping: skip)
        finishMacroContact(contact, at: time)
        if let ended = contacts.removeValue(forKey: contact), ended.ownsStick,
           let old = controls[source], effectiveAutoCenter(for: old.id) == false, ended.travel != .zero {
            ordinaryRetainedSticks[source] = ended.travel.clampedPosition; retainedTravel[source] = ended.travel
        }
        if controls[id]?.isTouchpad == true {
            try beginTouchpad(contact: contact, control: id, at: time, recognizesTap: false)
        } else {
            try begin(contact: contact, control: id, travel: arrivingTravel, direct: false, at: time)
        }
        swipeEnteredAt = swipeEnteredAt.filter { time < $0.value + 0.120 }
        swipeEnteredAt[id] = time
        return capturedControl(for: contact) == id
    }
    public mutating func transfer(contact: Int, to id: UUID?, at time: TimeInterval) throws {
        if let id, controls[id] == nil { throw ControllerInputError.invalidControl }
        if let id, !visibleControlIDs.contains(id) { throw ControllerInputError.invalidControl }
        try validateTime(time)
        if profile.swipeMode == .off { try advance(to: time); settle(at: time); return }
        if contacts[contact]?.control.flatMap({ controls[$0]?.kind }) == .pageButton { return }
        if profile.swipeMode == .controls {
            guard let id, controls[id]?.kind == .button,
                  let current = contacts[contact], current.stickChannel == nil else { return }
            _ = try handoff(contact: contact, to: id, at: time)
            return
        }
        guard let current = contacts[contact], current.stickChannel == nil else { try advance(to: time); settle(at: time); return }
        // Legacy button-only mode releases through gaps and cannot acquire surfaces.
        if let id, controls[id]?.kind.isStick == true || controls[id]?.isTouchpad == true { return }
        let target = id.flatMap { controls[$0]?.acceptsSwipeEntry == true ? $0 : nil }
        let departing = current.control
        if let target, current.control != target, controls[target]?.centerLeftStickBeforePress == true,
           controls[target]?.macroModeEnabled != true,
           !contacts.values.contains(where: { $0.control == target }), !latchedControls.contains(target),
           !modifiedButtons.slots.contains(target) { recenterLeftStick() }
        let skip = Set([departing, target.flatMap { latchedControls.contains($0) ? $0 : nil }].compactMap { $0 })
        if current.control != target { finishOrdinaryButtonSource(contact, at: time) }
        try advance(to: time, skipping: skip)
        if current.control != target {
            finishMacroContact(contact, at: time)
            contacts.removeValue(forKey: contact)
            if let target { enterButton(contact: contact, control: target, time: time, recognizesTap: false) }
            else { contacts[contact] = Contact(control: nil) }
        }
        settle(at: time)
    }
    public mutating func end(contact: Int, at time: TimeInterval) throws {
        if let id = ringID(contact: contact), let session = rings[id]?.sessionID {
            try endFloatingRing(contact: contact, sessionID: session, samples: [], at: time); return
        }
        if touchAims.contacts[contact] != nil {
            try validateTime(time);touchAims.end(contact:contact, at:time, cancelled:false)
            try advance(to:time);settle(at:time);return
        }
        if buttons.contacts[contact] != nil { try endButton(contact: contact, finalSamples: [], at: time); return }
        if touchpads.contacts[contact] != nil { try endTouchpad(contact: contact, finalDeltas: [], at: time); return }
        // A not-yet-run WAIT continuation must not begin merely because its finger lifted late.
        let departing = contacts[contact]?.control
        try validateTime(time)
        finishDoubleTapContact(contact, at: time)
        finishOrdinaryButtonSource(contact, at: time)
        try advance(to: time, skipping: Set([departing].compactMap { $0 }))
        finishMacroContact(contact, at: time)
        if let ended = contacts.removeValue(forKey: contact), let id = ended.control,
           ended.ownsStick, let control = controls[id] {
            if effectiveAutoCenter(for: control.id) == false && ended.travel != .zero {
                ordinaryRetainedSticks[id] = ended.travel.clampedPosition; retainedTravel[id] = ended.travel
            } else { ordinaryRetainedSticks.removeValue(forKey: id); retainedTravel.removeValue(forKey: id) }
        }
        settle(at: time)
    }
    public mutating func tick(at time: TimeInterval) throws { try advance(to: time); settle(at: time) }
    /// Scoped terminal cancellation, never normal UP: no release-shot, pulse detachment or
    /// overdue Hold Toggle/WAIT is allowed to run while a floating instance is being finished.
    /// Other owners, their deadlines and shared held outputs remain intact.
    public mutating func releaseControls(_ ids: Set<UUID>) {
        localStageLatches = localStageLatches.filter { !ids.contains($0.key.control) }
        edgeStageLatches = edgeStageLatches.filter { !ids.contains($0.key.control) }
        cameraMouseOwners.subtract(ids); cameraSuppressionBlocked.subtract(ids)
        let removedContacts = Set(contacts.filter { $0.value.control.map(ids.contains) ?? false }.keys)
            .union(buttons.contacts.filter { ids.contains($0.value) }.keys)
            .union(touchAims.contacts.filter { ids.contains($0.value) }.keys)
            .union(touchpads.contacts.filter { ids.contains($0.value.id) }.keys)
        contacts = contacts.filter { !removedContacts.contains($0.key) }
        buttonAccessibility = buttonAccessibility.filter { !removedContacts.contains($0.key) }
        ordinaryLatchedControls.subtract(ids)
        repeatLatchedControls.subtract(ids)
        firstTapEnds = firstTapEnds.filter { !ids.contains($0.key) }
        ordinaryRetainedSticks = ordinaryRetainedSticks.filter { !ids.contains($0.key) }
        retainedTravel = retainedTravel.filter { !ids.contains($0.key) }
        accessibilityDeadlines = accessibilityDeadlines.filter { !ids.contains($0.key) }
        for id in ids { fixedSticks.end(owner: id) }
        sustainedMacros.remove(controls: ids, ledger: &fixedSticks)
        macroStageLeases = macroStageLeases.filter { !ids.contains($0.key.control) }
        modifiedButtons.cancel { ids.contains($0) }
        macroContacts = macroContacts.filter { !ids.contains($0.key) }
        modifiedStages.cancel { ids.contains($0.control) }
        liveModifiedStages = liveModifiedStages.filter { !ids.contains($0.control) }
        runs = runs.filter { !ids.contains($0.key) }
        detachedPulses = detachedPulses.filter { !ids.contains($0.key.control) }
        swipeEnteredAt = swipeEnteredAt.filter { !ids.contains($0.key) }
        buttons.clear(controls: ids); touchAims.clear(controls: ids); touchpads.clear(controls: ids)
        for id in ids { rings[id]?.finish() }
        if let transientPadClick, ids.contains(transientPadClick) { self.transientPadClick = nil }
        refreshState(); emitResolvedDesktop()
    }
    public mutating func releaseAll() {
        for (zone, session) in floatingButtonSessions { dismissedFloatingButtonSessions[zone] = session }
        floatingButtonSessions.removeAll()
        cameraMouseOwners.removeAll(); cameraSuppressionBlocked.removeAll(); try? cameraFollow.reset(at: lastTime ?? 0)
        contacts.removeAll(); buttonAccessibility.removeAll(); ordinaryLatchedControls.removeAll(); ordinaryRetainedSticks.removeAll(); retainedTravel.removeAll(); accessibilityDeadlines.removeAll()
        repeatLatchedControls.removeAll(); firstTapEnds.removeAll()
        fixedSticks.clear(); sustainedMacros.clear(); macroStageLeases.removeAll()
        stickStageRepeats.removeAll(); modifiedButtons = .init(); modifiedStages = .init(); liveModifiedStages = []
        macroContacts.removeAll(); localStageLatches.removeAll(); edgeStageLatches.removeAll()
        runs.removeAll(); detachedPulses.removeAll(); swipeEnteredAt.removeAll(); nextSerial &+= 1
        activeControls.removeAll(); outputControls.removeAll(); stickPositions.removeAll()
        touchAims.clear(); buttons.clear(); touchpads.clear(); transientPadClick = nil; pointerTotal = .zero; scrollTotal = 0; scrollMode = false
        rings.removeAll()
        activeTouchpads.removeAll(); lockedTouchpads.removeAll(); pendingTouchpadLocks.removeAll()
        state = .neutral; practiceState = .neutral
        eventQueue.removeAll(keepingCapacity: true); omittedEvents = 0
        emitDesktopTransition(keys: [], mouse: [])
        appendEvent(.reset)
    }
    /// Stops only the current left-stick owners before a separate button action. Captured
    /// Aim surfaces keep their independent triggers/buttons and right-stick output.
    public mutating func recenterLeftStick() {
        let leftControls = Set(controls.values.filter { $0.kind.isStick && $0.logicalStick == .leftStick }.map(\.id))
        localStageLatches = localStageLatches.filter { !leftControls.contains($0.key.control) }
        edgeStageLatches = edgeStageLatches.filter { !leftControls.contains($0.key.control) }
        contacts = contacts.filter { !($0.value.control.map(leftControls.contains) ?? false) }
        ordinaryRetainedSticks = ordinaryRetainedSticks.filter { !leftControls.contains($0.key) }
        retainedTravel = retainedTravel.filter { !leftControls.contains($0.key) }
        modifiedStages.cancel { leftControls.contains($0.control) }
        liveModifiedStages = liveModifiedStages.filter { !leftControls.contains($0.control) }
        macroStageLeases = macroStageLeases.filter { !leftControls.contains($0.key.control) }
        stickStageRepeats = stickStageRepeats.filter { !leftControls.contains($0.key.control) }
        for id in runs.keys { fixedSticks.suppress(owner: id, channel: .left) }
        modifiedButtons.suppressMacros(channel: .left)
        modifiedStages.suppressMacros(channel: .left)
        sustainedMacros.suppress(channel: .left, ledger: &fixedSticks)
        buttons.recenter(channel: .left); touchAims.recenter(channel: .left)
        for id in rings.keys { rings[id]?.recenter(channel: .left) }
        try? cameraFollow.clearLeftInput(at: lastTime ?? 0)
        refreshState(); emitResolvedDesktop()
    }
    public mutating func recenterSticks(fromControl: Bool = false) {
        localStageLatches.removeAll(); edgeStageLatches.removeAll()
        for id in runs.keys { fixedSticks.suppress(owner: id) }
        modifiedStages = .init(); liveModifiedStages = []
        modifiedButtons.suppressMacros()
        touchAims.recenter(); buttons.recenter()
        for id in rings.keys {
            if fromControl { rings[id]?.recenterMovement() } else { rings[id]?.recenter() }
        }
        contacts = contacts.filter { entry in
            guard let id = entry.value.control else { return true }
            return controls[id]?.kind.isStick != true
        }
        ordinaryRetainedSticks.removeAll(); retainedTravel.removeAll()
        try? cameraFollow.clearInputs(at: lastTime ?? 0); refreshState()
    }
    public mutating func activate(_ id: UUID, at time: TimeInterval) throws {
        guard let control = controls[id], visibleControlIDs.contains(id), !control.kind.isStick, !control.isTouchpad, !control.isTouchAim else { throw ControllerInputError.invalidControl }
        try validateTime(time); cameraSuppressionBlocked.remove(id)
        if control.isReleaseAllAction { try validateTime(time); lastTime = time; releaseAll(); return }
        if let binding = control.floatingAction {
            noteAcceptedControl(id)
            performFloatingAction(binding)
            accessibilityDeadlines[id] = time + 0.15
            try advance(to: time); settle(at: time); return
        }
        if let command = programs[id]?.autoCenterCommand {
            noteAcceptedControl(id); performAutoCenter(command)
            accessibilityDeadlines[id] = time + 0.15
            try advance(to: time); settle(at: time); return
        }
        if let command = programs[id]?.cameraFollowCommand {
            try validateTime(time); guard allowCameraFollowPractice else { return }
            noteAcceptedControl(id)
            try performCameraFollow(command, control: control, at: time)
            accessibilityDeadlines[id] = time + 0.15
            try advance(to: time); settle(at: time); return
        }
        if let navigation = control.pageNavigation { noteAcceptedControl(id); _ = try navigate(navigation, at: time); return }
        if control.isAdvancedButton {
            // Accessibility is an explicit finite activation at the surface center; no synthetic movement.
            var token = Int.min
            while capturedControl(for: token) != nil { token += 1 }
            try beginButton(contact: token, control: id, sample: .init(x: control.resolvedWidth/2, y: control.resolvedHeight/2, width: control.resolvedWidth, height: control.resolvedHeight), at: time)
            buttonAccessibility[token] = time + 0.15
            return
        }
        if control.centerLeftStickBeforePress, !control.macroModeEnabled, !latchedControls.contains(id),
           !contacts.values.contains(where: { $0.control == id }), !modifiedButtons.slots.contains(id) { recenterLeftStick() }
        try advance(to: time, skipping: latchedControls.contains(id) ? [id] : [])
        if control.macroModeEnabled {
            if !contacts.values.contains(where: { $0.control == id }), startMacro(id, at: time) {
                modifiedButtons.end(id, at: time)
            }
        } else if control.doubleTapRepeatEnabled && latchedControls.contains(id) {
            ordinaryLatchedControls.remove(id); repeatLatchedControls.remove(id); firstTapEnds[id] = nil
            suppressPendingHolds(for: id)
        } else if control.kind == .recenter {
            recenterSticks(fromControl: true); accessibilityDeadlines[id] = time + 0.15
        } else if control.isScrollModeToggle {
            toggleScrollMode(); accessibilityDeadlines[id] = time + 0.15
        } else if control.autoTapEnabled || usesHoldToggle(id) || usesGlobalHold(id) {
            if !ordinaryLatchedControls.insert(id).inserted { ordinaryLatchedControls.remove(id) }
            suppressPendingHolds(for: id)
        } else { accessibilityDeadlines[id] = time + 0.15 }
        if !control.macroModeEnabled { noteAcceptedControl(id) }
        settle(at: time)
    }
    private func usesHoldToggle(_ id: UUID) -> Bool {
        guard let control = controls[id], control.buttonBehavior.holdToggle, !control.autoTapEnabled, !control.doubleTapRepeatEnabled else { return false }
        return !(profile.turboEnabled && programs[id]?.containsLegacyWaitOrPulse == false)
    }
    private func usesGlobalHold(_ id: UUID) -> Bool {
        guard profile.globalHoldEnabled, let control = controls[id], let program = programs[id],
              control.kind == .button, !control.buttonBehavior.holdToggle, !control.autoTapEnabled,
              !control.isAdvancedButton, !control.isLocalAction, !control.macroModeEnabled, !control.doubleTapRepeatEnabled,
              program.hasAnyOutput else { return false }
        return !(profile.turboEnabled && !program.containsLegacyWaitOrPulse)
    }
    private mutating func enterButton(contact: Int, control id: UUID, time: TimeInterval, recognizesTap: Bool = true) {
        guard let control = controls[id] else { return }
        var next = Contact(control: id)
        if control.doubleTapRepeatEnabled {
            if contacts.values.contains(where: { $0.control == id }) {
                next.suppressToggle = true
            } else if latchedControls.contains(id) {
                ordinaryLatchedControls.remove(id); repeatLatchedControls.remove(id)
                firstTapEnds[id] = nil; next.suppressToggle = true
            } else {
                if recognizesTap {
                    next.tapBeganAt = time
                    next.repeatTapCandidate = firstTapEnds[id].map { time - $0 <= 0.3 } ?? false
                }
                firstTapEnds[id] = nil
                if control.buttonBehavior.holdToggle {
                    next.holdDeadline = time + Double(control.buttonBehavior.holdMilliseconds) / 1000
                }
            }
        } else if control.macroModeEnabled {
            if !contacts.values.contains(where: { $0.control == id }), startMacro(id, at: time) {
                macroContacts[id] = contact
            }
        } else if control.autoTapEnabled {
            if !contacts.values.contains(where: { $0.control == id }) {
                if !ordinaryLatchedControls.insert(id).inserted { ordinaryLatchedControls.remove(id) }
            }
        } else if usesGlobalHold(id) {
            // All fingers on one instance share one logical activation. A second finger must not
            // toggle the latch established by the first; the next independent touch unlatches it.
            if !contacts.values.contains(where: { $0.control == id }) {
                if !ordinaryLatchedControls.insert(id).inserted {
                    ordinaryLatchedControls.remove(id); next.suppressToggle = true
                }
            }
        } else if usesHoldToggle(id) {
            if ordinaryLatchedControls.remove(id) != nil { suppressPendingHolds(for: id); next.suppressToggle = true }
            else if contacts.values.contains(where: { $0.control == id && $0.suppressToggle }) { next.suppressToggle = true }
            else { next.holdDeadline = time + Double(control.buttonBehavior.holdMilliseconds) / 1_000 }
        }
        contacts[contact] = next
        if !control.macroModeEnabled { noteAcceptedControl(id) }
    }
    /// A double tap must be consecutive on one surface. Only accepted new entries
    /// call this; moves and rejected competing touches leave the pending tap alone.
    private mutating func noteAcceptedControl(_ id: UUID) {
        firstTapEnds = firstTapEnds.filter { $0.key == id }
        for contact in contacts.keys where contacts[contact]?.control != id {
            contacts[contact]?.tapBeganAt = nil
            contacts[contact]?.repeatTapCandidate = false
        }
    }
    /// Two intentional quick DOWN/UP pairs arm repeat. Sliding and a long second touch
    /// cannot be mistaken for a double tap; cancellation never calls this path.
    private mutating func finishDoubleTapContact(_ contact: Int, at time: TimeInterval) {
        guard let source = contacts[contact], let id = source.control,
              let control = controls[id], control.doubleTapRepeatEnabled else { return }
        contacts[contact]?.holdDeadline = nil
        guard !source.suppressToggle, !latchedControls.contains(id),
              !contacts.contains(where: { $0.key != contact && $0.value.control == id }) else { return }
        if let due = source.holdDeadline, deadlineReached(due, at: time) {
            ordinaryLatchedControls.insert(id); firstTapEnds[id] = nil; return
        }
        guard let start = source.tapBeganAt, time - start <= 0.25 else { firstTapEnds[id] = nil; return }
        if source.repeatTapCandidate {
            firstTapEnds[id] = nil; repeatLatchedControls.insert(id)
            // End the second manual press before the first repeated press. Starting the
            // cycle in its OFF half guarantees a real gap even if the finger lifts late.
            stopRun(id, at: time); modifiedButtons.cancel(id)
        } else { firstTapEnds[id] = time }
    }
    @discardableResult
    private mutating func startMacro(_ id: UUID, at time: TimeInterval) -> Bool {
        guard !modifiedButtons.slots.contains(id), let program = programs[id] else { return false }
        noteAcceptedControl(id)
        // Admission follows advance(to:), so an expired macro whose timer was late
        // cannot skip centering on its next accepted activation.
        if controls[id]?.centerLeftStickBeforePress == true { recenterLeftStick() }
        modifiedButtons.start(id, program: program.macroProgram, at: time,
                              includePlain: true, completeOnRelease: true)
        return true
    }
    private mutating func finishMacroContact(_ contact: Int, at time: TimeInterval) {
        guard let id = contacts[contact]?.control, macroContacts[id] == contact else { return }
        modifiedButtons.end(id, at: time)
        macroContacts[id] = nil
    }
    private mutating func finishOrdinaryButtonSource(_ contact: Int, at time: TimeInterval) {
        guard let id = contacts[contact]?.control, let control = controls[id],
              control.kind == .button, !control.isAdvancedButton, !control.macroModeEnabled,
              !latchedControls.contains(id), accessibilityDeadlines[id] == nil,
              !contacts.contains(where: { $0.key != contact && $0.value.control == id }) else { return }
        modifiedButtons.end(id, at: time)
    }
    private mutating func suppressPendingHolds(for id: UUID) {
        for token in Array(contacts.keys) where contacts[token]?.control == id {
            contacts[token]?.holdDeadline = nil; contacts[token]?.suppressToggle = true
        }
    }
    private func validateTime(_ time: TimeInterval) throws {
        guard time.isFinite, time >= 0, lastTime.map({ time >= $0 }) ?? true else { throw ControllerInputError.invalidTime }
    }
    private mutating func advance(to time: TimeInterval, skipping: Set<UUID> = []) throws {
        try validateTime(time); lastTime = time
        modifiedButtons.advance(to: time); modifiedStages.advance(to: time)
        for (token, deadline) in buttonAccessibility where deadlineReached(deadline, at: time) {
            buttons.end(contact: token, time: deadline, cancelled: false); buttonAccessibility[token] = nil
        }
        try touchAims.advance(to:time)
        buttons.advance(to: time)
        touchpads.advance(to: time)
        for (id, deadline) in accessibilityDeadlines where deadlineReached(deadline, at: time) {
            if !skipping.contains(id) { advanceRun(id, to: deadline - max(1e-10, deadline.ulp * 2) * 2) }
            accessibilityDeadlines.removeValue(forKey: id)
        }
        detachedPulses = detachedPulses.filter { !deadlineReached($0.value.start + $0.value.duration, at: time) }
        var matured: [UUID: TimeInterval] = [:]
        for contact in contacts.values {
            if let id = contact.control, let deadline = contact.holdDeadline, deadlineReached(deadline, at: time) {
                matured[id] = min(matured[id] ?? deadline, deadline)
            }
        }
        for id in matured.keys { ordinaryLatchedControls.insert(id); firstTapEnds[id] = nil; suppressPendingHolds(for: id) }
        reconcileFixedStickClaims(at: time)
        synchronizeRuns(at: time, startingAt: matured)
        advanceRuns(to: time, skipping: skipping)
        for id in rings.keys.sorted(by: { first, second in
            let a = rings[first]?.nextDeadline ?? .infinity, b = rings[second]?.nextDeadline ?? .infinity
            return a == b ? first.uuidString < second.uuidString : a < b
        }) {
            let environment = ringEnvironment(excluding: id)
            rings[id]?.advance(to: time, environment: environment)
        }
    }
    private func activeButtonIDs() -> Set<UUID> {
        var active = latchedControls.union(accessibilityDeadlines.keys)
        for contact in contacts.values {
            if let id = contact.control, let control = controls[id], control.kind == .button,
               !control.autoTapEnabled, !usesHoldToggle(id), !usesGlobalHold(id),
               !(control.doubleTapRepeatEnabled && contact.suppressToggle) { active.insert(id) }
        }
        return active.filter { controls[$0]?.kind == .button && controls[$0]?.isLocalAction == false && controls[$0]?.isAdvancedButton == false && controls[$0]?.macroModeEnabled == false }
    }
    private mutating func synchronizeRuns(at time: TimeInterval, startingAt: [UUID: TimeInterval] = [:]) {
        let desired = activeButtonIDs()
        for id in Array(runs.keys) where !desired.contains(id) { stopRun(id, at: time) }
        for id in desired where runs[id] == nil {
            guard let control = controls[id], let program = programs[id] else { continue }
            let mode: RunMode = control.autoTapEnabled || repeatLatchedControls.contains(id) ? .autoTap :
                profile.turboEnabled && !control.doubleTapRepeatEnabled && !program.containsLegacyWaitOrPulse ? .turbo :
                latchedControls.contains(id) ? .latched : .ordinary
            var offset = 0.0, steps: [TimedStep] = []
            let legacySteps = program.hasModifiers ? [] : program.steps
            for step in legacySteps {
                if case let .wait(milliseconds) = step { offset += Double(milliseconds) / 1_000 }
                else { steps.append(.init(offset: offset, step: step)) }
            }
            let interval = Double(mode == .autoTap ? control.autoTapIntervalMilliseconds : profile.turboIntervalMilliseconds) / 1000
            let cadence: ModifiedPayloadRuntime<UUID>.Cycle?
            if mode == .turbo { cadence = .init(period: interval, width: min(0.1, interval - 0.005)) }
            else { cadence = nil }
            if mode != .autoTap {
                modifiedButtons.start(id, program: program, at: startingAt[id] ?? time, cycle: cadence,
                                      repeatsPulse: mode == .latched, includePlain: true, preserveAuthoredPulse: mode == .ordinary)
            }
            nextSerial &+= 1
            let start = repeatLatchedControls.contains(id) ? time - min(0.05, interval / 2) : (startingAt[id] ?? time)
            runs[id] = Run(serial: nextSerial, start: start, programStart: start, mode: mode,
                           interval: Double(mode == .autoTap ? control.autoTapIntervalMilliseconds : profile.turboIntervalMilliseconds) / 1_000, program: steps)
        }
    }
    private mutating func prepareCycle(_ id: UUID, at time: TimeInterval) {
        guard var run = runs[id], run.mode == .turbo || run.mode == .autoTap else { return }
        let result = cycle(run, at: time)
        guard result.on else { return }
        let index = floor((max(0, time - run.start) + max(1e-10, time.ulp * 2)) / run.interval)
        guard run.observedCycle != index else { return }
        let replay = run.observedCycle != nil
        fixedSticks.pause(owner: id)
        run.observedCycle = index; run.programStart = run.start + index * run.interval; run.cursor = 0
        if run.mode == .autoTap, let program = programs[id] {
            modifiedButtons.start(id, program: program, at: run.programStart, endsAt: run.programStart + min(0.05, run.interval / 2), includePlain: true)
        }
        run.digital.removeAll(); run.pressure.removeAll(); run.pulses.removeAll()
        run.keys.removeAll(); run.mouse.removeAll(); runs[id] = run
        // One observed new cycle may re-press, never replay every missed cycle.
        if replay { emitResolvedDesktop() }
    }
    private func isRetainedMacro(_ id: UUID) -> Bool {
        ordinaryLatchedControls.contains(id) && !contacts.values.contains { $0.control == id }
    }
    private mutating func reconcileFixedStickClaims(at time: TimeInterval) {
        for (id, run) in runs {
            if (run.mode == .turbo || run.mode == .autoTap) && !cycle(run, at: time).on {
                fixedSticks.pause(owner: id)
            } else { fixedSticks.setRetained(isRetainedMacro(id), owner: id) }
        }
        reconcileSustainedMacros(at: time)
    }
    private mutating func reconcileSustainedMacros(at time: TimeInterval) {
        synchronizeEdgeStageLatches()
        synchronizeModifiedStages(at: time)
        let selections = selectedStageDescriptors()
        let selected = Set(selections.map { $0.0 })
        macroStageLeases = macroStageLeases.filter { selected.contains($0.key) }
        for (key, program, order) in selections {
            if macroStageLeases[key] == nil {
                macroStageLeases[key] = .init(id: UUID(), control: key.control, program: program.unmodified,
                                            priority: 0, started: time, order: order)
            }
            macroStageLeases[key]?.retained = ordinaryRetainedSticks[key.control] != nil &&
                !contacts.values.contains { $0.control == key.control && $0.ownsStick }
        }
        let timed = modifiedButtons.slots.flatMap { id in
            modifiedButtons.macroLeases(for: id, control: id, at: time, priority: 0, retained: latchedControls.contains(id))
                .map { $0.suppressing(fixedSticks.rejectedChannels(owner: id)) }
        }
            + modifiedStages.slots.flatMap { key in modifiedStages.macroLeases(for: key, control: key.control, at: time, priority: 0, retained: ordinaryRetainedSticks[key.control] != nil) }
        let leases = timed + Array(macroStageLeases.values) + buttons.macroLeases(at: time) + touchAims.macroLeases(at: time) +
            rings.flatMap { $0.value.macroLeases(control: $0.key) }
        let occupied = occupiedManualChannels.union(buttons.occupiedChannels).union(touchAims.occupiedChannels).union(ringOccupiedChannels)
        let acquired = sustainedMacros.reconcile(leases, ledger: &fixedSticks, occupied: occupied)
        for channel in acquired {
            buttons.yieldRetained(channel: channel); yieldRetainedRings(channel: channel)
            ordinaryRetainedSticks = ordinaryRetainedSticks.filter { controls[$0.key]?.logicalStick != channel || controls[$0.key]?.isDirectional == true }
            retainedTravel = retainedTravel.filter { ordinaryRetainedSticks[$0.key] != nil }
        }
        if !acquired.isEmpty {
            // Taking a retained analog owner can also retire its old Stick+ stage. Reconcile
            // once more before publishing so its now-hidden macro cannot survive this frame.
            let surviving = Set(selectedStageDescriptors().map { $0.0 })
            if !selected.isSubset(of: surviving) {
                macroStageLeases = macroStageLeases.filter { surviving.contains($0.key) }
                _ = sustainedMacros.reconcile(timed + Array(macroStageLeases.values) + buttons.macroLeases(at: time) + touchAims.macroLeases(at: time) +
                    rings.flatMap { $0.value.macroLeases(control: $0.key) }, ledger: &fixedSticks, occupied: occupied)
            }
        }
    }
    private mutating func acquireFixedStick(_ macro: FixedStickMacro, owner id: UUID) {
        let occupied = occupiedManualChannels.union(buttons.occupiedChannels).union(touchAims.occupiedChannels).union(ringOccupiedChannels)
        let result = fixedSticks.request(owner: id, macro: macro, retained: isRetainedMacro(id), occupied: occupied)
        guard case .acquired = result else { return }
        let channel = macro.channel.control
        buttons.yieldRetained(channel: channel); yieldRetainedRings(channel: channel)
        ordinaryRetainedSticks = ordinaryRetainedSticks.filter { controls[$0.key]?.logicalStick != channel || controls[$0.key]?.isDirectional == true }
        retainedTravel = retainedTravel.filter { ordinaryRetainedSticks[$0.key] != nil }
    }
    private mutating func executeNextStep(_ id: UUID) {
        guard var run = runs[id], run.cursor < run.program.count else { return }
        let index = run.cursor, step = run.program[index]
        let start = run.programStart + step.offset
        switch step.step {
        case let .digital(action): run.digital.insert(action)
        case let .keyDown(key): run.keys.insert(key)
        case let .mouseDown(button): run.mouse.insert(button); noteCameraMouseOutput(id)
        case let .mouseUp(button): run.mouse.remove(button)
        case let .triggerPressure(channel, amount):
            run.pulses = run.pulses.filter { $0.value.channel != channel }
            run.pressure[channel] = amount
        case let .triggerPulse(channel, amount, duration):
            run.pressure.removeValue(forKey: channel)
            run.pulses = run.pulses.filter { $0.value.channel != channel }
            run.pulses[index] = .init(channel: channel, amount: amount, start: start, duration: duration, repeats: run.mode == .latched)
        case let .fixedStick(macro): acquireFixedStick(macro, owner: id)
        case .wait, .scrollModeToggle, .releaseAll, .cameraFollow, .autoCenter: break
        }
        run.cursor += 1; runs[id] = run
        // Resolve after every authored step so DOWN,UP survives a zero-duration click.
        emitResolvedDesktop()
    }
    private mutating func advanceRun(_ id: UUID, to time: TimeInterval) {
        prepareCycle(id, at: time)
        while let run = runs[id], run.cursor < run.program.count,
              deadlineReached(run.programStart + run.program[run.cursor].offset, at: time) {
            executeNextStep(id)
        }
    }
    private mutating func advanceRuns(to time: TimeInterval, skipping: Set<UUID> = []) {
        let ids = runs.keys.filter { !skipping.contains($0) }.sorted { runs[$0]!.serial < runs[$1]!.serial }
        for id in ids { prepareCycle(id, at: time) }
        // At most maximumControls * 64 authored steps. Stable order also covers equal deadlines.
        while let next = ids.filter({ id in
            guard let run = runs[id], run.cursor < run.program.count else { return false }
            return deadlineReached(run.programStart + run.program[run.cursor].offset, at: time)
        }).min(by: { lhs, rhs in
            let left = runs[lhs]!, right = runs[rhs]!
            let a = left.programStart + left.program[left.cursor].offset, b = right.programStart + right.program[right.cursor].offset
            return a == b ? left.serial < right.serial : a < b
        }) { executeNextStep(next) }
    }
    private mutating func stopRun(_ id: UUID, at time: TimeInterval) {
        modifiedButtons.end(id, at: time)
        fixedSticks.end(owner: id)
        guard let run = runs.removeValue(forKey: id), run.mode == .ordinary else { return }
        for (step, pulse) in run.pulses where !deadlineReached(pulse.start + pulse.duration, at: time) {
            let key = PulseKey(control: id, step: step)
            if (detachedPulses[key].map { $0.start + $0.duration } ?? 0) < pulse.start + pulse.duration { detachedPulses[key] = pulse }
        }
    }
    private mutating func settle(at time: TimeInterval) {
        reconcileFixedStickClaims(at: time)
        synchronizeRuns(at: time)
        advanceRuns(to: time)
        refreshState()
    }
    private func cycle(_ run: Run, at time: TimeInterval) -> (on: Bool, next: TimeInterval) {
        let interval = run.interval
        let width = run.mode == .autoTap ? min(0.05, interval / 2) : min(0.1, interval - 0.005)
        return phase(start: run.start, period: interval, width: width, at: time)
    }
    private func deadlineReached(_ deadline: TimeInterval, at time: TimeInterval) -> Bool {
        // Decimal millisecond intervals can accumulate a few binary floating-point ULPs.
        deadline <= time + max(1e-10, time.ulp * 2)
    }
    private func phase(start: TimeInterval, period: TimeInterval, width: TimeInterval,
                       at time: TimeInterval) -> (on: Bool, next: TimeInterval) {
        let elapsed = max(0, time - start)
        let count = floor((elapsed + max(1e-10, time.ulp * 2)) / period)
        let beginning = start + count * period
        let on = !deadlineReached(beginning + width, at: time)
        let next = on ? beginning + width : beginning + period
        return (on, next > time ? next : time.nextUp)
    }
    private func pulseStatus(_ pulse: Pulse, at time: TimeInterval) -> (on: Bool, next: TimeInterval?) {
        if pulse.repeats {
            let result = phase(start: pulse.start, period: pulse.duration, width: pulse.duration / 2, at: time)
            return (result.on && pulse.amount > 0, result.next)
        }
        let end = pulse.start + pulse.duration
        return (!deadlineReached(end, at: time) && pulse.amount > 0, !deadlineReached(end, at: time) ? end : nil)
    }
    /// The local command is an edge, never an output owner or a repeat clock.
    private mutating func performAutoCenter(_ command: AutoCenterCommand) {
        let enabled: Bool
        switch command {
        case .toggle: enabled = !allSticksAutoCenterEnabled
        case .enable: enabled = true
        case .disable: enabled = false
        }
        autoCenterOverride = enabled
        buttons.setAllAutoCenter(enabled)
        guard enabled else { return }
        let released = Set(ordinaryRetainedSticks.keys)
        ordinaryRetainedSticks.removeAll(); retainedTravel.removeAll()
        // End retained Stick+ immediately, including timed release tails. A finger
        // still controlling a stick retains its contact, output and edge latch.
        modifiedStages.cancel { released.contains($0.control) }
        liveModifiedStages = liveModifiedStages.filter { !released.contains($0.control) }
        macroStageLeases = macroStageLeases.filter { !released.contains($0.key.control) }
        stickStageRepeats = stickStageRepeats.filter { !released.contains($0.key.control) }
        edgeStageLatches = edgeStageLatches.filter { !released.contains($0.key.control) }
        sustainedMacros.remove(controls: released, ledger: &fixedSticks)
    }
    private func stageAxis(_ key: MacroStageKey, travel: StickTravel) -> Double {
        guard let control = controls[key.control] else { return 0 }
        let position: StickTravel
        if control.extendedBoost.enabled { position = travel }
        else if control.stickResponse.mode == .linear {
            let clamped = travel.clampedPosition
            position = .init(x: clamped.x * control.stickResponse.sensitivity, y: clamped.y * control.stickResponse.sensitivity)
        } else { position = StickTravel(travel.clampedPosition) }
        switch key.direction { case .up: return position.y; case .right: return position.x; case .down: return -position.y; case .left: return -position.x }
    }
    private func stageRearmThreshold(_ key: MacroStageKey, hysteresis: Double = 0.04) -> Double {
        guard let control = controls[key.control] else { return 0 }
        let custom = control.extendedBoost.enabled && control.extendedBoost.mode == .replaceThresholds ? control.extendedBoost.directions[key.direction] : nil
        let threshold: Double
        if key.stage == "outer" { threshold = control.extendedBoost.directions[key.direction]?.outerThreshold ?? 1 }
        else if key.stage == StickStage.superBoost.rawValue { threshold = custom?.superThreshold ?? control.stickBehavior.superBoostThreshold }
        else if key.stage == StickStage.boost.rawValue { threshold = custom?.regularThreshold ?? control.stickBehavior.boostThreshold }
        else { threshold = 0.1 }
        return max(0, threshold - hysteresis)
    }
    private mutating func synchronizeAutoCenterStages() {
        let travel = currentStickTravel()
        localStageLatches = localStageLatches.filter { key, threshold in
            guard let position = travel[key.control] else { return false }
            return stageAxis(key, travel: position) > threshold
        }
        // Deterministic order for simultaneous independent local actions.
        let order = Dictionary(uniqueKeysWithValues: profile.controls.enumerated().map { ($0.element.id, $0.offset) })
        let selected = selectedStageDescriptors().filter { $0.1.autoCenterCommand != nil }.sorted {
            let a = order[$0.0.control] ?? 0, b = order[$1.0.control] ?? 0
            return a == b ? $0.2 < $1.2 : a < b
        }
        for (key, program, _) in selected where localStageLatches[key] == nil {
            // A preceding On action may already have retired this retained owner.
            guard currentStickTravel()[key.control] != nil, let command = program.autoCenterCommand else { continue }
            localStageLatches[key] = stageRearmThreshold(key)
            performAutoCenter(command)
        }
    }
    private func currentStickTravel() -> [UUID: StickTravel] {
        var positions = retainedTravel
        for contact in contacts.values where contact.ownsStick {
            if let id = contact.control { positions[id] = contact.travel }
        }
        return positions
    }
    private func selectedStagePrograms() -> [(UUID, ControllerPayloadProgram)] {
        selectedStageDescriptors().map { ($0.0.control, $0.1.unmodified) }
    }
    private mutating func synchronizeModifiedStages(at time: Double) {
        let selected = selectedStageDescriptors().filter { $0.1.hasModifiers }
        let next = Set(selected.map { $0.0 })
        for key in liveModifiedStages.subtracting(next) { modifiedStages.end(key, at: time) }
        for (key, program, _) in selected where !liveModifiedStages.contains(key) {
            modifiedStages.start(key, program: program, at: time, resume: true)
        }
        liveModifiedStages = next
        modifiedStages.advance(to: time)
    }
    private func modifiedClaims(at time: Double) -> [UUID: GesturePayloadClaims] {
        var claims = modifiedButtons.claimsBySlot(at: time)
        for (key, stage) in modifiedStages.claimsBySlot(at: time) { claims[key.control, default: .init()].union(stage) }
        return claims
    }
    private mutating func synchronizeStickStageRepeats(at time: TimeInterval) {
        let selected = selectedStageDescriptors().filter { key, program, _ in
            guard let control = controls[key.control], control.stickBehavior.stickPlusEnabled,
                  !control.isDirectional, control.stickPlusRepeatIntervalMilliseconds != nil else { return false }
            return program.unmodified.steps.contains { if case .digital = $0 { true } else { false } }
        }
        let keys = Set(selected.map { $0.0 })
        // Departure wins before any due edge. Retained travel remains a selected owner.
        stickStageRepeats = stickStageRepeats.filter { keys.contains($0.key) }
        for (key, _, _) in selected {
            if stickStageRepeats[key] == nil {
                stickStageRepeats[key] = .init(milliseconds: controls[key.control]!.stickPlusRepeatIntervalMilliseconds!, at: time)
            } else { stickStageRepeats[key]?.advance(to: time) }
        }
    }
    private func rawStageDescriptors() -> [(MacroStageKey, ControllerPayloadProgram, Int)] {
        var selected: [(MacroStageKey, ControllerPayloadProgram, Int)] = []
        for (id, travel) in currentStickTravel() {
            guard let control = controls[id], control.isDirectional || control.stickBehavior.stickPlusEnabled else { continue }
            let behavior = control.stickBehavior, extended = control.extendedBoost
            let clamped = travel.clampedPosition
            let position: StickTravel
            if extended.enabled { position = travel }
            else if control.stickResponse.mode == .linear {
                position = .init(x: clamped.x * control.stickResponse.sensitivity, y: clamped.y * control.stickResponse.sensitivity)
            } else { position = StickTravel(clamped) }
            let axes: [(StickDirection, Double)] = [(.up, position.y), (.right, position.x), (.down, -position.y), (.left, -position.x)]
            for (order, pair) in axes.enumerated() where pair.1 > 0.1 {
                let (direction, amount) = pair
                func crosses(_ threshold: Double, program: ControllerPayloadProgram?) -> Bool {
                    amount > threshold || (amount == threshold && (control.stickPlusEdgeRearmHysteresis != nil || program?.autoCenterCommand != nil))
                }
                if extended.enabled, extended.mode == .addOuterStage,
                   let settings = extended.directions[direction], let program = outerPrograms[id]?[direction],
                   crosses(settings.outerThreshold, program: program) { selected.append((.init(control: id, direction: direction, stage: "outer"), program, order)); continue }
                let custom = extended.enabled && extended.mode == .replaceThresholds ? extended.directions[direction] : nil
                let regular = custom?.regularThreshold ?? behavior.boostThreshold
                let superBoost = custom?.superThreshold ?? behavior.superBoostThreshold
                let stage: StickStage = crosses(superBoost, program: stagePrograms[id]?[direction]?[.superBoost]) ? .superBoost : crosses(regular, program: stagePrograms[id]?[direction]?[.boost]) ? .boost : .normal
                if let program = stagePrograms[id]?[direction]?[stage] { selected.append((.init(control: id, direction: direction, stage: stage.rawValue), program, order)) }
            }
        }
        return selected
    }
    private func selectedStageDescriptors() -> [(MacroStageKey, ControllerPayloadProgram, Int)] {
        var selected = rawStageDescriptors()
        let travel = currentStickTravel()
        func rank(_ stage: String) -> Int { stage == "outer" ? 3 : stage == StickStage.superBoost.rawValue ? 2 : stage == StickStage.boost.rawValue ? 1 : 0 }
        for (key, value) in edgeStageLatches {
            guard let hysteresis = controls[key.control]?.stickPlusEdgeRearmHysteresis,
                  let position = travel[key.control], stageAxis(key, travel: position) > stageRearmThreshold(key, hysteresis: hysteresis) else { continue }
            let index = selected.firstIndex { $0.0.control == key.control && $0.0.direction == key.direction }
            if let index {
                // Moving outward into a higher stage still takes effect immediately.
                if rank(selected[index].0.stage) < rank(key.stage) { selected[index] = (key, value.0, value.1) }
            } else { selected.append((key, value.0, value.1)) }
        }
        return selected
    }
    private mutating func synchronizeEdgeStageLatches() {
        let selections = selectedStageDescriptors()
        edgeStageLatches = Dictionary(uniqueKeysWithValues: selections.compactMap { key, program, order in
            guard let hysteresis = controls[key.control]?.stickPlusEdgeRearmHysteresis, hysteresis > 0,
                  program.modifiers.contains(where: { $0.pressDurationMilliseconds != nil && $0.repeatMilliseconds == nil }) else { return nil }
            return (key, (program, order))
        })
    }
    private func desktopClaims() -> (keys: Set<KeyboardKey>, mouse: Set<PracticeMouseButton>) {
        let time = lastTime ?? 0
        let buttonClaims = buttons.claims(at: time)
        let touchClaims=touchAims.claims(at:time).claims
        var keys = buttonClaims.keys.union(touchClaims.keys), mouse = buttonClaims.mouse.union(touchClaims.mouse)
        for claims in modifiedClaims(at: time).values { keys.formUnion(claims.keys); mouse.formUnion(claims.mouse) }
        for ring in rings.values { keys.formUnion(ring.claims.keys); mouse.formUnion(ring.claims.mouse) }
        for run in runs.values where (run.mode != .turbo && run.mode != .autoTap) || cycle(run, at: time).on {
            keys.formUnion(run.keys); mouse.formUnion(run.mouse)
        }
        for (_, program) in selectedStagePrograms() {
            for step in program.steps {
                if case let .keyDown(key) = step { keys.insert(key) }
                if case let .mouseDown(button) = step { mouse.insert(button) }
            }
        }
        if !touchpads.leftOwners.isEmpty || transientPadClick != nil { mouse.insert(.left) }
        return (keys, mouse)
    }
    private mutating func appendEvent(_ kind: PracticeOutputEvent.Kind) {
        eventSequence &+= 1
        if eventQueue.count == Self.maximumUnreadPracticeEvents { eventQueue.removeFirst(); omittedEvents += 1 }
        eventQueue.append(.init(sequence: eventSequence, kind: kind))
    }
    private mutating func emitDesktopTransition(keys: Set<KeyboardKey>, mouse: Set<PracticeMouseButton>) {
        for key in resolvedKeys.subtracting(keys).sorted(by: { $0.rawValue < $1.rawValue }) { appendEvent(.keyUp(key)) }
        for button in resolvedMouse.subtracting(mouse).sorted(by: { $0.rawValue < $1.rawValue }) { appendEvent(.mouseUp(button)) }
        for key in keys.subtracting(resolvedKeys).sorted(by: { $0.rawValue < $1.rawValue }) { appendEvent(.keyDown(key)) }
        for button in mouse.subtracting(resolvedMouse).sorted(by: { $0.rawValue < $1.rawValue }) { appendEvent(.mouseDown(button)) }
        resolvedKeys = keys; resolvedMouse = mouse
    }
    private mutating func emitResolvedDesktop() {
        let claims = desktopClaims(); emitDesktopTransition(keys: claims.keys, mouse: claims.mouse)
    }
    private mutating func refreshState() {
        synchronizeAutoCenterStages()
        let time = lastTime ?? 0
        reconcileSustainedMacros(at: time)
        synchronizeStickStageRepeats(at: time)
        var active = latchedControls.union(accessibilityDeadlines.keys)
        var positions = retainedSticks
        for contact in contacts.values {
            guard let id = contact.control, let control = controls[id] else { continue }
            if contact.ownsStick { positions[id] = contact.travel.clampedPosition; active.insert(id) }
            else if control.kind == .recenter || (control.kind == .button && !control.autoTapEnabled && !usesHoldToggle(id) && !usesGlobalHold(id) && !(control.doubleTapRepeatEnabled && contact.suppressToggle)) { active.insert(id) }
        }
        active.formUnion(retainedSticks.keys)
        active.formUnion(touchpads.active)
        let buttonClaims = buttons.claims(at: time)
        active.formUnion(buttons.active); active.formUnion(buttons.latched)
        let touchClaims=touchAims.claims(at:time)
        active.formUnion(touchAims.active)
        var actions = buttonClaims.actions.union(touchClaims.claims.actions), producing = buttonClaims.producing.union(touchClaims.producing)
        var left = max(buttonClaims.pressure[.left] ?? 0,touchClaims.claims.pressure[.left] ?? 0), right = max(buttonClaims.pressure[.right] ?? 0,touchClaims.claims.pressure[.right] ?? 0)
        for (id, ring) in rings {
            let claims = ring.claims
            actions.formUnion(claims.actions); left = max(left, claims.pressure[.left] ?? 0); right = max(right, claims.pressure[.right] ?? 0)
            if ring.contact != nil || ring.state.retained { active.insert(id) }
            if claims.hasOutput { producing.insert(id) }
        }
        func addPressure(_ channel: TriggerChannel, _ amount: Double, owner: UUID) {
            if channel == .left { left = max(left, amount) } else { right = max(right, amount) }
            if amount > 0 { producing.insert(owner) }
        }
        for (id, claims) in modifiedClaims(at: time) {
            actions.formUnion(claims.actions)
            if claims.hasOutput { producing.insert(id) }
            if !claims.mouse.isEmpty { noteCameraMouseOutput(id) }
            for (channel, amount) in claims.pressure { addPressure(channel, amount, owner: id) }
        }
        for (id, run) in runs {
            guard (run.mode != .turbo && run.mode != .autoTap) || cycle(run, at: time).on else { continue }
            actions.formUnion(run.digital)
            if !run.digital.isEmpty || !run.keys.isEmpty || !run.mouse.isEmpty { producing.insert(id) }
            for (channel, amount) in run.pressure { addPressure(channel, amount, owner: id) }
            for pulse in run.pulses.values where pulseStatus(pulse, at: time).on { addPressure(pulse.channel, pulse.amount, owner: id) }
        }
        for (key, pulse) in detachedPulses where pulseStatus(pulse, at: time).on { addPressure(pulse.channel, pulse.amount, owner: key.control) }
        var output = GamepadState.neutral
        var leftAllowsCameraFollow = true
        for (id, position) in positions {
            guard let control = controls[id], let channel = control.logicalStick, !control.isDirectional else { continue }
            let response = control.stickResponse.applyValidated(position)
            if channel == .leftStick { output.leftStick = response; leftAllowsCameraFollow = !control.excludeFromCameraFollow } else { output.rightStick = response }
            if response != .zero { producing.insert(id) }
        }
        for (id, analog) in buttons.analogs {
            if analog.channel == .leftStick { output.leftStick = analog.position; leftAllowsCameraFollow = controls[id]?.excludeFromCameraFollow != true } else { output.rightStick = analog.position }
            positions[id] = analog.position
            if analog.retained { active.insert(id) }
        }
        for (id, analog) in touchAims.analogs {
            if analog.channel == .leftStick { output.leftStick=analog.position; leftAllowsCameraFollow = controls[id]?.excludeFromCameraFollow != true } else { output.rightStick=analog.position }
            positions[id]=analog.position
        }
        for (id, ring) in rings {
            for (candidate, movementLayer) in [(ring.movementAnalog, true), (ring.aimAnalog, false)] {
                guard let analog = candidate else { continue }
                if analog.channel == .leftStick {
                    output.leftStick = analog.position
                    leftAllowsCameraFollow = !movementLayer || !ring.geometry.config.movement.excludeFromCameraFollow
                } else { output.rightStick = analog.position }
                if analog.position != .zero { producing.insert(id) }
            }
        }
        for (channel, claim) in fixedSticks.claims {
            if channel == .left {
                output.leftStick = claim.position
                let owner = sustainedMacros.ownerControls[claim.owner] ?? claim.owner
                leftAllowsCameraFollow = controls[owner]?.excludeFromCameraFollow != true // Ring movement exclusion does not apply to its ADS/boost payload macros.
            } else { output.rightStick = claim.position }
            if claim.position != .zero { producing.insert(sustainedMacros.ownerControls[claim.owner] ?? claim.owner) }
        }
        for (key, program, _) in selectedStageDescriptors() {
            let id = key.control
            for step in program.unmodified.steps {
                switch step {
                case let .digital(action):
                    if stickStageRepeats[key]?.isOn != false { actions.insert(action); producing.insert(id) }
                case let .triggerPressure(channel, amount): addPressure(channel, amount, owner: id)
                case .keyDown, .mouseDown: producing.insert(id)
                case .fixedStick: break // Resolved by the shared first-live macro arbiter above.
                case .wait, .triggerPulse, .mouseUp, .scrollModeToggle, .releaseAll, .cameraFollow, .autoCenter: break // Rejected by stage validation.
                }
            }
        }
        producing.formUnion(touchpads.leftOwners)
        if actions.contains(.leftTrigger) { left = 1 }; if actions.contains(.rightTrigger) { right = 1 }
        output.buttons = Set(actions.compactMap(\.padButton))
        if left > 0 { output.buttons.insert(.leftTrigger) }; if right > 0 { output.buttons.insert(.rightTrigger) }
        let x = (actions.contains(.dpadRight) ? 1 : 0) - (actions.contains(.dpadLeft) ? 1 : 0)
        let y = (actions.contains(.dpadUp) ? 1 : 0) - (actions.contains(.dpadDown) ? 1 : 0)
        switch (x, y) {
        case (0, 1): output.dpad = .up; case (1, 1): output.dpad = .upRight
        case (1, 0): output.dpad = .right; case (1, -1): output.dpad = .downRight
        case (0, -1): output.dpad = .down; case (-1, -1): output.dpad = .downLeft
        case (-1, 0): output.dpad = .left; case (-1, 1): output.dpad = .upLeft
        default: break
        }
        for id in buttonClaims.mouseOwners.union(touchClaims.mouseOwners).union(touchpads.leftOwners) { noteCameraMouseOutput(id) }
        for (id, run) in runs where !run.mouse.isEmpty && ((run.mode != .turbo && run.mode != .autoTap) || cycle(run, at: time).on) { noteCameraMouseOutput(id) }
        for (id, program) in selectedStagePrograms() where program.steps.contains(where: { if case .mouseDown = $0 { true } else { false } }) { noteCameraMouseOutput(id) }
        let desktop = desktopClaims()
        emitDesktopTransition(keys: desktop.keys, mouse: desktop.mouse)
        state = output; practiceState = .init(gamepad: output, leftTrigger: left, rightTrigger: right,
                                             heldKeys: desktop.keys, heldMouseButtons: desktop.mouse,
                                             pointerOffset: pointerTotal, scrollOffset: scrollTotal, scrollModeEnabled: scrollMode)
        if allowCameraFollowPractice {
            // Generated RS is the lowest-priority Practice projection. Even a zero/retained
            // reservation keeps it out of a channel already owned by an actual control.
            let rightReserved = occupiedManualChannels.union(retainedManualChannels).union(buttons.occupiedChannels)
                .union(buttons.retainedChannels).union(touchAims.occupiedChannels).union(ringOccupiedChannels)
                .union(ringRetainedChannels).contains(.rightStick) || fixedSticks.claims[.right] != nil
            let rightMacro = fixedSticks.claims[.right]?.position ?? .zero
            let input = CameraFollowInputs(leftStick: output.leftStick, leftAllowsFollow: leftAllowsCameraFollow,
                manualRightStick: fixedSticks.claims[.right] == nil ? output.rightStick : .zero, macroRightStick: rightMacro,
                manualRightContactActive: rightReserved,
                mouseSuppressed: !cameraMouseOwners.isEmpty || rings.values.contains { $0.state.suppressed })
            do {
                try cameraFollow.updateInputs(input, at: time)
                if !rightReserved { practiceState.gamepad.rightStick = cameraFollow.snapshot.rightStick }
            } catch {
                // Validated inputs should make this unreachable; never publish stale assistance.
                try? cameraFollow.reset(at: time)
            }
        }
        activeControls = active; outputControls = producing; stickPositions = positions
        activeTouchpads = touchpads.active; lockedTouchpads = touchpads.locked; pendingTouchpadLocks = touchpads.pending
    }
}

private extension ProfileInputEngine {
    var ringOccupiedChannels: Set<ControllerControlID> { rings.values.reduce(into: []) { $0.formUnion($1.occupiedChannels) } }
    var ringRetainedChannels: Set<ControllerControlID> { rings.values.reduce(into: []) { $0.formUnion($1.retainedChannels) } }
    func ringID(contact: Int) -> UUID? { rings.first { $0.value.contact == contact }?.key }
    mutating func yieldRetainedRings(channel: ControllerControlID, except: UUID? = nil) {
        for id in rings.keys where id != except { rings[id]?.yieldRetained(channel: channel) }
    }
    func ringEnvironment(excluding id: UUID) -> FloatingRingEnvironment {
        let time = lastTime ?? 0
        var result = FloatingRingEnvironment(occupiedChannels: occupiedManualChannels.union(buttons.occupiedChannels).union(touchAims.occupiedChannels).union(fixedSticks.occupiedChannels))
        func keys(_ claims: GesturePayloadClaims) -> Set<RingOutputKey> {
            var keys = Set(claims.actions.map { action -> RingOutputKey in
                action == .leftTrigger ? .trigger(.left) : action == .rightTrigger ? .trigger(.right) : .digital(action)
            })
            keys.formUnion(claims.keys.map(RingOutputKey.key)); keys.formUnion(claims.mouse.map(RingOutputKey.mouse))
            keys.formUnion(claims.pressure.filter { $0.value > 0 }.keys.map(RingOutputKey.trigger))
            return keys
        }
        let advanced = buttons.claims(at: time)
        result.blockedPayloadKeys.formUnion(keys(.init(actions: advanced.actions, keys: advanced.keys, mouse: advanced.mouse, pressure: advanced.pressure)))
        result.blockedPayloadKeys.formUnion(keys(touchAims.claims(at: time).claims))
        for claims in modifiedClaims(at: time).values { result.blockedPayloadKeys.formUnion(keys(claims)) }
        for run in runs.values where (run.mode != .turbo && run.mode != .autoTap) || cycle(run, at: time).on {
            var claims = GesturePayloadClaims(actions: run.digital, keys: run.keys, mouse: run.mouse, pressure: run.pressure)
            for pulse in run.pulses.values where pulseStatus(pulse, at: time).on { claims.pressure[pulse.channel] = max(claims.pressure[pulse.channel] ?? 0, pulse.amount) }
            result.blockedPayloadKeys.formUnion(keys(claims))
        }
        for pulse in detachedPulses.values where pulseStatus(pulse, at: time).on { result.blockedPayloadKeys.insert(.trigger(pulse.channel)) }
        for (_, program) in selectedStagePrograms() { result.blockedPayloadKeys.formUnion(ringKeys(program.source).filter { if case .fixedStick = $0 { false } else { true } }) }
        if !touchpads.leftOwners.isEmpty { result.blockedPayloadKeys.insert(.mouse(.left)) }
        for (other, ring) in rings where other != id {
            result.occupiedChannels.formUnion(ring.occupiedChannels)
            // Analog macros use the shared channel arbiter; a blocked vector does not discard
            // independent digital outputs in a mixed ring payload.
            result.exclusivePayloadKeys.formUnion(ring.reservedKeys.filter { if case .fixedStick = $0 { false } else { true } })
            result.blockedPayloadKeys.formUnion(ring.reservedKeys.filter { if case .fixedStick = $0 { false } else { true } })
            result.blockedPayloadKeys.formUnion(ring.heldKeys.filter { if case .fixedStick = $0 { false } else { true } })
        }
        return result
    }
    mutating func consumeRingAnalogTakeovers(_ id: UUID) {
        guard let ring = rings[id] else { return }
        for channel in ring.occupiedChannels {
            fixedSticks.yieldRetained(channel: channel)
            buttons.yieldRetained(channel: channel)
            yieldRetainedRings(channel: channel, except: id)
            ordinaryRetainedSticks = ordinaryRetainedSticks.filter { controls[$0.key]?.logicalStick != channel || controls[$0.key]?.isDirectional == true }
            retainedTravel = retainedTravel.filter { ordinaryRetainedSticks[$0.key] != nil }
        }
    }
}

public extension ProfileInputEngine {
    /// Register before dispatching the first member Down, including a reveal-only summon.
    /// The canvas input epoch fences callbacks across profile/lifecycle replacement.
    @discardableResult
    mutating func registerFloatingButtonSession(zoneID: UUID, sessionID: UUID, at time: TimeInterval) throws -> Bool {
        try validateTime(time)
        guard let zone = profile.page(for: currentPageID)?.floatingButtonZones.first(where: { $0.id == zoneID }), zone.enabled,
              dismissedFloatingButtonSessions[zoneID] != sessionID else { return false }
        if let current = floatingButtonSessions[zoneID] { return current == sessionID }
        floatingButtonSessions[zoneID] = sessionID
        try advance(to: time); settle(at: time)
        return true
    }
    @discardableResult
    mutating func finishFloatingButtonSession(zoneID: UUID, sessionID: UUID, at time: TimeInterval) throws -> Bool {
        try validateTime(time)
        guard floatingButtonSessions[zoneID] == sessionID,
              let zone = profile.page(for: currentPageID)?.floatingButtonZones.first(where: { $0.id == zoneID }) else { return false }
        dismissFloatingButtonZone(zone)
        try advance(to: time); settle(at: time)
        return true
    }
    private mutating func dismissFloatingButtonZone(_ zone: FloatingButtonZone) {
        guard let session = floatingButtonSessions.removeValue(forKey: zone.id) else { return }
        dismissedFloatingButtonSessions[zone.id] = session
        releaseControls(Set(zone.memberIDs))
    }
    private mutating func performFloatingAction(_ binding: ProfileFloatingActionBinding) {
        switch binding.target {
        case let .control(id):
            guard binding.action == .endSuppression, controls[id] != nil, visibleControlIDs.contains(id) else { return }
            endCameraSuppression(for: id)
        case let .zone(id):
            guard let page = profile.page(for: currentPageID) else { return }
            if let zone = page.floatingButtonZones.first(where: { $0.id == id }), zone.enabled {
                if binding.action == .finish { dismissFloatingButtonZone(zone) }
            } else if let zone = page.floatingRingZones.first(where: { $0.id == id }), zone.enabled,
                      rings[id]?.state.visible == true {
                if binding.action == .finish { releaseControls([id]) }
                else { rings[id]?.localAction(binding.action) }
            }
        }
    }
    @discardableResult
    mutating func beginFloatingRing(contact: Int, zoneID: UUID, sessionID: UUID, point: FloatingPoint,
                                   usable: FloatingRect, at time: TimeInterval) throws -> Bool {
        try validateTime(time)
        guard point.isValid, usable.isValid else { throw ControllerInputError.invalidPosition }
        guard capturedControl(for: contact) == nil else { throw ControllerInputError.duplicateContact }
        guard let zone = profile.page(for: currentPageID)?.floatingRingZones.first(where: { $0.id == zoneID }), zone.enabled else { return false }
        reconcileFixedStickClaims(at: time)
        let initial: Bool
        if let existing = rings[zoneID], !existing.finished {
            guard existing.sessionID == sessionID else { return false }; initial = false
        } else {
            guard rings[zoneID]?.sessionID != sessionID else { return false }
            rings[zoneID] = try FloatingRingRuntime(config: zone.config, sessionID: sessionID, touch: point, usable: usable, finishIgnoresSwipes: zone.finishIgnoresSwipes)
            initial = true
        }
        let environment = ringEnvironment(excluding: zoneID)
        let accepted = rings[zoneID]!.begin(contact: contact, point: point, initial: initial, time: time, environment: environment)
        if accepted { noteAcceptedControl(zoneID) }
        consumeRingAnalogTakeovers(zoneID); try advance(to: time); settle(at: time)
        return accepted
    }
    mutating func moveFloatingRing(contact: Int, sessionID: UUID, samples: [FloatingRingSample], at time: TimeInterval) throws {
        try updateFloatingRing(contact: contact, sessionID: sessionID, samples: samples, ending: false, at: time)
    }
    mutating func endFloatingRing(contact: Int, sessionID: UUID, samples: [FloatingRingSample] = [], at time: TimeInterval) throws {
        try updateFloatingRing(contact: contact, sessionID: sessionID, samples: samples, ending: true, at: time)
    }
    private mutating func updateFloatingRing(contact: Int, sessionID: UUID, samples: [FloatingRingSample], ending: Bool, at time: TimeInterval) throws {
        try validateTime(time)
        guard let id = ringID(contact: contact), rings[id]?.sessionID == sessionID else { return }
        let environment = ringEnvironment(excluding: id)
        let movement = try rings[id]!.samples(contact: contact, samples: samples, ending: ending, now: time, environment: environment)
        for delta in movement { recordAimMovement(delta) }
        consumeRingAnalogTakeovers(id); try advance(to: time); settle(at: time)
    }
    mutating func cancelFloatingRing(contact: Int, sessionID: UUID, at time: TimeInterval) throws {
        try validateTime(time)
        guard let id = ringID(contact: contact), rings[id]?.sessionID == sessionID else { return }
        rings[id]?.cancel(); try advance(to: time); settle(at: time)
    }
    mutating func floatingRingAction(zoneID: UUID, sessionID: UUID, action: FloatingLocalAction, at time: TimeInterval) throws {
        try validateTime(time)
        guard rings[zoneID]?.sessionID == sessionID else { return }
        rings[zoneID]?.localAction(action); try advance(to: time); settle(at: time)
    }
    mutating func clearFloatingRingIssue(zoneID: UUID, sessionID: UUID) {
        guard rings[zoneID]?.sessionID == sessionID else { return }; rings[zoneID]?.clearIssue()
    }
}

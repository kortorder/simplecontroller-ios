import Foundation

public struct FloatingRingSample: Equatable, Sendable {
    public var point: FloatingPoint
    /// Seconds since this contact began, from the same monotonic source as its other samples.
    public var elapsed: Double
    public init(point: FloatingPoint, elapsed: Double) { self.point = point; self.elapsed = elapsed }
    public var isValid: Bool { point.isValid && elapsed.isFinite && (0...3600).contains(elapsed) }
}
public enum FloatingRingSlot: String, CaseIterable, Sendable { case ads, fire, boostOne, boostTwo, aimBoostOne, aimBoostTwo
    var stage: RingBoostStage? {
        switch self { case .boostOne, .aimBoostOne: .one; case .boostTwo, .aimBoostTwo: .two; default: nil }
    }
    var bank: RingBoostBank { self == .aimBoostOne || self == .aimBoostTwo ? .aim : .movement }
}
public struct FloatingRingState: Equatable, Sendable {
    public let sessionID: UUID
    public let geometry: FloatingRingGeometry
    public let placement: FloatingRingPlacement
    public let contact: Int?
    public let role: FloatingStartRole?
    public let visible: Bool
    public let retained: Bool
    public let finished: Bool
    public let movement: StickPosition
    public let aim: StickPosition?
    /// Live aim acquisition, including mouse outputs that have no analog position.
    public let aiming: Bool
    public let ads: Bool
    public let firing: Bool
    public let repeating: Bool
    public let armed: Bool
    public let pending: Bool
    public let busy: Bool
    public let suppressed: Bool
    public let fine: Bool
    public let boosts: Set<RingBoostStage>
    public let heldBoosts: Set<RingBoostStage>
    public let latchedBoosts: Set<RingBoostStage>
    public let boostBankStatus: [String]
    public let overridden: Set<FloatingRingSlot>
    public let issue: String?
    /// Actual target frames in canvas points; circle hit testing remains in geometry.knob(at:).
    public var knobFrames: [String: FloatingRect] {
        Dictionary(uniqueKeysWithValues: geometry.config.knobs.filter(\.enabled).map { knob in
            let center = geometry.knobCenter(knob), size = knob.targetDiameter
            return (knob.id, .init(x: placement.origin.x + center.x - size/2,
                                  y: placement.origin.y + center.y - size/2, width: size, height: size))
        })
    }
}

struct FloatingRingEnvironment: Sendable {
    var occupiedChannels: Set<ControllerControlID> = []
    var blockedPayloadKeys: Set<RingOutputKey> = []
    var exclusivePayloadKeys: Set<RingOutputKey> = []
}
struct FloatingRingAnalog: Sendable {
    var channel: ControllerControlID
    var position: StickPosition
    var retained: Bool
}

/// A value-owned surfaced ring. There are no callbacks or detached timers; the enclosing
/// engine validates/cancels a complete input packet before advancing its one-shot deadline.
struct FloatingRingRuntime: Sendable {
    struct Boost: Sendable {
        var inside = false
        var latched = false
        var direction: StickDirection?
        var pendingPayload = ""
        var sourceBank: RingBoostBank?
        var deadline: Double?
    }
    struct Aim: Sendable {
        var origin: ButtonPointerSample
        var last: ButtonPointerSample
        var smoothed: PointerDelta = .zero
        var centerOffset = FloatingPoint(x: 0, y: 0)
        var suspended = false
        var analog: FloatingRingAnalog?
    }
    let sessionID: UUID
    let geometry: FloatingRingGeometry
    let placement: FloatingRingPlacement
    private(set) var contact: Int?
    private(set) var finished = false
    private(set) var issue: String?
    private(set) var movementAnalog: FloatingRingAnalog?
    private var aimRuntime: Aim?
    private var aimActive = false
    private var macrosSuppressed = false
    private var suppressedMacroChannels: Set<FixedStickChannel> = []
    private var recenteredBoostBanks: Set<RingBoostBank> = []
    var aimAnalog: FloatingRingAnalog? { aimRuntime?.analog }
    private var role: FloatingStartRole?
    private var knobID: String?
    private var outputs: [FloatingRingSlot: FloatingRingOutput] = Dictionary(uniqueKeysWithValues: FloatingRingSlot.allCases.map { ($0, .init()) })
    private var boosts: [FloatingRingSlot: Boost] = Dictionary(uniqueKeysWithValues: FloatingRingSlot.allCases.filter { $0.stage != nil }.map { ($0, .init()) })
    private var bank: RingBoostBank = .movement
    private let finishIgnoresSwipes: Bool
    private var movementRecentered = false
    private var movementOffset = FloatingPoint(x: 0, y: 0)
    private var awaitingFirstAim = false
    private var earlyFireKnob: RingAimKnob?
    private var firingKnob: RingAimKnob? { earlyFireKnob ?? knob }
    private var overridden: Set<FloatingRingSlot> = []
    private var gesture: UInt64 = 0
    private var began: Double = 0
    private var elapsed: Double = 0
    private var lastPoint = FloatingPoint(x: 0, y: 0)
    private var applyGrabOffset = false
    private var finishGuard = FloatingFinishEntryGuard()
    private var previousOutputs: [FloatingRingSlot: (generation: UInt64, retained: Bool)] = [:]
    private var visited: Set<RingBoostStage> = []
    private var fineLatchSlots: Set<FloatingRingSlot> = []
    private var fineGesture = false
    private var insideAim = false
    private var armed = false
    private var fireEligible = false
    private var fireStopped = false
    private var adsStopped = false
    private var firedThisGesture = false
    private var releaseCancelled = false
    private var suppressed = false
    private var returnDeadline: Double?
    private var directOneUnlocked = false
    private var movementOverridden = false
    private var aimOverridden = false
    private var config: FloatingRingConfig { geometry.config }
    private var knob: RingAimKnob? { knobID.flatMap(config.knob) }
    private func slot(_ stage: RingBoostStage) -> FloatingRingSlot {
        if config.boostBanks?.enabled == true && bank == .aim { return stage == .one ? .aimBoostOne : .aimBoostTwo }
        return stage == .one ? .boostOne : .boostTwo
    }
    private var boostSlots: [FloatingRingSlot] {
        config.boostBanks?.enabled == true ? [.boostOne, .boostTwo, .aimBoostOne, .aimBoostTwo] : [.boostOne, .boostTwo]
    }
    private func boostStages(where predicate: (Boost, FloatingRingOutput) -> Bool) -> Set<RingBoostStage> {
        Set(boostSlots.compactMap { predicate(boosts[$0]!, outputs[$0]!) ? $0.stage : nil })
    }
    private var bankStatus: [String] {
        guard config.boostBanks?.enabled == true else { return [] }
        return boostSlots.compactMap { id in
            let boost = boosts[id]!, output = outputs[id]!
            guard boost.inside || boost.latched || boost.deadline != nil || output.hasReservation else { return nil }
            let status = boost.deadline != nil ? "pending" : output.repeating ? "repeating" : boost.latched ? "latched" : output.retained ? "retained" : output.held ? "held" : "active"
            return "\(id.bank == .aim ? "Aim" : "Movement") B\(id.stage == .one ? "1" : "2") \(status)"
        }
    }
    private var fine: Bool {
        config.aim.fine.enabled && (fineGesture || (config.aim.fine.persistWhileAdsLatched && fineLatchSlots.contains {
            boosts[$0]?.latched == true && outputs[$0]?.held == true
        }))
    }
    var state: FloatingRingState {
        .init(sessionID: sessionID, geometry: geometry, placement: placement, contact: contact, role: role,
              visible: !finished, retained: movementAnalog?.retained == true || aimAnalog?.retained == true || outputs.values.contains(where: \.retained),
              finished: finished, movement: movementAnalog?.position ?? .zero, aim: aimAnalog?.position, aiming: aimActive,
              ads: outputs[.ads]!.held || boostSlots.contains { boosts[$0]!.latched && outputs[$0]!.held && isADS(outputs[$0]!.payload) },
              firing: outputs[.fire]!.held, repeating: outputs[.fire]!.repeating, armed: armed,
              pending: returnDeadline != nil || boosts.values.contains { $0.deadline != nil }, busy: outputs.values.contains { $0.busy || $0.queued != nil },
              suppressed: suppressed, fine: fine,
              boosts: boostStages { $0.inside || $0.latched || $0.deadline != nil || $1.hasReservation },
              heldBoosts: boostStages { _, output in output.held },
              latchedBoosts: boostStages { $0.latched && $1.held },
              boostBankStatus: bankStatus, overridden: overridden, issue: issue)
    }
    var claims: GesturePayloadClaims {
        outputs.values.reduce(into: GesturePayloadClaims()) { $0.union($1.claims) }
    }
    func macroLeases(control: UUID) -> [SustainedMacroLease] {
        guard !macrosSuppressed else { return [] }
        return FloatingRingSlot.allCases.flatMap { slot in
            let priority: Int
            switch slot { case .ads: priority = 0; case .boostOne, .aimBoostOne: priority = 1; case .boostTwo, .aimBoostTwo: priority = 2; case .fire: priority = 3 }
            return (outputs[slot]?.macroLeases(control: control, priority: priority) ?? []).map { $0.suppressing(suppressedMacroChannels) }
        }
    }
    var reservedKeys: Set<RingOutputKey> { outputs.values.reduce(into: []) { $0.formUnion($1.exclusiveKeys) } }
    var heldKeys: Set<RingOutputKey> { outputs.values.filter(\.held).reduce(into: []) { $0.formUnion($1.keys) } }
    var occupiedChannels: Set<ControllerControlID> {
        Set([movementAnalog, aimAnalog].compactMap { $0?.retained == false ? $0?.channel : nil })
    }
    var retainedChannels: Set<ControllerControlID> {
        Set([movementAnalog, aimAnalog].compactMap { $0?.retained == true ? $0?.channel : nil })
    }
    var nextDeadline: Double? { (outputs.values.compactMap(\.deadline) + boosts.values.compactMap(\.deadline) + [returnDeadline].compactMap { $0 }).min() }

    init(config: FloatingRingConfig, sessionID: UUID, touch: FloatingPoint, usable: FloatingRect, finishIgnoresSwipes: Bool = false) throws {
        self.finishIgnoresSwipes = finishIgnoresSwipes
        geometry = try .init(config: config); self.sessionID = sessionID
        guard config.isActive, let placed = geometry.place(at: touch, usable: usable) else {
            throw FloatingControlError("The ring and its Finish target do not fit this canvas, or every ring layer is disabled.")
        }
        placement = placed
    }
    mutating func clearIssue() { issue = nil }
    mutating func begin(contact token: Int, point: FloatingPoint, initial: Bool, time: Double,
                        environment: FloatingRingEnvironment) -> Bool {
        guard !finished, contact == nil, point.isValid else { return false }
        observeOutputs(at: time)
        let physical = placement.local(point, applyGrabOffset: false)
        if !initial && geometry.finish.contains(physical) { finish(); return true }
        let selectedRole = initial ? config.startRole : geometry.role(at: physical)
        guard let selectedRole else { return false }
        let selectedKnob = initial ? config.knob(config.startKnobID) : geometry.knob(at: physical)
        gesture &+= 1; began = time; elapsed = 0; contact = token; role = selectedRole; bank = config.bank(for: selectedRole)
        movementRecentered = false; movementOffset = .init(x: 0, y: 0); earlyFireKnob = nil; awaitingFirstAim = false
        lastPoint = point; applyGrabOffset = initial; finishGuard = .init(initiallyInside: geometry.finish.contains(physical))
        previousOutputs = outputs.filter { $0.value.hasReservation }.mapValues { ($0.generation, $0.retained) }
        overridden = []; issue = nil; visited = []; fineGesture = false; directOneUnlocked = false
        movementOverridden = false; aimOverridden = false
        aimActive = false
        fireStopped = false; adsStopped = false; releaseCancelled = false; armed = false; fireEligible = false; firedThisGesture = false
        returnDeadline = nil
        let logical = placement.local(point, applyGrabOffset: initial); insideAim = geometry.insideAim(logical)
        switch selectedRole {
        case .movement:
            updateMovement(initial ? config.movement.initialPosition : geometry.movementVector(at: logical), environment: environment)
        case .aim:
            guard let selectedKnob, startAim(selectedKnob, physical: physical, directAddition: false, time: time, environment: environment) else {
                cancel(); return false
            }
        case .boostOne, .boostTwo:
            let stage: RingBoostStage = selectedRole == .boostOne ? .one : .two
            boosts[slot(stage)]!.inside = true
            if config.directBoostStartsAim, let destination = config.knob(config.directBoostAimKnobID), destination.enabled {
                fineGesture = config.aim.fine.enabled
                if startAim(destination, physical: physical, directAddition: true, time: time, environment: environment),
                   !insideAim && !config.aim.continueOutside { aimRuntime?.suspended = true }
            }
            enterBoost(stage, direction: geometry.boostDirection(at: logical), sampleTime: time, now: time, terminal: false, directTouch: true, environment: environment)
        }
        macrosSuppressed = false
        suppressedMacroChannels = []; recenteredBoostBanks = []
        return true
    }
    /// Validation has no effects. The complete Finish path is checked before output dispatch.
    mutating func samples(contact token: Int, samples: [FloatingRingSample], ending: Bool, now: Double,
                          environment: FloatingRingEnvironment) throws -> [PointerDelta] {
        guard contact == token, !finished else { return [] }
        guard samples.count <= 256 else { throw ControllerInputError.invalidPosition }
        var previous = elapsed
        for sample in samples {
            let local = placement.local(sample.point, applyGrabOffset: false)
            // UITouch timestamps and the enclosing callback clock share uptime but arrive
            // with different delivery latency. Match TouchAim's bounded 50 ms tolerance.
            guard sample.isValid, sample.elapsed >= previous, began + sample.elapsed <= now + 0.05,
                  abs(local.x) <= 65_536, abs(local.y) <= 65_536 else { throw ControllerInputError.invalidPosition }
            previous = sample.elapsed
        }
        var guardCopy = finishGuard
        if !finishIgnoresSwipes && samples.contains(where: { guardCopy.observe(inside: geometry.finish.contains(placement.local($0.point, applyGrabOffset: false))) }) {
            finish(); return []
        }
        finishGuard = guardCopy
        var movement: [PointerDelta] = []
        for (index, sample) in samples.enumerated() {
            observeOutputs(at: min(now, began + sample.elapsed))
            movement += observe(sample, terminal: ending && index == samples.count - 1, now: now, environment: environment)
            elapsed = sample.elapsed
        }
        observeOutputs(at: now)
        if ending { lift(now: now, environment: environment) }
        return movement
    }
    private mutating func observe(_ sample: FloatingRingSample, terminal: Bool, now: Double,
                                  environment: FloatingRingEnvironment) -> [PointerDelta] {
        let previous = placement.local(lastPoint, applyGrabOffset: applyGrabOffset)
        let logical = placement.local(sample.point, applyGrabOffset: applyGrabOffset)
        let physical = placement.local(sample.point, applyGrabOffset: false)
        lastPoint = sample.point
        let wasInside = insideAim; insideAim = geometry.insideAim(logical)
        let timing = knob?.fire.returnFire
        let restartEntry = wasInside && !insideAim && aimActive && timing?.enabled == true &&
            timing?.startOnBoostEntry == true && timing?.cancelOnExit == true && !awaitingFirstAim
        if restartEntry {
            returnDeadline = nil; if !fireEligible { armed = false }
        }
        if role == .movement {
            let relative = FloatingPoint(x: logical.x + movementOffset.x, y: logical.y + movementOffset.y)
            updateMovement(geometry.movementVector(at: relative), environment: environment)
        }
        let direct = role == .boostOne || role == .boostTwo
        if direct && !aimActive && config.directBoostToAim && insideAim && !terminal,
           let destination = config.knob(config.directBoostAimKnobID), destination.enabled {
            _ = startAim(destination, physical: physical, directAddition: true, time: now, environment: environment)
        }
        if participatesInBoosts {
            evaluateBoosts(point: logical, previous: previous, direct: direct, sampleTime: began + sample.elapsed,
                           now: now, terminal: terminal, environment: environment)
        }
        // Compact B1's exit hysteresis can overlap Aim. A new outward crossing
        // requalifies this clock without replaying the already-held boost action.
        if restartEntry && !terminal, let stage = RingBoostStage.allCases.first(where: {
            boosts[slot($0)]?.inside == true && timing?.qualifyingStages.contains($0) == true
        }) {
            startEntryFire(stage, sampleTime: began + sample.elapsed, now: now, environment: environment)
        }
        if aimActive {
            if wasInside && !insideAim { leaveAim(at: physical) }
            if (!wasInside && insideAim) || (direct && insideAim && !visited.isEmpty) {
                returnToAim(at: physical, sampleTime: began + sample.elapsed, now: now, terminal: terminal, environment: environment)
            }
            if config.aim.continueOutside || insideAim { return updateAim(at: physical) }
        }
        return []
    }
    private var participatesInBoosts: Bool {
        if recenteredBoostBanks.contains(bank) { return false }
        return switch role { case .movement: config.movement.participateInBoosts; case .aim: config.aim.participateInBoosts
        case .boostOne, .boostTwo: true; case nil: false }
    }
    private mutating func updateMovement(_ vector: StickPosition, environment: FloatingRingEnvironment) {
        guard !movementOverridden, let channel = config.movement.output.logicalStick else { return }
        if environment.occupiedChannels.contains(channel) || (aimAnalog?.channel == channel && aimAnalog?.retained == false) {
            movementAnalog = nil; movementOverridden = true; issue = "Another active control owns this movement stick."; return
        }
        if aimAnalog?.channel == channel && aimAnalog?.retained == true { aimRuntime = nil }
        if vector != .zero { movementRecentered = false }
        movementAnalog = .init(channel: channel, position: StickResponseSettings(mode: config.movement.response, sensitivity: config.movement.sensitivity).applyValidated(vector), retained: false)
    }
    private func aimSample(_ physical: FloatingPoint) -> ButtonPointerSample {
        let size = min(1200, max(1, config.innerRadius * 2))
        return .init(x: physical.x - geometry.center.x + size/2, y: physical.y - geometry.center.y + size/2, width: size, height: size)
    }
    private var effectiveTuning: ButtonAimTuning {
        var tuning = config.aim.tuning; if fine { tuning.sensitivity = config.aim.fine.sensitivity }; return tuning
    }
    private mutating func startAim(_ selected: RingAimKnob, physical: FloatingPoint, directAddition: Bool, time: Double,
                                   environment: FloatingRingEnvironment) -> Bool {
        guard !aimOverridden else { return false }
        if knobID != nil && knobID != selected.id { outputs[.fire]?.release(); outputs[.ads]?.release() }
        knobID = selected.id
        let tuning = effectiveTuning
        if let channel = tuning.output.logicalStick,
           environment.occupiedChannels.contains(channel) || (movementAnalog?.channel == channel && movementAnalog?.retained == false) {
            aimOverridden = true; issue = "Another active control owns this aim stick."; return false
        }
        let sample = aimSample(physical)
        aimRuntime = .init(origin: sample, last: sample)
        aimActive = true
        if let channel = tuning.output.logicalStick {
            if movementAnalog?.channel == channel && movementAnalog?.retained == true { movementAnalog = nil }
            aimRuntime?.analog = .init(channel: channel, position: .zero, retained: false)
            if directAddition && tuning.origin == .controlCenter {
                aimRuntime?.centerOffset = .init(x: sample.x - sample.width/2, y: sample.y - sample.height/2)
            }
            if !directAddition && tuning.origin == .controlCenter { _ = updateAim(at: physical) }
        }
        if config.aim.suppressCameraFollow && tuning.output.isMouse { suppressed = true }
        if !directAddition {
            if !adsStopped { hold(.ads, payload: selected.fire.adsPayload, environment: environment) }
            if !selected.fire.returnFire.enabled { activateFire(now: time, environment: environment) }
        }
        return true
    }
    private mutating func updateAim(at physical: FloatingPoint) -> [PointerDelta] {
        guard var aim = aimRuntime, !aim.suspended else { return [] }
        let sample = aimSample(physical), tuning = effectiveTuning
        defer { aim.last = sample; aimRuntime = aim }
        if let channel = tuning.output.logicalStick {
            guard aim.analog != nil else { return [] }
            var adjusted = sample; adjusted.x -= aim.centerOffset.x; adjusted.y -= aim.centerOffset.y
            aim.analog = .init(channel: channel, position: AimSurfaceMath.stick(sample: adjusted, origin: aim.origin, tuning: tuning), retained: false)
            return []
        }
        var dx = (sample.x - aim.last.x) * tuning.sensitivity
        var dy = (sample.y - aim.last.y) * tuning.sensitivity * (tuning.invertY ? -1 : 1)
        if tuning.mouseResponse == .smoothedNonlinear {
            dx = (dx + aim.smoothed.dx)/2; dy = (dy + aim.smoothed.dy)/2; aim.smoothed = .init(dx: dx, dy: dy)
            dx = AimSurfaceMath.mouseCurve(dx); dy = AimSurfaceMath.mouseCurve(dy)
        }
        return dx == 0 && dy == 0 ? [] : [.init(dx: dx, dy: dy)]
    }
    private mutating func leaveAim(at point: FloatingPoint) {
        guard let fire = knob?.fire else { return }
        if !config.aim.continueOutside {
            let sample = aimSample(point); aimRuntime?.suspended = true; aimRuntime?.last = sample
            aimRuntime?.smoothed = .zero; aimRuntime?.analog?.position = .zero
        }
        if fire.returnFire.enabled && fire.returnFire.cancelOnExit && !fire.returnFire.startOnBoostEntry { returnDeadline = nil; if !fireEligible { armed = false } }
        if !fire.continueADSOutside { outputs[.ads]?.release() }
        if !fire.continueFireOutside && (fire.mode == .hold || fire.mode == .repeat) { outputs[.fire]?.release() }
        if fire.mode == .releaseShot && fire.cancelReleaseShotOnBoundaryExit { releaseCancelled = true; armed = false }
    }
    private mutating func returnToAim(at point: FloatingPoint, sampleTime: Double, now: Double, terminal: Bool,
                                      environment: FloatingRingEnvironment) {
        guard let fire = knob?.fire else { return }
        if aimRuntime?.suspended == true {
            let sample = aimSample(point); aimRuntime?.origin = sample; aimRuntime?.last = sample
            aimRuntime?.smoothed = .zero; aimRuntime?.suspended = false
            if config.aim.tuning.origin == .controlCenter {
                aimRuntime?.centerOffset = .init(x: sample.x - sample.width/2, y: sample.y - sample.height/2)
            }
        }
        if config.aim.fine.enabled && !visited.isDisjoint(with: config.aim.fine.qualifyingStages) {
            fineGesture = true
            aimRuntime?.smoothed = .zero
            fineLatchSlots.formUnion(visited.intersection(config.aim.fine.qualifyingStages).map(slot).filter { boosts[$0]!.latched })
        }
        if releaseCancelled && fire.rearmReleaseShotOnBoundaryReturn {
            releaseCancelled = false; if fireEligible { armed = fire.mode == .releaseShot }
        }
        if !terminal && !fireStopped && fire.mode != .none && fire.returnFire.enabled &&
            !fire.returnFire.startOnBoostEntry && !visited.isDisjoint(with: fire.returnFire.qualifyingStages) && returnDeadline == nil {
            fireEligible = false; armed = false; firedThisGesture = false
            if fire.returnFire.delayMilliseconds == 0 { activateFire(now: now, environment: environment) }
            else { returnDeadline = sampleTime + Double(fire.returnFire.delayMilliseconds)/1000 }
        } else if !terminal && !fireStopped && returnDeadline == nil &&
                    ((fire.returnFire.enabled && fireEligible) || (!fire.returnFire.enabled && role == .aim && (fire.mode == .hold || fire.mode == .repeat))) {
            activateFire(now: now, environment: environment)
        }
        if !terminal && role == .aim && !fire.continueADSOutside && !adsStopped { hold(.ads, payload: fire.adsPayload, environment: environment) }
        awaitingFirstAim = false; visited = []
    }
    private mutating func activateFire(now: Double, environment: FloatingRingEnvironment) {
        guard !fireStopped, contact != nil, !finished, let fire = firingKnob?.fire else { return }
        fireEligible = true
        if !insideAim && !fire.continueFireOutside && fire.mode != .releaseShot { return }
        switch fire.mode {
        case .none: break
        case .hold: hold(.fire, payload: fire.firePayload, environment: environment)
        case .tap:
            if !firedThisGesture { firedThisGesture = true; pulse(.fire, payload: fire.firePayload, press: fire.pulsePressMilliseconds, gap: fire.pulseGapMilliseconds, now: now, environment: environment) }
        case .releaseShot: if !releaseCancelled { armed = true }
        case .repeat: repeatOutput(.fire, payload: fire.firePayload, press: fire.pulsePressMilliseconds, gap: fire.pulseGapMilliseconds, now: now, environment: environment)
        }
    }
    private mutating func evaluateBoosts(point: FloatingPoint, previous: FloatingPoint, direct: Bool, sampleTime: Double,
                                         now: Double, terminal: Bool, environment: FloatingRingEnvironment) {
        let selected: RingBoostStage = role == .boostOne ? .one : .two, distance = geometry.distance(to: point)
        let returning = role == .boostTwo && config.directBoostTwoToOne && config.boost(.one, bank: bank).enabled && !directOneUnlocked &&
            geometry.distance(to: previous) >= geometry.directBand(.two, bank: bank).lowerBound && distance < geometry.directBand(.two, bank: bank).lowerBound
        if returning { directOneUnlocked = true }
        func returningOne(_ stage: RingBoostStage) -> Bool { role == .boostTwo && directOneUnlocked && stage == .one }
        for stage in RingBoostStage.allCases.reversed() {
            if direct && stage != selected && !returningOne(stage) { continue }
            let settings = config.boost(stage, bank: bank), state = boosts[slot(stage)]!
            let inside = direct && !returningOne(stage) ? geometry.directHit(stage, at: point, bank: bank) : settings.enabled && distance >= geometry.boostDistance(stage, bank: bank) - (state.inside ? geometry.boostHysteresis(stage, bank: bank) : 0)
            if state.inside && !inside { boosts[slot(stage)]!.inside = false; exitBoost(stage) }
        }
        for stage in RingBoostStage.allCases {
            if direct && stage != selected && !returningOne(stage) { continue }
            let settings = config.boost(stage, bank: bank), crossed = returningOne(stage) && returning
            let enters = direct && !returningOne(stage) ? geometry.directHit(stage, at: point, bank: bank) : settings.enabled && geometry.enters(stage, distance: distance, bank: bank)
            let direction = geometry.boostDirection(at: crossed && !enters ? previous : point, previous: boosts[slot(stage)]!.direction)
            if !boosts[slot(stage)]!.inside && (enters || crossed) {
                boosts[slot(stage)]!.inside = true
                enterBoost(stage, direction: direction, sampleTime: sampleTime, now: now, terminal: terminal, environment: environment)
                if distance < geometry.boostDistance(stage, bank: bank) - geometry.boostHysteresis(stage, bank: bank) { boosts[slot(stage)]!.inside = false; exitBoost(stage) }
            } else if boosts[slot(stage)]!.inside && direction != boosts[slot(stage)]!.direction && boosts[slot(stage)]!.deadline == nil && !boosts[slot(stage)]!.latched {
                if settings.action != .tap { outputs[slot(stage)]?.release() }
                enterBoost(stage, direction: direction, sampleTime: sampleTime, now: now, terminal: terminal, environment: environment)
            }
        }
    }
    private mutating func enterBoost(_ stage: RingBoostStage, direction: StickDirection, sampleTime: Double, now: Double,
                                     terminal: Bool, directTouch: Bool = false, environment: FloatingRingEnvironment) {
        visited.insert(stage); boosts[slot(stage)]!.direction = direction
        guard !terminal else { return }
        startEntryFire(stage, sampleTime: sampleTime, now: now, environment: environment)
        guard boosts[slot(stage)]!.deadline == nil, !boosts[slot(stage)]!.latched,
              !outputs[slot(stage)]!.retained, !overridden.contains(slot(stage)) else { return }
        let settings = config.boost(stage, bank: bank), payload = settings.payload(for: direction), keys = ringKeys(payload)
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if fireStopped && config.knobs.contains(where: { !keys.isDisjoint(with: ringKeys($0.fire.firePayload)) }) { return }
        if adsStopped && (isADS(payload) || config.knobs.contains(where: { !keys.isDisjoint(with: ringKeys($0.fire.adsPayload)) })) { return }
        boosts[slot(stage)]!.sourceBank = bank
        if settings.activationDelayMilliseconds > 0 && !(directTouch && settings.skipDelayOnDirectTouch) {
            boosts[slot(stage)]!.pendingPayload = payload
            boosts[slot(stage)]!.deadline = sampleTime + Double(settings.activationDelayMilliseconds)/1000
        } else { activateBoost(stage, payload: payload, now: now, environment: environment) }
    }
    private mutating func startEntryFire(_ stage: RingBoostStage, sampleTime: Double, now: Double,
                                         environment: FloatingRingEnvironment) {
        let selected: RingAimKnob?
        switch role {
        case .aim: selected = knob
        case .boostOne, .boostTwo: selected = config.directBoostToAim || config.directBoostStartsAim ? config.knob(config.directBoostAimKnobID) : nil
        default: selected = nil
        }
        guard let selected, selected.enabled, selected.fire.mode != .none, !fireStopped,
              selected.fire.returnFire.enabled, selected.fire.returnFire.startOnBoostEntry,
              selected.fire.returnFire.qualifyingStages.contains(stage), returnDeadline == nil,
              !(fireEligible && awaitingFirstAim) else { return }
        if !aimActive { earlyFireKnob = selected }
        awaitingFirstAim = true; fireEligible = false; armed = false; firedThisGesture = false
        let delay = selected.fire.returnFire.delayMilliseconds
        if delay == 0 { activateFire(now: now, environment: environment) }
        else { returnDeadline = sampleTime + Double(delay)/1000 }
    }
    private mutating func activateBoost(_ stage: RingBoostStage, payload: String, now: Double, environment: FloatingRingEnvironment) {
        let settings = config.boost(stage, bank: bank), id = slot(stage)
        switch settings.action {
        case .tap: pulse(id, payload: payload, press: settings.pulsePressMilliseconds, gap: settings.pulseGapMilliseconds, now: now, environment: environment)
        case .hold:
            if boosts[slot(stage)]!.inside || settings.latchOnExit {
                hold(id, payload: payload, environment: environment); boosts[slot(stage)]!.latched = settings.latchOnExit && outputs[id]!.held
                if boosts[slot(stage)]!.latched && fineGesture && config.aim.fine.qualifyingStages.contains(stage) { fineLatchSlots.insert(slot(stage)) }
            }
        case .repeat:
            if boosts[slot(stage)]!.inside || settings.repeatAfterExit {
                repeatOutput(id, payload: payload, press: settings.pulsePressMilliseconds, gap: settings.pulseGapMilliseconds, now: now, environment: environment)
            }
        }
    }
    private mutating func exitBoost(_ stage: RingBoostStage) {
        let settings = config.boost(stage, bank: bank), id = slot(stage)
        if settings.cancelDelayOnExit { boosts[slot(stage)]!.deadline = nil; boosts[slot(stage)]!.pendingPayload = "" }
        if settings.action == .hold && !boosts[slot(stage)]!.latched && !outputs[id]!.retained { outputs[id]?.release() }
        if settings.action == .repeat && !settings.repeatAfterExit && !outputs[id]!.retained { outputs[id]?.release() }
    }
    private func isADS(_ payload: String) -> Bool {
        let keys = ringKeys(payload)
        return keys.contains(.trigger(.left)) || keys.contains(.mouse(.right))
    }
    private mutating func observeOutputs(at time: Double) {
        for id in FloatingRingSlot.allCases { outputs[id]?.observeTime(time) }
    }
    private mutating func stopOutput(_ id: FloatingRingSlot) { outputs[id]!.stop() }
    private mutating func failed(_ id: FloatingRingSlot) {
        overridden.insert(id); issue = "Another active output owns this ring action. Lift and start a new gesture to retry."
    }
    /// Exclusive edges cannot be masked by another bank's held action or its repeat gap.
    /// A new touch may take over a retained conflicting action; unrelated slots stay held.
    private mutating func acquire(_ id: FloatingRingSlot, keys: Set<RingOutputKey>, exclusive: Set<RingOutputKey>,
                                  environment: FloatingRingEnvironment) -> Bool {
        guard exclusive.isDisjoint(with: environment.blockedPayloadKeys),
              keys.isDisjoint(with: environment.exclusivePayloadKeys) else { return false }
        let conflicts = outputs.filter { slot, output in
            slot != id && (!exclusive.isDisjoint(with: output.keys) || !keys.isDisjoint(with: output.exclusiveKeys))
        }
        guard conflicts.values.allSatisfy(\.retained) else { return false }
        for slot in conflicts.keys {
            stopOutput(slot)
            if slot.stage != nil { boosts[slot] = Boost(); fineLatchSlots.remove(slot) }
        }
        return true
    }
    private mutating func hold(_ id: FloatingRingSlot, payload: String, environment: FloatingRingEnvironment) {
        guard !overridden.contains(id) else { return }
        let keys = ringKeys(payload)
        let fireKeys = config.knobs.reduce(into: Set<RingOutputKey>()) { $0.formUnion(ringKeys($1.fire.firePayload)) }
        let exclusive = id == .ads ? [] : id == .fire ? keys : keys.intersection(fireKeys)
        let permitted = acquire(id, keys: keys, exclusive: exclusive, environment: environment)
        if !outputs[id]!.hold(payload, gesture: gesture, exclusive: exclusive, permitted: permitted) { failed(id) }
    }
    private mutating func pulse(_ id: FloatingRingSlot, payload: String, press: Int, gap: Int, now: Double, environment: FloatingRingEnvironment) {
        guard !overridden.contains(id) else { return }
        let keys = ringKeys(payload)
        let permitted = acquire(id, keys: keys, exclusive: keys, environment: environment)
        if !outputs[id]!.pulse(payload, pressMilliseconds: press, gapMilliseconds: gap, gesture: gesture, now: now,
                              permitted: permitted) { failed(id) }
    }
    private mutating func repeatOutput(_ id: FloatingRingSlot, payload: String, press: Int, gap: Int, now: Double, environment: FloatingRingEnvironment) {
        guard !overridden.contains(id) else { return }
        let keys = ringKeys(payload)
        let permitted = acquire(id, keys: keys, exclusive: keys, environment: environment)
        if !outputs[id]!.repeatOutput(payload, pressMilliseconds: press, gapMilliseconds: gap, gesture: gesture, now: now,
                                     permitted: permitted) { failed(id) }
    }
    mutating func advance(to now: Double, environment: FloatingRingEnvironment) {
        guard !finished else { return }
        for id in FloatingRingSlot.allCases {
            let blocked = outputs.filter { $0.key != id }.values.reduce(into: environment.blockedPayloadKeys) { $0.formUnion($1.keys) }
            if !outputs[id]!.advance(to: now, permits: { $0.isDisjoint(with: blocked) }) { failed(id) }
        }
        guard contact != nil else { return }
        for stage in RingBoostStage.allCases {
            if let due = boosts[slot(stage)]!.deadline, now + 1e-10 >= due {
                let settings = config.boost(stage, bank: bank), payload = boosts[slot(stage)]!.pendingPayload
                boosts[slot(stage)]!.deadline = nil; boosts[slot(stage)]!.pendingPayload = ""
                if boosts[slot(stage)]!.inside || !settings.cancelDelayOnExit { activateBoost(stage, payload: payload, now: now, environment: environment) }
            }
        }
        if let due = returnDeadline, now + 1e-10 >= due {
            returnDeadline = nil
            if !fireStopped && (aimActive || earlyFireKnob != nil) && (awaitingFirstAim || insideAim || firingKnob?.fire.returnFire.cancelOnExit == false) { activateFire(now: now, environment: environment) }
        }
    }
    private mutating func lift(now: Double, environment: FloatingRingEnvironment) {
        guard contact != nil, !finished else { return }
        returnDeadline = nil
        for stage in RingBoostStage.allCases { boosts[slot(stage)]!.deadline = nil; boosts[slot(stage)]!.pendingPayload = "" }
        let fire = firingKnob?.fire
        if aimActive || earlyFireKnob != nil, let fire, fire.mode == .releaseShot && armed && !releaseCancelled && !fireStopped {
            pulse(.fire, payload: fire.firePayload, press: fire.pulsePressMilliseconds, gap: fire.pulseGapMilliseconds, now: now, environment: environment)
        }
        armed = false
        if role == .movement {
            if config.movement.autoCenter || movementRecentered { movementAnalog = nil } else { movementAnalog?.retained = true }
        }
        if aimActive {
            if config.aim.tuning.autoCenter || aimAnalog == nil { aimRuntime = nil } else { aimRuntime?.analog?.retained = true }
        }
        if aimActive || earlyFireKnob != nil {
            if let fire {
                if aimActive { outputs[.ads]!.retainOrRelease(fire.retainADSOnLift) }
                if fire.mode != .tap && fire.mode != .releaseShot { outputs[.fire]!.retainOrRelease(fire.retainFireOnLift) }
            }
        }
        for stage in RingBoostStage.allCases {
            let id = slot(stage), settings = config.boost(stage, bank: bank)
            if settings.action != .tap { outputs[id]!.retainOrRelease(settings.retainOnLift) }
            boosts[slot(stage)]!.latched = boosts[slot(stage)]!.latched && outputs[id]!.held; boosts[slot(stage)]!.inside = false
            if !boosts[slot(stage)]!.latched { fineLatchSlots.remove(slot(stage)) }
        }
        endPointer()
    }
    mutating func cancel() {
        guard contact != nil else { return }
        let cancelled = gesture; gesture &+= 1; returnDeadline = nil; armed = false
        for stage in RingBoostStage.allCases { boosts[slot(stage)]!.deadline = nil; boosts[slot(stage)]!.pendingPayload = ""; boosts[slot(stage)]!.inside = false }
        if aimActive { aimRuntime = nil }
        if role == .movement && movementAnalog?.retained != true { movementAnalog = nil }
        for id in FloatingRingSlot.allCases {
            let output = outputs[id]!, old = previousOutputs[id]
            if old?.generation != output.generation || output.activeGesture == cancelled { stopOutput(id) }
            else if let old, output.hasReservation { outputs[id]!.restoreRetained(old.retained, cancelQueuedFrom: cancelled) }
        }
        for stage in RingBoostStage.allCases {
            boosts[slot(stage)]!.latched = boosts[slot(stage)]!.latched && outputs[slot(stage)]!.held
            if !boosts[slot(stage)]!.latched { fineLatchSlots.remove(slot(stage)) }
        }
        endPointer()
    }
    private mutating func endPointer() { fineGesture = false; earlyFireKnob = nil; awaitingFirstAim = false; contact = nil; role = nil; aimActive = false; visited = []; previousOutputs = [:]; applyGrabOffset = false }
    mutating func finish() { finished = true; clear() }
    mutating func clear() {
        gesture &+= 1; returnDeadline = nil; armed = false; suppressed = false
        for id in FloatingRingSlot.allCases { stopOutput(id) }
        boosts = boosts.mapValues { _ in Boost() }; movementAnalog = nil; aimRuntime = nil; fineGesture = false; fineLatchSlots = []
        endPointer()
    }
    mutating func recenterMovement() {
        movementAnalog = nil
        if contact != nil && role == .movement {
            movementRecentered = true
            let here = placement.local(lastPoint, applyGrabOffset: applyGrabOffset)
            movementOffset = .init(x: geometry.center.x - here.x, y: geometry.center.y - here.y)
        }
    }
    mutating func recenter() {
        macrosSuppressed = true
        movementAnalog = nil; aimRuntime?.analog = nil; movementOverridden = true; aimOverridden = true
        for id in boostSlots { boosts[id]!.deadline = nil; boosts[id]!.pendingPayload = ""; boosts[id]!.latched = false; stopOutput(id) }
        fineLatchSlots = []; fineGesture = false
    }
    mutating func recenter(channel: FixedStickChannel) {
        suppressedMacroChannels.insert(channel)
        var stoppedBanks: Set<RingBoostBank> = []
        if config.movement.output.logicalStick == channel.control {
            movementAnalog = nil; movementOverridden = true; stoppedBanks.insert(.movement)
        }
        if config.aim.tuning.output.logicalStick == channel.control {
            aimRuntime?.analog = nil; aimOverridden = true; stoppedBanks.insert(.aim)
        }
        recenteredBoostBanks.formUnion(stoppedBanks)
        // Movement-derived sprint/jump latches stop with movement. ADS and fire owners
        // are separate slots and remain held, as does an independently aimed right stick.
        for id in boostSlots where boosts[id]?.sourceBank.map(stoppedBanks.contains) == true {
            boosts[id]!.inside = false; cancelBoost(id)
        }
    }
    mutating func yieldRetained(channel: ControllerControlID) {
        if movementAnalog?.channel == channel && movementAnalog?.retained == true { movementAnalog = nil; movementOverridden = true }
        if aimAnalog?.channel == channel && aimAnalog?.retained == true { aimRuntime = nil; aimOverridden = true }
    }
    mutating func localAction(_ action: FloatingLocalAction) {
        switch action {
        case .finish: finish()
        case .endSuppression: suppressed = false
        case .stopFire:
            fireStopped = true; fireEligible = false; armed = false; returnDeadline = nil; stopOutput(.fire)
            let keys = config.knobs.reduce(into: Set<RingOutputKey>()) { $0.formUnion(ringKeys($1.fire.firePayload)) }
            for id in boostSlots {
                let payloads = [boosts[id]!.pendingPayload, outputs[id]!.payload, outputs[id]!.queued?.payload ?? ""]
                if payloads.contains(where: { !ringKeys($0).isDisjoint(with: keys) }) { cancelBoost(id) }
            }
        case .releaseADS:
            adsStopped = true; stopOutput(.ads)
            let ads = ringKeys(knob?.fire.adsPayload ?? "")
            for id in boostSlots {
                let payloads = [boosts[id]!.pendingPayload, outputs[id]!.payload, outputs[id]!.queued?.payload ?? ""]
                if payloads.contains(where: { isADS($0) || !ringKeys($0).isDisjoint(with: ads) }) { cancelBoost(id) }
            }
            fineGesture = false; fineLatchSlots = []
        }
    }
    private mutating func cancelBoost(_ id: FloatingRingSlot) {
        boosts[id]!.deadline = nil; boosts[id]!.pendingPayload = ""; boosts[id]!.latched = false
        stopOutput(id); if fineLatchSlots.remove(id) != nil { fineGesture = false }
    }
}

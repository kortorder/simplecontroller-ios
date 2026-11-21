import Foundation

/// Captured TouchAim owners. Configuration is supplied explicitly so the detector/diagnostic
/// foundation can compile independently of native-profile version migration.
struct TouchAimRuntime: Sendable {
    enum Slot:Int,Hashable,Sendable { case aim,low,medium,high,shoot,pressLow,pressMedium,pressHigh,pressShoot
        var priority:Int { switch self { case .aim:0;case .low,.pressLow:1;case .medium,.pressMedium:2;case .high,.pressHigh:3;case .shoot,.pressShoot:4 } }
    }
    struct Analog:Sendable { var channel:ControllerControlID;var position:StickPosition }
    struct Session:Sendable {
        var contact:Int;var settings:TouchAimSettings;var detector:TouchAimDetector
        var origin:ButtonPointerSample;var pointer:ButtonPointerSample;var started:Double;var lastElapsed:Double
        var lastDetectorTick: Double = 0
        var previousMouse=PointerDelta.zero
        var leases:[Slot:OwnedGesturePayloadLease]=[:]
        var analog:Analog?
        var pressShootState: TouchAimState?
        var macrosSuppressed = false
    }
    private var settings:[UUID:TouchAimSettings]
    private struct StageOwner: Hashable, Sendable { let control: UUID; let slot: Slot }
    private var modified = ModifiedPayloadRuntime<StageOwner>()
    // Suppression survives finger-up while a modified stage still owns an HRD/SOR tail.
    private var suppressedMacroChannels: [UUID: Set<FixedStickChannel>] = [:]
    private var programs:[UUID:[Slot:ControllerPayloadProgram]]
    private(set) var contacts:[Int:UUID]=[:]
    private(set) var sessions:[UUID:Session]=[:]
    private(set) var issues:[UUID:String]=[:]
    private var takeovers:Set<ControllerControlID>=[]
    init(configurations:[UUID:TouchAimSettings])throws {
        guard configurations.count<=64 else { throw ControllerProfileError.tooManyControls }
        settings=configurations;programs=[:]
        for (id,c) in configurations {
            try c.validate()
            programs[id]=[.aim:try advancedButtonProgram(c.twoState.aimPayload),.shoot:try advancedButtonProgram(c.twoState.shootPayload),
                .low:try advancedButtonProgram(c.threeStage.low.payload),.medium:try advancedButtonProgram(c.threeStage.medium.payload),.high:try advancedButtonProgram(c.threeStage.high.payload)]
        }
    }
    var active:Set<UUID> { Set(contacts.values) }
    var states:[UUID:TouchAimState] { sessions.mapValues{$0.detector.state}.merging(issues.mapValues{_ in .unavailable},uniquingKeysWith:{_,new in new}) }
    var scores:[UUID:Double] { sessions.mapValues{$0.detector.filteredScore} }
    var analogs:[UUID:Analog] { sessions.compactMapValues(\.analog) }
    var occupiedChannels:Set<ControllerControlID> { Set(analogs.values.map(\.channel)) }
    mutating func consumeTakeovers()->Set<ControllerControlID> { let result=takeovers;takeovers=[];return result }
    mutating func clear() { sessions.removeAll();contacts.removeAll();issues.removeAll();takeovers=[];modified = .init();suppressedMacroChannels.removeAll() }
    mutating func clear(controls ids:Set<UUID>) {
        modified.cancel { ids.contains($0.control) }
        suppressedMacroChannels = suppressedMacroChannels.filter { !ids.contains($0.key) }
        let removedChannels=Set(sessions.filter { ids.contains($0.key) }.compactMap { $0.value.analog?.channel })
        sessions=sessions.filter { !ids.contains($0.key) };contacts=contacts.filter { !ids.contains($0.value) }
        issues=issues.filter { !ids.contains($0.key) };takeovers.subtract(removedChannels)
    }
    mutating func recenter() {
        modified.suppressMacros()
        // TouchAim's pointer remains captured; Re-center disables further analog output
        // until a new touch, while preserving this touch's independently owned payloads.
        for id in sessions.keys { sessions[id]?.analog=nil; sessions[id]?.macrosSuppressed = true }
    }
    mutating func recenter(channel: FixedStickChannel) {
        modified.suppressMacros(channel: channel)
        for id in sessions.keys {
            suppressedMacroChannels[id, default: []].insert(channel)
            if sessions[id]?.analog?.channel == channel.control { sessions[id]?.analog = nil }
        }
        takeovers.remove(channel.control)
    }
    mutating func begin(contact:Int,id:UUID,sample:TouchAimSample,time:Double,occupied:Set<ControllerControlID>,retained:Set<ControllerControlID>)throws->Bool {
        guard sample.isValid,sample.elapsed==0,time.isFinite,time>=0 else { throw ControllerInputError.invalidPosition }
        guard contacts[contact]==nil,!contacts.values.contains(id),let c=settings[id] else { return false }
        if let channel=c.aim.output.logicalStick,occupied.contains(channel) || occupiedChannels.contains(channel) { return false }
        var detector=try TouchAimDetector(settings:c)
        let actions=try detector.begin(metrics:sample.metrics,at:0)
        if let issue=detector.issue { issues[id]=issue;return false }
        issues[id]=nil
        suppressedMacroChannels[id] = nil
        var s=Session(contact:contact,settings:c,detector:detector,origin:sample.pointer,pointer:sample.pointer,started:time,lastElapsed:0)
        if let channel=c.aim.output.logicalStick {
            let initial=retained.contains(channel) ? AimSurfaceMath.stick(sample:sample.pointer,origin:sample.pointer,tuning:c.aim):.zero
            s.analog = .init(channel:channel,position:initial);takeovers.insert(channel)
        }
        apply(actions,to:&s,id:id,time:time)
        sessions[id]=s;contacts[contact]=id;return true
    }
    func validateBatch(contact:Int,samples:[TouchAimSample],time:Double)throws {
        guard time.isFinite,time>=0,samples.count<=256,samples.allSatisfy(\.isValid) else { throw ControllerInputError.invalidPosition }
        guard let id=contacts[contact],let s=sessions[id] else { return }
        var last=s.lastElapsed
        for sample in samples {
            guard sample.elapsed>=last,sample.elapsed<=max(0,time-s.started)+0.05 else { throw ControllerInputError.invalidTime }
            last=sample.elapsed
        }
    }
    /// The caller advances confirmation deadlines only after this complete batch is observed.
    mutating func move(contact:Int,samples:[TouchAimSample],time:Double)throws->[PointerDelta] {
        try validateBatch(contact:contact,samples:samples,time:time)
        guard let id=contacts[contact],var s=sessions[id] else { return [] }
        var movement:[PointerDelta]=[]
        for sample in samples {
            let actions=try s.detector.observe(metrics:sample.metrics,at:sample.elapsed,allowConfirmation:false)
            if let issue=s.detector.issue { issues[id]=issue;sessions[id]=nil;contacts[contact]=nil;modified.cancel { $0.control == id };return [] }
            apply(actions,to:&s,id:id,time:s.started+sample.elapsed)
            let tuning=currentTuning(s)
            if tuning.output.isMouse {
                let dx=(sample.pointer.x-s.pointer.x)*tuning.sensitivity
                let dy=(sample.pointer.y-s.pointer.y)*tuning.sensitivity*(tuning.invertY ? -1:1)
                if dx != 0 || dy != 0 {
                    var delta=PointerDelta(dx:dx,dy:dy)
                    if tuning.mouseResponse == .smoothedNonlinear {
                        s.previousMouse = .init(dx:dx*0.5+s.previousMouse.dx*0.5,dy:dy*0.5+s.previousMouse.dy*0.5)
                        delta = .init(dx:AimSurfaceMath.mouseCurve(s.previousMouse.dx),dy:AimSurfaceMath.mouseCurve(s.previousMouse.dy))
                    }
                    if abs(delta.dx)>=0.02 || abs(delta.dy)>=0.02 { movement.append(delta) }
                }
            } else if s.analog != nil { s.analog?.position=AimSurfaceMath.stick(sample:sample.pointer,origin:s.origin,tuning:tuning) }
            s.pointer=sample.pointer;s.lastElapsed=sample.elapsed
        }
        sessions[id]=s;return movement
    }
    mutating func end(contact:Int, at time:Double = 0, cancelled:Bool = true) {
        guard let id=contacts.removeValue(forKey:contact) else { return }
        if cancelled { modified.cancel { $0.control == id } }
        else {
            for owner in modified.slots where owner.control == id { modified.end(owner, at: time) }
        }
        // Pressure drops and normal lifts share one tail. A cancellation bypasses it.
        sessions[id]=nil
    }
    mutating func advance(to time:Double)throws {
        for id in Array(sessions.keys) {
            guard var s=sessions[id] else { continue }
            let elapsed=time-s.started
            guard elapsed>=0,elapsed<=3600 else { issues[id]="This touch exceeded the supported session duration. Lift and start again.";contacts[s.contact]=nil;sessions[id]=nil;modified.cancel { $0.control == id };continue }
            let priorState=s.detector.state
            let relativeDeadline = s.detector.nextDeadline
            let transitionTime = relativeDeadline.map { s.started + $0 } ?? time
            var detectorTime = max(elapsed, s.lastElapsed, s.lastDetectorTick)
            // Use the same absolute boundary we advertised to the app timer. Converting
            // it back by subtraction can otherwise leave the relative detector just short.
            if let relativeDeadline, GestureDeadline.reached(transitionTime, at: time) {
                detectorTime = max(detectorTime, relativeDeadline)
            }
            let actions = try s.detector.tick(at: detectorTime)
            s.lastDetectorTick = detectorTime
            // Finite presses belong to their confirmed deadline; a delayed callback must
            // not replay a press whose complete 90 ms lifetime has already elapsed.
            apply(actions,to:&s,id:id,time:min(time,transitionTime))
            if s.analog != nil && priorState != s.detector.state {
                let position=AimSurfaceMath.stick(sample:s.pointer,origin:s.origin,tuning:currentTuning(s))
                s.analog?.position=position
            }
            s.leases=s.leases.filter { $0.value.expires.map { !GestureDeadline.reached($0, at: time) } ?? true }
            sessions[id]=s
        }
        modified.advance(to: time)
    }
    func nextDeadline(after time:Double)->Double? {
        var due:[Double]=[modified.nextDeadline(after: time)].compactMap { $0 }
        for s in sessions.values {
            if let detector=s.detector.nextDeadline { due.append(s.started+detector) }
            due += s.leases.values.compactMap{$0.nextDeadline(after:time)}
        }
        return due.filter { $0.isFinite && !GestureDeadline.reached($0, at: time) }.min()
    }
    func macroLeases(at time: Double) -> [SustainedMacroLease] {
        let timed = modified.slots.filter { sessions[$0.control]?.macrosSuppressed != true }.flatMap { owner in
            modified.macroLeases(for: owner, control: owner.control, at: time, priority: owner.slot.priority, order: owner.slot.rawValue)
        }
        let leases = timed + sessions.flatMap { id, session in
            guard !session.macrosSuppressed, !session.settings.requiresLocalSetup else { return [SustainedMacroLease]() }
            return session.leases.compactMap { slot, lease in
                if let expires = lease.expires, GestureDeadline.reached(expires, at: time) { return nil }
                return .init(id: lease.activationID, control: id, program: lease.program,
                             priority: slot.priority, started: lease.started, order: slot.rawValue)
            }
        }
        return leases.map { $0.suppressing(suppressedMacroChannels[$0.control] ?? []) }
    }
    func claims(at time:Double)->(claims:GesturePayloadClaims,producing:Set<UUID>,mouseOwners:Set<UUID>) {
        var result=GesturePayloadClaims(),producing:Set<UUID>=[],mouseOwners:Set<UUID>=[]
        let timed = modified.claimsBySlot(at: time)
        let timedOwners = timed.keys
        let controlIDs = Set(sessions.keys).union(timedOwners.map(\.control))
        for id in controlIDs {
            let session = sessions[id]
            let timedSlots = timedOwners.filter { $0.control == id }.map(\.slot)
            let slots = Set(session?.leases.keys.map { $0 } ?? []).union(timedSlots)
            var own = GesturePayloadClaims()
            for slot in slots.sorted(by: { ($0.priority, $0.rawValue) < ($1.priority, $1.rawValue) }) {
                var stage = session?.leases[slot]?.claims(at: time) ?? .init()
                if let active = timed[.init(control: id, slot: slot)] { stage.union(active) }
                own.union(stage, overridePressure: true)
            }
            result.union(own)
            if !own.mouse.isEmpty { mouseOwners.insert(id) }
            if own.hasOutput || (session?.analog?.position ?? .zero) != .zero { producing.insert(id) }
        }
        return (result,producing,mouseOwners)
    }
    private func currentTuning(_ s:Session)->ButtonAimTuning {
        var tuning=s.settings.aim
        if s.detector.state == .shoot {
            tuning.sensitivity = s.settings.twoState.shootSensitivity
        } else if s.settings.mode == .manualThreeStage && !s.settings.requiresLocalSetup,
                  let sensitivity = s.settings.threeStage.tuning(for: s.detector.level).sensitivity {
            tuning.sensitivity = sensitivity
        }
        return tuning
    }
    private mutating func apply(_ actions:[TouchAimDetectorAction],to s:inout Session,id:UUID,time:Double) {
        guard !s.settings.requiresLocalSetup else { s.leases.removeAll(); return }
        func stageSlot(_ level:TouchAimLevel,press:Bool=false)->Slot {
            switch level { case .low:return press ? .pressLow:.low;case .medium:return press ? .pressMedium:.medium;case .high:return press ? .pressHigh:.high;case .aimOnly:return .aim }
        }
        func acquire(_ slot:Slot,program:Slot,expires:Double?=nil) {
            guard let source = programs[id]?[program] else { return }
            let owner = StageOwner(control: id, slot: slot)
            modified.start(owner, program: source, at: time, endsAt: expires, resume: expires == nil, includePlain: true, stagePress: expires != nil)
            s.leases[slot] = source.hasModifiers ? nil : OwnedGesturePayloadLease(program:source,started:time,expires:expires)
        }
        func release(_ slot: Slot) {
            modified.end(.init(control: id, slot: slot), at: time)
            s.leases[slot] = nil
        }
        for action in actions {
            switch action {
            case let .holdStage(level):acquire(stageSlot(level),program:stageSlot(level))
            case let .releaseStage(level):release(stageSlot(level))
            case let .pressStage(level):acquire(stageSlot(level,press:true),program:stageSlot(level),expires:time+0.09)
            case .holdAim:acquire(.aim,program:.aim)
            case .releaseAim:release(.aim)
            case .holdShoot:acquire(.shoot,program:.shoot)
            case .releaseShoot:release(.shoot)
            case .pressShoot:
                s.pressShootState = s.detector.state
                acquire(.pressShoot,program:.shoot,expires:time+0.09)
            }
        }
        // A PRESS stage's finite tap has its own duration. SOR and explicit repeats remain
        // tied to stage eligibility. Moving down into a PRESS stage must not re-arm it.
        let state = s.detector.state
        let carry = s.settings.threeStage.keepLowerHolds
        for (slot, eligible) in [(Slot.pressLow, state == .low || (carry && (state == .medium || state == .high))),
                                 (.pressMedium, state == .medium || (carry && state == .high)),
                                 (.pressHigh, state == .high), (.pressShoot, state == s.pressShootState)] where !eligible {
            modified.end(.init(control: id, slot: slot), at: time, preserveFinitePress: true)
        }
    }
}

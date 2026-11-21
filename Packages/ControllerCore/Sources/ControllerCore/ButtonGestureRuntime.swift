import Foundation

/// Deterministic, bounded owner leases for captured directional-button and Button Aim gestures.
/// No platform timer or receiver behavior is assumed by this model.
struct ButtonGestureRuntime: Sendable {
    enum Slot: Hashable, Sendable { case base, alternate, first, second }
    struct Lease: Sendable {
        let activationID = UUID()
        var program: ControllerPayloadProgram
        var start: Double
        var repeats = false
        var turboInterval: Double?
        var expires: Double?
    }
    struct DetachedPulse: Sendable { var value:Double; var expires:Double }
    struct Analog: Sendable { var channel: ControllerControlID; var position: StickPosition; var retained: Bool }
    struct Session: Sendable {
        var contact: Int?
        var origin: ButtonPointerSample
        var sample: ButtonPointerSample
        var phase: ButtonAlternatePhase = .base
        var resetReady = false
        var holdReady = false
        var selection = ButtonDirectionalSelection()
        var leases: [Slot: Lease] = [:]
        var modified = ModifiedPayloadRuntime<Slot>()
        var detachedPulses: [TriggerChannel:DetachedPulse] = [:]
        var latched = false
        var holdDeadline: Double?
        var resetDeadline: Double?
        var fireDeadline: Double?
        var finiteDeadline: Double?
        var unlatchDeadline: Double?
        var fireLatch = false
        var finishReturnsBase = false
        var boundaryCancelled = false
        var analog: Analog?
        var dpad: Set<ControllerControlID> = []
        var aimDeferred = false
        var aimSuppressed = false
        var previousMouse = PointerDelta.zero
        var visual: ButtonAimVisualState = .idle
        var suppressGesture = false
        var macrosSuppressed = false
        var suppressedMacroChannels: Set<FixedStickChannel> = []
        var directionalSuppressed = false
    }
    struct Claims: Sendable {
        var actions: Set<ControllerControlID> = []
        var keys: Set<KeyboardKey> = []
        var mouse: Set<PracticeMouseButton> = []
        var mouseOwners: Set<UUID> = []
        var pressure: [TriggerChannel: Double] = [:]
        var producing: Set<UUID> = []
    }
    private var controls: [UUID: ProfileControl]
    private var basePrograms: [UUID: ControllerPayloadProgram]
    private var alternatePrograms: [UUID: ControllerPayloadProgram]
    private var directionPrograms: [UUID: [StickDirection: [ControllerPayloadProgram]]]
    private var turboInterval: Double?
    private(set) var sessions: [UUID: Session] = [:]
    private(set) var contacts: [Int: UUID] = [:]
    private var feedback: [ButtonFeedback] = []
    private(set) var takeoverChannels: Set<ControllerControlID> = []
    init(profile: ControllerProfile) {
        let advanced = profile.controls.filter(\.isAdvancedButton)
        controls = Dictionary(uniqueKeysWithValues: advanced.map { ($0.id,$0) })
        basePrograms = Dictionary(uniqueKeysWithValues: advanced.map { ($0.id, try! $0.payloadProgram()) })
        alternatePrograms = Dictionary(uniqueKeysWithValues: advanced.map { ($0.id, try! advancedButtonProgram($0.buttonAim.alternate.payload)) })
        directionPrograms = Dictionary(uniqueKeysWithValues: advanced.map { control in
            (control.id, Dictionary(uniqueKeysWithValues: StickDirection.allCases.map { direction in
                let stage = control.buttonDirectional.directions[direction]!
                return (direction, [try! advancedButtonProgram(stage.firstPayload), try! advancedButtonProgram(stage.secondPayload)])
            }))
        })
        turboInterval = profile.turboEnabled ? Double(profile.turboIntervalMilliseconds)/1000 : nil
    }
    /// Runtime-only policy, kept outside the saved profile. Triggers and other button
    /// leases are independent from retained movement and must not be cancelled here.
    private var liveAutoCenterOverride: Bool?
    mutating func setAllAutoCenter(_ enabled: Bool) {
        liveAutoCenterOverride = enabled
        for id in controls.keys {
            if controls[id]?.buttonAim.tuning.output.logicalStick != nil {
                controls[id]?.buttonAim.tuning.autoCenter = enabled
            }
            if controls[id]?.buttonAim.alternate.tuning.output.logicalStick != nil {
                controls[id]?.buttonAim.alternate.tuning.autoCenter = enabled
            }
        }
        if enabled {
            for id in sessions.keys where sessions[id]?.contact == nil && sessions[id]?.analog?.retained == true {
                sessions[id]?.analog = nil
            }
        }
    }
    mutating func clear() { sessions.removeAll(); contacts.removeAll(); feedback.removeAll(); takeoverChannels.removeAll() }
    mutating func clear(controls ids: Set<UUID>) {
        let removedChannels = Set(sessions.filter { ids.contains($0.key) }.compactMap { $0.value.analog?.channel })
        sessions = sessions.filter { !ids.contains($0.key) }; contacts = contacts.filter { !ids.contains($0.value) }
        feedback.removeAll { ids.contains($0.control) }; takeoverChannels.subtract(removedChannels)
    }
    mutating func drainFeedback() -> [ButtonFeedback] { let result=feedback; feedback.removeAll(keepingCapacity:true); return result }
    mutating func consumeTakeovers() -> Set<ControllerControlID> { let result=takeoverChannels; takeoverChannels.removeAll(); return result }
    var active: Set<UUID> { Set(contacts.values) }
    var latched: Set<UUID> { Set(sessions.filter { $0.value.latched }.keys) }
    var visuals: [UUID:ButtonAimVisualState] { sessions.filter { controls[$0.key]?.buttonAim.enabled == true }.mapValues(\.visual) }
    var phases: [UUID:ButtonAlternatePhase] { sessions.mapValues(\.phase) }
    var selections: [UUID:ButtonDirectionalSelection] { sessions.mapValues(\.selection) }
    var analogs: [UUID:Analog] { sessions.compactMapValues(\.analog) }
    var occupiedChannels: Set<ControllerControlID> { Set(sessions.values.compactMap { s in s.analog.flatMap { $0.retained ? nil : $0.channel } }) }
    var retainedChannels: Set<ControllerControlID> { Set(sessions.values.compactMap { $0.analog?.retained == true ? $0.analog?.channel : nil }) }
    mutating func yieldRetained(channel: ControllerControlID, except id: UUID? = nil) {
        for key in sessions.keys where key != id && sessions[key]?.analog?.channel == channel && sessions[key]?.analog?.retained == true { sessions[key]?.analog=nil }
    }
    mutating func recenter() {
        for id in sessions.keys {
            sessions[id]?.macrosSuppressed = true
            sessions[id]?.modified.suppressMacros()
            guard sessions[id]?.analog != nil || tuning(for:id)?.output.logicalStick != nil else { continue }
            sessions[id]?.analog=nil; sessions[id]?.aimDeferred=false; sessions[id]?.aimSuppressed=true
        }
    }
    mutating func recenter(channel: FixedStickChannel) {
        for id in sessions.keys {
            sessions[id]?.suppressedMacroChannels.insert(channel)
            sessions[id]?.modified.suppressMacros(channel: channel)
            guard sessions[id]?.analog?.channel == channel.control || tuning(for: id)?.output.logicalStick == channel.control else { continue }
            sessions[id]?.analog = nil
            sessions[id]?.aimDeferred = false
            sessions[id]?.aimSuppressed = true
            sessions[id]?.directionalSuppressed = true
            sessions[id]?.selection = .init()
            for slot in [Slot.first, .second] {
                sessions[id]?.modified.cancel(slot); sessions[id]?.leases[slot] = nil
            }
        }
        takeoverChannels.remove(channel.control)
    }
    private func tuning(for id:UUID) -> ButtonAimTuning? {
        guard let c=controls[id], c.buttonAim.enabled else { return nil }
        return sessions[id]?.phase == .base ? c.buttonAim.tuning : c.buttonAim.alternate.tuning
    }
    private func timing(_ c:ProfileControl, _ s:Session) -> ButtonAimPayloadTiming {
        s.phase == .base ? c.buttonAim.payloadTiming : c.buttonAim.alternate.payloadTiming
    }
    private mutating func cue(_ id:UUID,_ kind:ButtonFeedback.Kind) {
        guard tuning(for:id)?.hapticsEnabled == true else { return }
        if feedback.count == 64 { feedback.removeFirst() }; feedback.append(.init(control:id,kind:kind))
    }
    /// Returns false for a second finger or an occupied analog channel; no claim is stolen.
    mutating func begin(contact:Int,id:UUID,sample:ButtonPointerSample,time:Double,
                        occupied:Set<ControllerControlID>,retained:Set<ControllerControlID>) -> Bool {
        guard let c=controls[id], !contacts.values.contains(id) else { return false }
        var s=sessions[id] ?? Session(origin:sample,sample:sample)
        s.macrosSuppressed = false
        s.suppressedMacroChannels = []
        s.directionalSuppressed = false
        // A new direct touch cancels a pending delayed Base, or completes a previous finite Alternate.
        if s.fireDeadline != nil { cancelState(&s, alternate:false) }
        if s.finiteDeadline != nil || s.unlatchDeadline != nil { completeAlternate(&s, control:c, time:time, immediate:true) }
        if c.buttonAim.enabled && s.phase == .base && s.latched {
            s.modified.end(.base, at: time)
            s.latched=false; s.leases[.base]=nil; s.suppressGesture=true
            s.contact=contact; s.origin=sample; s.sample=sample; s.visual = .idle
            sessions[id]=s; contacts[contact]=id; return true
        }
        let tune = s.phase == .base ? c.buttonAim.tuning : c.buttonAim.alternate.tuning
        let retainedElsewhereOnSurface = s.analog.map { $0.retained && $0.channel != tune.output.logicalStick } ?? false
        let shouldDefer = !tune.autoCenter || retainedElsewhereOnSurface || tune.output.logicalStick.map { retained.contains($0) } == true
        if c.buttonAim.enabled, let channel=tune.output.logicalStick, !shouldDefer,
           occupied.contains(channel) || sessions.contains(where: { $0.key != id && $0.value.analog?.channel == channel && $0.value.analog?.retained == false }) { return false }
        s.contact=contact; s.origin=sample; s.sample=sample; s.selection = .init(); s.previousMouse = .zero
        s.boundaryCancelled=false; s.resetReady=false; s.holdReady=false; s.suppressGesture=false; s.aimSuppressed=false
        s.holdDeadline=nil; s.resetDeadline=nil; s.aimDeferred=false
        if c.buttonAim.enabled {
            // Starting the shared mouse aim session ends this surface's old retained stick.
            // D-pad has a separate session and does not touch that retained analog owner.
            if tune.output.isMouse { s.analog=nil }
            if let channel=tune.output.logicalStick {
                s.aimDeferred = shouldDefer
                if !s.aimDeferred { s.analog = .init(channel:channel,position:.zero,retained:false); takeoverChannels.insert(channel) }
            }
            if s.phase == .base {
                let base = basePrograms[id]!
                if base.hasModifiers {
                    let turbo = turboInterval.flatMap { interval -> ModifiedPayloadRuntime<Slot>.Cycle? in
                        guard c.buttonAim.payloadTiming == .immediate && !c.buttonDirectional.enabled && !base.containsLegacyWaitOrPulse else { return nil }
                        return .init(period: interval, width: min(0.1, interval - 0.005))
                    }
                    s.modified.start(.base, program: base, at: time, inheritedRelease: c.buttonAim.payloadTiming == .sendOnRelease,
                                     releaseDelay: Double(c.buttonAim.releaseDelayMilliseconds)/1000, cycle: turbo, includePlain: true, preserveAuthoredPulse: true)
                    s.visual = .aiming
                } else if c.buttonAim.payloadTiming == .immediate {
                    s.leases[.base] = Lease(program:basePrograms[id]!,start:time,turboInterval:c.buttonDirectional.enabled || basePrograms[id]!.containsLegacyWaitOrPulse ? nil:turboInterval)
                    s.visual = .aiming
                } else { s.visual = .armed }
                if c.buttonBehavior.holdToggle && !(c.buttonAim.payloadTiming == .immediate && turboInterval != nil && !c.buttonDirectional.enabled && !basePrograms[id]!.containsLegacyWaitOrPulse) {
                    s.holdDeadline=time+Double(c.buttonBehavior.holdMilliseconds)/1000
                }
            } else {
                s.resetDeadline=time+Double(c.buttonAim.alternate.resetHoldMilliseconds)/1000
                if alternatePrograms[id]!.hasModifiers {
                    s.modified.start(.alternate, program: alternatePrograms[id]!, at: time, inheritedRelease: c.buttonAim.alternate.payloadTiming == .sendOnRelease, includePlain: true)
                    s.visual = .alternateAiming
                } else if c.buttonAim.alternate.payloadTiming == .immediate { s.leases[.alternate]=Lease(program:alternatePrograms[id]!,start:time); s.visual = .alternateAiming }
                else { s.visual = .alternateWaitingToFire }
            }
        } else {
            let base = basePrograms[id]!
            s.modified.start(.base, program: base, at: time)
            s.leases[.base] = Lease(program: base.unmodified, start:time); s.visual = .aiming
        }
        sessions[id]=s; contacts[contact]=id
        _ = move(contact:contact,samples:[sample],time:time,occupied:occupied)
        cue(id,.engaged); return true
    }
    /// Observes every sample and cancellation boundary before any external timer advances.
    mutating func move(contact:Int,samples:[ButtonPointerSample],time:Double,occupied:Set<ControllerControlID>) -> [PointerDelta] {
        guard let id=contacts[contact],let c=controls[id],var s=sessions[id],!s.suppressGesture else { return [] }
        var motion:[PointerDelta]=[]
        let tune=s.phase == .base ? c.buttonAim.tuning : c.buttonAim.alternate.tuning
        for sample in samples {
            let activeProgram = s.phase == .base ? basePrograms[id]! : alternatePrograms[id]!
            let boundaryUsesRelease = activeProgram.hasModifiers ?
                activeProgram.modifiers.contains { $0.timing == .sendOnRelease || ($0.timing == nil && timing(c,s) == .sendOnRelease) } :
                timing(c,s) == .sendOnRelease
            if c.buttonAim.enabled && c.buttonAim.cancelOnBoundaryExit && boundaryUsesRelease {
                let was=s.boundaryCancelled
                if !sample.isInside { s.boundaryCancelled=true }
                else if c.buttonAim.rearmOnBoundaryReturn { s.boundaryCancelled=false }
                if !was && s.boundaryCancelled { s.holdDeadline=nil; s.resetDeadline=nil; s.resetReady=false; s.holdReady=false; s.visual = s.phase == .base ? .aiming : .alternateAiming }
                if was && !s.boundaryCancelled {
                    if s.phase == .base {
                        if c.buttonBehavior.holdToggle { s.holdDeadline=time+Double(c.buttonBehavior.holdMilliseconds)/1000 }
                        s.visual = .armed
                    } else { s.resetDeadline=time+Double(c.buttonAim.alternate.resetHoldMilliseconds)/1000; s.visual = .alternateWaitingToFire }
                }
            }
            if c.buttonDirectional.enabled && !s.directionalSuppressed {
                let next=try! c.buttonDirectional.selection(dx:sample.x-s.origin.x,dy:sample.y-s.origin.y,previous:s.selection)
                if next != s.selection {
                    let changed=next.direction != s.selection.direction
                    for (slot,stage) in [(Slot.first,1),(.second,2)] {
                        if next.stage < stage { s.modified.end(slot, at: time); s.leases[slot]=nil }
                        else if changed || s.selection.stage < stage,let direction=next.direction {
                            let program = directionPrograms[id]![direction]![stage-1]
                            s.modified.end(slot, at: time)
                            s.modified.start(slot, program: program, at: time)
                            s.leases[slot]=Lease(program:program.unmodified,start:time)
                        }
                    }
                    s.selection=next
                }
            }
            if c.buttonAim.enabled && !s.aimSuppressed {
                if s.aimDeferred, let channel=tune.output.logicalStick,
                   hypot(sample.x-s.origin.x,sample.y-s.origin.y) > 8, !occupied.contains(channel), !sessions.contains(where: { $0.key != id && $0.value.analog?.channel == channel && $0.value.analog?.retained == false }) {
                    s.analog = .init(channel:channel,position:.zero,retained:false); s.aimDeferred=false
                    takeoverChannels.insert(channel)
                }
                if tune.output.isMouse {
                    let dx=(sample.x-s.sample.x)*tune.sensitivity
                    let dy=(sample.y-s.sample.y)*tune.sensitivity*(tune.invertY ? -1:1)
                    if dx != 0 || dy != 0 {
                        var delta=PointerDelta(dx:dx,dy:dy)
                        if tune.mouseResponse == .smoothedNonlinear {
                            s.previousMouse = .init(dx:dx*0.5+s.previousMouse.dx*0.5,dy:dy*0.5+s.previousMouse.dy*0.5)
                            delta = .init(dx:Self.mouseCurve(s.previousMouse.dx),dy:Self.mouseCurve(s.previousMouse.dy))
                        }
                        if abs(delta.dx)>=0.02 || abs(delta.dy)>=0.02 { motion.append(delta) }
                    }
                } else if tune.output == .dpad { s.dpad=Self.dpad(sample:sample,origin:s.origin,tuning:tune) }
                else if !s.aimDeferred,s.analog != nil { s.analog?.position=Self.vector(sample:sample,origin:s.origin,tuning:tune) }
            }
            s.sample=sample
        }
        sessions[id]=s
        for channel in takeoverChannels { yieldRetained(channel:channel,except:id) }
        return motion
    }
    mutating func end(contact:Int,time:Double,cancelled:Bool) {
        guard let id=contacts.removeValue(forKey:contact),let c=controls[id],var s=sessions[id] else { return }
        s.contact=nil; s.holdDeadline=nil; s.resetDeadline=nil
        // A global On request also ends an old retained vector when a deferred
        // touch lifts. Saved mixed Base/Alternate behavior keeps its legacy rule.
        if liveAutoCenterOverride == true && s.analog?.retained == true { s.analog = nil }
        if !cancelled { s.modified.end(.first, at: time); s.modified.end(.second, at: time) }
        s.leases[.first]=nil; s.leases[.second]=nil; s.selection = .init()
        if s.suppressGesture && !cancelled { s.suppressGesture=false; sessions[id]=s; return }
        if cancelled {
            cancelState(&s,alternate:s.phase != .base); sessions[id]=s; cue(id,.cancelled); return
        }
        if !c.buttonAim.enabled { s.modified.end(.base, at: time); s.leases[.base]=nil; s.visual = .idle; sessions[id]=s; return }
        if s.boundaryCancelled {
            if s.phase == .base && s.latched { s.modified.suppressArmedShots(.base) }
            else { s.modified.end(s.phase == .base ? .base : .alternate, at: time, suppressShot: true) }
            finishAim(&s,tuning:s.phase == .base ? c.buttonAim.tuning:c.buttonAim.alternate.tuning)
            if s.phase != .base { s.phase = .alternateRecovery; s.resetReady=false }
            s.visual=idleVisual(s); sessions[id]=s; return
        }
        if s.phase == .base {
            if basePrograms[id]!.hasModifiers {
                if !s.latched { s.modified.end(.base, at: time) }
                finishAim(&s,tuning:c.buttonAim.tuning); armAlternate(&s,control:c)
            } else if c.buttonAim.payloadTiming == .immediate {
                if !s.latched {
                    if let base=s.leases[.base] {
                        var latest:[TriggerChannel:ControllerPayloadStep]=[:]
                        for step in base.program.steps {
                            switch step { case let .triggerPulse(channel,_,_),let .triggerPressure(channel,_):latest[channel]=step;default:break }
                        }
                        for (channel,step) in latest {
                            if case let .triggerPulse(_,value,duration)=step, value>0, time < base.start+duration {
                                let old=s.detachedPulses[channel]
                                if old == nil || old!.expires < base.start+duration { s.detachedPulses[channel] = .init(value:value,expires:base.start+duration) }
                            }
                        }
                    }
                    s.leases[.base]=nil
                }
                finishAim(&s,tuning:c.buttonAim.tuning); armAlternate(&s,control:c)
            } else {
                s.fireLatch=s.holdReady; s.latched=false; s.holdReady=false
                s.fireDeadline=time+Double(c.buttonAim.releaseDelayMilliseconds)/1000
                s.visual = .waitingToFire
                if s.fireDeadline == time { fireBase(&s,id:id,control:c,deadline:time,time:time) }
            }
        } else {
            s.finishReturnsBase=s.resetReady
            if alternatePrograms[id]!.hasModifiers {
                s.modified.end(.alternate, at: time)
                finishAim(&s,tuning:c.buttonAim.alternate.tuning)
                completeAlternate(&s, control:c, time:time)
            } else if c.buttonAim.alternate.payloadTiming == .sendOnRelease {
                s.leases[.alternate]=Lease(program:alternatePrograms[id]!,start:time,expires:time+0.09)
                s.finiteDeadline=time+0.09; s.visual = .alternateWaitingToFire
                if c.buttonAim.alternate.tuning.autoCenter { s.analog?.position = .zero }
                s.dpad=[]
            } else {
                finishAim(&s,tuning:c.buttonAim.alternate.tuning)
                completeAlternate(&s,control:c,time:time)
            }
        }
        let armedNow = sessions[id]?.phase == .base && s.phase == .alternateArmed
        sessions[id]=s
        if armedNow { cue(id,.alternateArmed) }
    }
    private func cancelState(_ s:inout Session,alternate:Bool) {
        s.contact=nil; s.holdDeadline=nil; s.resetDeadline=nil; s.fireDeadline=nil; s.finiteDeadline=nil; s.unlatchDeadline=nil
        s.detachedPulses.removeAll()
        if alternate && s.latched { s.modified.cancel { $0 != .base } }
        else { s.modified = .init() }
        s.analog=nil; s.dpad=[]; s.aimDeferred=false; s.resetReady=false; s.holdReady=false; s.previousMouse = .zero
        if alternate { s.leases[.alternate]=nil; s.phase = .alternateRecovery }
        else { s.leases.removeAll(); s.latched=false; s.phase = .base }
        s.visual=idleVisual(s)
    }
    private func idleVisual(_ s:Session) -> ButtonAimVisualState {
        s.phase == .base ? (s.latched ? .latchReady:.idle) : s.phase == .alternateRecovery ? .alternateRecovery:.alternateArmed
    }
    private func finishAim(_ s:inout Session,tuning:ButtonAimTuning) {
        s.dpad=[]; s.aimDeferred=false; s.previousMouse = .zero
        // A short deferred touch never acquired the retained analog owner; it must not center it.
        if s.analog?.retained == false {
            if tuning.autoCenter { s.analog=nil } else { s.analog?.retained=true }
        }
    }
    private func armAlternate(_ s:inout Session,control:ProfileControl) {
        if control.buttonAim.alternate.enabled && basePrograms[control.id]?.hasAnyOutput == true { s.phase = .alternateArmed }
        s.visual=idleVisual(s)
    }
    private func fireBase(_ s:inout Session,id:UUID,control c:ProfileControl,deadline:Double,time:Double) {
        s.fireDeadline=nil; s.latched=s.fireLatch
        if s.fireLatch || !GestureDeadline.reached(deadline + 0.09, at: time) {
            s.leases[.base]=Lease(program:basePrograms[id]!,start:deadline,repeats:s.fireLatch,expires:s.fireLatch ? nil:deadline+0.09)
        }
        finishAim(&s,tuning:c.buttonAim.tuning); armAlternate(&s,control:c)
    }
    private func completeAlternate(_ s:inout Session,control c:ProfileControl,time:Double,immediate:Bool=false) {
        s.finiteDeadline=nil; s.leases[.alternate]=nil
        if s.finishReturnsBase {
            if !immediate && s.latched && (s.leases[.base] != nil || s.modified.slots.contains(.base)) && c.buttonAim.alternate.baseUnlatchDelayMilliseconds>0 {
                s.unlatchDeadline=time+Double(c.buttonAim.alternate.baseUnlatchDelayMilliseconds)/1000
                s.visual = .alternateResetReady; return
            }
            s.modified.end(.base, at: time); s.leases[.base]=nil; s.latched=false; s.phase = .base; s.unlatchDeadline=nil
        }
        s.resetReady=false; finishAim(&s,tuning:c.buttonAim.alternate.tuning); s.visual=idleVisual(s)
    }
    mutating func advance(to time:Double) {
        for id in Array(sessions.keys) {
            guard let c=controls[id], var s=sessions[id] else { continue }
            s.modified.advance(to: time)
            if let due=s.holdDeadline,GestureDeadline.reached(due, at: time) {
                s.holdDeadline=nil; s.holdReady=true
                if c.buttonAim.payloadTiming == .immediate || basePrograms[id]!.hasModifiers { s.latched=true }
                s.visual = .latchReady
                // Immediate pulse mode is fixed at activation in the source; do not restart it.
                cue(id,.latchReady)
            }
            if let due=s.resetDeadline,GestureDeadline.reached(due, at: time) { s.resetDeadline=nil; s.resetReady=true; s.visual = .alternateResetReady; cue(id,.resetReady) }
            if let due=s.fireDeadline,GestureDeadline.reached(due, at: time) { fireBase(&s,id:id,control:c,deadline:due,time:time) }
            if let due=s.finiteDeadline,GestureDeadline.reached(due, at: time) { completeAlternate(&s,control:c,time:due) }
            if let due=s.unlatchDeadline,GestureDeadline.reached(due, at: time) { completeAlternate(&s,control:c,time:due,immediate:true) }
            s.detachedPulses=s.detachedPulses.filter { !GestureDeadline.reached($0.value.expires, at: time) }
            s.leases=s.leases.filter { $0.value.expires.map { !GestureDeadline.reached($0, at: time) } ?? true }
            let armedNow = sessions[id]?.phase == .base && s.phase == .alternateArmed
            sessions[id]=s
            if armedNow { cue(id,.alternateArmed) }
        }
    }
    func nextDeadline(after time:Double) -> Double? {
        var due:[Double]=[]
        for s in sessions.values {
            if let next = s.modified.nextDeadline(after: time) { due.append(next) }
            due += s.detachedPulses.values.map(\.expires)
            due += [s.holdDeadline,s.resetDeadline,s.fireDeadline,s.finiteDeadline,s.unlatchDeadline].compactMap{$0}
            for lease in s.leases.values {
                if let expires=lease.expires { due.append(expires) }
                if let interval=lease.turboInterval {
                    due.append(GestureDeadline.phase(start: lease.start, period: interval,
                                                    width: min(0.1, max(0, interval - 0.005)), at: time).next)
                }
                for step in lease.program.steps {
                    if case let .triggerPulse(_,_,duration)=step,
                       let next = GestureDeadline.pulse(start: lease.start, duration: duration, repeats: lease.repeats, at: time).next {
                        due.append(next)
                    }
                }
            }
        }
        return due.filter { $0.isFinite && !GestureDeadline.reached($0, at: time) }.min()
    }
    func macroLeases(at time: Double) -> [SustainedMacroLease] {
        var result: [SustainedMacroLease] = []
        for (id, s) in sessions where !s.macrosSuppressed {
            for slot in s.modified.slots {
                let rank: Int
                switch slot { case .base: rank = 0; case .first: rank = 1; case .second: rank = 2; case .alternate: rank = 3 }
                result += s.modified.macroLeases(for: slot, control: id, at: time, priority: slot == .alternate ? 1 : 0,
                                                 order: rank, retained: s.contact == nil && s.latched)
            }
            for (slot, lease) in s.leases {
                if let expires = lease.expires, GestureDeadline.reached(expires, at: time) { continue }
                var active = true
                if let interval = lease.turboInterval {
                    active = GestureDeadline.phase(start: lease.start, period: interval,
                                                   width: min(0.1, max(0, interval - 0.005)), at: time).on
                }
                let rank: Int
                switch slot { case .base: rank = 0; case .first: rank = 1; case .second: rank = 2; case .alternate: rank = 3 }
                result.append(.init(id: lease.activationID, control: id, program: lease.program,
                                    priority: slot == .alternate ? 1 : 0, started: lease.start, order: rank,
                                    active: active, retained: s.contact == nil && (s.latched || s.fireLatch) && lease.expires == nil))
            }
        }
        return result.map { $0.suppressing(sessions[$0.control]?.suppressedMacroChannels ?? []) }
    }
    func claims(at time:Double) -> Claims {
        var result=Claims()
        for (id,s) in sessions {
            var own=Claims(); own.actions.formUnion(s.dpad)
            for (channel,pulse) in s.detachedPulses where !GestureDeadline.reached(pulse.expires, at: time) { own.pressure[channel]=pulse.value }
            // Source Alternate overrides Base within one surface; independent surfaces still use MAX.
            let timed = s.modified.claimsBySlot(at: time)
            for slot in [Slot.base, .first, .second, .alternate] {
                if let active = timed[slot] {
                    own.actions.formUnion(active.actions); own.keys.formUnion(active.keys); own.mouse.formUnion(active.mouse)
                    for (channel, amount) in active.pressure { own.pressure[channel] = amount }
                }
                guard let lease = s.leases[slot] else { continue }
                if let expires=lease.expires,GestureDeadline.reached(expires, at: time) { continue }
                if let interval=lease.turboInterval {
                    if !GestureDeadline.phase(start: lease.start, period: interval,
                                              width: min(0.1, max(0, interval - 0.005)), at: time).on { continue }
                }
                // Commands later in the same lease replace earlier trigger commands; other leases union.
                var pressures:[TriggerChannel:Double]=[:]
                for step in lease.program.steps {
                    switch step {
                    case let .digital(action):own.actions.insert(action)
                    case let .keyDown(key):own.keys.insert(key)
                    case let .mouseDown(button):own.mouse.insert(button)
                    case let .triggerPressure(channel,value):pressures[channel]=value
                    case let .triggerPulse(channel,value,duration):
                        let on = GestureDeadline.pulse(start: lease.start, duration: duration, repeats: lease.repeats, at: time).on
                        pressures[channel]=on ? value:0
                    case .wait,.mouseUp,.scrollModeToggle,.releaseAll,.cameraFollow,.autoCenter,.fixedStick:break
                    }
                }
                for (channel,value) in pressures where value > 0 { own.pressure[channel]=value }
            }
            result.actions.formUnion(own.actions);result.keys.formUnion(own.keys);result.mouse.formUnion(own.mouse)
            if !own.mouse.isEmpty { result.mouseOwners.insert(id) }
            for (channel,value) in own.pressure { result.pressure[channel]=max(result.pressure[channel] ?? 0,value) }
            if !own.actions.isEmpty || !own.keys.isEmpty || !own.mouse.isEmpty || own.pressure.values.contains(where:{$0>0}) || s.analog?.position != nil && s.analog?.position != .zero { result.producing.insert(id) }
        }
        return result
    }
    static func vector(sample:ButtonPointerSample,origin:ButtonPointerSample,tuning:ButtonAimTuning) -> StickPosition {
        let raw:StickPosition
        if tuning.origin == .controlCenter { raw = .init(x:min(1,max(-1,(sample.x-sample.width/2)/(sample.width/2))),y:min(1,max(-1,(sample.y-sample.height/2)/(sample.height/2)))) }
        else {
            let x=sample.x-origin.x,y=sample.y-origin.y,m=hypot(x,y)
            if m<=tuning.deadzone || m==0 { return .zero }
            let n=min(1,(m-tuning.deadzone)/max(1,tuning.fullDisplacement-tuning.deadzone))
            raw = .init(x:x/m*n,y:y/m*n)
        }
        let mapped=StickResponseSettings(mode:tuning.stickResponse,sensitivity:tuning.sensitivity).applyValidated(raw)
        // Native GamepadState uses +Y up; local pointer uses +Y down.
        return .init(x:mapped.x,y:mapped.y*(tuning.invertY ? 1:-1))
    }
    static func dpad(sample:ButtonPointerSample,origin:ButtonPointerSample,tuning:ButtonAimTuning) -> Set<ControllerControlID> {
        let x=sample.x-(tuning.dpadOrigin == .controlCenter ? sample.width/2:origin.x)
        let y=sample.y-(tuning.dpadOrigin == .controlCenter ? sample.height/2:origin.y)
        guard hypot(x,y)>tuning.dpadActivationDistance else { return [] }
        let h:ControllerControlID=x<0 ? .dpadLeft:.dpadRight,v:ControllerControlID=y<0 ? .dpadUp:.dpadDown
        if tuning.dpadMode == .fourWay { return [abs(x)>=abs(y) ? h:v] }
        if abs(y)<=abs(x)*tan(.pi/8) { return [h] }; if abs(y)>=abs(x)*tan(3 * .pi/8) { return [v] }; return [h,v]
    }
    static func mouseCurve(_ value:Double) -> Double {
        let m=abs(value),scaled=m<0.2 ? m*1.5:m<0.6 ? m:0.6+(m-0.6)*0.8
        return value<0 ? -scaled:scaled
    }
}

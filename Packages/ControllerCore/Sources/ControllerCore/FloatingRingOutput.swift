import Foundation

/// One ring-owned output slot. Reservation outlives its ON claim through every OFF gap.
/// All transitions occur on the enclosing engine's monotonic clock; no detached tasks exist.
struct FloatingRingOutput: Sendable {
    struct Request: Sendable {
        var payload: String
        var press: Double
        var gap: Double
        var gesture: UInt64
    }
    enum Phase: Sendable { case idle, held, on, gap }
    private(set) var phase: Phase = .idle
    private(set) var payload = ""
    private(set) var retained = false
    private(set) var repeating = false
    private(set) var generation: UInt64 = 0
    private(set) var activeGesture: UInt64?
    private(set) var queued: Request?
    private var phaseDeadline: Double?
    private var clock: Double = 0
    private var modified = ModifiedPayloadRuntime<Int>()
    var deadline: Double? { [phaseDeadline, modified.nextDeadline(after: clock)].compactMap { $0 }.min() }
    private var press: Double = 0.035
    private var gap: Double = 0.035
    private var lease: OwnedGesturePayloadLease?
    private var logicalKeys: Set<RingOutputKey> = []
    private var phaseExclusiveKeys: Set<RingOutputKey> = []
    var exclusiveKeys: Set<RingOutputKey> { phaseExclusiveKeys.intersection(keys) }
    var held: Bool { phase == .held || phase == .on || modified.claims(for: 0, at: clock).hasOutput }
    var busy: Bool { phase == .on || phase == .gap }
    var hasReservation: Bool { phase != .idle || !modified.slots.isEmpty }
    var keys: Set<RingOutputKey> { phase == .idle ? modified.targets : logicalKeys.union(modified.targets) }
    var claims: GesturePayloadClaims {
        var result = modified.claims(for: 0, at: clock)
        if (phase == .on || phase == .held), let lease { result.union(lease.claims(at: clock)) }
        return result
    }
    func macroLeases(control: UUID, priority: Int) -> [SustainedMacroLease] {
        [macroLease(control: control, priority: priority)].compactMap { $0 }
            + modified.macroLeases(for: 0, control: control, at: clock, priority: priority, retained: retained)
    }
    func macroLease(control: UUID, priority: Int) -> SustainedMacroLease? {
        guard hasReservation, let lease else { return nil }
        return .init(id: lease.activationID, control: control, program: lease.program,
                     priority: priority, started: lease.started, active: phase == .on || phase == .held, retained: retained)
    }

    mutating func observeTime(_ time: Double) {
        clock = max(clock, time)
        modified.advance(to: clock)
    }
    mutating func stop() {
        modified = .init(); resetPhase(); phaseExclusiveKeys = []
    }
    mutating func release() {
        modified.end(0, at: clock); resetPhase()
    }
    private mutating func resetPhase() {
        generation &+= 1; phase = .idle; retained = false; repeating = false
        activeGesture = nil; queued = nil; phaseDeadline = nil; lease = nil; logicalKeys = []
    }
    /// Same held payload reuses its original ownership generation; cancellation of a later
    /// touch can restore its earlier retained state rather than releasing someone else's hold.
    mutating func hold(_ payload: String, gesture: UInt64, exclusive: Set<RingOutputKey>,
                       permitted: Bool) -> Bool {
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        if phase == .held && self.payload == payload { retained = false; return true }
        release()
        guard permitted, let program = try? ringProgram(payload) else { return false }
        self.payload = payload; phase = .held; activeGesture = gesture; phaseExclusiveKeys = exclusive; logicalKeys = ringKeys(payload)
        modified.start(0, program: program, at: clock, resume: true, includePlain: true)
        lease = program.hasModifiers ? nil : .init(program: program, started: clock); return true
    }
    mutating func pulse(_ payload: String, pressMilliseconds: Int, gapMilliseconds: Int,
                        gesture: UInt64, now: Double, permitted: Bool) -> Bool {
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        observeTime(now)
        let request = Request(payload: payload, press: Double(pressMilliseconds)/1000,
                              gap: Double(gapMilliseconds)/1000, gesture: gesture)
        if busy { if queued == nil { queued = request }; return true }
        release()
        guard permitted else { return false }
        return start(request, now: now, repeating: false)
    }
    mutating func repeatOutput(_ payload: String, pressMilliseconds: Int, gapMilliseconds: Int,
                               gesture: UInt64, now: Double, permitted: Bool) -> Bool {
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        observeTime(now)
        if repeating && self.payload == payload { return true }
        release()
        guard permitted else { return false }
        return start(.init(payload: payload, press: Double(pressMilliseconds)/1000,
                           gap: Double(gapMilliseconds)/1000, gesture: gesture), now: now, repeating: true)
    }
    private mutating func start(_ request: Request, now: Double, repeating: Bool) -> Bool {
        guard now.isFinite, now >= 0, request.press.isFinite, request.gap.isFinite,
              (0.001...60).contains(request.press), (0.001...60).contains(request.gap),
              let program = try? ringProgram(request.payload) else { stop(); return false }
        generation &+= 1; payload = request.payload; press = request.press; gap = request.gap
        phase = .on; self.repeating = repeating; activeGesture = request.gesture; phaseDeadline = now + press
        logicalKeys = ringKeys(payload); phaseExclusiveKeys = logicalKeys
        modified.start(0, program: program, at: now, endsAt: now + press, includePlain: true)
        lease = program.hasModifiers ? nil : .init(program: program, started: now)
        return true
    }
    /// Advance at most one phase. A late callback still exposes a full OFF gap and never
    /// invents a burst of missed taps. Queued retrigger acquisition is checked at that time.
    mutating func advance(to time: Double, permits: (Set<RingOutputKey>) -> Bool) -> Bool {
        observeTime(time)
        guard let phaseDeadline, GestureDeadline.reached(phaseDeadline, at: time) else { return true }
        switch phase {
        case .on:
            phase = .gap; self.phaseDeadline = time + gap
        case .gap:
            if repeating {
                guard permits(exclusiveKeys) else { stop(); return false }
                phase = .on; self.phaseDeadline = time + press; queued = nil
                if let program = try? ringProgram(payload) { modified.start(0, program: program, at: time, endsAt: time + press, includePlain: true) }
            } else if let request = queued {
                queued = nil; retained = false
                guard permits(ringKeys(request.payload)) else { stop(); return false }
                return start(request, now: time, repeating: false)
            } else { release() }
        case .idle, .held: self.phaseDeadline = nil
        }
        return true
    }
    mutating func retainOrRelease(_ retain: Bool) {
        if retain && (phase == .held || phase == .on || repeating) { retained = true } else { release() }
    }
    mutating func restoreRetained(_ value: Bool, cancelQueuedFrom gesture: UInt64) {
        retained = value
        if queued?.gesture == gesture { queued = nil }
    }
}

import Foundation

/// A reversible output can be active, waiting for its start, or completing a finite release.
/// All deadlines use the enclosing engine's clock. Replacing/cancelling the bank invalidates
/// its entire schedule without asynchronous callbacks or calls to a receiver.
struct ModifiedPayloadRuntime<Slot: Hashable & Sendable>: Sendable {
    struct Cycle: Sendable {
        var period: Double
        var width: Double
    }
    private struct Key: Hashable, Sendable {
        let slot: Slot
        let program: String
        let index: Int
    }
    private struct Voice: Sendable {
        let id: UUID
        let step: ControllerPayloadStep
        let timing: PayloadCommandModifiers
        var start: Double
        let cycle: Cycle?
        let repeatsPulse: Bool
        let preserveAuthoredPulse: Bool
        let sendOnRelease: Bool
        let completeOnRelease: Bool
        var finiteEnd: Double?
        /// A completed normal release can own one remaining output window.
        var finitePress = false
        var released = false
        var window: Range<Double>?
        var resumable = false
        var needsGap = false
        var awaitingActivation = false
        var repeatWindow: Range<Double>?
        var nextRepeatActivation: Double?

        var observedRepeatPeriod: Double? {
            guard let milliseconds = timing.pressDurationMilliseconds else { return nil }
            if let repeatMilliseconds = timing.repeatMilliseconds { return Double(repeatMilliseconds) / 1000 }
            guard let cycle, timing.holdReleaseMilliseconds == nil else { return nil }
            let duration = Double(milliseconds) / 1000
            return max(cycle.period, ceil(duration / cycle.period) * cycle.period)
        }

        var pressDuration: Double? {
            if let milliseconds = timing.pressDurationMilliseconds { return Double(milliseconds) / 1000 }
            if case let .triggerPulse(_, _, duration) = step { return duration }
            return nil
        }
        func phase(at time: Double) -> (on: Bool, next: Double?) {
            if released {
                guard let window else { return (false, nil) }
                if awaitingActivation { return (false, window.lowerBound) }
                guard !GestureDeadline.reached(window.upperBound, at: time) else { return (false, nil) }
                return GestureDeadline.reached(window.lowerBound, at: time) ? (true, window.upperBound) : (false, window.lowerBound)
            }
            guard !sendOnRelease else { return (false, nil) }
            if let nextRepeatActivation {
                if let repeatWindow { return (true, repeatWindow.upperBound) }
                return (false, nextRepeatActivation)
            }
            if awaitingActivation { return (false, start) }
            guard GestureDeadline.reached(start, at: time) else { return (false, start) }
            if let cycle, timing.repeatMilliseconds == nil, timing.holdReleaseMilliseconds == nil {
                // D shifts the first press only. Later Turbo ticks stay on the control's cadence.
                let width = pressDuration ?? cycle.width
                let firstEnd = start + width
                if !GestureDeadline.reached(firstEnd, at: time) { return (true, firstEnd) }
                let origin = start - timing.delay
                let skip = ceil((firstEnd - origin - GestureDeadline.tolerance(at: firstEnd)) / cycle.period)
                let firstTick = origin + max(1, skip) * cycle.period
                if !GestureDeadline.reached(firstTick, at: time) { return (false, firstTick) }
                let period = timing.pressDurationMilliseconds == nil ? cycle.period :
                    max(cycle.period, ceil(width / cycle.period) * cycle.period)
                let result = GestureDeadline.phase(start: firstTick, period: period, width: min(width, period), at: time)
                return (result.on, result.next)
            }
            if let milliseconds = timing.repeatMilliseconds {
                let width = pressDuration ?? Double(min(milliseconds / 2, 50)) / 1000
                let phase = GestureDeadline.phase(start: start, period: Double(milliseconds) / 1000, width: width, at: time)
                return (phase.on, phase.next)
            }
            if let duration = pressDuration {
                let pulse = GestureDeadline.pulse(start: start, duration: duration,
                    repeats: repeatsPulse && timing.pressDurationMilliseconds == nil, at: time)
                return (pulse.on, pulse.next)
            }
            return (true, nil)
        }
        mutating func release(at time: Double) {
            guard !released else { return }
            if completeOnRelease && !sendOnRelease { return }
            let phase = phase(at: time)
            released = true; finiteEnd = nil
            if sendOnRelease {
                let begin = time + max(timing.delay, needsGap ? 0.035 : 0)
                let tail = timing.pressDurationMilliseconds != nil || completeOnRelease ? 0 : timing.tail
                window = begin..<(begin + (pressDuration ?? 0.09) + tail)
                awaitingActivation = begin > time && (timing.pressDurationMilliseconds != nil || completeOnRelease)
            } else if phase.on {
                let pulseEnd = preserveAuthoredPulse && timing.tail == 0 && timing.repeatMilliseconds == nil && !repeatsPulse ? pressDuration.map { start + $0 } : nil
                var end = max(time + timing.tail, pulseEnd ?? time)
                if timing.pressDurationMilliseconds != nil {
                    // U bounds this activation, including any release tail. It does not latch it.
                    end = min(time + timing.tail, phase.next ?? time)
                }
                if end > time {
                    window = time..<end
                    resumable = timing.tail > 0
                }
            }
        }
        mutating func observeActivation(at time: Double) {
            if !released, let next = nextRepeatActivation, let period = observedRepeatPeriod, let duration = pressDuration {
                if let repeatWindow {
                    if GestureDeadline.reached(repeatWindow.upperBound, at: time) {
                        self.repeatWindow = nil
                        let gap = period > duration ? period - duration : cycle?.period ?? period
                        nextRepeatActivation = max(next, time + gap)
                    }
                } else if GestureDeadline.reached(next, at: time) {
                    repeatWindow = time..<(time + duration)
                    nextRepeatActivation = time + period
                }
                return
            }
            guard awaitingActivation else { return }
            let scheduled = released ? window?.lowerBound : start
            guard let scheduled, GestureDeadline.reached(scheduled, at: time) else { return }
            awaitingActivation = false
            if released, let window {
                self.window = time..<(time + window.upperBound - window.lowerBound)
            } else {
                start = time
                if finitePress { finiteEnd = time + (pressDuration ?? 0.2) }
            }
        }
        func nextDeadline(after time: Double) -> Double? {
            [phase(at: time).next, finiteEnd].compactMap { $0 }.filter { !GestureDeadline.reached($0, at: time) }.min()
        }
    }

    private var voices: [Key: Voice] = [:]
    // A source may re-arm before its prior release shot finishes. Keep those shots independent.
    private var shots: [Key: [Voice]] = [:]

    mutating func start(_ slot: Slot, program: ControllerPayloadProgram, at time: Double,
                        inheritedRelease: Bool = false, releaseDelay: Double = 0,
                        cycle: Cycle? = nil, repeatsPulse: Bool = false, endsAt: Double? = nil,
                        resume: Bool = false, includePlain: Bool = false, stagePress: Bool = false,
                        preserveAuthoredPulse: Bool = false, completeOnRelease: Bool = false) {
        guard program.hasModifiers || completeOnRelease else { return }
        advance(to: time, only: slot)
        for (index, step) in program.steps.enumerated() {
            var timing = program.modifiers[index]
            guard timing.isModified || includePlain else { continue }
            let defaultRelease = timing.timing == nil && inheritedRelease
            let sor = timing.timing == .sendOnRelease || defaultRelease
            if defaultRelease { timing.activationDelayMilliseconds = (timing.activationDelayMilliseconds ?? 0) + Int((releaseDelay * 1000).rounded()) }
            let key = Key(slot: slot, program: program.source, index: index)
            if resume, var prior = voices[key], prior.resumable, prior.phase(at: time).on {
                prior.released = false; prior.window = nil; prior.resumable = false
                if prior.timing.pressDurationMilliseconds == nil { prior.start = time }
                prior.finiteEnd = endsAt
                voices[key] = prior
                continue
            }
            if var prior = voices[key], prior.released, let window = prior.window {
                // Overlapping shots of the same command share one physical hold.
                if let last = shots[key]?.last?.window, last.upperBound >= window.lowerBound && window.upperBound >= last.lowerBound {
                    prior.window = min(last.lowerBound, window.lowerBound)..<max(last.upperBound, window.upperBound)
                    shots[key]![shots[key]!.count - 1] = prior
                } else { shots[key, default: []].append(prior) }
            }
            let gap = sor && program.steps.indices.contains { sibling in
                guard sibling != index, step.timingTarget == program.steps[sibling].timingTarget else { return false }
                let m = program.modifiers[sibling]
                return m.repeatMilliseconds != nil || (cycle != nil && m.timing != .sendOnRelease && m.holdReleaseMilliseconds == nil)
            }
            var voice = Voice(id: UUID(), step: step, timing: timing, start: time + timing.delay,
                              cycle: cycle, repeatsPulse: repeatsPulse, preserveAuthoredPulse: preserveAuthoredPulse,
                              sendOnRelease: sor, completeOnRelease: completeOnRelease, finiteEnd: endsAt)
            voice.awaitingActivation = !sor && timing.delay > 0 &&
                (timing.pressDurationMilliseconds != nil || completeOnRelease) && cycle == nil && timing.repeatMilliseconds == nil
            if !sor && voice.observedRepeatPeriod != nil {
                voice.nextRepeatActivation = voice.start
                voice.observeActivation(at: time)
            }
            if completeOnRelease && !sor {
                voice.finitePress = true
                voice.finiteEnd = voice.awaitingActivation ? nil : voice.start + (voice.pressDuration ?? 0.2)
            }
            if stagePress {
                if sor || timing.repeatMilliseconds != nil { voice.finiteEnd = nil }
                else {
                    voice.finitePress = true
                    voice.finiteEnd = voice.awaitingActivation ? nil : voice.start + (voice.pressDuration ?? 0.09)
                }
            }
            voice.needsGap = gap
            voices[key] = voice
        }
    }
    mutating func end(_ slot: Slot, at time: Double, suppressShot: Bool = false, preserveFinitePress: Bool = false) {
        guard voices.contains(where: { $0.key.slot == slot && !$0.value.released }) else { return }
        for key in voices.keys where key.slot == slot {
            guard let voice = voices[key], !voice.released, !voice.completeOnRelease, !voice.sendOnRelease else { continue }
            if voice.awaitingActivation || (voice.nextRepeatActivation != nil && voice.repeatWindow == nil) {
                // A departing normal source cannot activate overdue work that never pressed.
                voices[key] = nil
            }
        }
        advance(to: time, only: slot)
        for key in voices.keys where key.slot == slot {
            if preserveFinitePress, let voice = voices[key], voice.finitePress, voice.phase(at: time).on { continue }
            if suppressShot && voices[key]?.sendOnRelease == true && voices[key]?.released == false { voices[key] = nil }
            else { voices[key]?.release(at: time) }
        }
        advance(to: time, only: slot)
    }
    mutating func suppressArmedShots(_ slot: Slot) {
        voices = voices.filter { $0.key.slot != slot || !$0.value.sendOnRelease || $0.value.released }
    }
    mutating func suppressMacros(channel: FixedStickChannel) {
        voices = voices.filter {
            if case let .fixedStick(macro) = $0.value.step { return macro.channel != channel }
            return true
        }
        shots = shots.filter {
            if case let .fixedStick(macro) = $0.value.first?.step { return macro.channel != channel }
            return true
        }
    }
    mutating func suppressMacros() {
        voices = voices.filter { if case .fixedStick = $0.value.step { false } else { true } }
        shots = shots.filter { if case .fixedStick = $0.value.first?.step { false } else { true } }
    }
    mutating func cancel(_ slot: Slot) { cancel { $0 == slot } }
    mutating func cancel(where predicate: (Slot) -> Bool) {
        voices = voices.filter { !predicate($0.key.slot) }; shots = shots.filter { !predicate($0.key.slot) }
    }
    mutating func advance(to time: Double, only slot: Slot? = nil) {
        for key in shots.keys where slot == nil || slot == key.slot {
            for index in shots[key]?.indices ?? 0..<0 { shots[key]?[index].observeActivation(at: time) }
            shots[key]?.removeAll { voice in voice.window.map { GestureDeadline.reached($0.upperBound, at: time) } ?? true }
            if shots[key]?.isEmpty == true { shots[key] = nil }
        }
        for key in voices.keys where slot == nil || slot == key.slot {
            guard var voice = voices[key] else { continue }
            voice.observeActivation(at: time)
            voices[key] = voice
            if let end = voice.finiteEnd, GestureDeadline.reached(end, at: time) {
                if voice.finitePress { voices[key] = nil; continue }
                voice.release(at: end); voices[key] = voice
            }
            if voice.released, voice.window.map({ GestureDeadline.reached($0.upperBound, at: time) }) ?? true {
                voices[key] = nil
            }
        }
    }
    private func forEachVoice(in slot: Slot? = nil, _ body: (Key, Voice) -> Void) {
        for (key, voice) in voices where slot == nil || key.slot == slot { body(key, voice) }
        for (key, pending) in shots where slot == nil || key.slot == slot {
            for voice in pending { body(key, voice) }
        }
    }
    func nextDeadline(after time: Double) -> Double? {
        var result: Double?
        forEachVoice { _, voice in
            if let next = voice.nextDeadline(after: time) { result = min(result ?? next, next) }
        }
        return result
    }
    var targets: Set<RingOutputKey> {
        var keys: Set<RingOutputKey> = []
        forEachVoice { _, voice in if let target = voice.step.timingTarget { keys.insert(target) } }
        return keys
    }
    var slots: Set<Slot> { Set(voices.keys.map(\.slot)).union(shots.keys.map(\.slot)) }
    func claimsBySlot(at time: Double, only slot: Slot? = nil) -> [Slot: GesturePayloadClaims] {
        var claims: [Slot: GesturePayloadClaims] = [:]
        var pressureOrder: [Slot: [TriggerChannel: (Double, Int)]] = [:]
        forEachVoice(in: slot) { key, voice in
            guard voice.phase(at: time).on else { return }
            switch voice.step {
            case let .digital(id): claims[key.slot, default: .init()].actions.insert(id)
            case let .mouseDown(button): claims[key.slot, default: .init()].mouse.insert(button)
            case let .keyDown(button): claims[key.slot, default: .init()].keys.insert(button)
            case let .triggerPressure(channel, amount), let .triggerPulse(channel, amount, _):
                let order = (voice.sendOnRelease ? voice.window?.lowerBound ?? voice.start : voice.start, key.index)
                if let newer = pressureOrder[key.slot]?[channel], newer > order { return }
                claims[key.slot, default: .init()].pressure[channel] = amount
                pressureOrder[key.slot, default: [:]][channel] = order
            default: break
            }
        }
        return claims
    }
    func claims(for slot: Slot, at time: Double) -> GesturePayloadClaims {
        claimsBySlot(at: time, only: slot)[slot] ?? .init()
    }

    func macroLeases(for slot: Slot, control: UUID, at time: Double, priority: Int, order: Int = 0,
                     retained: Bool = false) -> [SustainedMacroLease] {
        var result: [SustainedMacroLease] = []
        forEachVoice(in: slot) { key, voice in
            guard case .fixedStick = voice.step else { return }
            let on = voice.phase(at: time).on
            // A pending activation cannot reserve a channel; live repeat gaps retain ownership.
            guard on || (!voice.released && !voice.sendOnRelease && GestureDeadline.reached(voice.start, at: time)
                         && (voice.timing.repeatMilliseconds != nil || voice.cycle != nil)) else { return }
            result.append(.init(id: voice.id, control: control, program: .init(steps: [voice.step], source: ""),
                         priority: priority, started: voice.start, order: order*64 + key.index, active: on, retained: retained))
        }
        return result
    }
}

extension ControllerPayloadStep {
    var timingTarget: RingOutputKey? {
        switch self {
        case let .digital(action): return .digital(action)
        case let .triggerPressure(channel, _), let .triggerPulse(channel, _, _): return .trigger(channel)
        case let .keyDown(key): return .key(key)
        case let .mouseDown(button): return .mouse(button)
        case let .fixedStick(macro): return .fixedStick(macro.channel)
        default: return nil
        }
    }
}

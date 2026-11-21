import Foundation

/// Per-pad gesture ownership. All time advancement is driven by the enclosing engine.
struct TouchpadRuntime: Sendable {
    struct Contact: Sendable {
        var id: UUID; var owns: Bool; var began: TimeInterval
        var displacement: PointerDelta = .zero
        var maximumExcursion: Double = 0
        var filtered: PointerDelta = .zero
        var suppressEndClick = false
        var recognizesTap = true
    }
    struct PendingLock: Sendable { var deadline: TimeInterval; var contact: Int? }
    struct Pad: Sendable {
        var locked = false
        var pending: PendingLock?
        var primeUntil: TimeInterval?
        var cooldownUntil: TimeInterval?
    }
    var configurations: [UUID: TouchpadBehavior]
    private(set) var contacts: [Int: Contact] = [:]
    private var pads: [UUID: Pad] = [:]
    init(profile: ControllerProfile) {
        configurations = Dictionary(uniqueKeysWithValues: profile.controls.filter(\.isTouchpad).map { ($0.id, $0.touchpadBehavior) })
    }
    var active: Set<UUID> { Set(contacts.values.filter(\.owns).map(\.id)) }
    var locked: Set<UUID> { Set(pads.filter { $0.value.locked }.keys) }
    var pending: Set<UUID> { Set(pads.filter { $0.value.pending != nil }.keys) }
    var leftOwners: Set<UUID> {
        locked.union(contacts.values.filter { $0.owns && configurations[$0.id]?.clickMode == .hold }.map(\.id))
    }
    var nextDeadline: TimeInterval? { pads.values.compactMap { $0.pending?.deadline }.min() }
    mutating func clear() { contacts.removeAll(); pads.removeAll() }
    mutating func clear(controls ids: Set<UUID>) {
        contacts = contacts.filter { !ids.contains($0.value.id) }; pads = pads.filter { !ids.contains($0.key) }
    }
    mutating func resetFilters() {
        for token in Array(contacts.keys) { contacts[token]?.filtered = .zero }
    }
    mutating func begin(contact token: Int, control id: UUID, at time: TimeInterval, recognizesTap: Bool = true) {
        let owns = !contacts.values.contains { $0.id == id && $0.owns }
        contacts[token] = Contact(id: id, owns: owns, began: time, recognizesTap: recognizesTap)
        guard owns, let config = configurations[id] else { return }
        var pad = pads[id] ?? Pad()
        switch config.clickMode {
        case .none, .hold: break
        case .toggle:
            if pad.locked || pad.pending != nil { pad = Pad() }
            else { pad.pending = .init(deadline: time + 0.750, contact: nil) }
        case .doubleTapLock:
            pad.pending = nil
            if !recognizesTap { pad.primeUntil = nil }
            if recognizesTap, !pad.locked, let prime = pad.primeUntil, time <= prime + 1e-10,
               pad.cooldownUntil.map({ time + 1e-10 >= $0 }) ?? true {
                pad.pending = .init(deadline: time + 0.380, contact: token)
            }
            if pad.primeUntil.map({ time > $0 + 1e-10 }) ?? false { pad.primeUntil = nil }
        }
        pads[id] = pad
    }
    /// Updates all path samples before the enclosing engine advances lock deadlines.
    mutating func move(contact token: Int, deltas: [PointerDelta]) -> [PointerDelta] {
        guard var contact = contacts[token], contact.owns, let config = configurations[contact.id] else { return [] }
        var movement: [PointerDelta] = []
        for delta in deltas {
            contact.displacement.dx = clampedPracticeTotal(contact.displacement.dx, adding: delta.dx)
            contact.displacement.dy = clampedPracticeTotal(contact.displacement.dy, adding: delta.dy)
            contact.maximumExcursion = max(contact.maximumExcursion, abs(contact.displacement.dx), abs(contact.displacement.dy))
            let dx = delta.dx * config.sensitivity, dy = delta.dy * config.sensitivity
            if abs(dx) < 0.02 && abs(dy) < 0.02 { continue }
            contact.filtered = .init(dx: dx * 0.5 + contact.filtered.dx * 0.5,
                                     dy: dy * 0.5 + contact.filtered.dy * 0.5)
            movement.append(.init(dx: touchpadResponse(contact.filtered.dx), dy: touchpadResponse(contact.filtered.dy)))
        }
        contacts[token] = contact
        if contact.maximumExcursion > 20, configurations[contact.id]?.clickMode == .doubleTapLock {
            var pad = pads[contact.id] ?? Pad()
            if pad.pending?.contact == token { pad.pending = nil }
            pad.primeUntil = nil; pads[contact.id] = pad
        }
        return movement
    }
    /// Returns the owner of a normal tap click, never for cancellation.
    mutating func end(contact token: Int, at time: TimeInterval, cancelled: Bool) -> UUID? {
        guard let contact = contacts.removeValue(forKey: token), contact.owns,
              let config = configurations[contact.id] else { return nil }
        if cancelled { pads.removeValue(forKey: contact.id); return nil }
        guard config.clickMode == .doubleTapLock else { return nil }
        var pad = pads[contact.id] ?? Pad()
        pad.pending = nil // An unexecuted still-down deadline cannot fire from finger lift.
        guard contact.recognizesTap else {
            // Sliding into a pad is movement, never a direct tap, unlock, or double-tap prime.
            pad.primeUntil = nil; pads[contact.id] = pad
            return nil
        }
        let clean = time - contact.began <= 0.180 + max(1e-10, time.ulp * 2) && contact.maximumExcursion <= 20
        var click = false
        if pad.locked {
            if clean && !contact.suppressEndClick {
                pad.locked = false; pad.cooldownUntil = time + 0.120
            }
            pad.primeUntil = nil
        } else if clean {
            click = true; pad.primeUntil = time + 0.120
        } else { pad.primeUntil = nil }
        pads[contact.id] = pad
        return click ? contact.id : nil
    }
    /// Swipe departure is not a tap or cancellation: keep established locks and toggle arming.
    mutating func handoff(contact token: Int) {
        guard let contact = contacts.removeValue(forKey: token), contact.owns else { return }
        var pad = pads[contact.id] ?? Pad()
        pad.primeUntil = nil
        if pad.pending?.contact != nil { pad.pending = nil }
        pads[contact.id] = pad
    }
    mutating func advance(to time: TimeInterval) {
        for id in Array(pads.keys) {
            guard var pad = pads[id], let pending = pad.pending,
                  pending.deadline <= time + max(1e-10, time.ulp * 2) else { continue }
            pad.pending = nil
            if let token = pending.contact {
                if let contact = contacts[token], contact.owns, contact.id == id, contact.maximumExcursion <= 20 {
                    pad.locked = true; pad.primeUntil = nil
                    contacts[token]?.suppressEndClick = true
                }
            } else { pad.locked = true }
            pads[id] = pad
        }
    }
}

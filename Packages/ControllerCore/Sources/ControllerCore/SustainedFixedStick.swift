import Foundation

/// A stable activation identity belongs to a payload slot, never to a rendering/timer pass.
/// Inactive repeat phases remain present so a channel reservation and rejection survive the gap.
struct SustainedMacroLease: Sendable {
    let id: UUID
    let control: UUID
    let program: ControllerPayloadProgram
    let priority: Int
    let started: Double
    var order = 0
    var active = true
    var retained = false
    var suppressedChannels: Set<FixedStickChannel> = []
    func suppressing(_ channels: Set<FixedStickChannel>) -> Self {
        var copy = self; copy.suppressedChannels.formUnion(channels); return copy
    }
    var macros: [FixedStickChannel: FixedStickMacro] {
        program.steps.reduce(into: [:]) { result, step in
            if case let .fixedStick(macro) = step, !suppressedChannels.contains(macro.channel) { result[macro.channel] = macro }
        }
    }
}

/// Resolves one surface's local slot priority before the shared first-live channel arbiter.
/// A higher-priority Shoot/Alternate can replace and restore its own Base while the family
/// continuously owns the channel. Losing to another control rejects every existing activation.
struct SustainedMacroCoordinator: Sendable {
    struct Key: Hashable { let control: UUID; let channel: FixedStickChannel }
    struct Family: Sendable {
        var owner = UUID()
        var known: Set<UUID> = []
        var rejected: Set<UUID> = []
        var hadClaim = false
    }
    private var families: [Key: Family] = [:]
    var ownerControls: [UUID: UUID] { Dictionary(uniqueKeysWithValues: families.map { ($0.value.owner, $0.key.control) }) }
    var blockedChannels: [UUID: Set<FixedStickChannel>] {
        families.reduce(into: [:]) { result, pair in
            if !pair.value.hadClaim && !pair.value.rejected.isEmpty { result[pair.key.control, default: []].insert(pair.key.channel) }
        }
    }
    mutating func clear() { families.removeAll() }
    mutating func remove(controls: Set<UUID>, ledger: inout FixedStickClaimLedger) {
        for key in families.keys where controls.contains(key.control) {
            if let family = families.removeValue(forKey: key) { ledger.end(owner: family.owner) }
        }
    }
    mutating func suppress(channel: FixedStickChannel, ledger: inout FixedStickClaimLedger) {
        for key in families.keys where key.channel == channel {
            guard var family = families[key] else { continue }
            family.rejected.formUnion(family.known); family.hadClaim = false
            ledger.end(owner: family.owner); families[key] = family
        }
    }
    /// Returns channels newly acquired by a surface, so retained manual owners can be retired.
    mutating func reconcile(_ leases: [SustainedMacroLease], ledger: inout FixedStickClaimLedger,
                            occupied: Set<ControllerControlID>) -> Set<ControllerControlID> {
        var grouped: [Key: [(SustainedMacroLease, FixedStickMacro)]] = [:]
        for lease in leases {
            for (channel, macro) in lease.macros { grouped[.init(control: lease.control, channel: channel), default: []].append((lease, macro)) }
        }
        for key in families.keys where grouped[key] == nil {
            if let old = families.removeValue(forKey: key) { ledger.end(owner: old.owner) }
        }
        var acquired: Set<ControllerControlID> = []
        let ordered = grouped.keys.sorted { a, b in
            let first = grouped[a]!.map { $0.0.started }.min()!, second = grouped[b]!.map { $0.0.started }.min()!
            if first != second { return first < second }
            return a.control == b.control ? a.channel.rawValue < b.channel.rawValue : a.control.uuidString < b.control.uuidString
        }
        for key in ordered {
            let values = grouped[key]!, ids = Set(values.map { $0.0.id })
            var family = families[key] ?? .init()
            if family.hadClaim && ledger.claims[key.channel]?.owner != family.owner {
                family.rejected.formUnion(family.known) // Retained takeover cannot resurrect an old slot.
                family.hadClaim = false
            }
            family.rejected.formIntersection(ids)
            let eligible = values.filter { !family.rejected.contains($0.0.id) }.sorted { a, b in
                if a.0.priority != b.0.priority { return a.0.priority < b.0.priority }
                if a.0.started != b.0.started { return a.0.started < b.0.started }
                if a.0.order != b.0.order { return a.0.order < b.0.order }
                return a.0.id.uuidString < b.0.id.uuidString
            }
            if let (lease, macro) = eligible.last {
                let owns = ledger.claims[key.channel]?.owner == family.owner
                if macro.percentage == 0 {
                    // Zero affects only this family's claim; never another finger's stick.
                    if owns {
                        ledger.setPosition(.zero, owner: family.owner, channel: key.channel)
                        ledger.setRetained(lease.retained, owner: family.owner)
                    }
                } else if owns || lease.active {
                    if !owns { ledger.end(owner: family.owner); family.owner = UUID() }
                    switch ledger.request(owner: family.owner, macro: macro, retained: lease.retained, occupied: occupied) {
                    case .acquired:
                        family.hadClaim = true
                        if !owns { acquired.insert(key.channel.control) }
                        if !lease.active { ledger.setPosition(.zero, owner: family.owner, channel: key.channel) }
                    case .rejected:
                        family.rejected.formUnion(ids); family.hadClaim = false
                        ledger.end(owner: family.owner)
                    case .released: family.hadClaim = false
                    }
                }
            } else {
                ledger.end(owner: family.owner); family.hadClaim = false
            }
            family.known = ids; families[key] = family
        }
        return acquired
    }
}

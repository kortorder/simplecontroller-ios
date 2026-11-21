import Foundation

/// One owner UUID per deliberate payload activation. A failed acquisition is remembered until that
/// activation ends, so a held/timed command cannot wake up later merely because a channel became free.
struct FixedStickClaimLedger: Sendable {
    struct Claim: Equatable, Sendable {
        let owner: UUID
        var position: StickPosition
        var retained: Bool
    }
    enum Result: Equatable { case acquired(replaced: UUID?), rejected, released }
    private(set) var claims: [FixedStickChannel: Claim] = [:]
    private var rejected: [UUID: Set<FixedStickChannel>] = [:]
    func rejectedChannels(owner: UUID) -> Set<FixedStickChannel> { rejected[owner] ?? [] }
    var occupiedChannels: Set<ControllerControlID> { Set(claims.filter { !$0.value.retained }.keys.map(\.control)) }
    var retainedChannels: Set<ControllerControlID> { Set(claims.filter { $0.value.retained }.keys.map(\.control)) }

    @discardableResult
    mutating func request(owner: UUID, macro: FixedStickMacro, retained: Bool,
                          occupied: Set<ControllerControlID>) -> Result {
        let channel = macro.channel
        if macro.percentage == 0 {
            if claims[channel]?.owner == owner { claims[channel] = nil }
            return .released
        }
        guard rejected[owner]?.contains(channel) != true else { return .rejected }
        if occupied.contains(channel.control) {
            if claims[channel]?.owner == owner { claims[channel] = nil }
            reject(owner, channel)
            return .rejected
        }
        if let prior = claims[channel], prior.owner != owner {
            guard prior.retained else { reject(owner, channel); return .rejected }
            reject(prior.owner, channel)
            claims[channel] = .init(owner: owner, position: macro.position, retained: retained)
            return .acquired(replaced: prior.owner)
        }
        claims[channel] = .init(owner: owner, position: macro.position, retained: retained)
        return .acquired(replaced: nil)
    }
    mutating func setRetained(_ retained: Bool, owner: UUID) {
        for channel in FixedStickChannel.allCases where claims[channel]?.owner == owner {
            claims[channel]?.retained = retained
        }
    }
    /// An owned repeat OFF phase is neutral while retaining its channel reservation.
    mutating func setPosition(_ position: StickPosition, owner: UUID, channel: FixedStickChannel) {
        if claims[channel]?.owner == owner { claims[channel]?.position = position }
    }
    /// A deliberate manual/aim acquisition may take a retained macro. It cannot revive afterward.
    @discardableResult
    mutating func yieldRetained(channel: ControllerControlID) -> UUID? {
        guard let key = FixedStickChannel.allCases.first(where: { $0.control == channel }),
              let claim = claims[key], claim.retained else { return nil }
        claims[key] = nil; reject(claim.owner, key)
        return claim.owner
    }
    /// A repetition's off phase releases only this owner while keeping rejected-acquisition history.
    mutating func pause(owner: UUID) {
        claims = claims.filter { $0.value.owner != owner }
    }
    mutating func suppress(owner: UUID, channel: FixedStickChannel) {
        reject(owner, channel)
        if claims[channel]?.owner == owner { claims[channel] = nil }
    }
    mutating func suppress(owner: UUID) {
        for channel in FixedStickChannel.allCases { reject(owner, channel) }
        pause(owner: owner)
    }
    mutating func end(owner: UUID) { pause(owner: owner); rejected[owner] = nil }
    mutating func clear() { claims.removeAll(); rejected.removeAll() }
    private mutating func reject(_ owner: UUID, _ channel: FixedStickChannel) {
        rejected[owner, default: []].insert(channel)
    }
}

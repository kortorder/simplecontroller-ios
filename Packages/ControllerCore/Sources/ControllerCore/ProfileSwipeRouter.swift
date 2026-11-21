import Foundation

public enum ProfileSwipeMode: String, Codable, CaseIterable, Sendable { case off, buttons, controls }
public enum ProfileSwipeDecision: Equatable, Sendable {
    case moveCurrent
    case hold
    case transfer(to: UUID?)
}

/// Geometry stays in UIKit. This policy receives front-to-back hit IDs and decides ownership.
/// A proposed transfer is committed only after the input engine has accepted it.
public struct ProfileSwipeRouter: Sendable {
    private struct Route: Sendable {
        var current: UUID?
        var directOnly: Bool
        var pending: ProfileSwipeDecision?
    }
    public private(set) var profile: ControllerProfile
    private var controls: [UUID: ProfileControl]
    private var routes: [Int: Route] = [:]
    private var enteredAt: [UUID: TimeInterval] = [:]
    private var lastTime: TimeInterval?
    public init(profile: ControllerProfile) throws {
        try profile.validate(); self.profile = profile
        controls = Dictionary(uniqueKeysWithValues: profile.controls.map { ($0.id, $0) })
    }
    public mutating func apply(profile: ControllerProfile) throws {
        try profile.validate(); self.profile = profile
        controls = Dictionary(uniqueKeysWithValues: profile.controls.map { ($0.id, $0) })
        reset()
    }
    public mutating func reset() { routes.removeAll(); enteredAt.removeAll(); lastTime = nil }
    public mutating func end(contact: Int) { routes.removeValue(forKey: contact) }
    public func currentControl(for contact: Int) -> UUID? { routes[contact]?.current }
    public mutating func begin(contact: Int, control: UUID, at time: TimeInterval) throws {
        guard let target = controls[control] else { throw ControllerInputError.invalidControl }
        guard routes[contact] == nil else { throw ControllerInputError.duplicateContact }
        try advance(to: time)
        routes[contact] = Route(current: control, directOnly: target.isLocalAction || target.isAdvancedButton || target.isTouchAim)
    }
    public mutating func decision(contact: Int, hitControls: [UUID], unavailableControls: Set<UUID> = [],
                                  at time: TimeInterval) throws -> ProfileSwipeDecision {
        guard hitControls.count <= ControllerProfile.maximumControls, Set(hitControls).count == hitControls.count,
              hitControls.allSatisfy({ controls[$0] != nil }), unavailableControls.allSatisfy({ controls[$0] != nil }) else {
            throw ControllerInputError.invalidControl
        }
        try advance(to: time)
        guard let route = routes[contact] else { return .hold }
        let current = route.current.flatMap { controls[$0] }
        let result: ProfileSwipeDecision
        switch profile.swipeMode {
        case .off: result = .moveCurrent
        case .buttons:
            if current?.kind.isStick == true || current?.isTouchpad == true || current?.kind == .pageButton || current?.isAdvancedButton == true || current?.isTouchAim == true { result = .moveCurrent }
            else {
                let target = hitControls.first.flatMap { controls[$0] }
                if let target, target.id == route.current { result = .moveCurrent }
                else {
                    let eligible = target.flatMap { $0.kind == .button && $0.acceptsSwipeEntry && !unavailableControls.contains($0.id) ? $0.id : nil }
                    result = eligible == route.current ? .hold : .transfer(to: eligible)
                }
            }
        case .controls:
            if route.directOnly || route.current.map({ hitControls.contains($0) }) == true { result = .moveCurrent }
            else {
                let idle: ProfileSwipeDecision = current?.isTouchpad == true ? .moveCurrent : .hold
                if let id = hitControls.first, let target = controls[id], target.acceptsSwipeEntry,
                   !unavailableControls.contains(id), !occupied(id, excluding: contact),
                   enteredAt[id].map({ time + 1e-10 >= $0 + 0.120 }) ?? true {
                    result = .transfer(to: id)
                } else { result = idle }
            }
        }
        routes[contact]?.pending = result
        return result
    }
    public mutating func accept(contact: Int, target: UUID?, at time: TimeInterval) throws {
        guard routes[contact]?.pending == .transfer(to: target) else { throw ControllerInputError.invalidControl }
        try advance(to: time)
        if profile.swipeMode == .controls, let target { enteredAt[target] = time }
        routes[contact]?.current = target; routes[contact]?.pending = nil
    }
    private func occupied(_ id: UUID, excluding contact: Int) -> Bool {
        guard let target = controls[id], target.kind.isStick || target.isTouchpad else { return false }
        return routes.contains { token, route in
            guard token != contact, let otherID = route.current, let other = controls[otherID] else { return false }
            if target.isTouchpad || target.isDirectional { return otherID == id }
            return other.kind.isStick && !other.isDirectional && other.logicalStick == target.logicalStick
        }
    }
    private mutating func advance(to time: TimeInterval) throws {
        guard time.isFinite, time >= 0, lastTime.map({ time >= $0 }) ?? true else { throw ControllerInputError.invalidTime }
        lastTime = time
        // Profile limits bound this map; expired values need not survive indefinitely.
        enteredAt = enteredAt.filter { time < $0.value + 0.120 }
    }
}

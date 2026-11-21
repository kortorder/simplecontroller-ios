import Foundation

/// Detached view geometry, available before any UIKit view has been measured.
/// Boost annuli may extend outside the visible ring and never shrink its targets.
public struct FloatingRingGeometry: Equatable, Sendable {
    public let config: FloatingRingConfig
    public let visibleRadius: Double
    public let finishDiameter: Double = 48
    public var width: Double { visibleRadius * 2 }
    public var height: Double { width + finishDiameter }
    public var center: FloatingPoint { .init(x: visibleRadius, y: visibleRadius + finishDiameter) }
    public var finish: FloatingRect { .init(x: width - finishDiameter, y: 0, width: finishDiameter, height: finishDiameter) }

    public init(config: FloatingRingConfig) throws {
        try config.validate(); self.config = config
        let knobExtent = config.knobs.filter(\.enabled).map { hypot($0.x, $0.y) * config.innerRadius + $0.targetDiameter / 2 }.max() ?? 0
        visibleRadius = max(24, max(config.movement.enabled ? config.movementRadius : 0,
                                    config.aim.enabled ? max(config.innerRadius, knobExtent) : 0))
    }
    public func distance(to point: FloatingPoint) -> Double { hypot(point.x - center.x, point.y - center.y) }
    public func insideAim(_ point: FloatingPoint) -> Bool { point.isValid && distance(to: point) <= config.innerRadius }
    public func knobCenter(_ knob: RingAimKnob) -> FloatingPoint {
        .init(x: center.x + knob.x * config.innerRadius, y: center.y + knob.y * config.innerRadius)
    }
    public func knob(at point: FloatingPoint) -> RingAimKnob? {
        guard config.aim.enabled, insideAim(point) else { return nil }
        let enabled = config.knobs.filter(\.enabled)
        func gap(_ knob: RingAimKnob) -> Double {
            let c = knobCenter(knob); return hypot(point.x - c.x, point.y - c.y)
        }
        return enabled.filter { gap($0) <= $0.targetDiameter / 2 }.min { gap($0) < gap($1) }
            ?? enabled.first { $0.id == config.startKnobID } ?? enabled.first
    }
    public func boostDistance(_ stage: RingBoostStage, bank: RingBoostBank) -> Double {
        if let layout = config.boostBanks?[bank].geometry, layout.enabled {
            return layout.boost1Distance + (stage == .two ? layout.boost1Thickness : 0)
        }
        if bank == .aim && config.compactAimBoosts { return stage == .one ? config.innerRadius : config.movementRadius }
        if bank == .movement && config.adjacentMovementBoosts {
            let gap = config.boost(.two, bank: bank).distance - config.boost(.one, bank: bank).distance
            return config.movementRadius + (stage == .two ? gap : 0)
        }
        return config.boost(stage, bank: bank).distance
    }
    public func boostHysteresis(_ stage: RingBoostStage, bank: RingBoostBank) -> Double {
        let saved = config.boost(stage, bank: bank).hysteresis, radius = boostDistance(stage, bank: bank)
        if let layout = config.boostBanks?[bank].geometry, layout.enabled { return min(saved, min(radius, layout.boost1Thickness) / 2) }
        guard bank == .aim ? config.compactAimBoosts : config.adjacentMovementBoosts else { return saved }
        return min(saved, (stage == .one ? radius : radius - boostDistance(.one, bank: bank)) / 2)
    }
    public func directBand(_ stage: RingBoostStage, bank: RingBoostBank) -> ClosedRange<Double> {
        let settings = config.boost(stage, bank: bank)
        if let layout = config.boostBanks?[bank].geometry, layout.enabled {
            let start = layout.directStartDistance + (stage == .two ? layout.boost1Thickness : 0)
            return start...(start + (stage == .one ? layout.boost1Thickness : layout.boost2Thickness))
        }
        if config.compactAimBoosts || config.adjacentMovementBoosts {
            let width = bank == .aim && config.compactAimBoosts ? config.movementRadius - config.innerRadius
                : config.boost(.two, bank: bank).distance - config.boost(.one, bank: bank).distance
            let start = (config.movement.enabled ? config.movementRadius : config.innerRadius) + (stage == .two ? width : 0)
            return start...(start + (stage == .one ? width : settings.directOuterDistance - settings.directInnerDistance))
        }
        return settings.directInnerDistance...settings.directOuterDistance
    }
    public func directHit(_ stage: RingBoostStage, at point: FloatingPoint, bank selected: RingBoostBank? = nil) -> Bool {
        guard point.isValid else { return false }
        let bank = selected ?? config.directBoostBank, settings = config.boost(stage, bank: bank)
        return settings.enabled && settings.directTapEnabled && directBand(stage, bank: bank).contains(distance(to: point))
    }
    func enters(_ stage: RingBoostStage, distance: Double, bank: RingBoostBank) -> Bool {
        let boundary = boostDistance(stage, bank: bank)
        let closer = bank == .aim ? config.compactAimBoosts : config.adjacentMovementBoosts
        if stage == .one && (closer || boundary == config.innerRadius || boundary == config.movementRadius) {
            return distance > boundary
        }
        return distance >= boundary
    }
    public func role(at point: FloatingPoint) -> FloatingStartRole? {
        guard point.isValid, !finish.contains(point) else { return nil }
        if knob(at: point) != nil { return .aim }
        if config.movement.enabled && distance(to: point) <= config.movementRadius { return .movement }
        if directHit(.two, at: point) { return .boostTwo }
        if directHit(.one, at: point) { return .boostOne }
        return nil
    }
    public func startAnchor(role: FloatingStartRole? = nil, knobID: String? = nil) -> FloatingPoint {
        switch role ?? config.startRole {
        case .movement: return .init(x: center.x + config.movement.initialX * config.movementRadius,
                                     y: center.y + config.movement.initialY * config.movementRadius)
        case .aim:
            return config.knobs.first { $0.enabled && $0.id == (knobID ?? config.startKnobID) }.map(knobCenter) ?? center
        case .boostOne, .boostTwo:
            let boost = directBand((role ?? config.startRole) == .boostOne ? .one : .two, bank: config.directBoostBank)
            return .init(x: center.x, y: center.y - (boost.lowerBound + boost.upperBound) / 2)
        }
    }
    public func place(at touch: FloatingPoint, usable: FloatingRect) -> FloatingRingPlacement? {
        guard touch.isValid, usable.contains(touch),
              let placed = FloatingGeometry.place(width: width, height: height, anchor: startAnchor(), touch: touch, usable: usable) else { return nil }
        return .init(origin: placed.origin, grabOffset: placed.grabOffset,
                     bounds: .init(x: placed.origin.x, y: placed.origin.y, width: width, height: height),
                     finish: finish.translated(x: placed.origin.x, y: placed.origin.y))
    }
    public func unreachableDirections(_ stage: RingBoostStage, origin: FloatingPoint, usable: FloatingRect, bank selected: RingBoostBank? = nil) -> Set<StickDirection> {
        let bank = selected ?? config.bank(for: config.startRole), boost = config.boost(stage, bank: bank)
        guard boost.enabled else { return [] }
        let c = FloatingPoint(x: origin.x + center.x, y: origin.y + center.y), radius = boostDistance(stage, bank: bank)
        let points: [StickDirection: FloatingPoint] = [.up: .init(x: c.x, y: c.y - radius), .down: .init(x: c.x, y: c.y + radius),
                                                       .left: .init(x: c.x - radius, y: c.y), .right: .init(x: c.x + radius, y: c.y)]
        return Set(points.filter { !usable.contains($0.value) }.map(\.key))
    }
    /// Physical geometry is +Y down; native stick output is +Y up.
    public func movementVector(at point: FloatingPoint) -> StickPosition {
        guard point.isValid else { return .zero }
        let dx = point.x - center.x, dy = point.y - center.y, distance = hypot(dx, dy)
        guard distance > 0 else { return .zero }
        let scale = min(1, distance / config.movementRadius) / distance
        return .init(x: dx * scale, y: -dy * scale)
    }
    /// Source uses signed projection hysteresis, including reversal on the same axis.
    public func boostDirection(at point: FloatingPoint, previous: StickDirection? = nil) -> StickDirection {
        let dx = point.x - center.x, dy = point.y - center.y
        let selected: StickDirection = abs(dx) >= abs(dy) ? (dx >= 0 ? .right : .left) : (dy >= 0 ? .down : .up)
        func projection(_ direction: StickDirection) -> Double {
            switch direction { case .up: -dy; case .right: dx; case .down: dy; case .left: -dx }
        }
        if let previous, selected != previous, projection(selected) < projection(previous) + 12 { return previous }
        return selected
    }
}

public struct FloatingRingPlacement: Equatable, Sendable {
    public let origin: FloatingPoint
    public let grabOffset: FloatingPoint
    public let bounds: FloatingRect
    public let finish: FloatingRect
    public func local(_ point: FloatingPoint, applyGrabOffset: Bool) -> FloatingPoint {
        .init(x: point.x - origin.x - (applyGrabOffset ? grabOffset.x : 0),
              y: point.y - origin.y - (applyGrabOffset ? grabOffset.y : 0))
    }
}

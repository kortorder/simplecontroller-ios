import Foundation

/// Entry exclusion never prevents an already captured member from transferring out.
public struct FloatingButtonRouting: Equatable, Sendable {
    public var transferableMembers: Set<UUID>
    public var entryEnabledMembers: Set<UUID>
    public init(transferableMembers: Set<UUID>, entryEnabledMembers: Set<UUID>) {
        self.transferableMembers = transferableMembers; self.entryEnabledMembers = entryEnabledMembers
    }
}

/// The adapter executes these synchronously and returns whether ownership was accepted.
/// finishScope must cancel only these owners, including their retained/pending outputs,
/// without synthesizing a normal lift or release shot.
public enum FloatingButtonCommand: Equatable, Sendable {
    case begin(member: UUID, contact: Int, sample: ButtonPointerSample)
    case move(member: UUID, contact: Int, samples: [ButtonPointerSample])
    case handoff(contact: Int, from: UUID, to: UUID, departing: ButtonPointerSample, arriving: ButtonPointerSample)
    case end(member: UUID, contact: Int, samples: [ButtonPointerSample])
    case cancel(member: UUID, contact: Int)
    case finishScope(memberIDs: Set<UUID>)
}

public struct FloatingButtonPlacement: Equatable, Sendable {
    public let bounds: FloatingRect
    public let finish: FloatingRect
    public let members: [FloatingMemberGeometry]
    public let grabOffset: FloatingPoint
}

/// Detached, runtime-only session. It does not own platform timers or mutate templates.
/// Root page/epoch changes must finish/remove the session before accepting a new canvas.
public struct FloatingButtonSession: Sendable {
    public let sessionID: UUID
    public let zoneID: UUID
    public let placement: FloatingButtonPlacement
    public private(set) var activeContact: Int?
    public private(set) var capturedMemberID: UUID?
    public private(set) var isFinished = false
    private let zone: FloatingButtonZone
    private let routing: FloatingButtonRouting
    private let initialTouch: FloatingPoint
    private var lastPoint: FloatingPoint
    private var initialBegan = false
    private var usesInitialOffset = false
    private var finishEntry: FloatingFinishEntryGuard

    public init(zone: FloatingButtonZone, orientation: ControllerOrientation,
                canonicalGeometry: [UUID: FloatingRect], touch: FloatingPoint, usable: FloatingRect,
                routing: FloatingButtonRouting, sessionID: UUID = UUID(), finishHeight: Double = 48) throws {
        try zone.validate()
        guard zone.enabled else { throw FloatingControlError("This floating activation zone is disabled.") }
        let ids = Set(zone.memberIDs)
        guard routing.transferableMembers.isSubset(of: ids),
              routing.entryEnabledMembers.isSubset(of: routing.transferableMembers) else {
            throw FloatingControlError("Floating swipe routing contains an invalid member.")
        }
        guard touch.isValid, usable.contains(touch), finishHeight.isFinite, (44...200).contains(finishHeight) else {
            throw FloatingControlError("A floating control must start inside the usable canvas.")
        }
        let members = try zone.resolvedMembers(for: orientation, canonical: canonicalGeometry)
        guard let bounds = FloatingGeometry.bounds(of: members.map(\.frame)) else {
            throw FloatingControlError("The floating group has no valid member bounds.")
        }
        let start = members.first { $0.id == zone.startMemberID }?.frame
        let anchor = FloatingPoint(x: start.map { $0.center.x - bounds.x } ?? bounds.width / 2,
                                   y: (start.map { $0.center.y - bounds.y } ?? bounds.height / 2) + finishHeight)
        guard let fit = FloatingGeometry.place(width: bounds.width, height: bounds.height + finishHeight,
                                                anchor: anchor, touch: touch, usable: usable) else {
            throw FloatingControlError("This floating control does not fit. Edit its size or arrangement; targets were not shrunk.")
        }
        let finish = FloatingRect(x: fit.origin.x, y: fit.origin.y, width: bounds.width, height: finishHeight)
        placement = .init(bounds: .init(x: fit.origin.x, y: fit.origin.y, width: bounds.width, height: bounds.height + finishHeight),
                          finish: finish, members: members.map {
                              .init(id: $0.id, frame: $0.frame.translated(x: fit.origin.x - bounds.x,
                                                                       y: fit.origin.y + finishHeight - bounds.y))
                          }, grabOffset: fit.grabOffset)
        self.zone = zone; zoneID = zone.id; self.sessionID = sessionID; self.routing = routing
        initialTouch = touch; lastPoint = touch
        finishEntry = .init(initiallyInside: finish.contains(touch))
    }

    /// The summoning contact is either the configured start member or reveal-only for its entire gesture.
    @discardableResult
    public mutating func beginActivation(contact: Int, sessionID token: UUID,
                                         dispatch: (FloatingButtonCommand) -> Bool) -> Bool {
        guard current(token), !initialBegan, activeContact == nil else { return false }
        initialBegan = true; activeContact = contact; usesInitialOffset = true; lastPoint = initialTouch
        if let id = zone.startMemberID,
           dispatch(.begin(member: id, contact: contact, sample: sample(initialTouch, member: id, initial: true))) {
            capturedMemberID = id
        }
        return true
    }

    /// Later direct touches use visible member hit targets and no summon correction.
    @discardableResult
    public mutating func begin(contact: Int, at point: FloatingPoint, sessionID token: UUID,
                               dispatch: (FloatingButtonCommand) -> Bool) -> Bool {
        guard current(token), activeContact == nil, point.isValid else { return false }
        if placement.finish.contains(point) { finish(sessionID: token, dispatch: dispatch); return true }
        guard let target = placement.members.last(where: { $0.frame.contains(point) }) else { return false }
        initialBegan = true; activeContact = contact; usesInitialOffset = false; lastPoint = point
        finishEntry = .init()
        if dispatch(.begin(member: target.id, contact: contact, sample: sample(point, member: target.id, initial: false))) {
            capturedMemberID = target.id
        }
        return true
    }

    /// Preflight the complete path before timers/ownership can change. The adapter must cancel
    /// a rejected malformed platform packet rather than retrying part of it.
    @discardableResult
    public mutating func move(contact: Int, through points: [FloatingPoint], sessionID token: UUID,
                              dispatch: (FloatingButtonCommand) -> Bool) throws -> Bool {
        guard current(token), activeContact == contact else { return false }
        try validate(points)
        if crossedFinish(points) { finish(sessionID: token, dispatch: dispatch); return true }
        guard capturedMemberID != nil else { if let last = points.last { lastPoint = last }; return true }
        var pending: [FloatingPoint] = []
        for point in points {
            if zone.groupSwipe, let from = capturedMemberID, routing.transferableMembers.contains(from),
               let target = placement.members.last(where: { routing.entryEnabledMembers.contains($0.id) && $0.frame.contains(point) }),
               target.id != from {
                let accepted = dispatch(.handoff(contact: contact, from: from, to: target.id,
                                                  departing: sample(point, member: from, initial: usesInitialOffset),
                                                  arriving: sample(point, member: target.id, initial: false)))
                if accepted {
                    // Ordinary button positions before a transfer have no output meaning. Do not
                    // advance their pending Hold Toggle timer before the atomic departure cancels it.
                    pending.removeAll(keepingCapacity: true)
                    capturedMemberID = target.id; usesInitialOffset = false
                }
            }
            pending.append(point); lastPoint = point
        }
        if let id = capturedMemberID, !pending.isEmpty {
            _ = dispatch(.move(member: id, contact: contact,
                               samples: pending.map { sample($0, member: id, initial: usesInitialOffset) }))
        }
        return true
    }

    /// Final coalesced samples stay one terminal event. They must not mature overdue work
    /// through synthetic MOVE events before the owning engine handles normal lift.
    @discardableResult
    public mutating func end(contact: Int, through points: [FloatingPoint] = [], sessionID token: UUID,
                             dispatch: (FloatingButtonCommand) -> Bool) throws -> Bool {
        guard current(token), activeContact == contact else { return false }
        try validate(points)
        if crossedFinish(points) { finish(sessionID: token, dispatch: dispatch); return true }
        if let id = capturedMemberID {
            let final = points.isEmpty ? [lastPoint] : points
            _ = dispatch(.end(member: id, contact: contact,
                              samples: final.map { sample($0, member: id, initial: usesInitialOffset) }))
        }
        activeContact = nil; capturedMemberID = nil; usesInitialOffset = false
        return true
    }

    @discardableResult
    public mutating func cancel(contact: Int, sessionID token: UUID,
                                dispatch: (FloatingButtonCommand) -> Bool) -> Bool {
        guard current(token), activeContact == contact else { return false }
        if let id = capturedMemberID { _ = dispatch(.cancel(member: id, contact: contact)) }
        activeContact = nil; capturedMemberID = nil; usesInitialOffset = false
        return true
    }

    @discardableResult
    public mutating func finish(sessionID token: UUID, dispatch: (FloatingButtonCommand) -> Bool) -> Bool {
        guard current(token) else { return false }
        isFinished = true; activeContact = nil; capturedMemberID = nil
        _ = dispatch(.finishScope(memberIDs: Set(zone.memberIDs)))
        return true
    }

    private func current(_ token: UUID) -> Bool { token == sessionID && !isFinished }
    private func sample(_ point: FloatingPoint, member id: UUID, initial: Bool) -> ButtonPointerSample {
        let frame = placement.members.first { $0.id == id }!.frame
        return .init(x: point.x - frame.x - (initial ? placement.grabOffset.x : 0),
                     y: point.y - frame.y - (initial ? placement.grabOffset.y : 0),
                     width: frame.width, height: frame.height)
    }
    private func validate(_ points: [FloatingPoint]) throws {
        guard points.count <= 256, points.allSatisfy(\.isValid), points.allSatisfy({ point in
            placement.members.allSatisfy { member in
                sample(point, member: member.id, initial: false).isValid &&
                (member.id != capturedMemberID || !usesInitialOffset || sample(point, member: member.id, initial: true).isValid)
            }
        }) else { throw FloatingControlError("The floating touch path is invalid or too large; cancel this contact.") }
    }
    private mutating func crossedFinish(_ points: [FloatingPoint]) -> Bool {
        guard !zone.finishIgnoresSwipes else { return false }
        for point in points where finishEntry.observe(inside: placement.finish.contains(point)) { return true }
        return false
    }
}

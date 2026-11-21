import Foundation

/// Ephemeral measurements supplied by the actual canvas, never a device-size guess.
public struct FloatingCanvasSnapshot: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var frames: [UUID: FloatingRect]
    public init(width: Double, height: Double, frames: [UUID: FloatingRect]) {
        self.width = width; self.height = height; self.frames = frames
    }
    public var usable: FloatingRect { .init(x: 0, y: 0, width: width, height: height) }
    public func validate() throws {
        guard width.isFinite, height.isFinite, (1...65_536).contains(width), (1...65_536).contains(height),
              frames.count <= ControllerProfile.maximumControls, frames.values.allSatisfy({ $0.isValid && (1...1200).contains($0.width) && (1...1200).contains($0.height) }) else {
            throw FloatingControlError("Open this layout orientation to measure its actual canvas before editing the floating control.")
        }
    }
    func selected(_ ids: [UUID]) throws -> [FloatingMemberGeometry] {
        try validate()
        return try ids.map { id in
            guard let frame = frames[id] else { throw FloatingControlError("Every selected button must have a measured frame in this orientation.") }
            return .init(id: id, frame: frame)
        }
    }
}

public extension ControllerProfile {
    /// Conversion captures detached member/restoration frames. Canonical controls and both
    /// normalized layouts are left intact, so Unfloat exposes their exact original positions.
    @discardableResult
    mutating func convertToFloatingButtons(on pageID: UUID, memberIDs: [UUID], kind: FloatingButtonZoneKind,
                                           name: String, startMemberID: UUID? = nil, groupSwipe: Bool = false,
                                           snapshots: [ControllerOrientation: FloatingCanvasSnapshot]) throws -> UUID {
        try validate()
        guard let index = pages.firstIndex(where: { $0.id == pageID }), !snapshots.isEmpty,
              !memberIDs.isEmpty, Set(memberIDs).count == memberIDs.count,
              Set(memberIDs).isSubset(of: pages[index].controlIDs),
              Set(memberIDs).isDisjoint(with: pages[index].floatingMemberIDs),
              memberIDs.allSatisfy({ control(for: $0)?.kind == .button }) else {
            throw FloatingControlError("Choose distinct ordinary buttons on this page that do not already belong to a floating zone.")
        }
        var zone = FloatingButtonZone(name: name, kind: kind, memberIDs: memberIDs,
                                      startMemberID: kind == .singleButton ? (startMemberID ?? memberIDs.first) : startMemberID,
                                      groupSwipe: groupSwipe)
        for (orientation, snapshot) in snapshots {
            let members = try snapshot.selected(memberIDs)
            try checkFloatingArrangementFits(members, snapshot: snapshot)
            guard let bounds = FloatingGeometry.bounds(of: members.map(\.frame)) else { throw FloatingControlError("The selected buttons have no usable bounds.") }
            let geometry = FloatingZoneGeometry(canvasWidth: snapshot.width, canvasHeight: snapshot.height, zone: bounds)
            if orientation == .portrait {
                zone.portraitGeometry = geometry; zone.portraitMembers = members; zone.portraitRestoration = members
            } else {
                zone.landscapeGeometry = geometry; zone.landscapeMembers = members; zone.landscapeRestoration = members
            }
        }
        try zone.validate()
        var next = self; next.pages[index].floatingButtonZones.append(zone); try next.validate(); self = next
        return zone.id
    }
    /// Visit an orientation before editing it. Only the activation rectangle scales; detached
    /// member sizes/spacing use the source fallback, and restoration records real measurements.
    mutating func prepareFloatingButtonOrientation(_ zoneID: UUID, on pageID: UUID,
                                                   orientation: ControllerOrientation, snapshot: FloatingCanvasSnapshot) throws {
        try validate(); try snapshot.validate()
        guard let page = pages.firstIndex(where: { $0.id == pageID }),
              let index = pages[page].floatingButtonZones.firstIndex(where: { $0.id == zoneID }) else {
            throw FloatingControlError("This floating button zone is no longer on the page.")
        }
        var zone = pages[page].floatingButtonZones[index]
        let canonical = try snapshot.selected(zone.memberIDs)
        let detached = try zone.resolvedMembers(for: orientation, canonical: snapshot.frames)
        try checkFloatingArrangementFits(detached, snapshot: snapshot)
        if zone.geometry(for: orientation) == nil {
            guard let alternate = zone.geometry(for: orientation == .portrait ? .landscape : .portrait) else {
                throw FloatingControlError("This zone has no saved activation geometry to copy.")
            }
            let rectangle = try alternate.resolved(canvasWidth: snapshot.width, canvasHeight: snapshot.height)
            let geometry = FloatingZoneGeometry(canvasWidth: snapshot.width, canvasHeight: snapshot.height, zone: rectangle)
            if orientation == .portrait {
                zone.portraitGeometry = geometry; zone.portraitMembers = detached; zone.portraitRestoration = canonical
            } else {
                zone.landscapeGeometry = geometry; zone.landscapeMembers = detached; zone.landscapeRestoration = canonical
            }
        }
        var next = self; next.pages[page].floatingButtonZones[index] = zone; try next.validate(); self = next
    }
    mutating func setFloatingZoneGeometry(_ zoneID: UUID, on pageID: UUID, orientation: ControllerOrientation,
                                          rectangle: FloatingRect, canvasWidth: Double, canvasHeight: Double) throws {
        try validate()
        let canvas = FloatingRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        guard canvas.contains(rectangle), let page = pages.firstIndex(where: { $0.id == pageID }) else {
            throw FloatingControlError("Keep the activation zone inside the measured canvas.")
        }
        let geometry = FloatingZoneGeometry(canvasWidth: canvasWidth, canvasHeight: canvasHeight, zone: rectangle)
        try geometry.validate(); var next = self
        if let index = next.pages[page].floatingButtonZones.firstIndex(where: { $0.id == zoneID }) {
            guard next.pages[page].floatingButtonZones[index].geometry(for: orientation) != nil else {
                throw FloatingControlError("Prepare this orientation from its measured canvas before moving the activation zone.")
            }
            if orientation == .portrait { next.pages[page].floatingButtonZones[index].portraitGeometry = geometry }
            else { next.pages[page].floatingButtonZones[index].landscapeGeometry = geometry }
        } else if let index = next.pages[page].floatingRingZones.firstIndex(where: { $0.id == zoneID }) {
            if orientation == .portrait { next.pages[page].floatingRingZones[index].portraitGeometry = geometry }
            else { next.pages[page].floatingRingZones[index].landscapeGeometry = geometry }
        } else { throw FloatingControlError("This floating zone is no longer on the page.") }
        try next.validate(); self = next
    }
    /// Move a detached member only. The original canonical layout and restoration snapshot
    /// remain unchanged; the complete arrangement including Finish must still fit.
    mutating func setFloatingMemberFrame(_ memberID: UUID, zoneID: UUID, on pageID: UUID,
                                         orientation: ControllerOrientation, frame: FloatingRect,
                                         snapshot: FloatingCanvasSnapshot) throws {
        try validate(); try snapshot.validate()
        guard frame.isValid, (1...1200).contains(frame.width), (1...1200).contains(frame.height),
              let page = pages.firstIndex(where: { $0.id == pageID }),
              let index = pages[page].floatingButtonZones.firstIndex(where: { $0.id == zoneID }) else {
            throw FloatingControlError("The detached member frame is invalid.")
        }
        var zone = pages[page].floatingButtonZones[index]
        guard zone.memberIDs.contains(memberID), zone.geometry(for: orientation) != nil else {
            throw FloatingControlError("Prepare this orientation before editing one of its members.")
        }
        var members = try zone.resolvedMembers(for: orientation, canonical: snapshot.frames)
        guard let member = members.firstIndex(where: { $0.id == memberID }) else { throw ControllerProfileError.unknownControl }
        members[member].frame = frame; try checkFloatingArrangementFits(members, snapshot: snapshot)
        if orientation == .portrait { zone.portraitMembers = members } else { zone.landscapeMembers = members }
        var next = self; next.pages[page].floatingButtonZones[index] = zone; try next.validate(); self = next
    }
    /// Canonical positions are deliberately never rewritten by the floating workflow.
    mutating func unfloatButtons(_ zoneID: UUID, on pageID: UUID) throws {
        try validate()
        guard let page = pages.firstIndex(where: { $0.id == pageID }), pages[page].floatingButtonZones.contains(where: { $0.id == zoneID }) else {
            throw FloatingControlError("This floating button zone is no longer on the page.")
        }
        var next = self; next.pages[page].floatingButtonZones.removeAll { $0.id == zoneID }
        try next.validate(); self = next
    }
}

private func checkFloatingArrangementFits(_ members: [FloatingMemberGeometry], snapshot: FloatingCanvasSnapshot) throws {
    guard let bounds = FloatingGeometry.bounds(of: members.map(\.frame)),
          bounds.width <= snapshot.width, bounds.height + 48 <= snapshot.height else {
        throw FloatingControlError("The group and its 48-point Finish target do not fit this orientation. Move its members closer together or use a smaller group.")
    }
}

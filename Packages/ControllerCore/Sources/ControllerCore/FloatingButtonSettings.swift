import Foundation

public enum FloatingButtonZoneKind: String, Codable, CaseIterable, Sendable { case singleButton, buttonGroup }

public struct FloatingMemberGeometry: Codable, Equatable, Sendable {
    public var id: UUID
    public var frame: FloatingRect
    public init(id: UUID, frame: FloatingRect) { self.id = id; self.frame = frame }
    private enum CodingKeys: String, CodingKey { case id, frame }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["id", "frame"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); frame = try c.decode(FloatingRect.self, forKey: .frame)
    }
}

/// Page-owned saved template only. Runtime summons never overwrite these snapshots.
/// Disabled zones still own/hide their members; converting back is an explicit restore action.
public struct FloatingButtonZone: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: FloatingButtonZoneKind
    public var enabled: Bool
    public var memberIDs: [UUID]
    public var startMemberID: UUID?
    public var groupSwipe: Bool
    public var portraitGeometry: FloatingZoneGeometry?
    public var landscapeGeometry: FloatingZoneGeometry?
    public var portraitMembers: [FloatingMemberGeometry]
    public var landscapeMembers: [FloatingMemberGeometry]
    public var portraitRestoration: [FloatingMemberGeometry]
    public var landscapeRestoration: [FloatingMemberGeometry]

    public var finishIgnoresSwipes: Bool = false
    public init(id: UUID = UUID(), name: String = "Floating control", kind: FloatingButtonZoneKind,
                enabled: Bool = true, memberIDs: [UUID], startMemberID: UUID?, groupSwipe: Bool = false,
                portraitGeometry: FloatingZoneGeometry? = nil, landscapeGeometry: FloatingZoneGeometry? = nil,
                portraitMembers: [FloatingMemberGeometry] = [], landscapeMembers: [FloatingMemberGeometry] = [],
                portraitRestoration: [FloatingMemberGeometry] = [], landscapeRestoration: [FloatingMemberGeometry] = []) {
        self.id = id; self.name = name; self.kind = kind; self.enabled = enabled; self.memberIDs = memberIDs
        self.startMemberID = startMemberID; self.groupSwipe = groupSwipe
        self.portraitGeometry = portraitGeometry; self.landscapeGeometry = landscapeGeometry
        self.portraitMembers = portraitMembers; self.landscapeMembers = landscapeMembers
        self.portraitRestoration = portraitRestoration; self.landscapeRestoration = landscapeRestoration
    }
    public func geometry(for orientation: ControllerOrientation) -> FloatingZoneGeometry? {
        orientation == .portrait ? portraitGeometry : landscapeGeometry
    }
    public func members(for orientation: ControllerOrientation) -> [FloatingMemberGeometry] {
        orientation == .portrait ? portraitMembers : landscapeMembers
    }
    public func restoration(for orientation: ControllerOrientation) -> [FloatingMemberGeometry] {
        orientation == .portrait ? portraitRestoration : landscapeRestoration
    }
    public func routing(in profile: ControllerProfile) -> FloatingButtonRouting {
        let transferable = Set(memberIDs.filter { id in
            guard let control = profile.control(for: id) else { return false }
            return control.kind == .button && !control.isLocalAction && !control.isAdvancedButton
        })
        return .init(transferableMembers: transferable,
                     entryEnabledMembers: Set(transferable.filter { profile.control(for: $0)?.acceptsSwipeEntry == true }))
    }
    public func replacingIDs(controls: [UUID: UUID], zoneID: UUID = UUID()) throws -> Self {
        guard Set(memberIDs).isSubset(of: controls.keys), Set(controls.values).count == controls.count else {
            throw FloatingControlError("Copying a floating group needs distinct replacement IDs for every member.")
        }
        var copy = self; copy.id = zoneID; copy.memberIDs = memberIDs.map { controls[$0]! }
        copy.startMemberID = startMemberID.map { controls[$0]! }
        func remap(_ values: [FloatingMemberGeometry]) -> [FloatingMemberGeometry] {
            values.map { .init(id: controls[$0.id]!, frame: $0.frame) }
        }
        copy.portraitMembers = remap(portraitMembers); copy.landscapeMembers = remap(landscapeMembers)
        copy.portraitRestoration = remap(portraitRestoration); copy.landscapeRestoration = remap(landscapeRestoration)
        try copy.validate(); return copy
    }
    public func validate() throws {
        let ids = Set(memberIDs)
        guard (1...64).contains(name.count), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...64).contains(memberIDs.count), ids.count == memberIDs.count,
              !ids.contains(id), startMemberID.map(ids.contains) ?? true else {
            throw FloatingControlError("A floating control needs a name, distinct members and a valid starting member.")
        }
        if kind == .singleButton && (memberIDs.count != 1 || startMemberID != memberIDs.first) {
            throw FloatingControlError("A single floating button must start on its only member.")
        }
        guard portraitGeometry != nil || landscapeGeometry != nil else {
            throw FloatingControlError("A floating control needs a saved activation zone.")
        }
        try portraitGeometry?.validate(); try landscapeGeometry?.validate()
        for values in [portraitMembers, landscapeMembers, portraitRestoration, landscapeRestoration] {
            guard Set(values.map(\.id)).count == values.count, Set(values.map(\.id)).isSubset(of: ids),
                  values.allSatisfy({ $0.frame.isValid && (1...1200).contains($0.frame.width) && (1...1200).contains($0.frame.height) }) else {
                throw FloatingControlError("Floating member geometry must be distinct, valid and belong to this group.")
            }
        }
        if kind == .buttonGroup {
            for orientation in ControllerOrientation.allCases where geometry(for: orientation) != nil {
                guard Set(members(for: orientation).map(\.id)) == ids,
                      Set(restoration(for: orientation).map(\.id)) == ids else {
                    throw FloatingControlError("Each saved group orientation needs complete member and restoration geometry.")
                }
            }
        }
    }
    /// Context validation remains explicit until this type is integrated into native format 12.
    public static func validate(_ zones: [FloatingButtonZone], pageControlIDs: Set<UUID>, buttonIDs: Set<UUID>) throws {
        guard zones.count <= 64, Set(zones.map(\.id)).count == zones.count,
              Set(zones.map(\.id)).isDisjoint(with: pageControlIDs), buttonIDs.isSubset(of: pageControlIDs) else {
            throw FloatingControlError("Floating zone IDs must be unique and separate from page controls.")
        }
        var used = Set<UUID>()
        for zone in zones {
            try zone.validate()
            let members = Set(zone.memberIDs)
            guard members.isSubset(of: buttonIDs), used.isDisjoint(with: members) else {
                throw FloatingControlError("Each floating member must be a button on this page and belong to only one zone.")
            }
            used.formUnion(members)
        }
    }
    public func resolvedMembers(for orientation: ControllerOrientation, canonical: [UUID: FloatingRect]) throws -> [FloatingMemberGeometry] {
        try validate()
        let current = Dictionary(uniqueKeysWithValues: members(for: orientation).map { ($0.id, $0.frame) })
        let alternate = Dictionary(uniqueKeysWithValues: members(for: orientation == .portrait ? .landscape : .portrait).map { ($0.id, $0.frame) })
        let ids = Set(memberIDs)
        let chosen: [UUID: FloatingRect]
        if Set(current.keys).isSuperset(of: ids) { chosen = current }
        else if Set(alternate.keys).isSuperset(of: ids) { chosen = alternate }
        else { chosen = current.merging(alternate) { first, _ in first }.merging(canonical) { first, _ in first } }
        return try memberIDs.map { id in
            guard let frame = chosen[id], frame.isValid,
                  (1...1200).contains(frame.width), (1...1200).contains(frame.height) else {
                throw FloatingControlError("A floating member is missing its canonical geometry.")
            }
            return .init(id: id, frame: frame)
        }
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, memberIDs, startMemberID, groupSwipe, portraitGeometry, landscapeGeometry
        case portraitMembers, landscapeMembers, portraitRestoration, landscapeRestoration, finishIgnoresSwipes
    }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["id", "name", "kind", "enabled", "memberIDs", "startMemberID", "groupSwipe", "portraitGeometry", "landscapeGeometry", "portraitMembers", "landscapeMembers", "portraitRestoration", "landscapeRestoration"], optional: ["finishIgnoresSwipes"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        finishIgnoresSwipes = try c.decodeIfPresent(Bool.self, forKey: .finishIgnoresSwipes) ?? false
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(FloatingButtonZoneKind.self, forKey: .kind); enabled = try c.decode(Bool.self, forKey: .enabled)
        memberIDs = try c.decode([UUID].self, forKey: .memberIDs); startMemberID = try c.decodeIfPresent(UUID.self, forKey: .startMemberID)
        groupSwipe = try c.decode(Bool.self, forKey: .groupSwipe)
        portraitGeometry = try c.decodeIfPresent(FloatingZoneGeometry.self, forKey: .portraitGeometry)
        landscapeGeometry = try c.decodeIfPresent(FloatingZoneGeometry.self, forKey: .landscapeGeometry)
        portraitMembers = try c.decode([FloatingMemberGeometry].self, forKey: .portraitMembers)
        landscapeMembers = try c.decode([FloatingMemberGeometry].self, forKey: .landscapeMembers)
        portraitRestoration = try c.decode([FloatingMemberGeometry].self, forKey: .portraitRestoration)
        landscapeRestoration = try c.decode([FloatingMemberGeometry].self, forKey: .landscapeRestoration)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        if finishIgnoresSwipes { try c.encode(true, forKey: .finishIgnoresSwipes) }
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind)
        try c.encode(enabled, forKey: .enabled); try c.encode(memberIDs, forKey: .memberIDs)
        try c.encode(startMemberID, forKey: .startMemberID); try c.encode(groupSwipe, forKey: .groupSwipe)
        try c.encode(portraitGeometry, forKey: .portraitGeometry); try c.encode(landscapeGeometry, forKey: .landscapeGeometry)
        try c.encode(portraitMembers, forKey: .portraitMembers); try c.encode(landscapeMembers, forKey: .landscapeMembers)
        try c.encode(portraitRestoration, forKey: .portraitRestoration); try c.encode(landscapeRestoration, forKey: .landscapeRestoration)
    }
}

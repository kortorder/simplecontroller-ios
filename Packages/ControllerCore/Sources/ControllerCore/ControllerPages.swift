import Foundation

/// Local navigation only. No page action is encoded in controller transport output.
public enum ProfilePageNavigation: Equatable, Sendable, Codable {
    case goTo(UUID), toggle(UUID), back, home
    public var targetPageID: UUID? {
        switch self { case let .goTo(id), let .toggle(id): id; case .back, .home: nil }
    }
    private enum CodingKeys: String, CodingKey { case action, targetPageID }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["action", "targetPageID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let target = try values.decodeIfPresent(UUID.self, forKey: .targetPageID)
        switch try values.decode(String.self, forKey: .action) {
        case "goTo": guard let target else { throw ControllerProfileError.invalidNavigation }; self = .goTo(target)
        case "toggle": guard let target else { throw ControllerProfileError.invalidNavigation }; self = .toggle(target)
        case "back": guard target == nil else { throw ControllerProfileError.invalidNavigation }; self = .back
        case "home": guard target == nil else { throw ControllerProfileError.invalidNavigation }; self = .home
        default: throw ControllerProfileError.invalidNavigation
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let action: String
        switch self { case .goTo: action = "goTo"; case .toggle: action = "toggle"; case .back: action = "back"; case .home: action = "home" }
        try values.encode(action, forKey: .action); try values.encode(targetPageID, forKey: .targetPageID)
    }
    func remapping(_ ids: [UUID: UUID]) -> Self {
        switch self {
        case let .goTo(id): .goTo(ids[id] ?? id)
        case let .toggle(id): .toggle(ids[id] ?? id)
        case .back, .home: self
        }
    }
}

/// Ordered membership only; flat profile geometry retains its existing orientation/z-order data.
public struct ProfilePage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var controlIDs: [UUID]
    public var floatingButtonZones: [FloatingButtonZone]
    public var floatingRingZones: [FloatingRingZone]
    public init(id: UUID = UUID(), name: String = "Page", controlIDs: [UUID] = [],
                floatingButtonZones: [FloatingButtonZone] = [], floatingRingZones: [FloatingRingZone] = []) {
        self.id = id; self.name = name; self.controlIDs = controlIDs
        self.floatingButtonZones = floatingButtonZones; self.floatingRingZones = floatingRingZones
    }
    /// Disabled templates continue to own their members; removing the zone restores them.
    public var floatingMemberIDs: Set<UUID> { Set(floatingButtonZones.flatMap(\.memberIDs)) }
    public func validate() throws {
        try validateProfileName(name)
        guard Set(controlIDs).count == controlIDs.count else { throw ControllerProfileError.invalidPageMembership }
        let zones = floatingButtonZones.map(\.id) + floatingRingZones.map(\.id)
        guard zones.count <= 64, Set(zones).count == zones.count, Set(zones).isDisjoint(with: controlIDs) else {
            throw FloatingControlError("A page supports up to 64 distinct floating zones, separate from control IDs.")
        }
        for zone in floatingButtonZones { try zone.validate() }
        for zone in floatingRingZones { try zone.validate() }
    }
    private enum CodingKeys: String, CodingKey { case id, name, controlIDs, floatingButtonZones, floatingRingZones }
    public init(from decoder: Decoder) throws { try self.init(from: decoder, libraryVersion: ControllerProfileLibrary.currentVersion) }
    init(from decoder: Decoder, libraryVersion: Int) throws {
        try profileKeys(decoder, libraryVersion < 12 ? ["id", "name", "controlIDs"] : ["id", "name", "controlIDs", "floatingButtonZones", "floatingRingZones"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        controlIDs = try values.decode([UUID].self, forKey: .controlIDs)
        floatingButtonZones = libraryVersion < 12 ? [] : try values.decode([FloatingButtonZone].self, forKey: .floatingButtonZones)
        floatingRingZones = libraryVersion < 12 ? [] : try values.decode([FloatingRingZone].self, forKey: .floatingRingZones)
        if libraryVersion < 21 &&
            (floatingButtonZones.contains(where: \.finishIgnoresSwipes) ||
             floatingRingZones.contains { $0.finishIgnoresSwipes || $0.config.hasExpandedRingOptions || $0.config.usesCommandModifiers }) {
            throw ControllerProfileError.invalidFormat
        }
        if libraryVersion < 22 && floatingRingZones.contains(where: { $0.config.minimumCommandModifierVersion >= 17 }) {
            throw ControllerProfileError.invalidFormat
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name); try values.encode(controlIDs, forKey: .controlIDs)
        try values.encode(floatingButtonZones, forKey: .floatingButtonZones); try values.encode(floatingRingZones, forKey: .floatingRingZones)
    }
    func copied(id: UUID, name: String, controls: [UUID: UUID], zones: [UUID: UUID] = [:]) throws -> Self {
        .init(id: id, name: name, controlIDs: controlIDs.map { controls[$0]! },
              floatingButtonZones: try floatingButtonZones.map { try $0.replacingIDs(controls: controls, zoneID: zones[$0.id] ?? UUID()) },
              floatingRingZones: floatingRingZones.map { $0.replacingID(zones[$0.id] ?? UUID()) })
    }
    mutating func removeFloatingMember(_ id: UUID) {
        floatingButtonZones = floatingButtonZones.compactMap { zone in
            guard zone.memberIDs.contains(id) else { return zone }
            guard zone.memberIDs.count > 1 else { return nil }
            var next = zone; next.memberIDs.removeAll { $0 == id }
            if next.startMemberID == id { next.startMemberID = nil }
            next.portraitMembers.removeAll { $0.id == id }; next.landscapeMembers.removeAll { $0.id == id }
            next.portraitRestoration.removeAll { $0.id == id }; next.landscapeRestoration.removeAll { $0.id == id }
            return next
        }
    }
}

public extension ControllerProfile {
    static var maximumPages: Int { 32 }
    func page(for id: UUID) -> ProfilePage? { pages.first { $0.id == id } }
    func pageID(containing controlID: UUID) -> UUID? { pages.first { $0.controlIDs.contains(controlID) }?.id }
    func visibleControlIDs(on pageID: UUID) -> Set<UUID> { Set(page(for: pageID)?.controlIDs ?? []) }
    func controls(on pageID: UUID) -> [ProfileControl] {
        let ids = visibleControlIDs(on: pageID); return controls.filter { ids.contains($0.id) }
    }
    func placements(for orientation: ControllerOrientation, on pageID: UUID) -> [ProfilePlacement] {
        let ids = visibleControlIDs(on: pageID); return placements(for: orientation).filter { ids.contains($0.id) }
    }
    mutating func addControl(_ control: ProfileControl, toPage pageID: UUID,
                             portrait position: NormalizedControlPosition = .init(x: 0.5, y: 0.5),
                             landscape landscapePosition: NormalizedControlPosition = .init(x: 0.5, y: 0.5)) throws {
        try validate()
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { throw ControllerProfileError.unknownPage }
        var next = self
        next.controls.append(control); next.pages[index].controlIDs.append(control.id)
        next.portrait.append(.init(id: control.id, position: position)); next.landscape.append(.init(id: control.id, position: landscapePosition))
        try next.validate(); self = next
    }
    mutating func removeControl(_ id: UUID) throws {
        try validate(); guard control(for: id) != nil else { throw ControllerProfileError.unknownControl }
        var next = self
        next.controls.removeAll { $0.id == id }; next.portrait.removeAll { $0.id == id }; next.landscape.removeAll { $0.id == id }
        for i in next.pages.indices { next.pages[i].controlIDs.removeAll { $0 == id }; next.pages[i].removeFloatingMember(id) }
        for i in next.androidSources.indices { next.androidSources[i].controls.removeAll { $0.nativeID == id } }
        try next.validate(); self = next
    }
    mutating func moveControl(_ id: UUID, toPage pageID: UUID) throws {
        try validate(); guard control(for: id) != nil else { throw ControllerProfileError.unknownControl }
        guard let target = pages.firstIndex(where: { $0.id == pageID }) else { throw ControllerProfileError.unknownPage }
        if pages[target].controlIDs.contains(id) { return }
        var next = self
        for i in next.pages.indices { next.pages[i].controlIDs.removeAll { $0 == id }; next.pages[i].removeFloatingMember(id) }
        next.pages[target].controlIDs.append(id)
        try next.validate(); self = next
    }
    @discardableResult mutating func addPage(name: String) throws -> UUID {
        try validate(); var next = self
        let page = ProfilePage(name: name); next.pages.append(page)
        try next.validate(); self = next; return page.id
    }
    mutating func renamePage(_ id: UUID, to name: String) throws {
        try validate(); guard let index = pages.firstIndex(where: { $0.id == id }) else { throw ControllerProfileError.unknownPage }
        var next = self; next.pages[index].name = name
        try next.validate(); self = next
    }
    mutating func setHomePage(_ id: UUID) throws {
        try validate(); guard page(for: id) != nil else { throw ControllerProfileError.unknownPage }
        homePageID = id
    }
    @discardableResult mutating func duplicatePage(_ id: UUID, name: String? = nil) throws -> UUID {
        try validate(); guard let page = page(for: id) else { throw ControllerProfileError.unknownPage }
        var next = self
        let newID = UUID(), memberIDs = Set(page.controlIDs)
        let ids = Dictionary(uniqueKeysWithValues: page.controlIDs.map { ($0, UUID()) })
        let zones = Dictionary(uniqueKeysWithValues: (page.floatingButtonZones.map(\.id) + page.floatingRingZones.map(\.id)).map { ($0, UUID()) })
        next.pages.append(try page.copied(id: newID, name: name ?? availablePageName(page.name), controls: ids, zones: zones))
        next.controls += controls.filter { memberIDs.contains($0.id) }.map { value in
            var copy = value; copy.id = ids[value.id]!; copy.pageNavigation = value.pageNavigation?.remapping([id: newID])
            copy.floatingAction = value.floatingAction?.remapping(zones: zones, controls: ids); return copy
        }
        next.portrait += portrait.filter { memberIDs.contains($0.id) }.map { .init(id: ids[$0.id]!, position: $0.position) }
        next.landscape += landscape.filter { memberIDs.contains($0.id) }.map { .init(id: ids[$0.id]!, position: $0.position) }
        next.mergeAndroidSources(androidSources.map { $0.remapped(pages: [id: newID], controls: ids, zones: zones, asCopies: true) })
        try next.validate(); self = next; return newID
    }
    /// Import one selected page. Links to source pages outside the selection become Home.
    @discardableResult mutating func importPage(_ sourcePageID: UUID, from source: ControllerProfile, name: String? = nil) throws -> UUID {
        try validate(); try source.validate()
        guard let page = source.page(for: sourcePageID) else { throw ControllerProfileError.unknownPage }
        var next = self
        let newID = UUID(), memberIDs = Set(page.controlIDs)
        let ids = Dictionary(uniqueKeysWithValues: page.controlIDs.map { ($0, UUID()) })
        let zones = Dictionary(uniqueKeysWithValues: (page.floatingButtonZones.map(\.id) + page.floatingRingZones.map(\.id)).map { ($0, UUID()) })
        let importedName = name ?? (pages.contains { normalizedPageName($0.name) == normalizedPageName(page.name) } ? availablePageName(page.name) : page.name)
        let externalTargets = Set(source.controls.filter { memberIDs.contains($0.id) }.compactMap { control -> UUID? in
            guard let target = control.floatingAction?.target else { return nil }
            switch target { case let .zone(id): return zones[id] == nil ? id : nil; case let .control(id): return ids[id] == nil ? id : nil }
        })
        let isolatedTargets = Dictionary(uniqueKeysWithValues: externalTargets.map { ($0, UUID()) })
        next.pages.append(try page.copied(id: newID, name: importedName, controls: ids, zones: zones))
        next.controls += source.controls.filter { memberIDs.contains($0.id) }.map { value in
            var copy = value; copy.id = ids[value.id]!
            if let target = value.pageNavigation?.targetPageID {
                copy.pageNavigation = target == sourcePageID ? value.pageNavigation?.remapping([sourcePageID: newID]) : .home
            }
            copy.floatingAction = value.floatingAction?.remapping(zones: zones, controls: ids, missing: isolatedTargets)
            return copy
        }
        next.portrait += source.portrait.filter { memberIDs.contains($0.id) }.map { .init(id: ids[$0.id]!, position: $0.position) }
        next.landscape += source.landscape.filter { memberIDs.contains($0.id) }.map { .init(id: ids[$0.id]!, position: $0.position) }
        next.mergeAndroidSources(source.androidSources.map { $0.remapped(pages: [sourcePageID: newID], controls: ids, zones: zones, asCopies: true) })
        try next.validate(); self = next; return newID
    }
    mutating func deletePage(_ id: UUID) throws {
        try validate(); guard let page = page(for: id) else { throw ControllerProfileError.unknownPage }
        guard pages.count > 1 else { throw ControllerProfileError.invalidPageCount }
        var next = self; let removed = Set(page.controlIDs)
        next.pages.removeAll { $0.id == id }; next.controls.removeAll { removed.contains($0.id) }
        next.portrait.removeAll { removed.contains($0.id) }; next.landscape.removeAll { removed.contains($0.id) }
        for i in next.androidSources.indices {
            next.androidSources[i].pages.removeAll { $0.nativeID == id }
            next.androidSources[i].controls.removeAll { removed.contains($0.nativeID) }
        }
        if next.homePageID == id { next.homePageID = next.pages[0].id }
        for i in next.controls.indices where next.controls[i].pageNavigation?.targetPageID == id { next.controls[i].pageNavigation = .home }
        try next.validate(); self = next
    }
    func cloned(name: String? = nil) throws -> ControllerProfile {
        try validate(); var copy = self; copy.id = UUID(); copy.name = name ?? self.name
        let pageIDs = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, UUID()) })
        let ids = Dictionary(uniqueKeysWithValues: controls.map { ($0.id, UUID()) })
        let zones = Dictionary(uniqueKeysWithValues: pages.flatMap { $0.floatingButtonZones.map(\.id) + $0.floatingRingZones.map(\.id) }.map { ($0, UUID()) })
        copy.pages = try pages.map { try $0.copied(id: pageIDs[$0.id]!, name: $0.name, controls: ids, zones: zones) }
        copy.homePageID = pageIDs[homePageID]!
        copy.controls = controls.map { value in
            var item = value; item.id = ids[value.id]!; item.pageNavigation = value.pageNavigation?.remapping(pageIDs)
            item.floatingAction = value.floatingAction?.remapping(zones: zones, controls: ids); return item
        }
        copy.portrait = portrait.map { .init(id: ids[$0.id]!, position: $0.position) }
        copy.landscape = landscape.map { .init(id: ids[$0.id]!, position: $0.position) }
        copy.androidSources = androidSources.map { $0.remapped(pages: pageIDs, controls: ids, zones: zones) }
        try copy.validate(); return copy
    }
    private func availablePageName(_ original: String) -> String {
        var counter = 1
        while true {
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            let candidate = String(original.prefix(64 - suffix.count)) + suffix
            if !pages.contains(where: { normalizedPageName($0.name) == normalizedPageName(candidate) }) { return candidate }
            counter += 1
        }
    }

    /// Preserve origin metadata when the editor duplicates one control after adding the copy.
    mutating func duplicateSourceBinding(from originalID: UUID, to newID: UUID) throws {
        guard control(for: originalID) != nil, control(for: newID) != nil else { throw ControllerProfileError.unknownControl }
        var next = self
        if let index = next.controls.firstIndex(where: { $0.id == newID }) {
            next.controls[index].floatingAction = next.controls[index].floatingAction?.remapping(zones: [:], controls: [originalID: newID])
        }
        for i in next.androidSources.indices {
            if let binding = next.androidSources[i].controls.first(where: { $0.nativeID == originalID }),
               !next.androidSources[i].controls.contains(where: { $0.nativeID == newID }) {
                next.androidSources[i].controls.append(.init(nativeID: newID, sourcePath: binding.sourcePath, exportID: UUID().uuidString, floatingRestoration: binding.floatingRestoration))
            }
        }
        try next.validate(); self = next
    }

    private mutating func mergeAndroidSources(_ sources: [AndroidProfileSourceReference]) {
        for source in sources where !source.pages.isEmpty || !source.controls.isEmpty || !source.zones.isEmpty {
            if let index = androidSources.firstIndex(where: { $0.archiveID == source.archiveID && $0.sourceProfilePath.utf8.elementsEqual(source.sourceProfilePath.utf8) }) {
                androidSources[index].pages += source.pages
                androidSources[index].controls += source.controls
                androidSources[index].zones += source.zones
            } else { androidSources.append(source) }
        }
    }
}

func normalizedPageName(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

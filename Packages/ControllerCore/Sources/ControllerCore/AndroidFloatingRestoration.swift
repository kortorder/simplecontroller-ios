import Foundation

/// Explicit user-edit provenance. A copied loose button must not be mistaken for a member
/// restored later just because both bindings refer to the same original Android control.
public struct AndroidFloatingRestorationRecord: Codable, Equatable, Sendable {
    public let zoneSourcePath: String
    public let orientations: Set<ControllerOrientation>
    public init(zoneSourcePath: String, orientations: Set<ControllerOrientation>) {
        self.zoneSourcePath = zoneSourcePath; self.orientations = orientations
    }
    public func validate() throws {
        guard zoneSourcePath.hasPrefix("/"), zoneSourcePath.utf8.count <= 8_192,
              !orientations.isEmpty, orientations.count <= 2 else { throw AndroidArchiveError("Invalid floating restoration record.") }
    }
    private enum CodingKeys: String, CodingKey { case zoneSourcePath, orientations }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["zoneSourcePath", "orientations"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let values = try c.decode([ControllerOrientation].self, forKey: .orientations)
        guard Set(values).count == values.count else { throw ControllerProfileError.invalidFormat }
        self.init(zoneSourcePath: try c.decode(String.self, forKey: .zoneSourcePath), orientations: Set(values))
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(zoneSourcePath, forKey: .zoneSourcePath)
        try c.encode(orientations.sorted { $0.rawValue < $1.rawValue }, forKey: .orientations)
    }
}

/// Restoring an imported group needs the immutable original to distinguish archived pixel
/// rectangles from a later native orientation's measured point rectangles. No I/O or save occurs.
public enum AndroidFloatingRestoration {
    public static func restore(profile: ControllerProfile, zoneID: UUID, pageID: UUID,
                               original: AndroidProfileDocument, source: AndroidProfileSourceReference) throws -> ControllerProfile {
        try profile.validate()
        try source.validate(pageIDs: Set(profile.pages.map(\.id)), controlIDs: Set(profile.controls.map(\.id)))
        guard profile.androidSources.contains(source), let baseline = source.exportBaseline,
              baseline.originalSHA256 == androidSHA256(original.originalData),
              baseline.sourceProfilePath == source.sourceProfilePath,
              let pageIndex = profile.pages.firstIndex(where: { $0.id == pageID }),
              let zone = profile.pages[pageIndex].floatingButtonZones.first(where: { $0.id == zoneID }),
              let binding = source.zones.first(where: { $0.nativeID == zoneID }),
              let savedZone = baseline.zones.first(where: { $0.sourcePath == binding.sourcePath }),
              source.pages.first(where: { $0.nativeID == pageID })?.sourcePath == savedZone.pageSourcePath,
              let page = original.profiles.first(where: { $0.sourcePath == source.sourceProfilePath })?.pages.first(where: { $0.sourcePath == savedZone.pageSourcePath }),
              let rawZone = sourceZone(at: binding.sourcePath, on: page),
              ["SINGLE_BUTTON", "BUTTON_GROUP"].contains(rawZone["kind"]?.stringValue ?? "") else {
            throw AndroidArchiveError("The imported group's original restoration geometry could not be verified. The draft is unchanged.")
        }
        var next = profile
        guard let sourceIndex = next.androidSources.firstIndex(of: source) else { throw AndroidArchiveError("The Android source changed.") }
        for id in zone.memberIDs {
            guard let index = next.controls.firstIndex(where: { $0.id == id }),
                  let controlBinding = source.controls.first(where: { $0.nativeID == id }),
                  let originalControl = page.controls.first(where: { $0.sourcePath == controlBinding.sourcePath }),
                  rawZone["memberIds"]?.arrayValue?.contains(.string(originalControl.sourceID)) == true,
                  let old = baseline.controls.first(where: { $0.sourcePath == controlBinding.sourcePath }) else {
                throw AndroidArchiveError("An imported floating member has no unambiguous original identity. The draft is unchanged.")
            }
            var restored = Set<ControllerOrientation>()
            for orientation in ControllerOrientation.allCases {
                guard let raw = restorationValue(rawZone, controlID: originalControl.sourceID, orientation: orientation) else { continue }
                let rectangle = try rectangle(raw)
                guard let current = zone.restoration(for: orientation).first(where: { $0.id == id }),
                      current.frame == FloatingRect(x: rectangle.x, y: rectangle.y, width: rectangle.width, height: rectangle.height) else {
                    throw AndroidArchiveError("The imported restoration snapshot was changed. Its archived geometry cannot be applied without an explicit conversion.")
                }
                let basis = try geometry(rectangle, control: next.controls[index], orientation: orientation,
                                         previous: orientation == .portrait ? old.portrait : old.landscape, importBaseline: baseline)
                restored.insert(orientation)
                next.controls[index].orientationDimensions.set(.init(width: basis.importedWidth, height: basis.importedHeight), for: orientation)
                if orientation == .portrait {
                    guard let position = next.portrait.firstIndex(where: { $0.id == id }) else { throw ControllerProfileError.invalidPlacements }
                    next.portrait[position].position = basis.importedPosition
                } else {
                    guard let position = next.landscape.firstIndex(where: { $0.id == id }) else { throw ControllerProfileError.invalidPlacements }
                    next.landscape[position].position = basis.importedPosition
                }
            }
            if !restored.isEmpty, let bindingIndex = next.androidSources[sourceIndex].controls.firstIndex(where: { $0.nativeID == id }) {
                next.androidSources[sourceIndex].controls[bindingIndex].floatingRestoration = .init(zoneSourcePath: binding.sourcePath, orientations: restored)
            }
        }
        next.pages[pageIndex].floatingButtonZones.removeAll { $0.id == zoneID }
        try next.validate(); return next
    }

    static func sourceZone(at path: String, on page: AndroidSourcePage) -> AndroidJSONValue? {
        (page.value["floatingZones"]?.arrayValue ?? []).enumerated().first {
            page.sourcePath + "/floatingZones/\($0.offset)" == path
        }?.element
    }
    static func restorationValue(_ zone: AndroidJSONValue, controlID: String, orientation: ControllerOrientation) -> AndroidJSONValue? {
        zone[orientation == .portrait ? "portraitRestorationGeometry" : "landscapeRestorationGeometry"]?[controlID]
    }
    static func rectangle(_ raw: AndroidJSONValue) throws -> AndroidExportRectangle {
        func number(_ key: String) throws -> Double {
            guard let text = raw[key]?.numberValue?.rawValue, let value = Double(text), value.isFinite else {
                throw AndroidArchiveError("The archived restoration rectangle is invalid.")
            }
            return value
        }
        let result = try AndroidExportRectangle(x: number("x"), y: number("y"), width: number("w"), height: number("h"))
        try result.validate(); return result
    }
    /// Uses the original import's fitted canvas, then the same native touch-target bounds.
    /// Keeping the raw rectangle separately is essential when several sizes clamp to 44 points.
    static func geometry(_ raw: AndroidExportRectangle, control: ProfileControl, orientation: ControllerOrientation,
                         previous: AndroidGeometryExportBaseline, importBaseline: AndroidSourceExportBaseline) throws -> AndroidGeometryExportBaseline {
        let canvas = orientation == .portrait ? importBaseline.portraitCanvas : importBaseline.landscapeCanvas
        let width = min(canvas.width, raw.width * previous.sizeScale)
        let height = min(canvas.height, raw.height * previous.sizeScale)
        let x = min(canvas.width - width / 2, max(width / 2, (raw.x + raw.width / 2) / previous.sourceCanvasWidth * canvas.width)) / canvas.width
        let y = min(canvas.height - height / 2, max(height / 2, (raw.y + raw.height / 2) / previous.sourceCanvasHeight * canvas.height)) / canvas.height
        let result = AndroidGeometryExportBaseline(importedPosition: .init(x: x, y: y),
            importedWidth: min(1_200, max(control.minimumDiameter, width)), importedHeight: min(1_200, max(control.minimumDiameter, height)),
            sourceCanvasWidth: previous.sourceCanvasWidth, sourceCanvasHeight: previous.sourceCanvasHeight,
            sizeScale: previous.sizeScale, sourceRectangle: raw)
        try result.validate(); return result
    }
}

extension AndroidEditedPatcher {
    /// Only the explicit restoration record changes this control's geometry basis. Immutable
    /// conversion evidence and the original still have to prove the recorded zone/member link.
    func restorationBaseline(control: ProfileControl, originalControl: AndroidSourceControl?, page: ProfilePage,
                             originalPage: AndroidSourcePage?, orientation: ControllerOrientation,
                             previous: AndroidGeometryExportBaseline, baseline: AndroidSourceExportBaseline) throws -> AndroidGeometryExportBaseline? {
        guard let binding = source.controls.first(where: { $0.nativeID == control.id }),
              let record = binding.floatingRestoration, record.orientations.contains(orientation) else { return nil }
        guard let originalControl, let originalPage, binding.sourcePath == originalControl.sourcePath,
              source.pages.contains(where: { $0.nativeID == page.id && $0.sourcePath == originalPage.sourcePath }),
              let saved = baseline.zones.first(where: { $0.sourcePath == record.zoneSourcePath && $0.pageSourcePath == originalPage.sourcePath }),
              let rawZone = AndroidFloatingRestoration.sourceZone(at: saved.sourcePath, on: originalPage),
              ["SINGLE_BUTTON", "BUTTON_GROUP"].contains(rawZone["kind"]?.stringValue ?? ""),
              rawZone["memberIds"]?.arrayValue?.contains(.string(originalControl.sourceID)) == true,
              let raw = AndroidFloatingRestoration.restorationValue(rawZone, controlID: originalControl.sourceID, orientation: orientation) else {
            throw AndroidArchiveError("The recorded floating restoration could not be proved against this original. Edited export cannot guess its geometry.")
        }
        return try AndroidFloatingRestoration.geometry(AndroidFloatingRestoration.rectangle(raw), control: control,
            orientation: orientation, previous: previous, importBaseline: baseline)
    }
}

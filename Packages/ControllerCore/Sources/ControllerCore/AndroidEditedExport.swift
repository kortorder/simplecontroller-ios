import Foundation

public struct AndroidExportDiagnostic: Equatable, Sendable {
    public enum Severity: String, Sendable { case warning, blocked }
    public let severity: Severity
    public let message: String
    public let sourcePath: String
}

/// Data is nil whenever an edit cannot be represented without guessing. Preparing a preview never
/// changes the original, native profile, provenance or filesystem. Unchanged previews return exact bytes.
public struct AndroidEditedExportPreview: Equatable, Sendable {
    public let data: Data?
    public let diagnostics: [AndroidExportDiagnostic]
    public let changedFieldCount: Int
    public let addedControlCount: Int
    public let deletedControlCount: Int
    public let addedPageCount: Int
    public let deletedPageCount: Int
    public let suggestedFilename: String
    public let isUnchanged: Bool
    public var canExport: Bool { data != nil }

    /// Copy IDs are persisted with source bindings in native format10. Explicit arguments keep this
    /// pure component independently testable while migration metadata is introduced.
    public static func prepare(profile: ControllerProfile, original: AndroidProfileDocument,
        source: AndroidProfileSourceReference, baseline: AndroidSourceExportBaseline? = nil,
        copiedPageIDs: [UUID: String] = [:], copiedControlIDs: [UUID: String] = [:]) -> Self {
        // Public preview inputs are validated below. Never trap on a malformed duplicate binding.
        let pages = Dictionary(source.pages.compactMap { binding in binding.exportID.map { (binding.nativeID, $0) } }, uniquingKeysWith: { first, _ in first })
        let controls = Dictionary(source.controls.compactMap { binding in binding.exportID.map { (binding.nativeID, $0) } }, uniquingKeysWith: { first, _ in first })
        var patcher = AndroidEditedPatcher(profile: profile, original: original, source: source,
            baseline: baseline ?? source.exportBaseline,
            copiedPageIDs: pages.merging(copiedPageIDs) { _, explicit in explicit },
            copiedControlIDs: controls.merging(copiedControlIDs) { _, explicit in explicit })
        do { return try patcher.prepare() }
        catch {
            patcher.block(error.localizedDescription)
            return patcher.result(data: nil, unchanged: false)
        }
    }
}

struct AndroidEditedPatcher {
    let profile: ControllerProfile
    let original: AndroidProfileDocument
    let source: AndroidProfileSourceReference
    let baseline: AndroidSourceExportBaseline?
    let copiedPageIDs: [UUID: String]
    let copiedControlIDs: [UUID: String]
    var diagnostics: [AndroidExportDiagnostic] = []
    var changed = 0, addedControls = 0, deletedControls = 0, addedPages = 0, deletedPages = 0
    var pageTokens: [UUID: String] = [:]
    var pageIDs: [UUID: String] = [:]
    var controlIDs: [UUID: String] = [:]
    var targetIDs: [String: String] = [:]

    mutating func block(_ message: String, path: String = "") {
        diagnostics.append(.init(severity: .blocked, message: String(message.prefix(1_024)), sourcePath: path))
    }
    mutating func warn(_ message: String, path: String = "") {
        diagnostics.append(.init(severity: .warning, message: message, sourcePath: path))
    }
    func result(data: Data?, unchanged: Bool) -> AndroidEditedExportPreview {
        let name = profile.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        return .init(data: data, diagnostics: diagnostics, changedFieldCount: changed,
            addedControlCount: addedControls, deletedControlCount: deletedControls, addedPageCount: addedPages, deletedPageCount: deletedPages,
            suggestedFilename: String(name.prefix(64)) + "-Android-edited.json", isUnchanged: unchanged)
    }
    mutating func prepare() throws -> AndroidEditedExportPreview {
        try profile.validate()
        if profile.controls.contains(where: { $0.stickPlusEdgeRearmHysteresis != nil || $0.authoredPayloads.contains { (try? ControllerPayloadProgram.parse($0).autoCenterCommand) != nil } }) {
            block("Android edited export cannot yet represent live auto-center actions or deliberate Stick+ edge reactivation. Use a native backup to preserve these settings, or export the unchanged Android original.")
            return result(data: nil, unchanged: false)
        }
        if profile.controls.contains(where: { $0.doubleTapRepeatEnabled || $0.centerLeftStickBeforePress }) {
            block("Android edited export cannot represent double-tap repeat or centering before a press. Export a native backup to preserve those options, or export the unchanged Android original.")
            return result(data: nil, unchanged: false)
        }
        try source.validate(pageIDs: Set(profile.pages.map(\.id)), controlIDs: Set(profile.controls.map(\.id)))
        let sourceProfileValue = original.profiles.first { $0.sourcePath == source.sourceProfilePath }?.value
        let hasCommunityFields = sourceProfileValue?["safeControlArea"] != nil || sourceProfileValue?["swipeMode"] != nil ||
            sourceProfileValue?["pages"]?.arrayValue?.contains { page in
                page["controls"]?.arrayValue?.contains { $0["stickPlusRepeatIntervalMilliseconds"] != nil || $0["circularButton"] != nil } == true
            } == true
        if !hasCommunityFields && profile.controls.contains(where: { $0.stickPlusRepeatIntervalMilliseconds != nil }) {
            block("Android profiles cannot represent the iPhone Stick+ repeat setting. Turn it off before edited export, or export the unchanged original or a native backup.")
            return result(data: nil, unchanged: false)
        }
        if profile.globalHoldEnabled {
            block("Android profile files do not store global Hold. Turn off that native profile option before edited export, or export the unchanged original.")
            return result(data: nil, unchanged: false)
        }
        guard let baseline else {
            block("This import predates edit tracking. Export its unchanged original; edited export needs a new import with a conversion baseline.")
            return result(data: nil, unchanged: false)
        }
        try baseline.validate()
        guard baseline.originalSHA256 == androidSHA256(original.originalData), baseline.sourceProfilePath == source.sourceProfilePath else {
            throw AndroidArchiveError("The edit baseline does not match this Android original.")
        }
        guard profile.androidSources.count == 1,
              profile.androidSources.first?.archiveID == source.archiveID,
              profile.androidSources.first?.sourceProfilePath == source.sourceProfilePath else {
            block("This profile combines multiple Android sources. Their pages, references and reusable libraries need a deliberate merge before edited export.")
            return result(data: nil, unchanged: false)
        }
        guard profile.androidSources.first == source else {
            throw AndroidArchiveError("The export bindings do not match the saved profile's Android source reference.")
        }
        guard let sourceProfile = original.profiles.first(where: { $0.sourcePath == source.sourceProfilePath }) else {
            throw AndroidArchiveError("The original profile could not be located.")
        }
        if try matchesBaseline(baseline, originals: sourceProfile.pages.flatMap(\.controls)) && matchesFloatingBaseline(baseline) { return result(data: original.originalData, unchanged: true) }
        if original.kind != .legacyControls && (sourceProfile.pages.isEmpty || sourceProfile.pages.contains { $0.sourceID?.isEmpty != false }) {
            block("This original needs page-ID or empty-page repair before edited export. Its unchanged original remains available.")
            return result(data: nil, unchanged: false)
        }
        if try androidExportDigest(AndroidExportProjection.runtimeOptions(profile)) != baseline.runtimeOptionsDigest {
            block("Android files do not store the iPhone profile's Swipe or Turbo options. Those changed options cannot be represented in an edited Android file.")
        }
        let allSourceControls = sourceProfile.pages.flatMap(\.controls)
        let originalPageBindings = source.pages.filter { binding in copiedPageIDs[binding.nativeID] == nil && sourceProfile.pages.contains { $0.sourcePath == binding.sourcePath } }
        let originalControlBindings = source.controls.filter { copiedControlIDs[$0.nativeID] == nil }
        guard Set(originalPageBindings.map(\.sourcePath)).count == originalPageBindings.count,
              Set(originalControlBindings.map(\.sourcePath)).count == originalControlBindings.count else {
            throw AndroidArchiveError("Copies need stable export IDs before edited export.")
        }
        for page in profile.pages {
            let binding = source.pages.first { $0.nativeID == page.id }
            let sourcePage = binding.flatMap { b in sourceProfile.pages.first { $0.sourcePath == b.sourcePath } }
            if let copyID = copiedPageIDs[page.id] {
                try validateNewID(copyID); pageIDs[page.id] = copyID; pageTokens[page.id] = "copy:" + copyID
            } else if let sourcePage, let id = sourcePage.sourceID, !id.isEmpty {
                pageIDs[page.id] = id; pageTokens[page.id] = "source:" + sourcePage.sourcePath
            } else {
                pageIDs[page.id] = page.id.uuidString; pageTokens[page.id] = binding.map { "source:" + $0.sourcePath } ?? "native:" + page.id.uuidString
            }
            targetIDs[pageTokens[page.id]!] = pageIDs[page.id]!
            let p = profile.placements(for: .portrait, on: page.id).map(\.id)
            let l = profile.placements(for: .landscape, on: page.id).map(\.id)
            if p != l { block("\(page.name) has different portrait and landscape stacking orders. Android stores one order, so choose a consistent order before exporting.") }
        }
        guard Set(pageIDs.values).count == pageIDs.count else { throw AndroidArchiveError("An exported page ID would collide with another page.") }
        for control in profile.controls {
            let binding = source.controls.first { $0.nativeID == control.id }
            let old = binding.flatMap { b in allSourceControls.first { $0.sourcePath == b.sourcePath } }
            if let copyID = copiedControlIDs[control.id] { try validateNewID(copyID); controlIDs[control.id] = copyID }
            else { controlIDs[control.id] = old?.sourceID.isEmpty == false ? old!.sourceID : control.id.uuidString }
        }
        var pages: [AndroidJSONValue] = []
        let coveredPages = Set(baseline.pages.map(\.sourcePath))
        let coveredControls = Set(baseline.controls.map(\.sourcePath))
        for sourcePage in sourceProfile.pages {
            if let binding = originalPageBindings.first(where: { $0.sourcePath == sourcePage.sourcePath }),
               let page = profile.page(for: binding.nativeID) {
                pages.append(try patchedPage(page, originalPage: sourcePage, baseline: baseline, allSourceControls: allSourceControls, copy: false))
            } else if coveredPages.contains(sourcePage.sourcePath) {
                let archivedOnly = sourcePage.controls.contains { !coveredControls.contains($0.sourcePath) }
                let hasFloating = (sourcePage.value["floatingZones"]?.arrayValue ?? []).indices.contains { index in
                    !baseline.zones.contains { $0.sourcePath == sourcePage.sourcePath + "/floatingZones/\(index)" }
                }
                if archivedOnly || hasFloating {
                    block("A deleted page still contains archived-only controls or floating zones. Edited export will not discard that data.", path: sourcePage.sourcePath)
                    pages.append(sourcePage.value)
                } else { deletedPages += 1 }
            } else { pages.append(sourcePage.value) }
        }
        for page in profile.pages where !originalPageBindings.contains(where: { $0.nativeID == page.id }) {
            let binding = source.pages.first { $0.nativeID == page.id }
            let template = binding.flatMap { b in sourceProfile.pages.first { $0.sourcePath == b.sourcePath } }
            pages.append(try patchedPage(page, originalPage: template, baseline: baseline, allSourceControls: allSourceControls, copy: true))
            addedPages += 1
        }
        deletedControls = baseline.controls.filter { item in !originalControlBindings.contains { $0.sourcePath == item.sourcePath } }.count
        if deletedControls > 0 || deletedPages > 0 {
            warn("The edited copy removes \(deletedControls) converted controls and \(deletedPages) converted pages, including fields attached to those deleted records. Their complete data remains in the unchanged original.")
        }
        var patched = sourceProfile.value
        if original.kind == .legacyControls {
            guard profile.pages.count == 1, pages.count == 1 else { throw AndroidArchiveError("Legacy control arrays cannot represent page edits. Export the unchanged original until page-format conversion is supported.") }
            patched = pages[0]["controls"] ?? pages[0]
        } else {
            patched = try patched.androidReplacing(["pages"], with: .array(pages))
            let homeToken = pageTokens[profile.homePageID]!
            if homeToken != baseline.homePageToken {
                patched = try patched.androidReplacing(["homePageId"], with: .string(pageIDs[profile.homePageID]!)); changed += 1
            }
            var required = profile.pages.contains { !$0.floatingButtonZones.isEmpty || !$0.floatingRingZones.isEmpty } ? 10 : 5
            if profile.controls.contains(where: { $0.excludeFromCameraFollow || $0.cameraFollowStrengthPercent != 100 }) { required = max(required, 8) }
            if profile.controls.contains(where: \.mouseSuppressCameraFollow) { required = max(required, 10) }
            if profile.controls.contains(where: \.isFloatingAction) { required = max(required, 10) }
            if profile.controls.contains(where: { $0.isTouchAim && $0.touchAim.aim.output == .gameMouse }) { required = max(required, 6) }
            for control in profile.controls where control.buttonAim.enabled {
                if control.buttonAim.tuning.output == .gameMouse || (control.buttonAim.alternate.enabled && control.buttonAim.alternate.tuning.output == .gameMouse) { required = max(required, 7) }
                if control.buttonAim.cancelOnBoundaryExit || control.buttonAim.rearmOnBoundaryReturn { required = max(required, 9) }
            }
            required = max(required, AndroidTimingFormat.required(for: patched))
            if patched != sourceProfile.value && required > sourceProfile.formatVersion {
                patched = try patched.androidReplacing(["formatVersion"], with: .number(.init(String(required)))); changed += 1
                warn("The edited profile uses Android format \(required) to represent its supported settings.")
            }
        }
        var root = original.kind == .legacyControls ? patched : try original.root.androidReplacingPointer(source.sourceProfilePath, with: patched)
        if try androidExportDigest(.string(profile.name)) != baseline.profileNameDigest {
            switch original.kind {
            case .singleTransfer: root = try root.androidReplacing(["profileName"], with: .string(profile.name)); changed += 1
            case .allProfilesBackup:
                guard !original.profiles.contains(where: { $0.sourcePath != source.sourceProfilePath && $0.name.lowercased() == profile.name.lowercased() }) else {
                    throw AndroidArchiveError("The renamed profile would conflict with another profile in the Android backup.")
                }
                let parent = source.sourceProfilePath.split(separator: "/").dropLast().map(String.init)
                root = try root.androidReplacing(parent + ["name"], with: .string(profile.name)); changed += 1
                if original.activeProfileName == sourceProfile.name { root = try root.androidReplacing(["activeControllerProfileName"], with: .string(profile.name)) }
            case .rawProfile, .legacyControls: warn("This Android format stores its profile name in the filename. The suggested export filename uses the edited name.")
            }
        }
        if diagnostics.contains(where: { $0.severity == .blocked }) { return result(data: nil, unchanged: false) }
        if root == original.root { return result(data: original.originalData, unchanged: true) }
        let data = try root.encodedData()
        _ = try AndroidProfileDocument.parse(data, fallbackName: profile.name)
        return result(data: data, unchanged: false)
    }

    private func matchesBaseline(_ baseline: AndroidSourceExportBaseline, originals: [AndroidSourceControl]) throws -> Bool {
        guard copiedPageIDs.isEmpty, copiedControlIDs.isEmpty, source.pages.count == profile.pages.count,
              source.controls.count == profile.controls.count, baseline.pages.count == source.pages.count,
              baseline.controls.count == source.controls.count,
              try androidExportDigest(.string(profile.name)) == baseline.profileNameDigest,
              try androidExportDigest(AndroidExportProjection.runtimeOptions(profile)) == baseline.runtimeOptionsDigest,
              AndroidExportProjection.pageToken(profile.homePageID, source: source) == baseline.homePageToken else { return false }
        let paths = Dictionary(uniqueKeysWithValues: source.controls.map { ($0.nativeID, $0.sourcePath) })
        for page in profile.pages {
            guard let binding = source.pages.first(where: { $0.nativeID == page.id }),
                  let old = baseline.pages.first(where: { $0.sourcePath == binding.sourcePath }),
                  try androidExportDigest(.string(page.name)) == old.nameDigest,
                  profile.placements(for: .portrait, on: page.id).compactMap({ paths[$0.id] }) == old.portraitControlPaths,
                  profile.placements(for: .landscape, on: page.id).compactMap({ paths[$0.id] }) == old.landscapeControlPaths else { return false }
        }
        for control in profile.controls {
            guard let binding = source.controls.first(where: { $0.nativeID == control.id }),
                  let old = baseline.controls.first(where: { $0.sourcePath == binding.sourcePath }),
                  let p = profile.portrait.first(where: { $0.id == control.id }), let l = profile.landscape.first(where: { $0.id == control.id }),
                  p.position == old.portrait.importedPosition, l.position == old.landscape.importedPosition,
                  control.dimensions(for: .portrait).width == old.portrait.importedWidth, control.dimensions(for: .portrait).height == old.portrait.importedHeight,
                  control.dimensions(for: .landscape).width == old.landscape.importedWidth, control.dimensions(for: .landscape).height == old.landscape.importedHeight,
                  try AndroidExportProjection.fields(control, profile: profile, source: source).mapValues(androidExportDigest) == AndroidExportProjection.comparisonDigests(old, native: control, original: originals.first { $0.sourcePath == old.sourcePath }) else { return false }
        }
        return true
    }

    private mutating func patchedPage(_ page: ProfilePage, originalPage: AndroidSourcePage?, baseline: AndroidSourceExportBaseline,
        allSourceControls: [AndroidSourceControl], copy: Bool) throws -> AndroidJSONValue {
        var value = originalPage?.value ?? .object(.init(members: []))
        if originalPage?.isLegacyBasePage == true { value = .object(.init(members: [.init(name: "controls", value: originalPage!.value)])) }
        if copy, let originalPage {
            if let id = originalPage.sourceID, hasUnknownReference(originalPage.value, id: id, excluding: ["id", "name", "controls", "portraitGeometry", "landscapeGeometry", "floatingZones"]) {
                block("A copied page has an unknown self-reference. Edited export cannot guess how to remap it.", path: originalPage.sourcePath)
            }
        }
        let id = pageIDs[page.id]!
        if originalPage == nil || copy || originalPage?.sourceID == nil || originalPage?.sourceID == "" {
            value = try value.androidReplacing(["id"], with: .string(id))
        }
        let pageBaseline = originalPage.flatMap { originalPage in baseline.pages.first { $0.sourcePath == originalPage.sourcePath } }
        let pageNameDigest = try androidExportDigest(.string(page.name))
        if copy || pageBaseline?.nameDigest != pageNameDigest {
            value = try value.androidReplacing(["name"], with: .string(page.name)); changed += 1
        }
        let ordered = profile.placements(for: .portrait, on: page.id).compactMap { profile.control(for: $0.id) }
        let exportedIDs = ordered.compactMap { controlIDs[$0.id] }
        for old in originalPage?.controls ?? [] where baseline.controls.contains(where: { $0.sourcePath == old.sourcePath }) && !exportedIDs.contains(old.sourceID) {
            for orientation in ["portraitGeometry", "landscapeGeometry"] {
                value = value.androidRemoving([orientation, "controls", old.sourceID])
            }
        }
        let untouched = originalPage?.controls.filter { old in !baseline.controls.contains { $0.sourcePath == old.sourcePath } } ?? []
        guard Set(exportedIDs).count == exportedIDs.count, Set(exportedIDs).isDisjoint(with: Set(untouched.map(\.sourceID))) else {
            throw AndroidArchiveError("An exported control ID collides with an archived-only control.")
        }
        var generated: [AndroidJSONValue] = []
        for native in ordered {
            let binding = source.controls.first { $0.nativeID == native.id }
            let old = binding.flatMap { b in allSourceControls.first { $0.sourcePath == b.sourcePath } }
            let oldBaseline = old.flatMap { old in baseline.controls.first { $0.sourcePath == old.sourcePath } }
            let originPage = old.flatMap { old in original.profiles.flatMap(\.pages).first { $0.controls.contains { $0.sourcePath == old.sourcePath } } }
            let isCopy = copiedControlIDs[native.id] != nil || old == nil
            var control = try patchedControl(native, originalControl: old, baseline: oldBaseline, copy: isCopy)
            let p = profile.portrait.first { $0.id == native.id }!.position
            let l = profile.landscape.first { $0.id == native.id }!.position
            let movedPage = oldBaseline != nil && originalPage?.sourcePath != oldBaseline?.pageSourcePath
            let targetP = try newGeometry(native, position: p, page: originalPage, orientation: .portrait, baseline: baseline)
            let targetL = try newGeometry(native, position: l, page: originalPage, orientation: .landscape, baseline: baseline)
            var pBase = oldBaseline == nil || movedPage ? targetP : rebased(oldBaseline!.portrait, to: targetP)
            var lBase = oldBaseline == nil || movedPage ? targetL : rebased(oldBaseline!.landscape, to: targetL)
            let restoredP = try movedPage ? nil : restorationBaseline(control: native, originalControl: old, page: page,
                originalPage: originalPage, orientation: .portrait, previous: pBase, baseline: baseline)
            let restoredL = try movedPage ? nil : restorationBaseline(control: native, originalControl: old, page: page,
                originalPage: originalPage, orientation: .landscape, previous: lBase, baseline: baseline)
            if let restoredP { pBase = restoredP }; if let restoredL { lBase = restoredL }
            let portrait = try geometry(native, position: p, orientation: .portrait, baseline: pBase, force: isCopy || movedPage || restoredP != nil)
            let landscape = try geometry(native, position: l, orientation: .landscape, baseline: lBase, force: isCopy || movedPage || restoredL != nil)
            if original.kind == .legacyControls {
                if portrait != nil || landscape != nil {
                    let pRectangle = portrait ?? pBase.sourceRectangle
                    let lRectangle = landscape ?? lBase.sourceRectangle
                    guard pRectangle == lRectangle else {
                        block("Legacy arrays cannot preserve separate orientation geometry. Edited geometry needs an explicit profile-format conversion.", path: old?.sourcePath ?? "")
                        generated.append(control); continue
                    }
                    control = try applyRectangle(pRectangle, to: control)
                }
            } else {
                if let portrait {
                    value = try setGeometry(portrait, controlID: controlIDs[native.id]!, orientation: "portraitGeometry", on: value, baseline: pBase,
                        template: old.flatMap { originPage?.value["portraitGeometry"]?["controls"]?[$0.sourceID] })
                    if old == nil { control = try applyRectangle(portrait, to: control) }
                }
                if let landscape { value = try setGeometry(landscape, controlID: controlIDs[native.id]!, orientation: "landscapeGeometry", on: value, baseline: lBase,
                    template: old.flatMap { originPage?.value["landscapeGeometry"]?["controls"]?[$0.sourceID] }) }
                if portrait != nil, landscape == nil, let old,
                   originPage?.value["landscapeGeometry"]?["controls"]?[old.sourceID] == nil {
                    value = try setGeometry(lBase.sourceRectangle, controlID: controlIDs[native.id]!, orientation: "landscapeGeometry", on: value, baseline: lBase)
                }
                if landscape != nil, portrait == nil, let old,
                   originPage?.value["portraitGeometry"]?["controls"]?[old.sourceID] == nil {
                    value = try setGeometry(pBase.sourceRectangle, controlID: controlIDs[native.id]!, orientation: "portraitGeometry", on: value, baseline: pBase)
                }
                if copy && portrait == nil, let base = oldBaseline?.portrait {
                    value = try setGeometry(base.sourceRectangle, controlID: controlIDs[native.id]!, orientation: "portraitGeometry", on: value, baseline: base)
                }
                if copy && landscape == nil, let base = oldBaseline?.landscape {
                    value = try setGeometry(base.sourceRectangle, controlID: controlIDs[native.id]!, orientation: "landscapeGeometry", on: value, baseline: base)
                }
            }
            generated.append(control)
        }
        // Retain archived-only records in their original slots; replace only converted slots.
        var records: [AndroidJSONValue] = [], cursor = 0
        for old in originalPage?.controls ?? [] {
            if untouched.contains(where: { $0.sourcePath == old.sourcePath }) { records.append(old.value) }
            else if cursor < generated.count { records.append(generated[cursor]); cursor += 1 }
        }
        records += generated.dropFirst(cursor)
        value = try value.androidReplacing(["controls"], with: .array(records))
        let floating = try patchedFloatingZones(page, originalPage: originalPage, baseline: baseline, copyingPage: copy)
        if floating != (originalPage?.value["floatingZones"]?.arrayValue ?? []) || originalPage?.value["floatingZones"] != nil {
            value = try value.androidReplacing(["floatingZones"], with: .array(floating))
        }
        return value
    }

    private mutating func patchedControl(_ native: ProfileControl, originalControl: AndroidSourceControl?, baseline: AndroidControlExportBaseline?, copy: Bool) throws -> AndroidJSONValue {
        var value = originalControl?.value ?? .object(.init(members: []))
        if native.isTouchAim && originalControl?.type != "TOUCH_AIM" {
            block("Edited Android export cannot translate a new native Touch Aim calibration safely. Export the unchanged original to preserve its Android settings.")
            return value
        }
        if copy {
            addedControls += 1
            if let originalControl, hasUnknownReference(originalControl.value, id: originalControl.sourceID, excluding: ["id", "name", "payload", "pageTargetId", "floatingActionTargetId"]) {
                block("A copied control contains an unknown self-reference; its original remains available, but edited export cannot safely rename that reference.", path: originalControl.sourcePath)
            }
        }
        if copy || originalControl?.sourceID.isEmpty != false { value = try value.androidReplacing(["id"], with: .string(controlIDs[native.id]!)) }
        let fields = try AndroidExportProjection.fields(native, profile: profile, source: source, pageTokens: pageTokens)
        let comparison = try baseline.map { try AndroidExportProjection.comparisonDigests($0, native: native, original: originalControl) }
        let kindChanged = try baseline?.fieldDigests["type"] != fields["type"].map(androidExportDigest)
        if kindChanged, let oldType = originalControl?.type,
           !(["STICK", "CURVED_STICK", "RADIAL_CURVED_STICK"].contains(oldType) && native.kind.isStick) {
            block("Changing a control's type requires explicit conversion of its dormant Android settings. Keep its original type or add a new control.", path: originalControl?.sourcePath ?? "")
        }
        var forced: Set<String> = []
        for activation in ["directionalMode", "stickPlusMode", "extendedBoost/enabled", "buttonAimEnabled", "buttonDirectional/enabled", "buttonAimOneShotAlternateEnabled"] {
            if fields[activation] == .bool(true), try baseline?.fieldDigests[activation] != fields[activation].map(androidExportDigest) {
                forced.formUnion(fields.keys.filter { key in
                    switch activation {
                    case "directionalMode", "stickPlusMode": return key.hasSuffix("Command") || key.hasSuffix("Threshold")
                    case "extendedBoost/enabled": return key.hasPrefix("extendedBoost/")
                    case "buttonDirectional/enabled": return key.hasPrefix("buttonDirectional/")
                    default: return key.hasPrefix("buttonAim")
                    }
                })
            }
        }
        for key in fields.keys.sorted() {
            let field = fields[key]!
            let fieldDigest = try androidExportDigest(field)
            if key == "stickPlusRepeatIntervalMilliseconds", field == .null, baseline?.fieldDigests[key] == nil { continue }
            if let baseline, baseline.fieldDigests[key] == nil,
               (AndroidExportProjection.additiveMigrationDefaults[key] ?? AndroidTimingFormat.tuningDefaults[key]) == field { continue }
            if key == AndroidExportProjection.touchSetupKey {
                if fieldDigest != comparison?[key] {
                    block("The iPhone's Touch Aim sensor setup differs from the verified Android import. Export the iPhone backup to keep that setup.", path: originalControl?.sourcePath ?? "")
                }
                continue
            }
            // The source template already contains the original Android spelling, including
            // unplayable actions that imported as empty. A copy inherits it until explicitly edited.
            if AndroidExportProjection.contactPayloadKeys.contains(key), fieldDigest == comparison?[key] { continue }
            guard copy || baseline == nil || forced.contains(key) || fieldDigest != baseline?.fieldDigests[key] else { continue }
            var exported = field
            if key == "floatingActionTargetId", let binding = native.floatingAction {
                if let target = floatingTargetExportID(binding.target) { exported = .string(target) }
                else if baseline?.fieldDigests[key] == fieldDigest, originalControl != nil { continue }
                else { throw AndroidArchiveError("The scoped action has a missing target that cannot be safely represented in this Android file.") }
            }
            if key == "pageTargetId", let token = field.stringValue, !token.isEmpty {
                guard let target = targetIDs[token] else { throw AndroidArchiveError("An edited page button has no exportable target.") }
                exported = .string(target)
            }
            value = try value.androidReplacing(key.split(separator: "/").map(String.init), with: exported)
            changed += 1
        }
        return value
    }

    private func floatingTargetExportID(_ target: ProfileFloatingActionTarget) -> String? {
        switch target {
        case let .control(id): return controlIDs[id]
        case let .zone(id):
            guard profile.pages.contains(where: { $0.floatingButtonZones.contains(where: { $0.id == id }) || $0.floatingRingZones.contains(where: { $0.id == id }) }) else { return nil }
            guard let binding = source.zones.first(where: { $0.nativeID == id }) else { return id.uuidString }
            if let copied = binding.exportID { return copied }
            for page in original.profiles.flatMap(\.pages) {
                for (index, zone) in (page.value["floatingZones"]?.arrayValue ?? []).enumerated()
                    where page.sourcePath + "/floatingZones/\(index)" == binding.sourcePath { return zone["id"]?.stringValue }
            }
            return nil
        }
    }

    private mutating func geometry(_ native: ProfileControl, position: NormalizedControlPosition,
        orientation: ControllerOrientation, baseline: AndroidGeometryExportBaseline?, force: Bool) throws -> AndroidExportRectangle? {
        guard let baseline else {
            // New controls use a deliberate 1-point=1-pixel reference canvas, not a guessed source density.
            let width = native.dimensions(for: orientation).width, height = native.dimensions(for: orientation).height
            return .init(x: position.x * 1_000 - width / 2, y: position.y * 1_000 - height / 2, width: width, height: height)
        }
        let widthChanged = native.dimensions(for: orientation).width != baseline.importedWidth, heightChanged = native.dimensions(for: orientation).height != baseline.importedHeight
        let movedX = position.x != baseline.importedPosition.x, movedY = position.y != baseline.importedPosition.y
        guard force || widthChanged || heightChanged || movedX || movedY else { return nil }
        let old = baseline.sourceRectangle
        let width = widthChanged ? native.dimensions(for: orientation).width / baseline.sizeScale : old.width
        let height = heightChanged ? native.dimensions(for: orientation).height / baseline.sizeScale : old.height
        let cx = movedX ? position.x * baseline.sourceCanvasWidth : old.x + old.width / 2
        let cy = movedY ? position.y * baseline.sourceCanvasHeight : old.y + old.height / 2
        let rectangle = AndroidExportRectangle(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
        try rectangle.validate(); changed += 1; return rectangle
    }
    private func newGeometry(_ native: ProfileControl, position: NormalizedControlPosition, page: AndroidSourcePage?,
                             orientation: ControllerOrientation, baseline: AndroidSourceExportBaseline) throws -> AndroidGeometryExportBaseline {
        let canvas = orientation == .portrait ? baseline.portraitCanvas : baseline.landscapeCanvas
        let key = orientation == .portrait ? "portraitGeometry" : "landscapeGeometry"
        func positive(_ value: AndroidJSONValue?, fallback: Double) -> Double {
            guard let raw = value?.numberValue?.rawValue, let number = Double(raw), number.isFinite, number > 0, number <= 1_000_000 else { return fallback }
            return number
        }
        let saved = baseline.controls.first { $0.pageSourcePath == page?.sourcePath }
        let fallback = orientation == .portrait ? saved?.portrait : saved?.landscape
        let width = positive(page?.value[key]?["canvasWidth"], fallback: fallback?.sourceCanvasWidth ?? canvas.width)
        let height = positive(page?.value[key]?["canvasHeight"], fallback: fallback?.sourceCanvasHeight ?? canvas.height)
        let scale = min(canvas.width / width, canvas.height / height)
        let w = native.dimensions(for: orientation).width / scale, h = native.dimensions(for: orientation).height / scale
        return .init(importedPosition: position, importedWidth: native.dimensions(for: orientation).width, importedHeight: native.dimensions(for: orientation).height,
            sourceCanvasWidth: width, sourceCanvasHeight: height, sizeScale: scale,
            sourceRectangle: .init(x: position.x * width - w / 2, y: position.y * height - h / 2, width: w, height: h))
    }
    private func rebased(_ source: AndroidGeometryExportBaseline, to target: AndroidGeometryExportBaseline) -> AndroidGeometryExportBaseline {
        .init(importedPosition: source.importedPosition, importedWidth: source.importedWidth, importedHeight: source.importedHeight,
            sourceCanvasWidth: target.sourceCanvasWidth, sourceCanvasHeight: target.sourceCanvasHeight,
            sizeScale: target.sizeScale, sourceRectangle: source.sourceRectangle)
    }
    private func applyRectangle(_ rectangle: AndroidExportRectangle, to value: AndroidJSONValue) throws -> AndroidJSONValue {
        var value = value
        for (key, number) in [("x", rectangle.x), ("y", rectangle.y), ("w", rectangle.width), ("h", rectangle.height)] {
            value = try value.androidReplacing([key], with: androidExportNumber(number))
        }
        return value
    }
    private func setGeometry(_ rectangle: AndroidExportRectangle, controlID: String, orientation: String,
        on page: AndroidJSONValue, baseline: AndroidGeometryExportBaseline?, template: AndroidJSONValue? = nil) throws -> AndroidJSONValue {
        var page = page
        if page[orientation] == nil || page[orientation] == .null {
            page = try page.androidReplacing([orientation], with: .object(.init(members: [])))
            page = try page.androidReplacing([orientation, "canvasWidth"], with: androidExportNumber(baseline?.sourceCanvasWidth ?? 1_000))
            page = try page.androidReplacing([orientation, "canvasHeight"], with: androidExportNumber(baseline?.sourceCanvasHeight ?? 1_000))
        }
        let old = page[orientation]?["controls"]?[controlID] ?? template ?? .object(.init(members: []))
        return try page.androidReplacing([orientation, "controls", controlID], with: applyRectangle(rectangle, to: old))
    }
    private func validateNewID(_ value: String) throws {
        guard UUID(uuidString: value) != nil else { throw AndroidArchiveError("Copied Android records require stable UUID export IDs.") }
    }
    private func hasUnknownReference(_ value: AndroidJSONValue, id: String, excluding: Set<String>) -> Bool {
        guard !id.isEmpty else { return false }
        func contains(_ value: AndroidJSONValue) -> Bool {
            switch value {
            case .string(let string): return string == id
            case .array(let array): return array.contains(where: contains)
            case .object(let object): return object.members.contains { $0.name == id || contains($0.value) }
            default: return false
            }
        }
        return value.objectValue?.members.contains { !excluding.contains($0.name) && contains($0.value) } ?? false
    }
}

extension AndroidJSONValue {
    func androidRemoving(_ path: [String]) -> Self {
        guard let first = path.first, case .object(let object) = self else { return self }
        if path.count == 1 { return .object(.init(members: object.members.filter { !$0.name.utf8.elementsEqual(first.utf8) })) }
        return .object(.init(members: object.members.map { member in
            member.name.utf8.elementsEqual(first.utf8) ? .init(name: member.name, value: member.value.androidRemoving(Array(path.dropFirst()))) : member
        }))
    }
    func androidReplacingPointer(_ pointer: String, with replacement: AndroidJSONValue) throws -> Self {
        guard pointer.isEmpty || pointer.hasPrefix("/") else { throw AndroidArchiveError("Invalid source JSON pointer.") }
        let path = pointer.isEmpty ? [] : pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        return try androidReplacing(path, with: replacement)
    }
    func androidReplacing(_ path: [String], with replacement: AndroidJSONValue) throws -> Self {
        guard let first = path.first else { return replacement }
        let tail = Array(path.dropFirst())
        switch self {
        case .object(let object):
            var members = object.members
            if let index = members.firstIndex(where: { $0.name.utf8.elementsEqual(first.utf8) }) {
                members[index] = .init(name: members[index].name, value: try members[index].value.androidReplacing(tail, with: replacement))
            } else {
                let blank = AndroidJSONValue.object(.init(members: []))
                members.append(.init(name: first, value: try blank.androidReplacing(tail, with: replacement)))
            }
            return .object(.init(members: members))
        case .array(let array):
            guard let index = Int(first), array.indices.contains(index) else { throw AndroidArchiveError("Source array reference is missing.") }
            var array = array; array[index] = try array[index].androidReplacing(tail, with: replacement); return .array(array)
        default: throw AndroidArchiveError("A source field is not an object and cannot be safely patched.")
        }
    }
}

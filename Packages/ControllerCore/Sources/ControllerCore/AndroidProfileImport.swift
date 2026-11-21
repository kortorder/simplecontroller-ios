import Foundation

public struct AndroidImportCanvas: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite, (104...4_096).contains(width), (104...4_096).contains(height) else {
            throw AndroidArchiveError("Invalid destination canvas size.")
        }
        self.width = width; self.height = height
    }
    private enum CodingKeys: String, CodingKey { case width, height }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["width", "height"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: values.decode(Double.self, forKey: .width), height: values.decode(Double.self, forKey: .height))
    }
}

public struct AndroidImportIssue: Equatable, Sendable {
    public enum Kind: String, Sendable { case adaptation, archivedOnly, preservedUnknown }
    public let kind: Kind
    public let sourcePath: String
    public let message: String
}

public struct AndroidImportedProfile: Equatable, Sendable {
    public var profile: ControllerProfile
    public var source: AndroidProfileSourceReference
}

/// A preview only: no files, settings, active selection or input state change when building a plan.
public struct AndroidProfileImportPlan: Equatable, Sendable {
    public let profiles: [AndroidImportedProfile]
    public let sourceProfileCount: Int
    public let sourceControlCount: Int
    public let convertedControlCount: Int
    public let issues: [AndroidImportIssue]
    public let settingsPresets: SettingsPresetLibrary
    public var convertedPresetCount: Int { settingsPresets.entries.count }
    public let sourceSHA256: String
    public let sourceByteCount: Int
    public var archivedOnlyControlCount: Int { sourceControlCount - convertedControlCount }
    public var archivedOnlyProfileCount: Int { sourceProfileCount - profiles.count }

    public static func prepare(_ document: AndroidProfileDocument, archiveID: UUID,
                               portrait: AndroidImportCanvas = try! .init(width: 337, height: 428),
                               landscape: AndroidImportCanvas = try! .init(width: 494, height: 208)) throws -> Self {
        var mapper = AndroidNativeMapper(archiveID: archiveID, portrait: portrait, landscape: landscape, original: document)
        var profiles: [AndroidImportedProfile] = []
        if document.profiles.count > 32 {
            mapper.issue(.archivedOnly, "", "This document has more than 32 profiles. Its exact original is archived; no profiles were partially imported.")
        } else {
            for source in document.profiles {
                if let converted = try mapper.profile(source) { profiles.append(converted) }
            }
        }
        for diagnostic in document.diagnostics where diagnostic.kind == .unknownFields {
            mapper.issue(.preservedUnknown, diagnostic.sourcePath, diagnostic.message)
        }
        let importedPresets = AndroidSettingsPresetImport.prepare(document)
        for issue in importedPresets.issues { mapper.issue(issue.kind, issue.sourcePath, issue.message) }
        if mapper.omittedIssueCount > 0 {
            mapper.issues.append(.init(kind: .preservedUnknown, sourcePath: "", message: "\(mapper.omittedIssueCount) additional notes are omitted from this preview. The complete original file is still preserved."))
        }
        return .init(profiles: profiles, sourceProfileCount: document.profiles.count,
            sourceControlCount: document.profiles.reduce(0) { $0 + $1.pages.reduce(0) { $0 + $1.controls.count } },
            convertedControlCount: profiles.reduce(0) { $0 + $1.profile.controls.count }, issues: mapper.issues, settingsPresets: importedPresets.library,
            sourceSHA256: androidSHA256(document.originalData), sourceByteCount: document.originalData.count)
    }

    /// Pure, whole-library merge for the confirmation step. Preserve the current profile selection.
    /// Callers archive the source first, then persist this fully validated candidate atomically.
    public func merged(into library: ControllerProfileLibrary, source reference: AndroidSourceArchiveReference) throws -> ControllerProfileLibrary {
        try library.validate(); try reference.validate()
        guard reference.sha256 == sourceSHA256, reference.byteCount == sourceByteCount else {
            throw AndroidArchiveError("The import preview does not match the preserved original.")
        }
        guard library.profiles.count + profiles.count <= 32 else { throw AndroidArchiveError("This import would exceed 32 native profiles. Nothing was imported.") }
        var result = library
        if let existing = result.androidSources.first(where: { $0.id == reference.id }) {
            guard existing == reference else { throw AndroidArchiveError("Conflicting Android archive metadata.") }
        } else { result.androidSources.append(reference) }
        var names = Set(library.profiles.map { $0.name.lowercased() })
        for item in profiles {
            var copy = try item.profile.cloned()
            let base = copy.name
            var name = base, index = 1
            while !names.insert(name.lowercased()).inserted {
                let suffix = index == 1 ? " imported" : " imported \(index)"
                name = String(base.prefix(64 - suffix.count)) + suffix; index += 1
            }
            copy.name = name
            copy.androidSources = copy.androidSources.map { $0.replacingArchiveID(reference.id) }
            result.profiles.append(copy)
        }
        if !settingsPresets.entries.isEmpty {
            _ = try result.settingsPresets.merge(settingsPresets, at: settingsPresets.entries.map(\.updatedAtMilliseconds).max() ?? 0)
        }
        try result.validate()
        return result
    }
}

private struct AndroidNativeMapper {
    let archiveID: UUID
    let portrait: AndroidImportCanvas
    let landscape: AndroidImportCanvas
    let original: AndroidProfileDocument
    var issues: [AndroidImportIssue] = []
    var omittedIssueCount = 0
    mutating func issue(_ kind: AndroidImportIssue.Kind, _ path: String, _ message: String) {
        guard issues.count < 500 else { omittedIssueCount += 1; return }
        let summary = message.count <= 1_024 ? message : String(message.prefix(1_024)) + "…"
        issues.append(.init(kind: kind, sourcePath: path, message: summary))
    }
    func string(_ value: AndroidJSONValue?, _ fallback: String = "") -> String { value?.stringValue ?? fallback }
    func bool(_ value: AndroidJSONValue?, _ fallback: Bool = false) throws -> Bool {
        guard let value else { return fallback }
        guard case let .bool(result) = value else { throw AndroidArchiveError("Expected a Boolean setting.") }
        return result
    }
    func number(_ value: AndroidJSONValue?, _ fallback: Double) throws -> Double {
        guard let value else { return fallback }
        guard let raw = value.numberValue?.rawValue, let result = Double(raw), result.isFinite else {
            throw AndroidArchiveError("A numeric setting cannot be represented safely on iPhone.")
        }
        return result
    }
    func integer(_ value: AndroidJSONValue?, _ fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let raw = value.numberValue?.rawValue, let result = Int(raw) else { throw AndroidArchiveError("Expected a whole-number timing setting.") }
        return result
    }
    func nativeName(_ source: String, fallback: String) -> String {
        let clean = source.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? fallback : clean).prefix(64))
    }
    mutating func profile(_ source: AndroidSourceProfile) throws -> AndroidImportedProfile? {
        let count = source.pages.reduce(0) { $0 + $1.controls.count }
        guard source.pages.count <= ControllerProfile.maximumPages, count <= 64 else {
            issue(.archivedOnly, source.sourcePath, "This profile exceeds 32 pages or 64 controls. It remains archived in full rather than losing controls.")
            return nil
        }
        let profileID = UUID()
        var sourcePages = source.pages
        if sourcePages.isEmpty {
            issue(.adaptation, source.sourcePath, "An empty Main page replaces missing pages in the iPhone copy only.")
            sourcePages = [.init(sourcePath: source.sourcePath + "/pages", sourceID: nil, name: "Main", isLegacyBasePage: false, controls: [], value: .null)]
        }
        let ids = sourcePages.map { _ in UUID() }
        let pageMap = Dictionary(uniqueKeysWithValues: zip(sourcePages, ids).compactMap { page, id in page.sourceID.map { (Data($0.utf8), id) } })
        var usedNames: Set<String> = []
        var pages: [ProfilePage] = [], controls: [ProfileControl] = []
        var portraitPositions: [ProfilePlacement] = [], landscapePositions: [ProfilePlacement] = []
        var pageBindings: [AndroidSourceBinding] = [], controlBindings: [AndroidSourceBinding] = [], zoneBindings: [AndroidSourceBinding] = []
        for (index, page) in sourcePages.enumerated() {
            let base = nativeName(page.name, fallback: "Page \(index + 1)")
            var name = base, suffix = 2
            while !usedNames.insert(name.lowercased()).inserted {
                let ending = " \(suffix)"; name = String(base.prefix(64 - ending.count)) + ending; suffix += 1
            }
            if name != page.name { issue(.adaptation, page.sourcePath, "Page name was made nonblank, unique and at most 64 characters in the iPhone copy.") }
            var members: [UUID] = []
            for sourceControl in page.controls {
                do {
                    var native = try control(sourceControl, pageMap: pageMap)
                    let p = try geometry(sourceControl, on: page, orientation: .portrait, canvas: portrait)
                    let l = try geometry(sourceControl, on: page, orientation: .landscape, canvas: landscape)
                    if native.isTouchpad {
                        native.touchpadWidth = min(1_200, max(44, p.width)); native.touchpadHeight = min(1_200, max(44, p.height))
                    } else {
                        native.diameter = min(native.kind.isStick ? 300 : 200, max(native.minimumDiameter, min(p.width, p.height)))
                        native.controlWidth = min(1_200, max(native.minimumDiameter, p.width))
                        native.controlHeight = min(1_200, max(native.minimumDiameter, p.height))
                        if native.controlWidth != p.width || native.controlHeight != p.height {
                            issue(.adaptation, sourceControl.sourcePath, "Control size was bounded to the native minimum touch target and maximum dimensions. Original geometry remains archived.")
                        }
                    }
                    func dimensions(_ geometry: FittedGeometry) -> ProfileControlDimensions {
                        .init(width: min(1_200, max(native.minimumDiameter, geometry.width)),
                              height: min(1_200, max(native.minimumDiameter, geometry.height)))
                    }
                    native.orientationDimensions = .init(portrait: dimensions(p), landscape: dimensions(l))
                    if native.dimensions(for: .landscape).width != l.width || native.dimensions(for: .landscape).height != l.height ||
                        (native.isTouchpad && (native.touchpadWidth != p.width || native.touchpadHeight != p.height)) {
                        issue(.adaptation, sourceControl.sourcePath, "Orientation dimensions were bounded to the native touch-target minimum and maximum. Original geometry remains archived.")
                    }
                    try native.validate()
                    controls.append(native); members.append(native.id)
                    portraitPositions.append(.init(id: native.id, position: p.position))
                    landscapePositions.append(.init(id: native.id, position: l.position))
                    controlBindings.append(.init(nativeID: native.id, sourcePath: sourceControl.sourcePath))
                } catch {
                    let label = nativeName(sourceControl.name, fallback: String(sourceControl.type.prefix(64)))
                    issue(.archivedOnly, sourceControl.sourcePath, "\(label): \(error.localizedDescription) The original control is preserved and is not made playable.")
                }
            }
            var nativePage = ProfilePage(id: ids[index], name: name, controlIDs: members)
            let mappedPairs = controlBindings.compactMap { binding -> (String, UUID)? in
                guard let original = page.controls.first(where: { $0.sourcePath == binding.sourcePath }), controls.first(where: { $0.id == binding.nativeID })?.kind == .button else { return nil }
                return (original.sourceID, binding.nativeID)
            }
            let groupedPairs = Dictionary(grouping: mappedPairs, by: { $0.0 })
            let mappedButtons = groupedPairs.compactMapValues { $0.count == 1 ? $0[0].1 : nil }
            var seenZoneIDs = Set<String>()
            for (zoneIndex, zone) in (page.value["floatingZones"]?.arrayValue ?? []).enumerated() {
                let path = page.sourcePath + "/floatingZones/\(zoneIndex)"
                do {
                    guard let sourceID = zone["id"]?.stringValue, !sourceID.isEmpty, seenZoneIDs.insert(sourceID).inserted else { throw AndroidArchiveError("Floating source IDs must be nonblank and unique.") }
                    let converted = try AndroidFloatingConversion.decode(zone, controls: mappedButtons)
                    var candidate = nativePage
                    switch converted {
                    case let .button(value): candidate.floatingButtonZones.append(value)
                    case let .ring(value): candidate.floatingRingZones.append(value)
                    }
                    try candidate.validate()
                    try FloatingButtonZone.validate(candidate.floatingButtonZones, pageControlIDs: Set(members), buttonIDs: Set(mappedButtons.values))
                    nativePage = candidate; zoneBindings.append(.init(nativeID: converted.id, sourcePath: path))
                    issue(.adaptation, path, "Floating template converted with saved activation geometry and detached members. Android pixels/dp are native point tuning; review size and comfort on this iPhone. Runtime touch ownership and cancellation use native safety rules.")
                } catch { issue(.archivedOnly, path, "Floating template: \(error.localizedDescription) Its complete original stays archived; converted buttons remain available outside this unsupported zone.") }
            }
            pages.append(nativePage)
            pageBindings.append(.init(nativeID: ids[index], sourcePath: page.sourcePath))
        }
        // Zones depend on converted members, so scoped targets resolve after every page is built.
        for index in controls.indices where controls[index].floatingAction != nil {
            guard let binding = controlBindings.first(where: { $0.nativeID == controls[index].id }),
                  let page = sourcePages.first(where: { $0.controls.contains(where: { $0.sourcePath == binding.sourcePath }) }),
                  let originalControl = page.controls.first(where: { $0.sourcePath == binding.sourcePath }),
                  let action = controls[index].floatingAction?.action else { continue }
            let target = string(originalControl.value["floatingActionTargetId"])
            var choices: [ProfileFloatingActionTarget] = []
            for (zoneIndex, zone) in (page.value["floatingZones"]?.arrayValue ?? []).enumerated() where zone["id"]?.stringValue == target {
                let path = page.sourcePath + "/floatingZones/\(zoneIndex)"
                if let mapped = zoneBindings.first(where: { $0.sourcePath == path }),
                   action == .finish || pages.contains(where: { $0.floatingRingZones.contains(where: { $0.id == mapped.nativeID }) }) { choices.append(.zone(mapped.nativeID)) }
            }
            if action == .endSuppression {
                for item in page.controls where item.sourceID == target {
                    if let mapped = controlBindings.first(where: { $0.sourcePath == item.sourcePath }) { choices.append(.control(mapped.nativeID)) }
                }
            }
            if choices.count == 1 { controls[index].floatingAction?.target = choices[0] }
            else { issue(.adaptation, binding.sourcePath, "The scoped action button has an unavailable, incompatible or ambiguous target. It stays inert until a target is selected; its original target text is preserved for Android export.") }
        }
        let home = source.homePageID.flatMap { pageMap[Data($0.utf8)] } ?? ids[0]
        if source.homePageID.flatMap({ pageMap[Data($0.utf8)] }) == nil {
            issue(.adaptation, source.sourcePath, "The first page becomes Home because the Android Home reference is missing or unresolved.")
        }
        let name = nativeName(source.name, fallback: "Imported Android profile")
        if name != source.name { issue(.adaptation, source.sourcePath, "Profile name was shortened or repaired in the iPhone copy.") }
        let reference = AndroidProfileSourceReference(archiveID: archiveID, sourceProfilePath: source.sourcePath, pages: pageBindings, controls: controlBindings, zones: zoneBindings)
        let swipeMode = source.value["swipeMode"]?.stringValue.flatMap { ProfileSwipeMode(rawValue: $0.lowercased()) } ?? .off
        var profile = try ControllerProfile(id: profileID, name: name, controls: controls,
            portrait: portraitPositions, landscape: landscapePositions, swipeMode: swipeMode, pages: pages, homePageID: home, androidSources: [reference])
        let baseline = try AndroidSourceExportBaseline.capture(profile: profile, source: reference, original: original, portrait: portrait, landscape: landscape)
        let trackedReference = reference.withExportBaseline(baseline)
        profile.androidSources = [trackedReference]
        issue(.adaptation, source.sourcePath, source.value["swipeMode"] == nil
              ? "Android global Swipe and Turbo settings are not part of this file. The iPhone copy starts with both off. Desktop outputs remain Practice-only."
              : "The iPhone copy uses the saved Swipe option. Turbo starts off. Desktop outputs stay in Practice.")
        return .init(profile: profile, source: trackedReference)
    }

    mutating func control(_ source: AndroidSourceControl, pageMap: [Data: UUID]) throws -> ProfileControl {
        let v = source.value
        let floatingActionName = string(v["floatingLocalAction"], "NONE")
        let kind: ProfileControlKind
        switch source.type {
        case "BUTTON": kind = string(v["pageAction"], "NONE") == "NONE" ? .button : .pageButton
        case "STICK", "CURVED_STICK", "RADIAL_CURVED_STICK":
            let payload = source.payload.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            kind = payload == "R" || payload == "RS" || payload == "RIGHT" || payload.contains("_R") ? .rightStick : .leftStick
        case "TOUCHPAD": kind = .touchpad
        case "TOUCH_AIM": kind = .touchAim
        case "RECENTER": kind = .recenter
        default: throw AndroidArchiveError("This Android control type is not supported by the native importer.")
        }
        var c = ProfileControl(name: nativeName(source.name, fallback: source.type == "BUTTON" ? source.payload : kind == .leftStick ? "Left stick" : kind == .rightStick ? "Right stick" : source.type.capitalized), kind: kind)
        if c.name.isEmpty { c.name = "Button" }
        c.swipeActivationEnabled = try bool(v["swipeActivate"], true)
        c.cameraFollowStrengthPercent = try number(v["cameraFollowStrengthPercent"], 100)
        c.excludeFromCameraFollow = try bool(v["excludeFromCameraFollow"])
        c.mouseSuppressCameraFollow = try bool(v["mouseSuppressCameraFollow"])
        if c.cameraFollowStrengthPercent != 100 || c.excludeFromCameraFollow || c.mouseSuppressCameraFollow {
            issue(.adaptation, source.sourcePath, "Camera Follow strength and participation/suppression settings are retained for the local Practice preview. They do not establish desktop or console delivery.")
        }
        if kind == .pageButton {
            switch string(v["pageAction"]) {
            case "HOME": c.pageNavigation = .home
            case "RETURN": c.pageNavigation = .back
            case "GO_TO", "TOGGLE":
                guard let target = pageMap[Data(string(v["pageTargetId"]).utf8)] else { throw AndroidArchiveError("The page button has an unresolved target.") }
                c.pageNavigation = string(v["pageAction"]) == "GO_TO" ? .goTo(target) : .toggle(target)
            default: throw AndroidArchiveError("Unknown page action.")
            }
            issue(.adaptation, source.sourcePath, "Page navigation is local and direct-touch only; any ordinary button payload is inactive.")
        } else if kind == .button {
            if floatingActionName != "NONE" {
                let action: FloatingLocalAction
                switch floatingActionName {
                case "FINISH": action = .finish
                case "STOP_FIRE": action = .stopFire
                case "RELEASE_ADS": action = .releaseADS
                case "END_SUPPRESSION": action = .endSuppression
                default: throw AndroidArchiveError("Unknown scoped floating action.")
                }
                guard !string(v["floatingActionTargetId"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AndroidArchiveError("A scoped action needs a target.") }
                c.floatingAction = .init(action: action, target: .zone(UUID()))
                c.payload = source.payload
                c.buttonBehavior = .init(holdToggle: try bool(v["holdToggle"]), holdMilliseconds: try integer(v["holdDurationMs"], 500))
                c.autoTapEnabled = try bool(v["autoTapEnabled"])
                c.macroModeEnabled = try bool(v["macroModeEnabled"])
                c.buttonDirectional = try directionalButton(v["buttonDirectional"]); c.buttonAim = try buttonAim(v)
                issue(.adaptation, source.sourcePath, "Scoped floating action converted as direct-touch only. Its ordinary payload is inactive; only the selected floating session or suppression owner is affected.")
            } else { c.payload = try ControllerPayloadProgram.parse(source.payload).source }
            if c.isFloatingAction {
                // Explicit source validation below rejects conflicting behavior rather than enabling it.
            } else if c.isReleaseAllAction || c.isCameraFollowAction {
                // Android dispatches this safety action before Hold, AutoTap or advanced behavior.
                // Keep the inactive originals in the archive; the native button is immediate only.
                issue(.adaptation, source.sourcePath, c.isReleaseAllAction
                    ? "Release all is an immediate local safety action. Inactive Android Hold, AutoTap and Aim settings stay in the original archive."
                    : "Camera Follow is a direct local Practice command. Inactive Android Hold, AutoTap and Aim settings stay in the original archive.")
            } else {
                c.buttonBehavior = .init(holdToggle: try bool(v["holdToggle"]), holdMilliseconds: try integer(v["holdDurationMs"], 500))
                c.autoTapEnabled = try bool(v["autoTapEnabled"])
                c.macroModeEnabled = try bool(v["macroModeEnabled"])
                c.autoTapIntervalMilliseconds = try integer(v["autoTapIntervalMs"], 100)
                c.buttonDirectional = try directionalButton(v["buttonDirectional"])
                c.buttonAim = try buttonAim(v)
            }
            if c.isAdvancedButton {
                issue(.adaptation, source.sourcePath, "Directional and Aim distances use iOS points. Android numeric tuning is retained and may need adjustment on the phone; mouse output remains Practice-only.")
            }
        } else if kind.isStick {
            c.directionalEnabled = try bool(v["directionalMode"])
            c.stickBehavior = .init(autoCenter: try bool(v["autoCenter"], true), stickPlusEnabled: try bool(v["stickPlusMode"]),
                boostThreshold: try number(v["boostThreshold"], 0.5), superBoostThreshold: try number(v["superBoostThreshold"], 0.75))
            if let repeatInterval = v["stickPlusRepeatIntervalMilliseconds"], repeatInterval != .null {
                c.stickPlusRepeatIntervalMilliseconds = try integer(repeatInterval, 200)
            }
            c.stickResponse = .init(mode: source.type == "CURVED_STICK" ? .perAxis : source.type == "RADIAL_CURVED_STICK" ? .radial : .linear,
                sensitivity: try number(v["sensitivity"], 1))
            if c.directionalEnabled || c.stickBehavior.stickPlusEnabled {
                for direction in StickDirection.allCases {
                    let key = direction.rawValue
                    let normal = key == "up" ? "W" : key == "down" ? "S" : key == "left" ? "A" : "D"
                    let boost = normal + (key == "down" ? ",CTRL" : ",SHIFT")
                    c.directionPayloads[direction] = .init(normalPayload: string(v[key + "Command"], normal),
                        boostPayload: string(v[key + "BoostCommand"], boost), superBoostPayload: string(v[key + "SuperBoostCommand"], boost + ",SPACE"))
                }
            }
            if let extended = v["extendedBoost"] {
                guard extended.objectValue != nil else { throw AndroidArchiveError("Invalid Extended Boost settings.") }
                for key in ["regular", "superBoost", "outer", "outerCommands"] where extended[key] != nil {
                    guard extended[key]?.objectValue != nil else { throw AndroidArchiveError("Invalid Extended Boost \(key) settings.") }
                }
                let mode: ExtendedBoostMode
                switch string(extended["mode"], "REPLACE_THRESHOLDS") {
                case "REPLACE_THRESHOLDS": mode = .replaceThresholds
                case "ADD_OUTER_STAGE": mode = .addOuterStage
                default: throw AndroidArchiveError("Unknown Extended Boost mode.")
                }
                var directions: [StickDirection: ExtendedBoostDirectionSettings] = [:]
                for direction in StickDirection.allCases {
                    let key = direction.rawValue
                    if let payload = extended["outerCommands"]?[key], payload.stringValue == nil {
                        throw AndroidArchiveError("Outer Boost commands must be text.")
                    }
                    directions[direction] = .init(regularThreshold: try number(extended["regular"]?[key], 0.5),
                        superThreshold: try number(extended["superBoost"]?[key], 0.75), outerThreshold: try number(extended["outer"]?[key], 1.25),
                        outerPayload: extended["outerCommands"]?[key]?.stringValue)
                }
                c.extendedBoost = .init(enabled: try bool(extended["enabled"]), mode: mode, directions: directions)
            }
        } else if kind == .touchpad {
            let mode: TouchpadClickMode = try bool(v["doubleTapClickLock"]) ? .doubleTapLock : bool(v["toggleLeftClick"]) ? .toggle : bool(v["holdLeftWhileTouch"]) ? .hold : .none
            c.touchpadBehavior = .init(sensitivity: try number(v["sensitivity"], 1), clickMode: mode)
            issue(.adaptation, source.sourcePath, "Touchpad movement uses iOS points. Android sensitivity is retained; feel may need adjustment on the phone.")
        } else if kind == .touchAim {
            c.touchAim = try touchAimSettings(v, path: source.sourcePath)
        }
        if floatingActionName != "NONE", kind != .button { throw AndroidArchiveError("Scoped floating actions require an ordinary Button.") }
        for flag in ["thresholdEnabled", "superThresholdEnabled"] where (try? bool(v[flag])) == true {
            issue(.archivedOnly, source.sourcePath + "/" + flag, "This Android option is preserved in the original but is not applied to the native copy.")
        }
        try c.validate()
        return c
    }

    private mutating func touchAimSettings(_ v: AndroidJSONValue, path: String) throws -> TouchAimSettings {
        let output: ButtonAimOutput
        switch try text(v["touchAimOutput"], "MOUSE") {
        case "MOUSE": output = try bool(v["touchAimGameMouse"]) ? .gameMouse : .mouse
        case "LEFT_STICK": output = .leftStick
        case "RIGHT_STICK": output = .rightStick
        default: throw AndroidArchiveError("Unknown Touch Aim output routing.")
        }
        var settings = TouchAimSettings(requiresLocalSetup: true)
        settings.aim = .init(output: output, sensitivity: try number(v["sensitivity"], 1),
            invertY: try bool(v["touchInvertY"]), stickResponse: try bool(v["touchUseResponseCurve"]) ? .perAxis : .linear,
            mouseResponse: .smoothedNonlinear, origin: try bool(v["touchAimStickUsesTouchPosition"], true) ? .controlCenter : .initialTouch,
            fullDisplacement: try number(v["touchAimStickFullDisplacementPx"], 220), deadzone: try number(v["touchAimStickDeadzonePx"], 8))
        try settings.aim.validate()
        switch try text(v["touchAimMode"], "MANUAL_THREE_STAGE") {
        case "MANUAL_THREE_STAGE": settings.mode = .manualThreeStage
        case "MANUAL_TWO_STATE": settings.mode = .manualTwoState
        case "CALIBRATED_TWO_STATE": settings.mode = .calibratedTwoState
        default: throw AndroidArchiveError("Unknown Touch Aim detector mode.")
        }
        func action(_ value: AndroidJSONValue?, _ fallback: TouchAimStageAction) throws -> TouchAimStageAction {
            switch try text(value, fallback == .press ? "PRESS" : "HOLD") {
            case "PRESS": return .press
            case "HOLD": return .hold
            default: throw AndroidArchiveError("Unknown Touch Aim stage action.")
            }
        }
        // Preserve supported authored actions for review, but never claim Android measurements are
        // equivalent to the iPhone metric. The persistent gate blocks even valid action programs.
        for (key, fallback) in [("touchLowPayload", ""), ("touchMediumPayload", "LT:1.0"), ("touchHighPayload", "RT:1.0"),
                                ("touchAimAimPayload", ""), ("touchAimShootPayload", "RT:1.0")] {
            let raw = try text(v[key], fallback)
            let payload: String
            do { _ = try advancedButtonProgram(raw); payload = raw }
            catch {
                payload = ""
                issue(.archivedOnly, path + "/" + key, "This contact action cannot run natively and remains in the Android original: \(error.localizedDescription)")
            }
            switch key {
            case "touchLowPayload": settings.threeStage.low.payload = payload
            case "touchMediumPayload": settings.threeStage.medium.payload = payload
            case "touchHighPayload": settings.threeStage.high.payload = payload
            case "touchAimAimPayload": settings.twoState.aimPayload = payload
            default: settings.twoState.shootPayload = payload
            }
        }
        settings.threeStage.low.action = try action(v["touchLowAction"], .press)
        settings.threeStage.medium.action = try action(v["touchMediumAction"], .hold)
        settings.threeStage.high.action = try action(v["touchHighAction"], .hold)
        settings.threeStage.keepLowerHolds = try bool(v["touchKeepLowerHolds"], true)
        for level in TouchAimLevel.allCases {
            let keys = AndroidTimingFormat.keys(for: level)
            let sensitivity = try v[keys.sensitivity].flatMap { $0 == .null ? nil : try number($0, 1) }
            let tuning = TouchAimStageTuning(sensitivity: sensitivity, confirmationMilliseconds: try integer(v[keys.confirmation], 0))
            switch level {
            case .aimOnly: settings.threeStage.aimOnlyTuning = tuning
            case .low: settings.threeStage.low.tuning = tuning
            case .medium: settings.threeStage.medium.tuning = tuning
            case .high: settings.threeStage.high.tuning = tuning
            }
        }
        settings.twoState.keepAimWhileShooting = try bool(v["touchAimKeepAimPayloadWhileShooting"], true)
        settings.twoState.shootSensitivity = try number(v["touchAimShootSensitivity"], 1)
        switch try text(v["touchAimShootBehavior"], "HOLD_WHILE_ABOVE") {
        case "HOLD_WHILE_ABOVE": settings.twoState.shootBehavior = .hold
        case "PRESS_ON_ENTER": settings.twoState.shootBehavior = .pressOnEnter
        case "PRESS_ON_RETURN_TO_AIM": settings.twoState.shootBehavior = .pressOnReturn
        default: throw AndroidArchiveError("Unknown Touch Aim shooting action.")
        }
        settings.twoState.enterMilliseconds = try integer(v["touchAimEnterShootConfirmationMs"], 90)
        settings.twoState.returnMilliseconds = try integer(v["touchAimReturnToAimConfirmationMs"], 120)
        // Source detector thresholds/transforms depend on unavailable Android size/major/minor
        // measurements. Keep them solely in the archive; native defaults remain disabled placeholders.
        issue(.adaptation, path, "Touch Aim movement and supported action texts are copied. Contact actions stay disabled until explicit local touch setup. Android averaged sensor values, thresholds and calibration are preserved only in the original; no iPhone equivalence is assumed.")
        try settings.validate()
        return settings
    }

    private func directionalButton(_ value: AndroidJSONValue?) throws -> ButtonDirectionalSettings {
        guard let value else { return .init() }
        guard value.objectValue != nil else { throw AndroidArchiveError("Invalid directional button settings.") }
        var directions: [StickDirection: ButtonDirectionStages] = [:]
        for direction in StickDirection.allCases {
            let item = value[direction.rawValue]
            if let item, item.objectValue == nil { throw AndroidArchiveError("Invalid directional button stage settings.") }
            directions[direction] = .init(firstDistance: try number(item?["firstDistancePx"], 48),
                secondDistance: try number(item?["secondDistancePx"], 96),
                firstPayload: try text(item?["firstPayload"], ""), secondPayload: try text(item?["secondPayload"], ""))
        }
        return .init(enabled: try bool(value["enabled"]), directions: directions)
    }
    private func text(_ value: AndroidJSONValue?, _ fallback: String) throws -> String {
        guard let value else { return fallback }
        guard let result = value.stringValue else { throw AndroidArchiveError("Expected a text setting.") }
        return result
    }
    private func timing(_ value: AndroidJSONValue?) throws -> ButtonAimPayloadTiming {
        switch try text(value, "IMMEDIATE") {
        case "IMMEDIATE": return .immediate
        case "SEND_ON_RELEASE": return .sendOnRelease
        default: throw AndroidArchiveError("Unknown Button Aim payload timing.")
        }
    }
    private func aimTuning(_ value: AndroidJSONValue, prefix: String) throws -> ButtonAimTuning {
        let output: ButtonAimOutput
        switch try text(value[prefix + "Output"], "MOUSE") {
        case "MOUSE": output = .mouse
        case "GAME_MOUSE": output = .gameMouse
        case "LEFT_STICK": output = .leftStick
        case "RIGHT_STICK": output = .rightStick
        case "DPAD": output = .dpad
        default: throw AndroidArchiveError("Unknown Button Aim output.")
        }
        let response: StickResponseMode
        switch try text(value[prefix + "StickProfile"], "LINEAR") {
        case "LINEAR": response = .linear
        case "RESPONSE_CURVE": response = .perAxis
        case "RADIAL_RESPONSE_CURVE": response = .radial
        default: throw AndroidArchiveError("Unknown Button Aim stick response.")
        }
        let mouse: ButtonAimMouseResponse
        switch try text(value[prefix + "MouseProfile"], "SMOOTHED_NONLINEAR") {
        case "LINEAR_RELATIVE": mouse = .linearRelative
        case "SMOOTHED_NONLINEAR": mouse = .smoothedNonlinear
        default: throw AndroidArchiveError("Unknown Button Aim mouse response.")
        }
        let mode: ButtonAimDpadMode
        switch try text(value[prefix + "DpadMode"], "EIGHT_WAY") {
        case "FOUR_WAY": mode = .fourWay
        case "EIGHT_WAY": mode = .eightWay
        default: throw AndroidArchiveError("Unknown Button Aim D-pad mode.")
        }
        let origin: ButtonAimOrigin
        switch try text(value[prefix + "DpadOrigin"], "CONTROL_CENTER") {
        case "CONTROL_CENTER": origin = .controlCenter
        case "INITIAL_TOUCH": origin = .initialTouch
        default: throw AndroidArchiveError("Unknown Button Aim D-pad origin.")
        }
        return .init(output: output, sensitivity: try number(value[prefix + "Sensitivity"], 1),
            invertY: try bool(value[prefix + "InvertY"]), stickResponse: response, mouseResponse: mouse,
            origin: try bool(value[prefix + "StickUsesTouchPosition"]) ? .controlCenter : .initialTouch,
            fullDisplacement: try number(value[prefix + "StickFullDisplacementPx"], 220), deadzone: try number(value[prefix + "StickDeadzonePx"], 8),
            autoCenter: try bool(value[prefix + "AutoCenter"], true), dpadMode: mode, dpadOrigin: origin,
            dpadActivationDistance: try number(value[prefix + "DpadActivationDistancePx"], 8), hapticsEnabled: try bool(value[prefix + "Haptics"], true))
    }
    private func buttonAim(_ value: AndroidJSONValue) throws -> ButtonAimSettings {
        .init(enabled: try bool(value["buttonAimEnabled"]), payloadTiming: try timing(value["buttonAimPayloadTiming"]),
            releaseDelayMilliseconds: try integer(value["buttonAimReleaseDelayMs"], 0),
            cancelOnBoundaryExit: try bool(value["buttonAimCancelOnBoundaryExit"]), rearmOnBoundaryReturn: try bool(value["buttonAimRearmOnBoundaryReturn"]),
            tuning: try aimTuning(value, prefix: "buttonAim"),
            alternate: .init(enabled: try bool(value["buttonAimOneShotAlternateEnabled"]),
                payload: try text(value["buttonAimAlternatePayload"], ""), payloadTiming: try timing(value["buttonAimAlternatePayloadTiming"]),
                resetHoldMilliseconds: try integer(value["buttonAimAlternateResetHoldDurationMs"], 2000),
                baseUnlatchDelayMilliseconds: try integer(value["buttonAimAlternateBaseUnlatchDelayMs"], 0),
                displayName: try text(value["buttonAimAlternateDisplayName"], ""), tuning: try aimTuning(value, prefix: "buttonAimAlternate")))
    }

    private struct FittedGeometry { let position: NormalizedControlPosition; let width: Double; let height: Double }
    private mutating func geometry(_ control: AndroidSourceControl, on page: AndroidSourcePage,
                           orientation: ControllerOrientation, canvas: AndroidImportCanvas) throws -> FittedGeometry {
        let key = orientation == .portrait ? "portraitGeometry" : "landscapeGeometry"
        let other = orientation == .portrait ? "landscapeGeometry" : "portraitGeometry"
        let primary = page.value[key], alternate = page.value[other]
        let geometry: AndroidJSONValue
        let sourceLayout: AndroidJSONValue?
        if let value = primary?["controls"]?[control.sourceID] { geometry = value; sourceLayout = primary }
        else if let value = alternate?["controls"]?[control.sourceID] { geometry = value; sourceLayout = alternate }
        else { geometry = control.value; sourceLayout = nil }
        let x = try number(geometry["x"], 0), y = try number(geometry["y"], 0)
        let width = try number(geometry["w"], 0), height = try number(geometry["h"], 0)
        guard width > 0, height > 0, abs(x) <= 1_000_000, abs(y) <= 1_000_000, width <= 1_000_000, height <= 1_000_000 else {
            throw AndroidArchiveError("Control geometry is invalid or outside the supported conversion range.")
        }
        var sw = try number(sourceLayout?["canvasWidth"], 0), sh = try number(sourceLayout?["canvasHeight"], 0)
        if sw <= 0 || sh <= 0 {
            // Legacy files have no canvas metadata. Fitting the whole saved content is an explicit
            // adaptation, rather than treating Android pixels as points and clipping most controls.
            sw = 1; sh = 1
            for item in page.controls {
                let value = sourceLayout?["controls"]?[item.sourceID] ?? item.value
                let right = (try? number(value["x"], 0) + number(value["w"], 0)) ?? 0
                let bottom = (try? number(value["y"], 0) + number(value["h"], 0)) ?? 0
                if right.isFinite { sw = max(sw, right) }; if bottom.isFinite { sh = max(sh, bottom) }
            }
            issue(.adaptation, control.sourcePath, "The \(orientation.rawValue) canvas size was absent; placement is fitted to the saved content bounds.")
        }
        guard sw <= 1_000_000, sh <= 1_000_000 else { throw AndroidArchiveError("Source canvas is too large to convert safely.") }
        let scale = min(canvas.width / sw, canvas.height / sh)
        let w = min(canvas.width, width * scale), h = min(canvas.height, height * scale)
        let cx = min(canvas.width - w / 2, max(w / 2, (x + width / 2) / sw * canvas.width))
        let cy = min(canvas.height - h / 2, max(h / 2, (y + height / 2) / sh * canvas.height))
        return .init(position: .init(x: cx / canvas.width, y: cy / canvas.height), width: w, height: h)
    }
}

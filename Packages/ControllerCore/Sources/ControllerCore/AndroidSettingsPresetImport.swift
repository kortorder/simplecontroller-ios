import Foundation

/// Source libraries are copied into independent native presets, never applied automatically.
/// Android sensor presets remain archived because their units/calibration are not iOS sensors.
struct AndroidSettingsPresetImport {
    var library = SettingsPresetLibrary.empty
    var issues: [AndroidImportIssue] = []
    private var omitted = 0
    private mutating func note(_ issue: AndroidImportIssue) { if issues.count < 500 { issues.append(issue) } else { omitted += 1 } }
    static func prepare(_ document: AndroidProfileDocument) -> Self {
        var result = Self()
        for source in document.settingsLibraries {
            if source.key == "touchAimCalibrations" || source.key == "touchAimManualProfiles" {
                if !source.entries.isEmpty { result.note(.init(kind: .archivedOnly, sourcePath: source.sourcePath,
                    message: "Android Touch Aim manual presets and calibrations use incompatible sensor measurements. They remain in the exact original; complete local iPhone setup before saving a native sensor preset.")) }
                continue
            }
            for (index, value) in source.entries.enumerated() {
                let path = source.sourcePath + "/\(index)"
                if let category = nativeCategory(source.key), result.library.entries.filter({ $0.category == category }).count >= SettingsPresetLibrary.maximumPerCategory {
                    result.note(.init(kind: .archivedOnly, sourcePath: path,
                        message: "The native limit of 64 presets in this category was reached. The remaining \(source.entries.count - index) source presets remain in the unchanged original."))
                    break
                }
                do {
                    let converted = try convert(value, category: source.key)
                    let rawName = try text(value["name"])
                    let cleaned = rawName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    let base = String((cleaned.isEmpty ? "Imported settings" : cleaned).prefix(64))
                    var name = base, suffix = 2
                    let occupied = Set(result.library.entries.filter { $0.category == converted.category }.map { nameKey($0.name) })
                    while occupied.contains(nameKey(name)) { let end = " \(suffix)"; name = String(base.prefix(64 - end.count)) + end; suffix += 1 }
                    let created = try timestamp(value["createdAtEpochMs"]), updated = try timestamp(value["updatedAtEpochMs"])
                    let entry = SettingsPreset(name: name, createdAtMilliseconds: created, updatedAtMilliseconds: updated, value: converted)
                    try result.library.save(entry)
                    result.note(.init(kind: .adaptation, sourcePath: path,
                        message: "Reusable \(source.key) settings converted as an independent preset named “\(name)”. They are not applied automatically. Android originals and unknown fields remain archived; numeric size/distance tuning uses native points."))
                } catch {
                    result.note(.init(kind: .archivedOnly, sourcePath: path,
                        message: "Reusable settings were preserved without conversion: \(error.localizedDescription)"))
                }
            }
        }
        if result.omitted > 0 { result.issues.append(.init(kind: .archivedOnly, sourcePath: "", message: "\(result.omitted) additional reusable-settings notices were omitted. Every source entry remains in the unchanged original.")) }
        return result
    }
    private static func nameKey(_ name: String) -> String { name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    private static func nativeCategory(_ key: String) -> SettingsPresetCategory? {
        switch key {
        case "stickDirectionalProfiles": .stickDirectional
        case "buttonAimProfiles": .buttonAim
        case "floatingBoostProfiles": .floatingBoost
        case "floatingRingPresets": .floatingRing
        default: nil
        }
    }
    private static func convert(_ source: AndroidJSONValue, category: String) throws -> SettingsPresetValue {
        guard source.objectValue != nil, !(try text(source["id"])).isEmpty else { throw AndroidArchiveError("A preset needs its source identity.") }
        switch category {
        case "stickDirectionalProfiles":
            guard let settings = source["settings"], settings.objectValue != nil else { throw AndroidArchiveError("Directional settings are missing.") }
            for key in ["upCommand", "rightCommand", "downCommand", "leftCommand", "upBoostCommand", "rightBoostCommand", "downBoostCommand", "leftBoostCommand", "upSuperBoostCommand", "rightSuperBoostCommand", "downSuperBoostCommand", "leftSuperBoostCommand"] { _ = try text(settings[key]) }
            for key in ["boostThreshold", "superBoostThreshold"] { guard settings[key]?.numberValue != nil else { throw AndroidArchiveError("Directional threshold is missing.") } }
            let mode = try text(source["mode"])
            guard mode == "WASD" || mode == "STICK_PLUS" else { throw AndroidArchiveError("Unknown directional preset mode.") }
            var control = settings
            for (key, value) in ["id": AndroidJSONValue.string("preset"), "type": .string("STICK"), "name": .string("Preset"), "payload": .string("L"),
                                 "x": .number(.init("0")), "y": .number(.init("0")), "w": .number(.init("104")), "h": .number(.init("104")),
                                 "directionalMode": .bool(mode == "WASD"), "stickPlusMode": .bool(mode == "STICK_PLUS")] {
                control = try control.androidReplacing([key], with: value)
            }
            let page = AndroidFloatingConversion.object(["id": .string("p"), "name": .string("Main"), "controls": .array([control])])
            let version = max(10, AndroidTimingFormat.timingVersion(control))
            let root = AndroidFloatingConversion.object(["formatVersion": .number(.init(String(version))), "homePageId": .string("p"), "pages": .array([page])])
            let document = try AndroidProfileDocument.parse(root.encodedData())
            // This synthetic control document has no settings libraries, so conversion terminates here.
            let plan = try AndroidProfileImportPlan.prepare(document, archiveID: UUID())
            guard let native = plan.profiles.first?.profile.controls.first else { throw AndroidArchiveError("Directional payloads or tuning are not supported by the native validator.") }
            return .stickDirectional(try .capture(native))
        case "buttonAimProfiles":
            guard let base = source["base"], let alternate = source["alternate"], let actions = source["actions"] else { throw AndroidArchiveError("Button Aim preset settings are incomplete.") }
            for tuning in [base, alternate] { try requireTuning(tuning) }
            for key in ["sourceControlWidthPx", "sourceControlHeightPx"] {
                guard let number = source[key]?.numberValue?.rawValue, let value = Double(number), value.isFinite, value > 0 else { throw AndroidArchiveError("The source preset size is invalid.") }
            }
            let tuning: ButtonAimTuning = try AndroidFloatingConversion.decodeSettings(base, defaults: ButtonAimTuning())
            let alternateTuning: ButtonAimTuning = try AndroidFloatingConversion.decodeSettings(alternate, defaults: ButtonAimTuning())
            let schema = try source["schemaVersion"].map { try integer($0) } ?? 3
            let cancel = try boolean(actions["cancelOnBoundaryExit"], fallback: false)
            let rearm = try boolean(actions["rearmOnBoundaryReturn"], fallback: false)
            guard schema >= 5 || (!cancel && !rearm), schema >= 4 || (tuning.output != .gameMouse && alternateTuning.output != .gameMouse) else {
                throw AndroidArchiveError("The Button Aim preset declares an older schema than its saved behavior requires.")
            }
            let settings = try ButtonAimSettings(enabled: true, payloadTiming: timing(actions["payloadTiming"]),
                releaseDelayMilliseconds: integer(actions["releaseDelayMs"]), cancelOnBoundaryExit: cancel,
                rearmOnBoundaryReturn: rearm, tuning: tuning,
                alternate: .init(enabled: boolean(actions["oneShotAlternateEnabled"]), payload: text(actions["alternatePayload"]),
                    payloadTiming: timing(actions["alternatePayloadTiming"]), resetHoldMilliseconds: integer(actions["alternateResetHoldDurationMs"]),
                    baseUnlatchDelayMilliseconds: integer(actions["alternateBaseUnlatchDelayMs"]), displayName: text(actions["alternateDisplayName"]), tuning: alternateTuning))
            let value = try ButtonAimPreset(payload: text(actions["payload"]), buttonBehavior: .init(holdToggle: boolean(actions["holdToggle"]), holdMilliseconds: integer(actions["holdDurationMs"])), settings: settings)
            try value.validate(); return .buttonAim(value)
        case "floatingBoostProfiles":
            guard let first = source["boost1"], let second = source["boost2"] else { throw AndroidArchiveError("Both saved Boost stages are required.") }
            var aim: RingAimSettings?, actions: [RingFireSettings]?
            if let bundle = source["ringAimActions"], bundle != .null {
                guard bundle.objectValue != nil else { throw AndroidArchiveError("Ring aim actions must be an object.") }
                let defaults = RingAimSettings()
                aim = try bundle["aim"].map { try AndroidFloatingConversion.decodeSettings($0, defaults: defaults) } ?? defaults
                if let raw = bundle["knobActions"] {
                    guard let array = raw.arrayValue, (1...3).contains(array.count) else { throw AndroidArchiveError("Ring action presets need one to three slots.") }
                    actions = try array.map { try AndroidFloatingConversion.decodeSettings($0, defaults: RingFireSettings()) }
                } else { actions = [.init()] }
            }
            let value = try FloatingBoostPreset(boost1: AndroidFloatingConversion.boost(first), boost2: AndroidFloatingConversion.boost(second), aim: aim, knobActions: actions)
            try value.validate(); return .floatingBoost(value)
        case "floatingRingPresets":
            guard let value = source["zone"], case let .ring(zone) = try AndroidFloatingConversion.decode(value, controls: [:]) else { throw AndroidArchiveError("A complete ring preset is required.") }
            let identifier = try text(source["id"])
            guard UUID(uuidString: identifier)?.uuidString.lowercased() == identifier else { throw AndroidArchiveError("The source ring preset ID is invalid.") }
            guard !(try boolean(value["groupSwipe"], fallback: false)),
                  ["portraitMemberGeometry", "landscapeMemberGeometry", "portraitRestorationGeometry", "landscapeRestorationGeometry"].allSatisfy({ value[$0] == nil || value[$0]?.objectValue?.members.isEmpty == true }) else {
                throw AndroidArchiveError("A ring preset cannot contain Button or group settings.")
            }
            return .floatingRing(zone)
        default: throw AndroidArchiveError("This reusable Android settings category has no native adapter.")
        }
    }
    private static func requireTuning(_ value: AndroidJSONValue) throws {
        let keys = ["output", "sensitivity", "invertY", "stickProfile", "mouseProfile", "stickFullDisplacementPx", "stickDeadzonePx", "stickUsesTouchPosition", "haptics"]
        guard keys.allSatisfy({ value[$0] != nil }) else { throw AndroidArchiveError("Explicit aim tuning is missing required source fields.") }
    }
    private static func text(_ value: AndroidJSONValue?) throws -> String { guard let text = value?.stringValue else { throw AndroidArchiveError("A required preset text field is missing.") }; return text }
    private static func boolean(_ value: AndroidJSONValue?, fallback: Bool? = nil) throws -> Bool {
        if value == nil, let fallback { return fallback }
        guard case let .bool(flag)? = value else { throw AndroidArchiveError("A required preset switch is missing or invalid.") }; return flag
    }
    private static func timestamp(_ value: AndroidJSONValue?) throws -> Int64 {
        guard let text = value?.numberValue?.rawValue, let number = Int64(text), number >= 0 else { throw AndroidArchiveError("A preset timestamp is missing or invalid.") }; return number
    }
    private static func integer(_ value: AndroidJSONValue?) throws -> Int {
        guard let text = value?.numberValue?.rawValue, let number = Int(text) else { throw AndroidArchiveError("A preset timing value is missing or invalid.") }; return number
    }
    private static func timing(_ value: AndroidJSONValue?) throws -> ButtonAimPayloadTiming {
        switch try text(value) { case "IMMEDIATE": .immediate; case "SEND_ON_RELEASE": .sendOnRelease; default: throw AndroidArchiveError("Unknown saved Button Aim timing mode.") }
    }
}

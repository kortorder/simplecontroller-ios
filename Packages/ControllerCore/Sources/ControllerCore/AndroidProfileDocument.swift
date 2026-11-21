import Foundation

/// An Android JSON number's spelling is retained without conversion through a floating-point value.
public struct AndroidJSONNumber: Equatable, Sendable {
    public let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Ordered members keep distinct Unicode key spellings that Swift String dictionaries can equate.
public struct AndroidJSONObject: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public let name: String
        public let value: AndroidJSONValue
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.value == rhs.value
        }
    }
    public let members: [Member]
    public var keys: [String] { members.map(\.name) }
    public var count: Int { members.count }
    public subscript(_ key: String) -> AndroidJSONValue? {
        members.first { $0.name.utf8.elementsEqual(key.utf8) }?.value
    }
}

/// JSON values are preserved independently of the strict native profile model.
public indirect enum AndroidJSONValue: Equatable, Sendable {
    case object(AndroidJSONObject), array([AndroidJSONValue])
    case string(String), number(AndroidJSONNumber), bool(Bool), null

    public var objectValue: AndroidJSONObject? { if case let .object(value) = self { value } else { nil } }
    public var arrayValue: [AndroidJSONValue]? { if case let .array(value) = self { value } else { nil } }
    public var stringValue: String? { if case let .string(value) = self { value } else { nil } }
    public var numberValue: AndroidJSONNumber? { if case let .number(value) = self { value } else { nil } }
    public subscript(_ key: String) -> AndroidJSONValue? { objectValue?[key] }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a.utf8.elementsEqual(b.utf8)
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    /// Deterministic JSON with exact number spellings. Use exportOriginalData for byte-exact export.
    public func encodedData() throws -> Data {
        var writer = AndroidJSONWriter()
        try writer.write(self, depth: 0)
        return Data(writer.bytes)
    }
}

public struct AndroidProfileDocumentError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public let sourcePath: String
    public init(_ message: String, sourcePath: String = "") { self.message = message; self.sourcePath = sourcePath }
    public var errorDescription: String? { sourcePath.isEmpty ? message : "\(sourcePath): \(message)" }
}

public struct AndroidProfileDiagnostic: Equatable, Sendable {
    public enum Kind: String, Sendable { case unknownFields, unsupportedControl, unsupportedFeature, mappingRequired, sourceRepairNeeded }
    public let kind: Kind
    /// RFC 6901 JSON Pointer; an empty string denotes the document root.
    public let sourcePath: String
    public let message: String
}

public struct AndroidSourceControl: Equatable, Sendable {
    public let sourcePath: String
    public let sourceID: String
    public let type: String
    public let name: String
    public let payload: String
    public let value: AndroidJSONValue
}

public struct AndroidSourcePage: Equatable, Sendable {
    public let sourcePath: String
    public let sourceID: String?
    public let name: String
    public let isLegacyBasePage: Bool
    public let controls: [AndroidSourceControl]
    public let value: AndroidJSONValue
}

public struct AndroidSourceProfile: Equatable, Sendable {
    public let sourcePath: String
    public let name: String
    public let formatVersion: Int
    public let homePageID: String?
    public let pages: [AndroidSourcePage]
    public let value: AndroidJSONValue
}

public struct AndroidSourceSettingsLibrary: Equatable, Sendable {
    public let key: String
    public let sourcePath: String
    public let entries: [AndroidJSONValue]
}

/// Read-only structural/archive validation. This does not execute, repair, or convert Android controls.
/// Matches the community Android 0.18 transfer envelopes and timing gates from upstream d6e20f6.
public struct AndroidProfileDocument: Equatable, Sendable {
    public enum Kind: String, Sendable { case legacyControls, rawProfile, singleTransfer, allProfilesBackup }
    public static let maximumBytes = 25 * 1024 * 1024
    public static let maximumNestingDepth = 64
    public static let maximumValueCount = 250_000
    public static let maximumCollectionCount = 100_000

    public let originalData: Data
    public let kind: Kind
    public let root: AndroidJSONValue
    public let profiles: [AndroidSourceProfile]
    public let settingsLibraries: [AndroidSourceSettingsLibrary]
    public let diagnostics: [AndroidProfileDiagnostic]
    public let activeProfileName: String?

    public func exportOriginalData() -> Data { originalData }

    public static func parse(_ data: Data, fallbackName: String = "Imported Android profile") throws -> Self {
        guard data.count <= maximumBytes else { throw AndroidProfileDocumentError("Android profile file exceeds 25 MiB.") }
        guard String(data: data, encoding: .utf8) != nil else { throw AndroidProfileDocumentError("Android profile file must contain valid UTF-8.") }
        var reader = AndroidJSONReader(bytes: Array(data))
        let root = try reader.readDocument()
        var inspection = AndroidProfileInspection()
        let kind: Kind
        let profiles: [AndroidSourceProfile]
        var libraries: [AndroidSourceSettingsLibrary] = []
        var active: String?
        let fallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Android profile" : fallbackName
        switch root {
        case .array:
            kind = .legacyControls
            profiles = [try inspection.legacy(root, path: "", name: fallback)]
        case let .object(object):
            if let fileType = object["fileType"] {
                let tag = try inspection.string(fileType, path: "/fileType")
                switch tag {
                case "simplecontroller-profile":
                    kind = .singleTransfer
                    _ = try inspection.version(object["transferVersion"], maximum: 1, defaultValue: nil, path: "/transferVersion")
                    let name = try inspection.string(object["profileName"], path: "/profileName")
                    profiles = [try inspection.profile(object["profile"], path: "/profile", name: name.isEmpty ? fallback : name)]
                    inspection.unknown(object, known: ["fileType", "transferVersion", "profileName", "profile"], path: "")
                case "simplecontroller-profiles-backup":
                    kind = .allProfilesBackup
                    let version = try inspection.version(object["backupVersion"], maximum: 3, defaultValue: nil, path: "/backupVersion")
                    active = try inspection.string(object["activeControllerProfileName"], path: "/activeControllerProfileName")
                    let entries = try inspection.array(object["controllerProfiles"], path: "/controllerProfiles")
                    guard !entries.isEmpty else { throw AndroidProfileDocumentError("Backup must contain a controller profile.", sourcePath: "/controllerProfiles") }
                    var names: Set<Data> = []
                    profiles = try entries.enumerated().map { index, entry in
                        let path = "/controllerProfiles/\(index)"
                        let named = try inspection.object(entry, path: path)
                        let name = try inspection.string(named["name"], path: path + "/name")
                        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard !normalized.isEmpty, names.insert(Data(normalized.utf8)).inserted else { throw AndroidProfileDocumentError("Backup profile names must be nonblank and unique.", sourcePath: path + "/name") }
                        inspection.unknown(named, known: ["name", "profile"], path: path)
                        return try inspection.profile(named["profile"], path: path + "/profile", name: name)
                    }
                    guard let active, names.contains(Data(active.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)) else { throw AndroidProfileDocumentError("Backup active profile is missing.", sourcePath: "/activeControllerProfileName") }
                    for (key, maximum) in AndroidProfileInspection.libraryVersions {
                        guard let value = object[key] else { continue }
                        let path = "/" + key
                        let values = try inspection.array(value, path: path)
                        if !values.isEmpty && ((key == "floatingBoostProfiles" && version < 2) || (key == "floatingRingPresets" && version < 3)) {
                            throw AndroidProfileDocumentError("This settings library requires a newer backup envelope.", sourcePath: path)
                        }
                        for (index, entry) in values.enumerated() {
                            let itemPath = path + "/\(index)"
                            let item = try inspection.object(entry, path: itemPath)
                            let schema = try inspection.version(item["schemaVersion"], maximum: maximum, defaultValue: AndroidTimingFormat.legacyPresetSchema(key), path: itemPath + "/schemaVersion")
                            guard schema >= AndroidTimingFormat.requiredPresetSchema(for: entry, library: key) else {
                                throw AndroidProfileDocumentError("These saved actions require a newer preset version.", sourcePath: itemPath + "/schemaVersion")
                            }
                            _ = try inspection.string(item["id"], path: itemPath + "/id")
                            _ = try inspection.string(item["name"], path: itemPath + "/name")
                        }
                        libraries.append(.init(key: key, sourcePath: path, entries: values))
                        if !values.isEmpty { inspection.add(.unsupportedFeature, path, "Reusable Android settings are preserved without being applied.") }
                    }
                    inspection.unknown(object, known: Set(["fileType", "backupVersion", "activeControllerProfileName", "controllerProfiles"] + AndroidProfileInspection.libraryVersions.map(\.0)), path: "")
                default:
                    throw AndroidProfileDocumentError("Unrecognized Android profile file type.", sourcePath: "/fileType")
                }
            } else {
                guard object["pages"] != nil else { throw AndroidProfileDocumentError("Raw Android profile must contain pages.") }
                kind = .rawProfile
                profiles = [try inspection.profile(root, path: "", name: fallback)]
            }
        default:
            throw AndroidProfileDocumentError("Expected an Android profile object or legacy control array.")
        }
        return Self(originalData: data, kind: kind, root: root, profiles: profiles, settingsLibraries: libraries, diagnostics: inspection.diagnostics, activeProfileName: active)
    }
}

private struct AndroidProfileInspection {
    var diagnostics: [AndroidProfileDiagnostic] = []
    static let libraryVersions: [(String, Int)] = [("touchAimCalibrations", 5), ("touchAimManualProfiles", 5), ("buttonAimProfiles", 9), ("stickDirectionalProfiles", 6), ("floatingBoostProfiles", 7), ("floatingRingPresets", 8)]
    mutating func add(_ kind: AndroidProfileDiagnostic.Kind, _ path: String, _ message: String) { diagnostics.append(.init(kind: kind, sourcePath: path, message: message)) }
    func string(_ value: AndroidJSONValue?, path: String) throws -> String {
        guard case let .string(result)? = value else { throw AndroidProfileDocumentError("Expected a string.", sourcePath: path) }; return result
    }
    func object(_ value: AndroidJSONValue?, path: String) throws -> AndroidJSONObject {
        guard case let .object(result)? = value else { throw AndroidProfileDocumentError("Expected an object.", sourcePath: path) }; return result
    }
    func array(_ value: AndroidJSONValue?, path: String) throws -> [AndroidJSONValue] {
        guard case let .array(result)? = value else { throw AndroidProfileDocumentError("Expected an array.", sourcePath: path) }; return result
    }
    func version(_ value: AndroidJSONValue?, maximum: Int, defaultValue: Int?, path: String) throws -> Int {
        if value == nil, let defaultValue { return defaultValue }
        guard case let .number(number)? = value, let result = Int(number.rawValue), (1...maximum).contains(result) else {
            throw AndroidProfileDocumentError("Expected a supported integer version from 1 through \(maximum).", sourcePath: path)
        }
        return result
    }
    mutating func unknown(_ object: AndroidJSONObject, known: Set<String>, path: String) {
        let count = object.keys.filter { !known.contains($0) }.count
        if count > 0 { add(.unknownFields, path, "Preserved \(count) unrecognized field(s).") }
    }
    mutating func legacy(_ value: AndroidJSONValue, path: String, name: String) throws -> AndroidSourceProfile {
        guard AndroidTimingFormat.timingVersion(value) < 14 else {
            throw AndroidProfileDocumentError("Payload modifiers and per-stage Touch Aim tuning need a versioned Android profile.", sourcePath: path)
        }
        let values = try array(value, path: path)
        let controls = try inspectControls(values, path: path, formatVersion: 2, hasGeometry: false)
        add(.mappingRequired, path, "Legacy controls require a native Base page and pixel-to-point mapping; the original array is unchanged.")
        return .init(sourcePath: path, name: name, formatVersion: 2, homePageID: nil, pages: [.init(sourcePath: path, sourceID: nil, name: "Base", isLegacyBasePage: true, controls: controls, value: value)], value: value)
    }
    mutating func profile(_ value: AndroidJSONValue?, path: String, name: String) throws -> AndroidSourceProfile {
        let fields = try object(value, path: path)
        let version = try version(fields["formatVersion"], maximum: 17, defaultValue: 2, path: path + "/formatVersion")
        let required = AndroidTimingFormat.required(for: .object(fields))
        guard version >= required else {
            throw AndroidProfileDocumentError("These control settings require Android profile format \(required).", sourcePath: path + "/formatVersion")
        }
        let home = try fields["homePageId"].map { try string($0, path: path + "/homePageId") }
        let pageValues = try fields["pages"].map { try array($0, path: path + "/pages") } ?? []
        if pageValues.isEmpty { add(.sourceRepairNeeded, path + "/pages", "Source has no pages; no replacement page was created by this parser.") }
        var pageIDs: Set<Data> = []
        let pages = try pageValues.enumerated().map { index, value -> AndroidSourcePage in
            let pagePath = path + "/pages/\(index)"
            let page = try object(value, path: pagePath)
            let id = try page["id"].map { try string($0, path: pagePath + "/id") }
            if let id, !id.isEmpty {
                guard pageIDs.insert(Data(id.utf8)).inserted else { throw AndroidProfileDocumentError("Duplicate page ID makes navigation ambiguous.", sourcePath: pagePath + "/id") }
            } else { add(.sourceRepairNeeded, pagePath + "/id", "Page has no stable ID; it is preserved without repair.") }
            let name = try page["name"].map { try string($0, path: pagePath + "/name") } ?? ""
            let values = try page["controls"].map { try array($0, path: pagePath + "/controls") } ?? []
            if page["controls"] == nil { add(.sourceRepairNeeded, pagePath + "/controls", "Missing controls field is preserved as missing.") }
            let hasGeometry = ["portraitGeometry", "landscapeGeometry"].contains { page[$0] != nil && page[$0] != .null }
            let controls = try inspectControls(values, path: pagePath + "/controls", formatVersion: version, hasGeometry: hasGeometry)
            for key in ["portraitGeometry", "landscapeGeometry"] {
                if let geometry = page[key], geometry != .null { try inspectGeometry(geometry, path: pagePath + "/" + key) }
            }
            if let zones = page["floatingZones"] {
                let items = try array(zones, path: pagePath + "/floatingZones")
                for (i, zone) in items.enumerated() { _ = try object(zone, path: pagePath + "/floatingZones/\(i)") }
                if !items.isEmpty { add(.unsupportedFeature, pagePath + "/floatingZones", "Floating zones are preserved without activation or conversion.") }
            }
            unknown(page, known: ["id", "name", "controls", "portraitGeometry", "landscapeGeometry", "floatingZones"], path: pagePath)
            return .init(sourcePath: pagePath, sourceID: id, name: name, isLegacyBasePage: false, controls: controls, value: value)
        }
        guard pages.filter({ $0.sourceID?.isEmpty ?? true }).count <= 1 else {
            throw AndroidProfileDocumentError("Multiple pages without IDs make source references ambiguous.", sourcePath: path + "/pages")
        }
        if home == nil || !pageIDs.contains(Data((home ?? "").utf8)) { add(.sourceRepairNeeded, path + "/homePageId", "Home page is missing or unresolved; the source is unchanged.") }
        unknown(fields, known: ["formatVersion", "homePageId", "pages", "swipeMode", "safeControlArea"], path: path)
        add(.mappingRequired, path, "Android pixels, payloads and settings require explicit native mapping; parsing does not make this profile playable.")
        return .init(sourcePath: path, name: name, formatVersion: version, homePageID: home, pages: pages, value: .object(fields))
    }
    mutating func inspectControls(_ values: [AndroidJSONValue], path: String, formatVersion: Int, hasGeometry: Bool) throws -> [AndroidSourceControl] {
        var ids: Set<Data> = []
        return try values.enumerated().map { index, value in
            let item = try control(value, path: path + "/\(index)")
            if item.sourceID.isEmpty || !ids.insert(Data(item.sourceID.utf8)).inserted {
                guard formatVersion < 3, !hasGeometry else {
                    throw AndroidProfileDocumentError("Blank or duplicate control IDs make source geometry ambiguous.", sourcePath: item.sourcePath + "/id")
                }
                add(.sourceRepairNeeded, item.sourcePath + "/id", "Legacy blank or duplicate control ID is preserved without repair.")
            }
            return item
        }
    }
    func inspectGeometry(_ value: AndroidJSONValue, path: String) throws {
        let geometry = try object(value, path: path)
        for key in ["canvasWidth", "canvasHeight"] { if let value = geometry[key] { try number(value, path: path + "/" + key) } }
        if let placements = geometry["controls"] {
            for member in try object(placements, path: path + "/controls").members {
                let itemPath = path + "/controls/" + pointerComponent(member.name)
                let placement = try object(member.value, path: itemPath)
                for key in ["x", "y", "w", "h"] { try number(placement[key], path: itemPath + "/" + key) }
            }
        }
    }
    func number(_ value: AndroidJSONValue?, path: String) throws {
        guard case .number? = value else { throw AndroidProfileDocumentError("Expected a JSON number.", sourcePath: path) }
    }
    mutating func control(_ value: AndroidJSONValue, path: String) throws -> AndroidSourceControl {
        let fields = try object(value, path: path)
        let id = try string(fields["id"], path: path + "/id")
        let type = try string(fields["type"], path: path + "/type")
        let payload = try string(fields["payload"], path: path + "/payload")
        let name = try fields["name"].map { try string($0, path: path + "/name") } ?? ""
        for key in ["x", "y", "w", "h"] { try number(fields[key], path: path + "/" + key) }
        for key in Self.booleanFields where fields[key] != nil {
            guard case .bool? = fields[key] else { throw AndroidProfileDocumentError("Expected a Boolean.", sourcePath: path + "/" + key) }
        }
        for key in Self.numberFields where fields[key] != nil { try number(fields[key], path: path + "/" + key) }
        for level in TouchAimLevel.allCases {
            let names = AndroidTimingFormat.keys(for: level)
            if let sensitivity = fields[names.sensitivity], sensitivity != .null { try number(sensitivity, path: path + "/" + names.sensitivity) }
            if let confirmation = fields[names.confirmation] { try number(confirmation, path: path + "/" + names.confirmation) }
        }
        for key in Self.stringFields where fields[key] != nil { _ = try string(fields[key], path: path + "/" + key) }
        for key in ["buttonDirectional", "extendedBoost"] where fields[key] != nil {
            let nested = try object(fields[key], path: path + "/" + key)
            if let enabled = nested["enabled"] {
                guard case let .bool(on) = enabled else { throw AndroidProfileDocumentError("Expected a Boolean.", sourcePath: path + "/" + key + "/enabled") }
                if on { add(.unsupportedFeature, path + "/" + key, "Advanced Android \(key) settings are preserved for later mapping.") }
            }
        }
        if let transforms = fields["touchAimSensorTransforms"] { _ = try array(transforms, path: path + "/touchAimSensorTransforms") }
        if !["BUTTON", "STICK", "TOUCHPAD", "RECENTER"].contains(type) { add(.unsupportedControl, path + "/type", "Control type requires a future native adapter; all fields are preserved.") }
        for key in ["buttonAimEnabled", "buttonAimOneShotAlternateEnabled", "thresholdEnabled", "superThresholdEnabled", "excludeFromCameraFollow", "mouseSuppressCameraFollow", "touchAimGameMouse"] where fields[key] == .bool(true) {
            add(.unsupportedFeature, path + "/" + key, "Enabled Android feature is preserved without execution.")
        }
        for key in ["pageAction", "floatingLocalAction"] {
            if case let .string(action)? = fields[key], action != "NONE" { add(.mappingRequired, path + "/" + key, "Local action and source target IDs need explicit mapping; they are never receiver commands.") }
        }
        for (key, values) in Self.enumFields {
            if case let .string(selected)? = fields[key], !values.contains(selected) {
                add(.unsupportedFeature, path + "/" + key, "Unknown Android option is preserved without interpretation.")
            }
        }
        if type == "BUTTON", !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (try? ControllerPayloadProgram.parse(payload)) == nil {
            add(.unsupportedFeature, path + "/payload", "Payload is not accepted by the current native parser; the full source text is preserved.")
        }
        unknown(fields, known: Self.knownControlFields, path: path)
        return .init(sourcePath: path, sourceID: id, type: type, name: name, payload: payload, value: value)
    }
    static let enumFields: [(String, Set<String>)] = [
        ("pageAction", ["NONE", "GO_TO", "TOGGLE", "RETURN", "HOME"]),
        ("floatingLocalAction", ["NONE", "FINISH", "STOP_FIRE", "RELEASE_ADS", "END_SUPPRESSION"]),
        ("buttonAimOutput", ["MOUSE", "RIGHT_STICK", "LEFT_STICK", "DPAD", "GAME_MOUSE"]),
        ("buttonAimAlternateOutput", ["MOUSE", "RIGHT_STICK", "LEFT_STICK", "DPAD", "GAME_MOUSE"]),
        ("buttonAimPayloadTiming", ["IMMEDIATE", "SEND_ON_RELEASE"]),
        ("buttonAimAlternatePayloadTiming", ["IMMEDIATE", "SEND_ON_RELEASE"]),
        ("buttonAimStickProfile", ["LINEAR", "RESPONSE_CURVE", "RADIAL_RESPONSE_CURVE"]),
        ("buttonAimAlternateStickProfile", ["LINEAR", "RESPONSE_CURVE", "RADIAL_RESPONSE_CURVE"]),
        ("buttonAimMouseProfile", ["LINEAR_RELATIVE", "SMOOTHED_NONLINEAR"]),
        ("buttonAimAlternateMouseProfile", ["LINEAR_RELATIVE", "SMOOTHED_NONLINEAR"]),
        ("buttonAimDpadMode", ["FOUR_WAY", "EIGHT_WAY"]),
        ("buttonAimAlternateDpadMode", ["FOUR_WAY", "EIGHT_WAY"]),
        ("buttonAimDpadOrigin", ["CONTROL_CENTER", "INITIAL_TOUCH"]),
        ("buttonAimAlternateDpadOrigin", ["CONTROL_CENTER", "INITIAL_TOUCH"]),
        ("touchAimOutput", ["MOUSE", "RIGHT_STICK", "LEFT_STICK"]),
        ("touchAimMode", ["MANUAL_THREE_STAGE", "MANUAL_TWO_STATE", "CALIBRATED_TWO_STATE"]),
        ("touchAimShootBehavior", ["HOLD_WHILE_ABOVE", "PRESS_ON_ENTER", "PRESS_ON_RETURN_TO_AIM"]),
        ("touchLowAction", ["PRESS", "HOLD"]), ("touchMediumAction", ["PRESS", "HOLD"]), ("touchHighAction", ["PRESS", "HOLD"])
    ]
    static let booleanFields: Set<String> = Set("autoCenter excludeFromCameraFollow mouseSuppressCameraFollow holdToggle macroModeEnabled autoTapEnabled buttonAimEnabled buttonAimCancelOnBoundaryExit buttonAimRearmOnBoundaryReturn buttonAimInvertY buttonAimStickUsesTouchPosition buttonAimAutoCenter buttonAimHaptics buttonAimOneShotAlternateEnabled buttonAimAlternateInvertY buttonAimAlternateStickUsesTouchPosition buttonAimAlternateAutoCenter buttonAimAlternateHaptics holdLeftWhileTouch toggleLeftClick doubleTapClickLock swipeActivate directionalMode stickPlusMode thresholdEnabled superThresholdEnabled touchAimGameMouse touchUseSize touchUseMajor touchUseMinor touchKeepLowerHolds touchInvertY touchUseResponseCurve touchAimStickUsesTouchPosition touchAimKeepAimPayloadWhileShooting touchAimManualThresholdsInitialized".split(separator: " ").map(String.init))
    static let numberFields: Set<String> = Set("sensitivity cameraFollowStrengthPercent holdDurationMs autoTapIntervalMs buttonAimReleaseDelayMs buttonAimSensitivity buttonAimStickFullDisplacementPx buttonAimStickDeadzonePx buttonAimDpadActivationDistancePx buttonAimAlternateResetHoldDurationMs buttonAimAlternateBaseUnlatchDelayMs buttonAimAlternateSensitivity buttonAimAlternateStickFullDisplacementPx buttonAimAlternateStickDeadzonePx buttonAimAlternateDpadActivationDistancePx boostThreshold superBoostThreshold threshold superThreshold touchSizeScale touchScoreSmoothing touchLowThreshold touchMediumThreshold touchHighThreshold touchHysteresis touchStickFullSpeed touchAimStickFullDisplacementPx touchAimStickDeadzonePx touchAimShootSensitivity touchAimManualShootOnThreshold touchAimManualShootOffThreshold touchAimShootOnThreshold touchAimShootOffThreshold touchAimTwoStateSmoothing touchAimEnterShootConfirmationMs touchAimReturnToAimConfirmationMs".split(separator: " ").map(String.init))
    static let stringFields: Set<String> = Set("floatingLocalAction floatingActionTargetId pageAction pageTargetId buttonAimOutput buttonAimPayloadTiming buttonAimStickProfile buttonAimMouseProfile buttonAimDpadMode buttonAimDpadOrigin buttonAimAlternatePayload buttonAimAlternatePayloadTiming buttonAimAlternateDisplayName buttonAimAlternateOutput buttonAimAlternateStickProfile buttonAimAlternateMouseProfile buttonAimAlternateDpadMode buttonAimAlternateDpadOrigin upCommand downCommand leftCommand rightCommand upBoostCommand downBoostCommand leftBoostCommand rightBoostCommand upSuperBoostCommand downSuperBoostCommand leftSuperBoostCommand rightSuperBoostCommand thresholdPayload superThresholdPayload touchAimOutput touchLowPayload touchMediumPayload touchHighPayload touchLowAction touchMediumAction touchHighAction touchAimMode touchAimAppliedCalibrationId touchAimAppliedCalibrationName touchAimAimPayload touchAimShootPayload touchAimShootBehavior".split(separator: " ").map(String.init))
    static let knownControlFields = booleanFields.union(numberFields).union(stringFields).union(AndroidTimingFormat.controlKeys).union(["id", "type", "x", "y", "w", "h", "payload", "name", "buttonDirectional", "extendedBoost", "touchAimSensorTransforms"])
}

private func pointerComponent(_ key: String) -> String { key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }

private struct AndroidJSONReader {
    let bytes: [UInt8]
    var index = 0
    var valueCount = 0
    mutating func readDocument() throws -> AndroidJSONValue {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        let value = try readValue(depth: 0)
        whitespace()
        guard index == bytes.count else { throw error("Unexpected trailing data") }
        return value
    }
    func error(_ message: String) -> AndroidProfileDocumentError { .init("\(message) at UTF-8 byte \(index).") }
    mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func readValue(depth: Int) throws -> AndroidJSONValue {
        guard depth <= AndroidProfileDocument.maximumNestingDepth else { throw error("JSON nesting exceeds 64 levels") }
        valueCount += 1
        guard valueCount <= AndroidProfileDocument.maximumValueCount else { throw error("JSON contains too many values") }
        whitespace()
        guard index < bytes.count else { throw error("Expected a JSON value") }
        switch bytes[index] {
        case 123:
            index += 1; whitespace()
            var members: [AndroidJSONObject.Member] = []
            var keys: Set<Data> = []
            if take(125) { return .object(.init(members: members)) }
            while true {
                whitespace()
                let key = try readString()
                guard keys.insert(Data(key.utf8)).inserted else { throw error("Duplicate object key") }
                whitespace(); guard take(58) else { throw error("Expected a colon") }
                members.append(.init(name: key, value: try readValue(depth: depth + 1)))
                guard members.count <= AndroidProfileDocument.maximumCollectionCount else { throw error("JSON object is too large") }
                whitespace()
                if take(125) { return .object(.init(members: members)) }
                guard take(44) else { throw error("Expected a comma or closing brace") }
            }
        case 91:
            index += 1; whitespace()
            var array: [AndroidJSONValue] = []
            if take(93) { return .array(array) }
            while true {
                array.append(try readValue(depth: depth + 1))
                guard array.count <= AndroidProfileDocument.maximumCollectionCount else { throw error("JSON array is too large") }
                whitespace()
                if take(93) { return .array(array) }
                guard take(44) else { throw error("Expected a comma or closing bracket") }
            }
        case 34: return .string(try readString())
        case 116: try literal([116,114,117,101]); return .bool(true)
        case 102: try literal([102,97,108,115,101]); return .bool(false)
        case 110: try literal([110,117,108,108]); return .null
        case 45, 48...57: return .number(try readNumber())
        default: throw error("Invalid JSON value")
        }
    }
    mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true
    }
    mutating func literal(_ expected: [UInt8]) throws {
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { throw error("Invalid JSON literal") }; index += expected.count
    }
    mutating func readNumber() throws -> AndroidJSONNumber {
        let start = index
        _ = take(45)
        if !take(48) {
            guard index < bytes.count, (49...57).contains(bytes[index]) else { throw error("Invalid JSON number") }
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
        }
        if take(46) {
            let fraction = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > fraction else { throw error("Expected fractional digits") }
        }
        if take(101) || take(69) {
            if !take(43) { _ = take(45) }
            let exponent = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > exponent else { throw error("Expected exponent digits") }
        }
        return .init(String(decoding: bytes[start..<index], as: UTF8.self))
    }
    mutating func readString() throws -> String {
        guard take(34) else { throw error("Expected a quoted string") }
        var result: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 { return String(decoding: result, as: UTF8.self) }
            guard byte >= 32 else { throw error("Unescaped control character in string") }
            if byte != 92 { result.append(byte); continue }
            guard index < bytes.count else { throw error("Unfinished string escape") }
            let escaped = bytes[index]; index += 1
            switch escaped {
            case 34, 47, 92: result.append(escaped)
            case 98: result.append(8)
            case 102: result.append(12)
            case 110: result.append(10)
            case 114: result.append(13)
            case 116: result.append(9)
            case 117:
                var scalar = try hexUnit()
                if (0xD800...0xDBFF).contains(scalar) {
                    guard take(92), take(117) else { throw error("High surrogate requires a low surrogate") }
                    let low = try hexUnit()
                    guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid low surrogate") }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + low - 0xDC00
                } else if (0xDC00...0xDFFF).contains(scalar) { throw error("Unexpected low surrogate") }
                guard let value = Unicode.Scalar(scalar) else { throw error("Invalid Unicode scalar") }
                result.append(contentsOf: String(value).utf8)
            default: throw error("Invalid string escape")
            }
        }
        throw error("Unterminated string")
    }
    mutating func hexUnit() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("Incomplete Unicode escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]; index += 1
            let digit: UInt32
            switch byte { case 48...57: digit = UInt32(byte - 48); case 65...70: digit = UInt32(byte - 55); case 97...102: digit = UInt32(byte - 87); default: throw error("Invalid Unicode escape") }
            value = value * 16 + digit
        }
        return value
    }
}

private struct AndroidJSONWriter {
    var bytes: [UInt8] = []
    var count = 0
    mutating func append(_ content: [UInt8]) throws {
        guard content.count <= AndroidProfileDocument.maximumBytes - bytes.count else { throw AndroidProfileDocumentError("Encoded Android JSON exceeds 25 MiB.") }
        bytes.append(contentsOf: content)
    }
    mutating func quoted(_ value: String) throws {
        guard value.utf8.count <= AndroidProfileDocument.maximumBytes else { throw AndroidProfileDocumentError("JSON string exceeds 25 MiB.") }
        try append([34])
        let hex = Array("0123456789abcdef".utf8)
        for byte in value.utf8 {
            switch byte {
            case 34, 92: try append([92, byte])
            case 0...31: try append([92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
            default:
                guard bytes.count < AndroidProfileDocument.maximumBytes else { throw AndroidProfileDocumentError("Encoded Android JSON exceeds 25 MiB.") }
                bytes.append(byte)
            }
        }
        try append([34])
    }
    mutating func write(_ value: AndroidJSONValue, depth: Int) throws {
        count += 1
        guard depth <= AndroidProfileDocument.maximumNestingDepth, count <= AndroidProfileDocument.maximumValueCount else { throw AndroidProfileDocumentError("Encoded JSON exceeds structural limits.") }
        switch value {
        case let .object(object):
            guard object.count <= AndroidProfileDocument.maximumCollectionCount else { throw AndroidProfileDocumentError("JSON object is too large.") }
            try append([123])
            for (index, member) in object.members.enumerated() {
                if index > 0 { try append([44]) }; try quoted(member.name); try append([58]); try write(member.value, depth: depth + 1)
            }
            try append([125])
        case let .array(array):
            guard array.count <= AndroidProfileDocument.maximumCollectionCount else { throw AndroidProfileDocumentError("JSON array is too large.") }
            try append([91])
            for (index, item) in array.enumerated() { if index > 0 { try append([44]) }; try write(item, depth: depth + 1) }
            try append([93])
        case let .string(value): try quoted(value)
        case let .number(value): try append(Array(value.rawValue.utf8))
        case let .bool(value): try append(Array((value ? "true" : "false").utf8))
        case .null: try append(Array("null".utf8))
        }
    }
}

// Internal bounded value decoder for pure native-to-source projections. Original source values
// still use the same lexical-number reader; no NSNumber/Double round-trip touches unknown data.
extension AndroidJSONValue {
    static func decodingValue(_ data: Data) throws -> Self {
        guard data.count <= AndroidProfileDocument.maximumBytes else { throw AndroidArchiveError("JSON value exceeds the archive bound.") }
        var reader = AndroidJSONReader(bytes: Array(data)); return try reader.readDocument()
    }
}

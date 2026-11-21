import Foundation

/// Audited Android 71a647c floating templates. Conversion is pure and does not create runtime input.
/// Numeric Android pixels/dp become explicit native point tuning; source bytes remain immutable.
enum AndroidFloatingConversion {
    enum Template {
        case button(FloatingButtonZone), ring(FloatingRingZone)
        var id: UUID { switch self { case let .button(v): v.id; case let .ring(v): v.id } }
    }
    static func decode(_ source: AndroidJSONValue, controls: [String: UUID]) throws -> Template {
        guard source.objectValue != nil else { throw AndroidArchiveError("A floating zone must be an object.") }
        let kind = try string(source["kind"]), id = UUID()
        let rawName = try string(source["name"], default: "")
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let enabled = try bool(source["enabled"], default: true)
        let portrait = try geometry(source["portraitGeometry"]), landscape = try geometry(source["landscapeGeometry"])
        if kind == "RING" {
            guard source["memberIds"]?.arrayValue?.isEmpty ?? true, try string(source["startMemberId"], default: "").isEmpty,
                  let config = source["ring"], config != .null else { throw AndroidArchiveError("A ring must have a configuration and no button members.") }
            var value = FloatingRingZone(id: id, name: name.isEmpty ? "Floating ring" : name, enabled: enabled,
                portraitGeometry: portrait, landscapeGeometry: landscape, config: try ring(config))
            value.finishIgnoresSwipes = try bool(source["finishIgnoresSwipes"], default: false)
            try value.validate(); return .ring(value)
        }
        guard kind == "SINGLE_BUTTON" || kind == "BUTTON_GROUP", source["ring"] == nil || source["ring"] == .null,
              let sourceMembers = source["memberIds"]?.arrayValue else { throw AndroidArchiveError("Unknown or invalid floating zone kind.") }
        let memberIDs = try sourceMembers.map { value -> UUID in
            let key = try string(value)
            guard let id = controls[key] else { throw AndroidArchiveError("A floating member is not a converted button on this page.") }
            return id
        }
        let start = try string(source["startMemberId"], default: "")
        let startID: UUID?
        if start.isEmpty { startID = nil }
        else { guard let id = controls[start] else { throw AndroidArchiveError("The floating starting member is unresolved.") }; startID = id }
        func members(_ key: String) throws -> [FloatingMemberGeometry] {
            guard let value = source[key] else { return [] }
            guard let object = value.objectValue else { throw AndroidArchiveError("Floating member geometry must be an object.") }
            return try object.members.map { item in
                guard let id = controls[item.name] else { throw AndroidArchiveError("A floating geometry reference is unresolved.") }
                return .init(id: id, frame: try rect(item.value))
            }
        }
        var value = try FloatingButtonZone(id: id, name: name.isEmpty ? "Floating buttons" : name,
            kind: kind == "SINGLE_BUTTON" ? .singleButton : .buttonGroup, enabled: enabled,
            memberIDs: memberIDs, startMemberID: startID, groupSwipe: bool(source["groupSwipe"], default: false),
            portraitGeometry: portrait, landscapeGeometry: landscape,
            portraitMembers: members("portraitMemberGeometry"), landscapeMembers: members("landscapeMemberGeometry"),
            portraitRestoration: members("portraitRestorationGeometry"), landscapeRestoration: members("landscapeRestorationGeometry"))
        value.finishIgnoresSwipes = try bool(source["finishIgnoresSwipes"], default: false)
        try value.validate(); return .button(value)
    }
    static func ring(_ value: AndroidJSONValue) throws -> FloatingRingConfig {
        let defaults = FloatingRingConfig()
        return try decodeSettings(value, defaults: defaults)
    }
    static func boost(_ value: AndroidJSONValue, second: Bool = false) throws -> RingBoostSettings {
        // A present settings object uses RingBoostSettings defaults. Only an absent whole
        // FloatingRingConfig.boost2 property uses the enclosing 160/160/184 default.
        try decodeSettings(value, defaults: RingBoostSettings())
    }
    static func decodeSettings<T: Codable>(_ value: AndroidJSONValue, defaults: T) throws -> T {
        let native = try fromSource(value, defaults: json(defaults))
        return try JSONDecoder().decode(T.self, from: native.encodedData())
    }
    static func json<T: Encodable>(_ value: T) throws -> AndroidJSONValue {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try .decodingValue(encoder.encode(value))
    }
    static func projection(_ template: Template, controlIDs: [UUID: String]) throws -> AndroidJSONValue {
        switch template {
        case let .ring(zone):
            return try object(["kind": .string("RING"), "name": .string(zone.name), "enabled": .bool(zone.enabled),
                "memberIds": .array([]), "startMemberId": .string(""),
                "portraitGeometry": geometryValue(zone.portraitGeometry), "landscapeGeometry": geometryValue(zone.landscapeGeometry),
                "ring": toSource(json(zone.config))].merging(zone.finishIgnoresSwipes ? ["finishIgnoresSwipes": .bool(true)] : [:]) { _, new in new })
        case let .button(zone):
            func id(_ value: UUID) throws -> String {
                guard let found = controlIDs[value] else { throw AndroidArchiveError("A floating member has no exported control identity.") }; return found
            }
            func members(_ values: [FloatingMemberGeometry]) throws -> AndroidJSONValue {
                try object(Dictionary(uniqueKeysWithValues: values.map { (try id($0.id), try rectValue($0.frame)) }))
            }
            return try object(["kind": .string(zone.kind == .singleButton ? "SINGLE_BUTTON" : "BUTTON_GROUP"), "name": .string(zone.name),
                "enabled": .bool(zone.enabled), "memberIds": .array(zone.memberIDs.map { .string(try id($0)) }),
                "startMemberId": .string(zone.startMemberID.map { try id($0) } ?? ""), "groupSwipe": .bool(zone.groupSwipe),
                "portraitGeometry": geometryValue(zone.portraitGeometry), "landscapeGeometry": geometryValue(zone.landscapeGeometry),
                "portraitMemberGeometry": members(zone.portraitMembers), "landscapeMemberGeometry": members(zone.landscapeMembers),
                "portraitRestorationGeometry": members(zone.portraitRestoration), "landscapeRestorationGeometry": members(zone.landscapeRestoration), "ring": .null].merging(zone.finishIgnoresSwipes ? ["finishIgnoresSwipes": .bool(true)] : [:]) { _, new in new })
        }
    }
    static func templates(_ page: ProfilePage) -> [Template] { page.floatingButtonZones.map(Template.button) + page.floatingRingZones.map(Template.ring) }
    static func object(_ values: [String: AndroidJSONValue]) -> AndroidJSONValue {
        .object(.init(members: values.keys.sorted().map { .init(name: $0, value: values[$0]!) }))
    }
    private static func geometry(_ value: AndroidJSONValue?) throws -> FloatingZoneGeometry? {
        guard let value, value != .null else { return nil }
        guard value.objectValue != nil else { throw AndroidArchiveError("Floating activation geometry must be an object.") }
        let g = try FloatingZoneGeometry(canvasWidth: number(value["canvasWidth"], default: 0), canvasHeight: number(value["canvasHeight"], default: 0),
            zone: value["zone"].map(rect) ?? .init(x: 0, y: 0, width: 240, height: 240))
        try g.validate(); return g
    }
    private static func rect(_ value: AndroidJSONValue) throws -> FloatingRect {
        guard value.objectValue != nil else { throw AndroidArchiveError("Floating rectangle must be an object.") }
        let result = try FloatingRect(x: number(value["x"]), y: number(value["y"]), width: number(value["w"]), height: number(value["h"]))
        try result.validate(); return result
    }
    private static func rectValue(_ value: FloatingRect) throws -> AndroidJSONValue {
        try object(["x": androidExportNumber(value.x), "y": androidExportNumber(value.y), "w": androidExportNumber(value.width), "h": androidExportNumber(value.height)])
    }
    private static func geometryValue(_ value: FloatingZoneGeometry?) throws -> AndroidJSONValue {
        guard let value else { return .null }
        return try object(["canvasWidth": androidExportNumber(value.canvasWidth), "canvasHeight": androidExportNumber(value.canvasHeight), "zone": rectValue(value.zone)])
    }
    private static func string(_ value: AndroidJSONValue?, default fallback: String? = nil) throws -> String {
        if value == nil, let fallback { return fallback }
        guard let text = value?.stringValue else { throw AndroidArchiveError("Expected a floating string setting.") }; return text
    }
    private static func bool(_ value: AndroidJSONValue?, default fallback: Bool) throws -> Bool {
        guard let value else { return fallback }; guard case let .bool(flag) = value else { throw AndroidArchiveError("Expected a floating Boolean setting.") }; return flag
    }
    private static func number(_ value: AndroidJSONValue?, default fallback: Double? = nil) throws -> Double {
        if value == nil, let fallback { return fallback }
        guard let raw = value?.numberValue?.rawValue, let result = Double(raw), result.isFinite else { throw AndroidArchiveError("Expected a finite floating numeric setting.") }; return result
    }
    // Only audited field names are projected. Unknown fields never pass through this mapper;
    // edited export patches this projection into the preserved source object instead.
    private static let names = ["innerRadius":"innerRadiusDp", "movementRadius":"movementRadiusDp", "response":"profile",
        "stickResponse":"stickProfile", "mouseResponse":"mouseProfile", "origin":"stickUsesTouchPosition",
        "fullDisplacement":"stickFullDisplacementPx", "deadzone":"stickDeadzonePx", "hapticsEnabled":"haptics",
        "dpadActivationDistance":"dpadActivationDistancePx", "delayMilliseconds":"delayMs",
        "pulsePressMilliseconds":"pulsePressMs", "pulseGapMilliseconds":"pulseGapMs", "retainADSOnLift":"retainAdsOnLift", "continueADSOutside":"continueAdsOutside",
        "targetDiameter":"targetDiameterDp", "distance":"distanceDp", "activationDelayMilliseconds":"activationDelayMs", "hysteresis":"hysteresisDp",
        "directInnerDistance":"directInnerDistanceDp", "directOuterDistance":"directOuterDistanceDp", "boost1Distance":"boost1DistanceDp", "boost1Thickness":"boost1ThicknessDp",
        "boost2Thickness":"boost2ThicknessDp", "directStartDistance":"directStartDistanceDp", "startKnobID":"startKnobId", "directBoostAimKnobID":"directBoostAimKnobId"]
    private static let enumKeys: Set<String> = ["output", "response", "stickResponse", "mouseResponse", "dpadMode", "dpadOrigin", "mode", "action", "startRole", "directStartBank", "qualifyingStages"]
    private static let enumNames = ["leftStick":"LEFT_STICK", "rightStick":"RIGHT_STICK", "gameMouse":"GAME_MOUSE", "mouse":"MOUSE", "dpad":"DPAD",
        "linear":"LINEAR", "perAxis":"RESPONSE_CURVE", "radial":"RADIAL_RESPONSE_CURVE", "linearRelative":"LINEAR_RELATIVE", "smoothedNonlinear":"SMOOTHED_NONLINEAR",
        "fourWay":"FOUR_WAY", "eightWay":"EIGHT_WAY", "controlCenter":"CONTROL_CENTER", "initialTouch":"INITIAL_TOUCH",
        "none":"NONE", "hold":"HOLD", "tap":"TAP", "repeat":"REPEAT", "releaseShot":"RELEASE_SHOT", "movement":"MOVEMENT", "aim":"AIM", "boostOne":"BOOST_ONE", "boostTwo":"BOOST_TWO", "one":"ONE", "two":"TWO"]
    private static func fromSource(_ source: AndroidJSONValue, defaults: AndroidJSONValue, key: String = "") throws -> AndroidJSONValue {
        let defaults = key == "boost2" ? try json(RingBoostSettings()) : defaults
        if key == "tuning" {
            let required = ["output", "sensitivity", "invertY", "stickProfile", "mouseProfile", "stickFullDisplacementPx", "stickDeadzonePx", "stickUsesTouchPosition", "haptics"]
            guard required.allSatisfy({ source[$0] != nil }) else { throw AndroidArchiveError("An explicit Android aim-tuning object is missing required fields.") }
        }
        if key == "origin" { return .string(try bool(source, default: false) ? "controlCenter" : "initialTouch") }
        if enumKeys.contains(key), let text = source.stringValue {
            guard let native = enumNames.first(where: { $0.value == text })?.key else { throw AndroidArchiveError("Unsupported floating \(key): \(text).") }; return .string(native)
        }
        if let object = defaults.objectValue {
            guard source.objectValue != nil else { throw AndroidArchiveError("A floating settings group must be an object.") }
            var fields = object.members
            // Native encoders omit disabled additions so old layouts stay readable. Include
            // only fields recognized for this specific object when Android explicitly stores them.
            let flags: [String]
            if defaults["startRole"] != nil { flags = ["compactAimBoosts", "adjacentMovementBoosts", "directBoostStartsAim"] }
            else if defaults["activationDelayMilliseconds"] != nil { flags = ["skipDelayOnDirectTouch"] }
            else if defaults["qualifyingStages"] != nil && defaults["cancelOnExit"] != nil { flags = ["startOnBoostEntry"] }
            else { flags = [] }
            for flag in flags where source[flag] != nil { fields.append(.init(name: flag, value: .bool(false))) }
            if defaults["startRole"] != nil, let banks = source["boostBanks"], banks != .null {
                fields.append(.init(name: "boostBanks", value: try json(RingBoostBanks())))
            }
            return .object(.init(members: try fields.map { field in
                let name = names[field.name] ?? field.name
                return .init(name: field.name, value: try source[name].map { try fromSource($0, defaults: field.value, key: field.name) } ?? field.value)
            }))
        }
        if case let .array(defaults) = defaults {
            guard case let .array(values) = source, values.count <= 64 else { throw AndroidArchiveError("Invalid floating settings list.") }
            let template = key == "knobs" ? try json(RingAimKnob()) : defaults.first ?? .string("")
            return .array(try values.map { try fromSource($0, defaults: template, key: key) })
        }
        switch (defaults, source) {
        case (.bool, .bool), (.string, .string), (.number, .number): return source
        default: throw AndroidArchiveError("A floating setting has the wrong type.")
        }
    }
    private static func toSource(_ native: AndroidJSONValue, key: String = "") throws -> AndroidJSONValue {
        if key == "origin" { return .bool(native.stringValue == "controlCenter") }
        if enumKeys.contains(key), let text = native.stringValue {
            guard let mapped = enumNames[text] else { throw AndroidArchiveError("Native floating setting cannot be exported.") }; return .string(mapped)
        }
        if let object = native.objectValue { return .object(.init(members: try object.members.map { .init(name: names[$0.name] ?? $0.name, value: try toSource($0.value, key: $0.name)) })) }
        if case let .array(values) = native { return .array(try values.map { try toSource($0, key: key) }) }
        return native
    }
}

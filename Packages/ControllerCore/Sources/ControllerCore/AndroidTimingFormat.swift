import Foundation

/// Android shares version 11 between the community layout options and the upstream ring options.
/// Inspect the settings themselves when importing or writing a modified copy of a profile.
enum AndroidTimingFormat {
    static func keys(for level: TouchAimLevel) -> (sensitivity: String, confirmation: String) {
        let prefix: String
        switch level {
        case .aimOnly: prefix = "touchAimAimOnly"
        case .low: prefix = "touchLow"
        case .medium: prefix = "touchMedium"
        case .high: prefix = "touchHigh"
        }
        return (prefix + "Sensitivity", prefix + "EnterConfirmationMs")
    }

    static let tuningDefaults: [String: AndroidJSONValue] = {
        var fields: [String: AndroidJSONValue] = [:]
        for level in TouchAimLevel.allCases {
            let names = keys(for: level)
            fields[names.sensitivity] = .null
            fields[names.confirmation] = .number(.init("0"))
        }
        return fields
    }()
    static let controlKeys = Set(tuningDefaults.keys)
    private static let payloadKeys = Set("""
        payload alternatePayload buttonAimAlternatePayload thresholdPayload superThresholdPayload
        touchLowPayload touchMediumPayload touchHighPayload touchAimAimPayload touchAimShootPayload
        lowPayload mediumPayload highPayload aimPayload shootPayload adsPayload firePayload
        upCommand downCommand leftCommand rightCommand upBoostCommand downBoostCommand leftBoostCommand rightBoostCommand
        upSuperBoostCommand downSuperBoostCommand leftSuperBoostCommand rightSuperBoostCommand firstPayload secondPayload
        up down left right
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    private static let sensitivities = Set(TouchAimLevel.allCases.map { keys(for: $0).sensitivity })
        .union(["aimOnlySensitivity", "lowSensitivity", "mediumSensitivity", "highSensitivity"])
    private static let confirmations = Set(TouchAimLevel.allCases.map { keys(for: $0).confirmation })
        .union(["aimOnlyEnterConfirmationMs", "lowEnterConfirmationMs", "mediumEnterConfirmationMs", "highEnterConfirmationMs"])

    /// Android scans every nested object for authored payload keys before typed decoding.
    /// Identically named fields in future containers are subject to the same timing gate.
    static func timingVersion(_ value: AndroidJSONValue, stageTuning: Bool = true) -> Int {
        if let children = value.arrayValue {
            return children.reduce(1) { max($0, timingVersion($1, stageTuning: stageTuning)) }
        }
        guard let object = value.objectValue else { return 1 }
        var version = 1
        for member in object.members {
            let key = member.name, field = member.value
            if key == "macroModeEnabled", field == .bool(true) { version = max(version, 17) }
            if payloadKeys.contains(key), let source = field.stringValue {
                version = max(version, payloadVersion(source))
            }
            if stageTuning {
                if sensitivities.contains(key), field != .null { version = max(version, 14) }
                if confirmations.contains(key), field.numberValue.flatMap({ Int64($0.rawValue) }) != 0 {
                    version = max(version, 14)
                }
            }
            version = max(version, timingVersion(field, stageTuning: stageTuning))
            if version == 17 { break }
        }
        return version
    }

    static func required(for profile: AndroidJSONValue) -> Int {
        var version = timingVersion(profile)
        if profile["safeControlArea"] == .bool(true) ||
            profile["swipeMode"]?.stringValue.map({ $0 != "OFF" }) == true { version = max(version, 11) }
        for page in profile["pages"]?.arrayValue ?? [] {
            for control in page["controls"]?.arrayValue ?? [] {
                if control["circularButton"] == .bool(true) ||
                    control["stickPlusRepeatIntervalMilliseconds"].map({ $0 != .null }) == true {
                    version = max(version, 11)
                }
            }
            for zone in page["floatingZones"]?.arrayValue ?? [] {
                version = max(version, ringOptionsVersion(zone))
            }
        }
        return version
    }

    private static func skipsDirectDelay(_ pair: AndroidJSONValue?) -> Bool {
        ["boost1", "boost2"].contains { pair?[$0]?["skipDelayOnDirectTouch"] == .bool(true) }
    }

    private static func startsTimerOnBoost(_ fire: AndroidJSONValue?) -> Bool {
        fire?["returnFire"]?["startOnBoostEntry"] == .bool(true)
    }

    private static func ringOptionsVersion(_ zone: AndroidJSONValue) -> Int {
        let ring = zone["ring"], banks = ring?["boostBanks"]
        if skipsDirectDelay(ring) || skipsDirectDelay(banks?["movement"]) || skipsDirectDelay(banks?["aim"]) { return 13 }
        if banks.map({ $0 != .null }) == true || ring?["directBoostStartsAim"] == .bool(true) { return 12 }
        if zone["finishIgnoresSwipes"] == .bool(true) || ring?["compactAimBoosts"] == .bool(true) ||
            ring?["adjacentMovementBoosts"] == .bool(true) ||
            ring?["knobs"]?.arrayValue?.contains(where: { startsTimerOnBoost($0["fire"]) }) == true { return 11 }
        return 1
    }

    static func legacyPresetSchema(_ library: String) -> Int {
        switch library {
        case "buttonAimProfiles": 3
        case "stickDirectionalProfiles": 2
        default: 1
        }
    }

    static func requiredPresetSchema(for entry: AndroidJSONValue, library: String) -> Int {
        let profileVersion = timingVersion(entry, stageTuning: library == "touchAimManualProfiles")
        if profileVersion >= 14 {
            let first: Int
            switch library {
            case "buttonAimProfiles", "floatingBoostProfiles": first = library == "buttonAimProfiles" ? 6 : 4
            case "floatingRingPresets": first = 5
            case "stickDirectionalProfiles": first = 3
            default: first = 2
            }
            return first + profileVersion - 14
        }
        if library == "floatingRingPresets", let zone = entry["zone"] {
            let options = ringOptionsVersion(zone)
            if options >= 11 { return options - 9 }
        }
        if library == "floatingBoostProfiles" {
            if skipsDirectDelay(entry) { return 3 }
            if entry["ringAimActions"]?["knobActions"]?.arrayValue?.contains(where: startsTimerOnBoost) == true { return 2 }
        }
        return 1
    }

    // Match attempted modifiers as Android does, even when the command later fails validation.
    static func payloadVersion(_ source: String) -> Int {
        guard source.contains("(") || source.contains(")") else { return 1 }
        let upper = source.uppercased()
        if upper.contains("(U") { return 17 }
        if upper.contains("(D") { return 16 }
        if upper.contains("(R") { return 15 }
        return 14
    }
}

import Foundation

public struct AndroidExportRectangle: Codable, Equatable, Sendable {
    public let x: Double; public let y: Double; public let width: Double; public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), abs(x) <= 1_000_000, abs(y) <= 1_000_000,
              (0.000_000_001...1_000_000).contains(width), (0.000_000_001...1_000_000).contains(height) else {
            throw AndroidArchiveError("Invalid Android export source geometry.")
        }
    }
}

public struct AndroidGeometryExportBaseline: Codable, Equatable, Sendable {
    public let importedPosition: NormalizedControlPosition
    public let importedWidth: Double
    public let importedHeight: Double
    public let sourceCanvasWidth: Double
    public let sourceCanvasHeight: Double
    public let sizeScale: Double
    public let sourceRectangle: AndroidExportRectangle
    func validate() throws {
        try sourceRectangle.validate()
        guard importedPosition.isValid, [importedWidth, importedHeight, sourceCanvasWidth, sourceCanvasHeight, sizeScale].allSatisfy(\.isFinite),
              (44...1_200).contains(importedWidth), (44...1_200).contains(importedHeight),
              (0.000_000_001...1_000_000).contains(sourceCanvasWidth), (0.000_000_001...1_000_000).contains(sourceCanvasHeight),
              sizeScale > 0 else { throw AndroidArchiveError("Invalid Android export conversion baseline.") }
    }
}

public struct AndroidControlExportBaseline: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let pageSourcePath: String
    /// SHA-256 of the supported native field value, not the original Android spelling.
    public let fieldDigests: [String: String]
    public let portrait: AndroidGeometryExportBaseline
    public let landscape: AndroidGeometryExportBaseline
}

public struct AndroidPageExportBaseline: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let nameDigest: String
    public let portraitControlPaths: [String]
    public let landscapeControlPaths: [String]
}

/// Immutable conversion evidence. Source paths retain deletion coverage even after bindings disappear.
/// This schema is independent of later native settings so old baselines remain comparable.
public struct AndroidSourceExportBaseline: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public let version: Int
    public let originalSHA256: String
    public let sourceProfilePath: String
    public let profileNameDigest: String
    public let homePageToken: String
    public let runtimeOptionsDigest: String
    public let portraitCanvas: AndroidImportCanvas
    public let landscapeCanvas: AndroidImportCanvas
    public let pages: [AndroidPageExportBaseline]
    public let controls: [AndroidControlExportBaseline]
    public let zones: [AndroidZoneExportBaseline]

    public func validate() throws {
        func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard (1...Self.currentVersion).contains(version), (version >= 2 || zones.isEmpty), hash(originalSHA256), hash(profileNameDigest), hash(runtimeOptionsDigest),
              sourceProfilePath.utf8.count <= 8_192, homePageToken.utf8.count <= 8_256,
              pages.count <= 32, controls.count <= 64, zones.count <= 2048,
              Set(zones.map(\.sourcePath)).count == zones.count,
              Set(pages.map(\.sourcePath)).count == pages.count, Set(controls.map(\.sourcePath)).count == controls.count else {
            throw AndroidArchiveError("Invalid Android export baseline.")
        }
        let pagePaths = Set(pages.map(\.sourcePath)), controlPaths = Set(controls.map(\.sourcePath))
        for page in pages {
            guard hash(page.nameDigest), page.sourcePath.utf8.count <= 8_192,
                  page.portraitControlPaths.count <= 64, page.landscapeControlPaths.count <= 64,
                  Set(page.portraitControlPaths).isSubset(of: controlPaths), Set(page.landscapeControlPaths).isSubset(of: controlPaths) else {
                throw AndroidArchiveError("Invalid Android page export baseline.")
            }
        }
        for zone in zones { try zone.validate(pagePaths: pagePaths) }
        for control in controls {
            guard control.sourcePath.utf8.count <= 8_192, pagePaths.contains(control.pageSourcePath),
                  control.fieldDigests.count <= 160,
                  control.fieldDigests.allSatisfy({ $0.key.utf8.count <= 128 && hash($0.value) }) else {
                throw AndroidArchiveError("Invalid Android control export baseline.")
            }
            try control.portrait.validate(); try control.landscape.validate()
        }
    }

    public static func capture(profile: ControllerProfile, source: AndroidProfileSourceReference,
                               original: AndroidProfileDocument,
                               portrait: AndroidImportCanvas, landscape: AndroidImportCanvas) throws -> Self {
        try profile.validate()
        guard let originalProfile = original.profiles.first(where: { $0.sourcePath == source.sourceProfilePath }) else {
            throw AndroidArchiveError("The native profile has no matching Android original.")
        }
        let allControls = originalProfile.pages.flatMap(\.controls)
        var controls: [AndroidControlExportBaseline] = []
        for binding in source.controls {
            guard let native = profile.control(for: binding.nativeID),
                  let originalControl = allControls.first(where: { $0.sourcePath == binding.sourcePath }),
                  let page = originalProfile.pages.first(where: { $0.controls.contains { $0.sourcePath == binding.sourcePath } }),
                  let p = profile.portrait.first(where: { $0.id == native.id }),
                  let l = profile.landscape.first(where: { $0.id == native.id }) else { throw AndroidArchiveError("Incomplete import baseline binding.") }
            let fields = try AndroidExportProjection.fields(native, profile: profile, source: source)
            controls.append(.init(sourcePath: binding.sourcePath, pageSourcePath: page.sourcePath,
                fieldDigests: try fields.mapValues(androidExportDigest),
                portrait: try geometry(originalControl, page: page, orientation: .portrait, canvas: portrait, native: native, position: p.position),
                landscape: try geometry(originalControl, page: page, orientation: .landscape, canvas: landscape, native: native, position: l.position)))
        }
        let pages = try source.pages.map { binding -> AndroidPageExportBaseline in
            guard let page = profile.page(for: binding.nativeID) else { throw AndroidArchiveError("Incomplete page baseline binding.") }
            let pathByID = Dictionary(uniqueKeysWithValues: source.controls.map { ($0.nativeID, $0.sourcePath) })
            return .init(sourcePath: binding.sourcePath, nameDigest: try androidExportDigest(.string(page.name)),
                portraitControlPaths: profile.placements(for: .portrait, on: page.id).compactMap { pathByID[$0.id] },
                landscapeControlPaths: profile.placements(for: .landscape, on: page.id).compactMap { pathByID[$0.id] })
        }
        let sourceIDs = Dictionary(uniqueKeysWithValues: source.controls.compactMap { binding -> (UUID, String)? in
            allControls.first { $0.sourcePath == binding.sourcePath }.map { (binding.nativeID, $0.sourceID) }
        })
        let zones = try source.zones.map { binding -> AndroidZoneExportBaseline in
            guard let page = profile.pages.first(where: { AndroidFloatingConversion.templates($0).contains { $0.id == binding.nativeID } }),
                  let pageBinding = source.pages.first(where: { $0.nativeID == page.id }),
                  let zone = AndroidFloatingConversion.templates(page).first(where: { $0.id == binding.nativeID }) else { throw AndroidArchiveError("Incomplete floating import baseline.") }
            return .init(sourcePath: binding.sourcePath, pageSourcePath: pageBinding.sourcePath,
                projectionData: try AndroidFloatingConversion.projection(zone, controlIDs: sourceIDs).encodedData())
        }
        let result = Self(version: currentVersion, originalSHA256: androidSHA256(original.originalData),
            sourceProfilePath: source.sourceProfilePath, profileNameDigest: try androidExportDigest(.string(profile.name)),
            homePageToken: AndroidExportProjection.pageToken(profile.homePageID, source: source),
            runtimeOptionsDigest: try androidExportDigest(AndroidExportProjection.runtimeOptions(profile)), portraitCanvas: portrait, landscapeCanvas: landscape,
            pages: pages, controls: controls, zones: zones)
        try result.validate(); return result
    }

    private static func geometry(_ control: AndroidSourceControl, page: AndroidSourcePage,
        orientation: ControllerOrientation, canvas: AndroidImportCanvas, native: ProfileControl,
        position: NormalizedControlPosition) throws -> AndroidGeometryExportBaseline {
        let primary = page.value[orientation == .portrait ? "portraitGeometry" : "landscapeGeometry"]
        let alternate = page.value[orientation == .portrait ? "landscapeGeometry" : "portraitGeometry"]
        let raw: AndroidJSONValue, layout: AndroidJSONValue?
        if let found = primary?["controls"]?[control.sourceID] { raw = found; layout = primary }
        else if let found = alternate?["controls"]?[control.sourceID] { raw = found; layout = alternate }
        else { raw = control.value; layout = nil }
        func number(_ value: AndroidJSONValue?, fallback: Double = 0) throws -> Double {
            guard let value else { return fallback }
            guard let raw = value.numberValue?.rawValue, let number = Double(raw), number.isFinite else { throw AndroidArchiveError("Invalid source geometry number.") }
            return number
        }
        let rectangle = try AndroidExportRectangle(x: number(raw["x"]), y: number(raw["y"]), width: number(raw["w"]), height: number(raw["h"]))
        var sw = try number(layout?["canvasWidth"]), sh = try number(layout?["canvasHeight"])
        if sw <= 0 || sh <= 0 {
            sw = 1; sh = 1
            for item in page.controls {
                let value = layout?["controls"]?[item.sourceID] ?? item.value
                if let edge = try? number(value["x"]) + number(value["w"]), edge.isFinite { sw = max(sw, edge) }
                if let edge = try? number(value["y"]) + number(value["h"]), edge.isFinite { sh = max(sh, edge) }
            }
        }
        return .init(importedPosition: position, importedWidth: native.dimensions(for: orientation).width, importedHeight: native.dimensions(for: orientation).height,
            sourceCanvasWidth: sw, sourceCanvasHeight: sh, sizeScale: min(canvas.width / sw, canvas.height / sh), sourceRectangle: rectangle)
    }
}

extension AndroidExportRectangle {
    private enum CodingKeys: String, CodingKey { case x, y, width, height }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["x", "y", "width", "height"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y),
                  width: try c.decode(Double.self, forKey: .width), height: try c.decode(Double.self, forKey: .height))
        try validate()
    }
}
extension AndroidGeometryExportBaseline {
    private enum CodingKeys: String, CodingKey { case importedPosition, importedWidth, importedHeight, sourceCanvasWidth, sourceCanvasHeight, sizeScale, sourceRectangle }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["importedPosition", "importedWidth", "importedHeight", "sourceCanvasWidth", "sourceCanvasHeight", "sizeScale", "sourceRectangle"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(importedPosition: try c.decode(NormalizedControlPosition.self, forKey: .importedPosition),
            importedWidth: try c.decode(Double.self, forKey: .importedWidth), importedHeight: try c.decode(Double.self, forKey: .importedHeight),
            sourceCanvasWidth: try c.decode(Double.self, forKey: .sourceCanvasWidth), sourceCanvasHeight: try c.decode(Double.self, forKey: .sourceCanvasHeight),
            sizeScale: try c.decode(Double.self, forKey: .sizeScale), sourceRectangle: try c.decode(AndroidExportRectangle.self, forKey: .sourceRectangle))
        try validate()
    }
}
extension AndroidControlExportBaseline {
    private enum CodingKeys: String, CodingKey { case sourcePath, pageSourcePath, fieldDigests, portrait, landscape }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["sourcePath", "pageSourcePath", "fieldDigests", "portrait", "landscape"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sourcePath: try c.decode(String.self, forKey: .sourcePath), pageSourcePath: try c.decode(String.self, forKey: .pageSourcePath),
            fieldDigests: try c.decode([String: String].self, forKey: .fieldDigests),
            portrait: try c.decode(AndroidGeometryExportBaseline.self, forKey: .portrait), landscape: try c.decode(AndroidGeometryExportBaseline.self, forKey: .landscape))
    }
}
extension AndroidPageExportBaseline {
    private enum CodingKeys: String, CodingKey { case sourcePath, nameDigest, portraitControlPaths, landscapeControlPaths }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["sourcePath", "nameDigest", "portraitControlPaths", "landscapeControlPaths"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sourcePath: try c.decode(String.self, forKey: .sourcePath), nameDigest: try c.decode(String.self, forKey: .nameDigest),
            portraitControlPaths: try c.decode([String].self, forKey: .portraitControlPaths), landscapeControlPaths: try c.decode([String].self, forKey: .landscapeControlPaths))
    }
}
extension AndroidSourceExportBaseline {
    private enum CodingKeys: String, CodingKey { case version, originalSHA256, sourceProfilePath, profileNameDigest, homePageToken, runtimeOptionsDigest, portraitCanvas, landscapeCanvas, pages, controls, zones }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        var keys: Set<String> = ["version", "originalSHA256", "sourceProfilePath", "profileNameDigest", "homePageToken", "runtimeOptionsDigest", "portraitCanvas", "landscapeCanvas", "pages", "controls"]
        if version >= 2 { keys.insert("zones") }; try profileKeys(decoder, keys)
        self.init(version: try c.decode(Int.self, forKey: .version), originalSHA256: try c.decode(String.self, forKey: .originalSHA256),
            sourceProfilePath: try c.decode(String.self, forKey: .sourceProfilePath), profileNameDigest: try c.decode(String.self, forKey: .profileNameDigest),
            homePageToken: try c.decode(String.self, forKey: .homePageToken), runtimeOptionsDigest: try c.decode(String.self, forKey: .runtimeOptionsDigest),
            portraitCanvas: try c.decode(AndroidImportCanvas.self, forKey: .portraitCanvas), landscapeCanvas: try c.decode(AndroidImportCanvas.self, forKey: .landscapeCanvas),
            pages: try c.decode([AndroidPageExportBaseline].self, forKey: .pages), controls: try c.decode([AndroidControlExportBaseline].self, forKey: .controls),
            zones: version < 2 ? [] : try c.decode([AndroidZoneExportBaseline].self, forKey: .zones))
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(originalSHA256, forKey: .originalSHA256)
        try c.encode(sourceProfilePath, forKey: .sourceProfilePath); try c.encode(profileNameDigest, forKey: .profileNameDigest)
        try c.encode(homePageToken, forKey: .homePageToken); try c.encode(runtimeOptionsDigest, forKey: .runtimeOptionsDigest)
        try c.encode(portraitCanvas, forKey: .portraitCanvas); try c.encode(landscapeCanvas, forKey: .landscapeCanvas)
        try c.encode(pages, forKey: .pages); try c.encode(controls, forKey: .controls)
        if version >= 2 { try c.encode(zones, forKey: .zones) }
    }
}

func androidExportDigest(_ value: AndroidJSONValue) throws -> String { androidSHA256(try value.encodedData()) }
func androidExportNumber(_ number: Double) throws -> AndroidJSONValue {
    guard number.isFinite else { throw AndroidArchiveError("Cannot export a non-finite number.") }
    if number.rounded(.towardZero) == number, number >= Double(Int64.min), number < Double(Int64.max) {
        return .number(.init(String(Int64(number))))
    }
    return .number(.init(String(number)))
}

/// A stable, audited projection. Future native fields must be mapped explicitly, never auto-serialized.
enum AndroidExportProjection {
    /// A native-only comparison sentinel. It is never emitted as an Android JSON field.
    static let touchSetupKey = "#nativeTouchAimSetup"
    static var contactPayloads: [(key: String, path: WritableKeyPath<TouchAimSettings, String>, fallback: String)] {
        [("touchLowPayload", \.threeStage.low.payload, ""),
         ("touchMediumPayload", \.threeStage.medium.payload, "LT:1.0"),
         ("touchHighPayload", \.threeStage.high.payload, "RT:1.0"),
         ("touchAimAimPayload", \.twoState.aimPayload, ""),
         ("touchAimShootPayload", \.twoState.shootPayload, "RT:1.0")]
    }
    static let contactPayloadKeys = Set(contactPayloads.map(\.key))
    /// Pre-format-17 imports did not apply these source fields. Their native migration defaults
    /// are the comparison baseline, so unrelated edits never overwrite archived source values.
    static let cameraMigrationDefaults: [String: AndroidJSONValue] = [
        "cameraFollowStrengthPercent": .number(.init("100")),
        "excludeFromCameraFollow": .bool(false), "mouseSuppressCameraFollow": .bool(false)
    ]
    static let floatingActionMigrationDefaults: [String: AndroidJSONValue] = ["floatingLocalAction": .string("NONE"), "floatingActionTargetId": .string("")]
    static var additiveMigrationDefaults: [String: AndroidJSONValue] {
        cameraMigrationDefaults.merging(floatingActionMigrationDefaults) { _, value in value }
            .merging(["macroModeEnabled": .bool(false)]) { _, value in value }
    }
    static func comparisonDigests(_ baseline: AndroidControlExportBaseline, native: ProfileControl,
                                  original: AndroidSourceControl?) throws -> [String: String] {
        var values = baseline.fieldDigests
        for (key, value) in additiveMigrationDefaults where values[key] == nil { values[key] = try androidExportDigest(value) }
        if values["stickPlusMode"] != nil && values["stickPlusRepeatIntervalMilliseconds"] == nil {
            values["stickPlusRepeatIntervalMilliseconds"] = try androidExportDigest(.null)
        }
        if values[touchSetupKey] != nil {
            for (key, value) in AndroidTimingFormat.tuningDefaults where values[key] == nil { values[key] = try androidExportDigest(value) }
        }
        // Older imports kept all five contact actions inside the sensor digest. Split that
        // record only when the old digest proves the original native values and sensor setup.
        if native.isTouchAim, let previous = values[touchSetupKey], values["touchHighPayload"] == nil {
            var candidates = [native.touchAim]
            if let original {
                var oldReader = native.touchAim, currentReader = native.touchAim
                for (key, path, fallback) in contactPayloads {
                    let raw = original.value[key]?.stringValue ?? fallback
                    let program = try? advancedButtonProgram(raw)
                    currentReader[keyPath: path] = program == nil ? "" : raw
                    oldReader[keyPath: path] = program?.hasModifiers == false ? raw : ""
                }
                candidates += [oldReader, currentReader]
            }
            guard let restored = try candidates.first(where: {
                try androidExportDigest(touchSetup($0, separatePayloads: false)) == previous
            }) else {
                // Existing native sensor settings or unsupported source conversion cannot be verified.
                values[touchSetupKey] = "unverified"
                return values
            }
            values[touchSetupKey] = try androidExportDigest(touchSetup(restored, separatePayloads: true))
            for (key, path, _) in contactPayloads {
                values[key] = try androidExportDigest(.string(restored[keyPath: path]))
            }
        }
        return values
    }
    static func touchSetup(_ settings: TouchAimSettings, separatePayloads: Bool) throws -> AndroidJSONValue {
        var unmapped = settings
        if separatePayloads {
            for (_, path, _) in contactPayloads { unmapped[keyPath: path] = "" }
        }
        unmapped.threeStage.aimOnlyTuning = .init()
        unmapped.threeStage.low.tuning = .init()
        unmapped.threeStage.medium.tuning = .init()
        unmapped.threeStage.high.tuning = .init()
        unmapped.aim.output = .mouse; unmapped.aim.sensitivity = 1; unmapped.aim.invertY = false
        unmapped.aim.stickResponse = .linear; unmapped.aim.origin = .controlCenter
        unmapped.aim.fullDisplacement = 220; unmapped.aim.deadzone = 8
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .string(androidSHA256(try encoder.encode(unmapped)))
    }
    static func floatingTargetToken(_ target: ProfileFloatingActionTarget, source: AndroidProfileSourceReference) -> String {
        let bindings: [AndroidSourceBinding], prefix: String
        switch target { case .zone: bindings = source.zones; prefix = "zone:"; case .control: bindings = source.controls; prefix = "control:" }
        return prefix + (bindings.first(where: { $0.nativeID == target.targetID }).map { $0.exportID.map { "copy:" + $0 } ?? "source:" + $0.sourcePath } ?? "native:" + target.targetID.uuidString)
    }
    static func pageToken(_ id: UUID, source: AndroidProfileSourceReference) -> String {
        source.pages.first(where: { $0.nativeID == id }).map { binding in
            binding.exportID.map { "copy:" + $0 } ?? "source:" + binding.sourcePath
        } ?? "native:" + id.uuidString
    }
    static func runtimeOptions(_ profile: ControllerProfile) -> AndroidJSONValue {
        .array([.bool(profile.turboEnabled), .number(.init(String(profile.turboIntervalMilliseconds))), .string(profile.swipeMode.rawValue)])
    }
    static func fields(_ control: ProfileControl, profile: ControllerProfile, source: AndroidProfileSourceReference,
                       pageTokens: [UUID: String] = [:]) throws -> [String: AndroidJSONValue] {
        var fields: [String: AndroidJSONValue] = ["name": .string(control.name), "swipeActivate": .bool(control.swipeActivationEnabled)]
        func num(_ key: String, _ value: Double) throws { fields[key] = try androidExportNumber(value) }
        func text(_ key: String, _ value: String) { fields[key] = .string(value) }
        func flag(_ key: String, _ value: Bool) { fields[key] = .bool(value) }
        try num("cameraFollowStrengthPercent", control.cameraFollowStrengthPercent)
        flag("excludeFromCameraFollow", control.excludeFromCameraFollow)
        flag("mouseSuppressCameraFollow", control.mouseSuppressCameraFollow)
        if let binding = control.floatingAction {
            switch binding.action { case .finish: text("floatingLocalAction", "FINISH"); case .stopFire: text("floatingLocalAction", "STOP_FIRE"); case .releaseADS: text("floatingLocalAction", "RELEASE_ADS"); case .endSuppression: text("floatingLocalAction", "END_SUPPRESSION") }
            text("floatingActionTargetId", floatingTargetToken(binding.target, source: source))
        } else { text("floatingLocalAction", "NONE"); text("floatingActionTargetId", "") }
        switch control.kind {
        case .button:
            text("type", "BUTTON"); text("payload", control.isFloatingAction ? control.payload ?? ControllerPayloadProgram.source(for: control.actions) : try control.payloadProgram().source)
            flag("holdToggle", control.buttonBehavior.holdToggle); try num("holdDurationMs", Double(control.buttonBehavior.holdMilliseconds))
            flag("macroModeEnabled", control.macroModeEnabled)
            flag("autoTapEnabled", control.autoTapEnabled); try num("autoTapIntervalMs", Double(control.autoTapIntervalMilliseconds))
            text("pageAction", "NONE"); text("pageTargetId", "")
            flag("buttonDirectional/enabled", control.buttonDirectional.enabled)
            for direction in StickDirection.allCases {
                let settings = control.buttonDirectional.directions[direction]!
                let prefix = "buttonDirectional/" + direction.rawValue + "/"
                try num(prefix + "firstDistancePx", settings.firstDistance); try num(prefix + "secondDistancePx", settings.secondDistance)
                text(prefix + "firstPayload", settings.firstPayload); text(prefix + "secondPayload", settings.secondPayload)
            }
            let aim = control.buttonAim
            flag("buttonAimEnabled", aim.enabled)
            text("buttonAimPayloadTiming", aim.payloadTiming == .immediate ? "IMMEDIATE" : "SEND_ON_RELEASE")
            try num("buttonAimReleaseDelayMs", Double(aim.releaseDelayMilliseconds))
            flag("buttonAimCancelOnBoundaryExit", aim.cancelOnBoundaryExit); flag("buttonAimRearmOnBoundaryReturn", aim.rearmOnBoundaryReturn)
            fields.merge(try tuning(aim.tuning, prefix: "buttonAim")) { _, new in new }
            flag("buttonAimOneShotAlternateEnabled", aim.alternate.enabled)
            text("buttonAimAlternatePayload", aim.alternate.payload)
            text("buttonAimAlternatePayloadTiming", aim.alternate.payloadTiming == .immediate ? "IMMEDIATE" : "SEND_ON_RELEASE")
            try num("buttonAimAlternateResetHoldDurationMs", Double(aim.alternate.resetHoldMilliseconds))
            try num("buttonAimAlternateBaseUnlatchDelayMs", Double(aim.alternate.baseUnlatchDelayMilliseconds))
            text("buttonAimAlternateDisplayName", aim.alternate.displayName)
            fields.merge(try tuning(aim.alternate.tuning, prefix: "buttonAimAlternate")) { _, new in new }
        case .leftStick, .rightStick:
            text("type", control.stickResponse.mode == .linear ? "STICK" : control.stickResponse.mode == .perAxis ? "CURVED_STICK" : "RADIAL_CURVED_STICK")
            text("payload", control.kind == .leftStick ? "STICK_L" : "STICK_R")
            fields["stickPlusRepeatIntervalMilliseconds"] = control.stickPlusRepeatIntervalMilliseconds.map { .number(.init(String($0))) } ?? .null
            try num("sensitivity", control.stickResponse.sensitivity); flag("autoCenter", control.stickBehavior.autoCenter)
            flag("directionalMode", control.directionalEnabled); flag("stickPlusMode", control.stickBehavior.stickPlusEnabled)
            try num("boostThreshold", control.stickBehavior.boostThreshold); try num("superBoostThreshold", control.stickBehavior.superBoostThreshold)
            for direction in StickDirection.allCases {
                text(direction.rawValue + "Command", try control.stageProgram(direction: direction, stage: .normal).source)
                text(direction.rawValue + "BoostCommand", try control.stageProgram(direction: direction, stage: .boost).source)
                text(direction.rawValue + "SuperBoostCommand", try control.stageProgram(direction: direction, stage: .superBoost).source)
                let extended = control.extendedBoost.directions[direction]!
                try num("extendedBoost/regular/" + direction.rawValue, extended.regularThreshold)
                try num("extendedBoost/superBoost/" + direction.rawValue, extended.superThreshold)
                try num("extendedBoost/outer/" + direction.rawValue, extended.outerThreshold)
                text("extendedBoost/outerCommands/" + direction.rawValue, extended.outerPayload ?? "")
            }
            flag("extendedBoost/enabled", control.extendedBoost.enabled)
            text("extendedBoost/mode", control.extendedBoost.mode == .replaceThresholds ? "REPLACE_THRESHOLDS" : "ADD_OUTER_STAGE")
        case .touchpad:
            text("type", "TOUCHPAD"); text("payload", "TOUCHPAD"); try num("sensitivity", control.touchpadBehavior.sensitivity)
            flag("holdLeftWhileTouch", control.touchpadBehavior.clickMode == .hold)
            flag("toggleLeftClick", control.touchpadBehavior.clickMode == .toggle)
            flag("doubleTapClickLock", control.touchpadBehavior.clickMode == .doubleTapLock)
        case .touchAim:
            text("type", "TOUCH_AIM")
            let aim = control.touchAim.aim
            text("touchAimOutput", aim.output == .leftStick ? "LEFT_STICK" : aim.output == .rightStick ? "RIGHT_STICK" : "MOUSE")
            flag("touchAimGameMouse", aim.output == .gameMouse)
            try num("sensitivity", aim.sensitivity); flag("touchInvertY", aim.invertY)
            if aim.stickResponse == .radial {
                throw AndroidArchiveError("Android Touch Aim cannot represent the native radial stick response.")
            }
            flag("touchUseResponseCurve", aim.stickResponse == .perAxis)
            flag("touchAimStickUsesTouchPosition", aim.origin == .controlCenter)
            try num("touchAimStickFullDisplacementPx", aim.fullDisplacement)
            try num("touchAimStickDeadzonePx", aim.deadzone)
            for (key, path, _) in contactPayloads { text(key, control.touchAim[keyPath: path]) }
            for level in TouchAimLevel.allCases {
                let keys = AndroidTimingFormat.keys(for: level)
                let tuning = control.touchAim.threeStage.tuning(for: level)
                fields[keys.sensitivity] = try tuning.sensitivity.map(androidExportNumber) ?? .null
                try num(keys.confirmation, Double(tuning.confirmationMilliseconds))
            }
            fields[touchSetupKey] = try touchSetup(control.touchAim, separatePayloads: true)
        case .recenter:
            text("type", "RECENTER"); text("payload", "RECENTER")
        case .pageButton:
            text("type", "BUTTON"); text("payload", "")
            switch control.pageNavigation! {
            case .goTo(let id): text("pageAction", "GO_TO"); text("pageTargetId", pageTokens[id] ?? pageToken(id, source: source))
            case .toggle(let id): text("pageAction", "TOGGLE"); text("pageTargetId", pageTokens[id] ?? pageToken(id, source: source))
            case .back: text("pageAction", "RETURN"); text("pageTargetId", "")
            case .home: text("pageAction", "HOME"); text("pageTargetId", "")
            }
        }
        return fields
    }
    private static func tuning(_ tuning: ButtonAimTuning, prefix: String) throws -> [String: AndroidJSONValue] {
        let output: String
        switch tuning.output { case .mouse: output = "MOUSE"; case .gameMouse: output = "GAME_MOUSE"; case .leftStick: output = "LEFT_STICK"; case .rightStick: output = "RIGHT_STICK"; case .dpad: output = "DPAD" }
        return [prefix + "Output": .string(output), prefix + "Sensitivity": try androidExportNumber(tuning.sensitivity),
            prefix + "InvertY": .bool(tuning.invertY), prefix + "StickProfile": .string(tuning.stickResponse == .linear ? "LINEAR" : tuning.stickResponse == .perAxis ? "RESPONSE_CURVE" : "RADIAL_RESPONSE_CURVE"),
            prefix + "MouseProfile": .string(tuning.mouseResponse == .linearRelative ? "LINEAR_RELATIVE" : "SMOOTHED_NONLINEAR"),
            prefix + "StickUsesTouchPosition": .bool(tuning.origin == .controlCenter),
            prefix + "StickFullDisplacementPx": try androidExportNumber(tuning.fullDisplacement), prefix + "StickDeadzonePx": try androidExportNumber(tuning.deadzone),
            prefix + "AutoCenter": .bool(tuning.autoCenter), prefix + "DpadMode": .string(tuning.dpadMode == .fourWay ? "FOUR_WAY" : "EIGHT_WAY"),
            prefix + "DpadOrigin": .string(tuning.dpadOrigin == .controlCenter ? "CONTROL_CENTER" : "INITIAL_TOUCH"),
            prefix + "DpadActivationDistancePx": try androidExportNumber(tuning.dpadActivationDistance), prefix + "Haptics": .bool(tuning.hapticsEnabled)]
    }
}

public struct AndroidZoneExportBaseline: Codable, Equatable, Sendable {
    public let sourcePath: String
    public let pageSourcePath: String
    /// Bounded, known-field projection; never the original or unknown Android data.
    public let projectionData: Data
    func validate(pagePaths: Set<String>) throws {
        guard sourcePath.utf8.count <= 8192, pagePaths.contains(pageSourcePath), projectionData.count <= 65536,
              try AndroidJSONValue.decodingValue(projectionData).objectValue != nil else { throw AndroidArchiveError("Invalid floating export baseline.") }
    }
    private enum CodingKeys: String, CodingKey { case sourcePath, pageSourcePath, projectionData }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["sourcePath", "pageSourcePath", "projectionData"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourcePath = try c.decode(String.self, forKey: .sourcePath); pageSourcePath = try c.decode(String.self, forKey: .pageSourcePath)
        projectionData = try c.decode(Data.self, forKey: .projectionData)
    }
    init(sourcePath: String, pageSourcePath: String, projectionData: Data) { self.sourcePath = sourcePath; self.pageSourcePath = pageSourcePath; self.projectionData = projectionData }
}

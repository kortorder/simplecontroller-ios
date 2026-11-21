import XCTest
@testable import ControllerCore

final class AndroidSettingsPresetImportTests: XCTestCase {
    private let metadata = #""id":"fd0d556b-57dd-4cb5-af46-72d4a98d1544","name":"Saved","createdAtEpochMs":100,"updatedAtEpochMs":200"#
    private var directional: String {
        let commands = ["up":"W", "right":"D", "down":"S", "left":"A"].sorted { $0.key < $1.key }.flatMap { direction, key in
            [#""\#(direction)Command":"\#(key)""#, #""\#(direction)BoostCommand":"\#(key),SHIFT""#, #""\#(direction)SuperBoostCommand":"\#(key),SPACE""#]
        }.joined(separator: ",")
        return #"{\#(metadata),"mode":"WASD","settings":{\#(commands),"boostThreshold":0.5,"superBoostThreshold":0.75},"unknown":9007199254740993}"#
    }
    private var buttonAim: String {
        let tuning = #"{"output":"RIGHT_STICK","sensitivity":1.5,"invertY":true,"stickProfile":"RADIAL_RESPONSE_CURVE","mouseProfile":"LINEAR_RELATIVE","stickFullDisplacementPx":220,"stickDeadzonePx":8,"stickUsesTouchPosition":true,"haptics":true}"#
        return #"{\#(metadata),"schemaVersion":5,"sourceControlWidthPx":100,"sourceControlHeightPx":80,"base":\#(tuning),"alternate":\#(tuning),"actions":{"payload":"X360A","holdToggle":false,"holdDurationMs":500,"payloadTiming":"IMMEDIATE","releaseDelayMs":0,"oneShotAlternateEnabled":true,"alternatePayload":"RT:0.5","alternatePayloadTiming":"SEND_ON_RELEASE","alternateResetHoldDurationMs":1000,"alternateBaseUnlatchDelayMs":100,"alternateDisplayName":"Alt","cancelOnBoundaryExit":true,"rearmOnBoundaryReturn":true}}"#
    }
    private var boost: String { #"{\#(metadata),"boost1":{"payload":"X360A"},"boost2":{"payload":"X360B","distanceDp":160,"directInnerDistanceDp":160,"directOuterDistanceDp":184},"ringAimActions":{}}"# }
    private var ring: String { #"{\#(metadata),"zone":{"id":"ring","kind":"RING","name":"Stored ring","portraitGeometry":{"canvasWidth":400,"canvasHeight":800,"zone":{"x":10,"y":20,"w":240,"h":240}},"ring":{}}}"# }
    private func document(_ entries: [String: [String]]) throws -> AndroidProfileDocument {
        let libraries = entries.sorted { $0.key < $1.key }.map { #", "\#($0.key)":[\#($0.value.joined(separator: ","))]"# }.joined()
        return try .parse(Data(#"{"fileType":"simplecontroller-profiles-backup","backupVersion":3,"activeControllerProfileName":"Original","controllerProfiles":[{"name":"Original","profile":{"formatVersion":10,"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[]}]}}]\#(libraries)}"#.utf8))
    }
    private func plan(_ entries: [String: [String]]) throws -> AndroidProfileImportPlan { try .prepare(document(entries), archiveID: UUID()) }
    private func reference(_ d: AndroidProfileDocument) throws -> AndroidSourceArchiveReference { try .init(sha256: androidSHA256(d.originalData), byteCount: d.originalData.count, displayName: "Original backup") }

    func testFourCompatibleLibrariesConvertWithoutApplyingOrMutatingOriginal() throws {
        let d = try document(["stickDirectionalProfiles":[directional], "buttonAimProfiles":[buttonAim], "floatingBoostProfiles":[boost], "floatingRingPresets":[ring]])
        let bytes = d.originalData, p = try AndroidProfileImportPlan.prepare(d, archiveID: UUID())
        XCTAssertEqual(p.convertedPresetCount, 4, "\(p.issues)")
        XCTAssertEqual(Set(p.settingsPresets.entries.map(\.category)), [.stickDirectional, .buttonAim, .floatingBoost, .floatingRing])
        XCTAssertTrue(p.profiles[0].profile.controls.isEmpty)
        XCTAssertEqual(d.originalData, bytes)
        XCTAssertEqual(d.settingsLibraries.first { $0.key == "stickDirectionalProfiles" }?.entries[0]["unknown"]?.numberValue?.rawValue, "9007199254740993")
        XCTAssertEqual(try SettingsPresetLibraryCodec.decode(SettingsPresetLibraryCodec.encode(p.settingsPresets)), p.settingsPresets)
        for preset in p.settingsPresets.entries { XCTAssertEqual(preset.createdAtMilliseconds, 100); XCTAssertEqual(preset.updatedAtMilliseconds, 200) }
    }
    func testTimingInSavedDirectionalPresetSurvivesNativeConversion() throws {
        let entry = directional.replacingOccurrences(of: #""mode":"WASD""#, with: #""schemaVersion":5,"mode":"STICK_PLUS""#)
            .replacingOccurrences(of: #""upBoostCommand":"W,SHIFT""#, with: #""upBoostCommand":"X360A(D40)(R100)""#)
        let result = try plan(["stickDirectionalProfiles": [entry]])
        guard case let .stickDirectional(stick) = result.settingsPresets.entries.first?.value else {
            return XCTFail("Expected the saved stick preset to convert: \(result.issues)")
        }
        XCTAssertEqual(stick.directionPayloads[.up]?.boostPayload, "X360A(D40)(R100)")
    }

    func testSavedRingAndKnobActionsKeepIndependentSettings() throws {
        let savedRing = ring.replacingOccurrences(of: #""zone":{"#, with: #""schemaVersion":7,"zone":{"finishIgnoresSwipes":true,"#)
            .replacingOccurrences(of: #""ring":{}"#, with: #""ring":{"boostBanks":{"enabled":true,"directStartBank":"AIM","aim":{"boost1":{"payload":"X360A(D40)"}}}}"#)
        let savedBoost = boost.replacingOccurrences(of: #""boost1":{"#, with: #""schemaVersion":5,"boost1":{"#)
            .replacingOccurrences(of: #""ringAimActions":{}"#, with: #""ringAimActions":{"knobActions":[{"mode":"HOLD","firePayload":"RT:0.4(R100)","returnFire":{"startOnBoostEntry":true}}]}"#)
        let result = try plan(["floatingRingPresets": [savedRing], "floatingBoostProfiles": [savedBoost]])
        guard case let .floatingRing(zone) = result.settingsPresets.entries.first(where: { $0.category == .floatingRing })?.value,
              case let .floatingBoost(settings) = result.settingsPresets.entries.first(where: { $0.category == .floatingBoost })?.value else {
            return XCTFail("Expected both presets to convert: \(result.issues)")
        }
        XCTAssertTrue(zone.finishIgnoresSwipes)
        XCTAssertEqual(zone.config.boostBanks?.directStartBank, .aim)
        XCTAssertEqual(zone.config.boostBanks?.aim.boost1.payload, "X360A(D40)")
        XCTAssertEqual(zone.config.boostBanks?.movement.boost1.payload, "")
        XCTAssertEqual(settings.knobActions?.first?.firePayload, "RT:0.4(R100)")
        XCTAssertEqual(settings.knobActions?.first?.returnFire.startOnBoostEntry, true)
    }

    func testNestedRingAndBoostPresetSchemasFollowAndroidEvenForInactiveOptions() throws {
        let options: [(library: String, content: String, required: Int)] = [
            ("floatingRingPresets", #""zone":{"ring":{"compactAimBoosts":true}}"#, 2),
            ("floatingRingPresets", #""zone":{"ring":{"boostBanks":{"enabled":false}}}"#, 3),
            ("floatingRingPresets", #""zone":{"ring":{"boostBanks":{"aim":{"boost2":{"skipDelayOnDirectTouch":true}}}}}"#, 4),
            ("floatingRingPresets", #""zone":{"ring":{"boostBanks":{"movement":{"boost1":{"directionalPayloads":{"left":"X360A(HRD200)"}}}}}}"#, 5),
            ("floatingRingPresets", #""zone":{"ring":{"knobs":[{"fire":{"adsPayload":"X360B(R80)"}}]}}"#, 6),
            ("floatingRingPresets", #""zone":{"ring":{"boostBanks":{"aim":{"boost2":{"payload":"X360B(D40)"}}}}}"#, 7),
            ("floatingBoostProfiles", #""ringAimActions":{"knobActions":[{"returnFire":{"startOnBoostEntry":true}}]}"#, 2),
            ("floatingBoostProfiles", #""boost2":{"skipDelayOnDirectTouch":true}"#, 3),
            ("floatingBoostProfiles", #""ringAimActions":{"knobActions":[{"firePayload":"X360B(SOR)"}]}"#, 4),
            ("floatingBoostProfiles", #""ringAimActions":{"knobActions":[{"firePayload":"X360B(R80)"}]}"#, 5),
            ("floatingBoostProfiles", #""ringAimActions":{"knobActions":[{"firePayload":"X360B(D40)"}]}"#, 6),
            ("touchAimManualProfiles", #""threeStage":{"aimOnlySensitivity":0}"#, 2),
            ("touchAimManualProfiles", #""threeStage":{"highEnterConfirmationMs":120}"#, 2),
            ("touchAimCalibrations", #""aimPayload":"X360A(D40)""#, 4)
        ]
        for (library, content, required) in options {
            func entry(_ version: Int) -> String { #"{\#(metadata),"schemaVersion":\#(version),\#(content)}"# }
            XCTAssertThrowsError(try document([library: [entry(required - 1)]]), "\(library) \(content)")
            XCTAssertNoThrow(try document([library: [entry(required)]]), "\(library) \(content)")
        }
    }

    func testDirectionalAndAimSettingsKeepTheirNativeMeaning() throws {
        let p = try plan(["stickDirectionalProfiles":[directional], "buttonAimProfiles":[buttonAim]])
        guard case let .stickDirectional(stick) = try XCTUnwrap(p.settingsPresets.entries.first { $0.category == .stickDirectional }?.value),
              case let .buttonAim(aim) = try XCTUnwrap(p.settingsPresets.entries.first { $0.category == .buttonAim }?.value) else { return XCTFail("Missing converted presets: \(p.issues)") }
        XCTAssertEqual(stick.mode, .directional); XCTAssertEqual(stick.directionPayloads[.up]?.normalPayload, "W")
        XCTAssertEqual(stick.superBoostThreshold, 0.75)
        XCTAssertEqual(aim.payload, "X360A"); XCTAssertEqual(aim.settings.tuning.output, .rightStick)
        XCTAssertEqual(aim.settings.tuning.stickResponse, .radial); XCTAssertEqual(aim.settings.tuning.origin, .controlCenter)
        XCTAssertTrue(aim.settings.cancelOnBoundaryExit); XCTAssertTrue(aim.settings.rearmOnBoundaryReturn)
        XCTAssertEqual(aim.settings.alternate.payload, "RT:0.5"); XCTAssertEqual(aim.settings.alternate.payloadTiming, .sendOnRelease)
    }
    func testAndroidSensorLibrariesStayArchivedWithoutNativeCalibrationOrThresholds() throws {
        let sensor = #"{\#(metadata),"nativeLookingValue":9007199254740993}"#
        let d = try document(["touchAimManualProfiles":[sensor], "touchAimCalibrations":[sensor]])
        let p = try AndroidProfileImportPlan.prepare(d, archiveID: UUID())
        XCTAssertTrue(p.settingsPresets.entries.isEmpty)
        XCTAssertEqual(p.issues.filter { $0.kind == .archivedOnly && $0.message.contains("sensor measurements") }.count, 2)
        XCTAssertTrue(String(decoding: d.originalData, as: UTF8.self).contains("9007199254740993"))
    }
    func testUnknownPayloadBadPartialTuningAndInvalidRingAreArchivedPerEntry() throws {
        let invalidDirection = directional.replacingOccurrences(of: #""upCommand":"W""#, with: #""upCommand":"FUTURE_OUTPUT""#)
        let invalidAim = buttonAim.replacingOccurrences(of: #""haptics":true"#, with: #""futureHaptics":true"#)
        let invalidRing = ring.replacingOccurrences(of: #""ring":{}"#, with: #""ring":{},"groupSwipe":true"#)
        let p = try plan(["stickDirectionalProfiles":[invalidDirection, directional], "buttonAimProfiles":[invalidAim], "floatingRingPresets":[invalidRing]])
        XCTAssertEqual(p.convertedPresetCount, 1, "\(p.issues)")
        XCTAssertEqual(p.issues.filter { $0.kind == .archivedOnly }.count, 3)
    }
    func testRepeatedImportUsesFreshPresetIDsNamesAndOneSharedOriginal() throws {
        let d = try document(["stickDirectionalProfiles":[directional, directional.replacingOccurrences(of: "Saved", with: "saved")]])
        let p = try AndroidProfileImportPlan.prepare(d, archiveID: UUID()), r = try reference(d), initial = ControllerProfileLibrary.default
        XCTAssertEqual(p.settingsPresets.entries.map(\.name), ["Saved", "saved 2"])
        let once = try p.merged(into: initial, source: r), twice = try p.merged(into: once, source: r)
        XCTAssertEqual(twice.activeProfileID, initial.activeProfileID); XCTAssertEqual(twice.androidSources, [r])
        XCTAssertEqual(twice.settingsPresets.entries.count, 4); XCTAssertEqual(Set(twice.settingsPresets.entries.map(\.id)).count, 4)
        XCTAssertTrue(Set(p.settingsPresets.entries.map(\.id)).isDisjoint(with: twice.settingsPresets.entries.map(\.id)))
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(twice)), twice)
    }
    func testCategoryLimitArchivesRemainingPresetsAndMergeCapacityFailureDoesNotMutate() throws {
        let p = try plan(["stickDirectionalProfiles":Array(repeating: directional, count: 65)])
        XCTAssertEqual(p.convertedPresetCount, 64); XCTAssertTrue(p.issues.contains { $0.message.contains("remaining 1 source") })
        let d = try document(["stickDirectionalProfiles":[directional]]), one = try AndroidProfileImportPlan.prepare(d, archiveID: UUID())
        var full = ControllerProfileLibrary.default; full.settingsPresets = p.settingsPresets
        let before = full
        XCTAssertThrowsError(try one.merged(into: full, source: reference(d)))
        XCTAssertEqual(full, before)
    }
    func testMissingTimestampOrBackwardTimestampPreservesEntryWithoutRepair() throws {
        let missing = directional.replacingOccurrences(of: #""createdAtEpochMs":100,"# , with: "")
        let backwards = directional.replacingOccurrences(of: #""updatedAtEpochMs":200"#, with: #""updatedAtEpochMs":50"#)
        XCTAssertEqual(try plan(["stickDirectionalProfiles":[missing, backwards]]).convertedPresetCount, 0)
    }
    func testButtonAimLegacySchemaCannotEnableNewerBehavior() throws {
        let boundary = buttonAim.replacingOccurrences(of: #""schemaVersion":5"#, with: #""schemaVersion":4"#)
        let missingSchema = buttonAim.replacingOccurrences(of: #""schemaVersion":5,"#, with: "")
        let gameMouse = buttonAim.replacingOccurrences(of: #""schemaVersion":5"#, with: #""schemaVersion":3"#)
            .replacingOccurrences(of: "RIGHT_STICK", with: "GAME_MOUSE").replacingOccurrences(of: "true", with: "false")
        XCTAssertEqual(try plan(["buttonAimProfiles":[boundary, missingSchema, gameMouse]]).convertedPresetCount, 0)
    }
}

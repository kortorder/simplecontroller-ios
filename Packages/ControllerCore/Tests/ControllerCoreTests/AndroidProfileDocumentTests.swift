import Foundation
import XCTest
@testable import ControllerCore

final class AndroidProfileDocumentTests: XCTestCase {
    private func control(_ extra: String = "", type: String = "BUTTON") -> String {
        "{\"id\":\"android-control\",\"type\":\"\(type)\",\"x\":20,\"y\":30,\"w\":120,\"h\":80,\"payload\":\"X360A\"\(extra)}"
    }
    private func profile(_ extra: String = "", controls: String = "[]", version: String = "5") -> String {
        "{\"formatVersion\":\(version),\"homePageId\":\"base\",\"pages\":[{\"id\":\"base\",\"name\":\"Base\",\"controls\":\(controls)}]\(extra)}"
    }
    private func parse(_ text: String) throws -> AndroidProfileDocument { try .parse(Data(text.utf8)) }
    private func backup(version: Int = 1, extra: String = "") -> String {
        "{\"fileType\":\"simplecontroller-profiles-backup\",\"backupVersion\":\(version),\"activeControllerProfileName\":\"Original\",\"controllerProfiles\":[{\"name\":\"Original\",\"profile\":\(profile())}]\(extra)}"
    }

    func testLegacyArrayMetadataAndExactOriginalExport() throws {
        let source = " [\n\(control()),\(control(type: "TOUCHPAD"))\n] "
        let result = try parse(source)
        XCTAssertEqual(result.kind, .legacyControls)
        XCTAssertEqual(result.exportOriginalData(), Data(source.utf8))
        XCTAssertEqual(result.profiles[0].formatVersion, 2)
        XCTAssertEqual(result.profiles[0].pages[0].name, "Base")
        XCTAssertTrue(result.profiles[0].pages[0].isLegacyBasePage)
        XCTAssertNil(result.profiles[0].pages[0].sourceID)
        XCTAssertEqual(result.profiles[0].pages[0].controls[1].sourcePath, "/1")
        XCTAssertEqual(result.profiles[0].pages[0].controls[0].sourceID, "android-control")
    }

    func testLegacyArrayChecksNestedAndEscapedModifiersAndStageTuning() throws {
        let escaped = control().replacingOccurrences(of: "X360A", with: #"X360A\u0028D40\u0029"#)
        for item in [escaped, control(#","touchAimAimOnlySensitivity":0"#), control(#","touchHighEnterConfirmationMs":30"#),
                     control(#","extension":{"nested":[{"firePayload":"X360A(R50)"}]}"#)] {
            XCTAssertThrowsError(try parse("[\(item)]"))
        }
        let punctuationOnlyInLabel = control(#","name":"Room (D40)","touchHighSensitivity":null,"touchHighEnterConfirmationMs":0"#)
        XCTAssertNoThrow(try parse("[\(punctuationOnlyInLabel)]"))
        XCTAssertThrowsError(try parse(profile(controls: "[\(escaped)]", version: "15")))
        let original = profile(controls: "[\(escaped)]", version: "16")
        let document = try parse(original)
        XCTAssertEqual(document.profiles[0].pages[0].controls[0].payload, "X360A(D40)")
        XCTAssertEqual(document.exportOriginalData(), Data(original.utf8))
    }

    func testRawProfileVersionsOneThroughTenAndMissingVersionDefault() throws {
        for version in 1...10 {
            let result = try parse(profile(controls: "[\(control())]", version: String(version)))
            XCTAssertEqual(result.kind, .rawProfile)
            XCTAssertEqual(result.profiles[0].formatVersion, version)
            XCTAssertEqual(result.profiles[0].homePageID, "base")
            XCTAssertEqual(result.profiles[0].pages[0].sourcePath, "/pages/0")
            XCTAssertEqual(result.profiles[0].pages[0].controls[0].sourcePath, "/pages/0/controls/0")
        }
        XCTAssertEqual(try parse("{\"pages\":[]}").profiles[0].formatVersion, 2)
    }

    func testTransferWrapperBOMAndUnknownEnvelopeFields() throws {
        let source = "\u{FEFF} \n{\"fileType\":\"simplecontroller-profile\",\"transferVersion\":1,\"profileName\":\"Source\",\"profile\":\(profile()),\"future\":{\"deep\":[null,true,\"text\"]}}\n"
        let result = try parse(source)
        XCTAssertEqual(result.kind, .singleTransfer)
        XCTAssertEqual(result.profiles[0].name, "Source")
        XCTAssertEqual(result.profiles[0].sourcePath, "/profile")
        XCTAssertEqual(result.exportOriginalData(), Data(source.utf8))
        XCTAssertEqual(try AndroidProfileDocument.parse(result.root.encodedData()).root, result.root)
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .unknownFields && $0.sourcePath.isEmpty })
    }

    func testEmptyTransferNameUsesFallbackWithoutChangingSource() throws {
        let raw = "{\"fileType\":\"simplecontroller-profile\",\"transferVersion\":1,\"profileName\":\"\",\"profile\":\(profile())}"
        let result = try AndroidProfileDocument.parse(Data(raw.utf8), fallbackName: "Filename")
        XCTAssertEqual(result.profiles[0].name, "Filename")
        XCTAssertEqual(result.root["profileName"], .string(""))
    }

    func testAllBackupEnvelopeVersionsAndLibraries() throws {
        let cases = [(1, "touchAimCalibrations", 1), (1, "buttonAimProfiles", 5), (1, "stickDirectionalProfiles", 2), (2, "floatingBoostProfiles", 1), (3, "floatingRingPresets", 1)]
        for (version, key, schema) in cases {
            let source = backup(version: version, extra: ",\"\(key)\":[{\"id\":\"setting\",\"name\":\"Named\",\"schemaVersion\":\(schema),\"unknown\":9223372036854775809}]")
            let result = try parse(source)
            XCTAssertEqual(result.kind, .allProfilesBackup)
            XCTAssertEqual(result.activeProfileName, "Original")
            XCTAssertEqual(result.profiles[0].sourcePath, "/controllerProfiles/0/profile")
            XCTAssertEqual(result.settingsLibraries.first?.sourcePath, "/\(key)")
            XCTAssertEqual(result.settingsLibraries.first?.entries.first?["unknown"]?.numberValue?.rawValue, "9223372036854775809")
            XCTAssertEqual(result.originalData, Data(source.utf8))
        }
    }

    func testAllSixSettingLibrariesAreRetainedAndMissingSchemaUsesSourceDefault() throws {
        let keys = ["touchAimCalibrations", "touchAimManualProfiles", "buttonAimProfiles", "stickDirectionalProfiles", "floatingBoostProfiles", "floatingRingPresets"]
        let extra = keys.map { ",\"\($0)\":[{\"id\":\"s\",\"name\":\"Settings\",\"unknown\":[1,2,3]}]" }.joined()
        let result = try parse(backup(version: 3, extra: extra))
        XCTAssertEqual(Set(result.settingsLibraries.map(\.key)), Set(keys))
        XCTAssertEqual(result.settingsLibraries.count, 6)
        XCTAssertNil(result.settingsLibraries[0].entries[0]["schemaVersion"])
    }

    func testNumbersNeverPassThroughDoubleAndKeepLexicalForm() throws {
        let numbers = ["9007199254740993", "18446744073709551616", "1234567890123456789012345678901234567890", "-0", "1.2300", "1e+9999", "-2.5E-9999", "0.000000000000000000000000001"]
        let result = try parse(profile(",\"future\":[\(numbers.joined(separator: ","))]"))
        XCTAssertEqual(result.root["future"]?.arrayValue?.map { $0.numberValue!.rawValue }, numbers)
        let encoded = try result.root.encodedData()
        XCTAssertEqual(try AndroidProfileDocument.parse(encoded).root["future"], result.root["future"])
        for number in numbers { XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(number)) }
    }

    func testUnknownNestedValuesAndUnsupportedControlAreNotDropped() throws {
        let extra = #", "futureControl":{"array":[false,null,{"x":7}]}, "buttonAimEnabled":true, "extendedBoost":{"enabled":true,"future":9}, "pageAction":"GO_TO", "pageTargetId":"missing""#
        let result = try parse(profile(",\"futureProfile\":null", controls: "[\(control(extra, type: "FUTURE_SENSOR"))]"))
        let sourceControl = result.profiles[0].pages[0].controls[0]
        XCTAssertNotNil(sourceControl.value["futureControl"])
        XCTAssertEqual(sourceControl.value["extendedBoost"]?["future"]?.numberValue?.rawValue, "9")
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .unsupportedControl })
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .unsupportedFeature && $0.sourcePath.hasSuffix("/buttonAimEnabled") })
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .mappingRequired && $0.sourcePath.hasSuffix("/pageAction") })
        XCTAssertEqual(try AndroidProfileDocument.parse(result.root.encodedData()).root, result.root)
    }

    func testUnsupportedPayloadIsDiagnosticRatherThanLossOrExecution() throws {
        let source = control().replacingOccurrences(of: "X360A", with: "FUTURE_STICK:UR100")
        let result = try parse("[\(source)]")
        XCTAssertEqual(result.profiles[0].pages[0].controls[0].payload, "FUTURE_STICK:UR100")
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .unsupportedFeature && $0.sourcePath == "/0/payload" })
    }

    func testUnicodeEscapesSurrogatePairAndControlCharactersRoundTrip() throws {
        let source = profile(#", "future":"\uD83D\uDE80\u0000\b\f\n\r\t\\\/\" café""#)
        let result = try parse(source)
        XCTAssertEqual(result.root["future"]?.stringValue, "🚀\0\u{8}\u{C}\n\r\t\\/\" café")
        XCTAssertEqual(try AndroidProfileDocument.parse(result.root.encodedData()).root, result.root)
    }

    func testCanonicallyEquivalentUnicodeObjectKeysRemainDistinct() throws {
        let result = try parse(profile(#", "future":{"é":1,"e\u0301":2}"#))
        let object = try XCTUnwrap(result.root["future"]?.objectValue)
        XCTAssertEqual(object.count, 2)
        XCTAssertEqual(object["é"]?.numberValue?.rawValue, "1")
        XCTAssertEqual(object["e\u{301}"]?.numberValue?.rawValue, "2")
        let restored = try AndroidProfileDocument.parse(result.root.encodedData())
        XCTAssertEqual(restored.root["future"]?.objectValue?.count, 2)
        XCTAssertEqual(restored.root["future"]?["e\u{301}"]?.numberValue?.rawValue, "2")
    }

    func testJSONEqualityDistinguishesUnicodeScalarSpellings() throws {
        let composed = try parse(profile(#", "future":"é""#))
        let decomposed = try parse(profile(#", "future":"e\u0301""#))
        XCTAssertNotEqual(composed.root, decomposed.root)
        XCTAssertNotEqual(AndroidJSONValue.string("é"), .string("e\u{301}"))
    }

    func testLegacyDuplicateControlsAreReportedButCurrentAmbiguousIDsReject() throws {
        let values = "[\(control()),\(control())]"
        XCTAssertTrue(try parse(values).diagnostics.contains { $0.kind == .sourceRepairNeeded })
        XCTAssertThrowsError(try parse(profile(controls: values)))
        XCTAssertThrowsError(try parse(#"{"pages":[{},{}]}"#))
    }

    func testUnknownEnumOptionIsPreservedAndReported() throws {
        let result = try parse("[" + control(#", "buttonAimOutput":"FUTURE_OUTPUT""#) + "]")
        XCTAssertEqual(result.profiles[0].pages[0].controls[0].value["buttonAimOutput"], .string("FUTURE_OUTPUT"))
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .unsupportedFeature && $0.sourcePath == "/0/buttonAimOutput" })
    }

    func testDuplicateJSONKeysIncludingEscapedAliasesAreRejected() {
        for source in [#"{"pages":[],"pages":[]}"#, #"{"pages":[],"\u0070ages":[]}"#] { XCTAssertThrowsError(try parse(source)) }
    }

    func testMalformedJSONNumbersAreRejected() {
        for number in ["01", "-01", "-", ".2", "2.", "2e", "2e+", "+2", "NaN", "Infinity"] {
            XCTAssertThrowsError(try parse(profile(",\"future\":\(number)")), number)
        }
    }

    func testMalformedStringsAndUTF8AreRejected() {
        for string in [#""\uD800""#, #""\uDC00""#, #""\uD800\u0041""#, #""\uZZZZ""#, #""\q""#, "\"line\nline\"", "\"unterminated"] {
            XCTAssertThrowsError(try parse(profile(",\"future\":\(string)")), string)
        }
        XCTAssertThrowsError(try AndroidProfileDocument.parse(Data([0x7b,0x22,0xff,0x22,0x3a,0x30,0x7d])))
    }

    func testWrongKnownFieldTypesAndRequiredControlFieldsAreRejected() {
        for extra in [",\"autoCenter\":1", ",\"sensitivity\":\"1\"", ",\"pageAction\":false", ",\"extendedBoost\":[]", ",\"buttonDirectional\":{\"enabled\":1}", ",\"touchAimSensorTransforms\":false"] {
            XCTAssertThrowsError(try parse("[\(control(extra))]"), extra)
        }
        for source in [#"[{}]"#, #"{"pages":{}}"#, #"{"pages":[false]}"#, #"{"pages":[{"controls":{}}]}"#, #"{"pages":[{"id":0}]}"#] { XCTAssertThrowsError(try parse(source)) }
        XCTAssertThrowsError(try parse("[" + control().replacingOccurrences(of: "\"x\":20", with: "\"x\":\"20\"") + "]"))
    }

    func testFutureInvalidAndNonIntegerProfileVersionsAreRejected() {
        for version in ["0", "18", "-1", "1.0", "1e0", "true", "null", "\"5\"", "999999999999999999999999"] {
            XCTAssertThrowsError(try parse(profile(version: version)), version)
        }
    }

    func testWrongFileTypesEnvelopeVersionsAndMissingRequiredWrapperFieldsReject() {
        for source in ["null", "[] true", "{\"future\":1}", "{\"fileType\":1}", "{\"fileType\":\"unknown\"}", "{\"fileType\":\"simplecontroller-profile\",\"profileName\":\"x\",\"profile\":{}}", "{\"fileType\":\"simplecontroller-profile\",\"transferVersion\":2,\"profileName\":\"x\",\"profile\":{}}"] {
            XCTAssertThrowsError(try parse(source), source)
        }
        XCTAssertThrowsError(try parse(backup(version: 4)))
    }

    func testBackupVersionsGateLibrariesAndNestedSchemas() {
        let setting = "[{\"id\":\"s\",\"name\":\"S\",\"schemaVersion\":1}]"
        XCTAssertThrowsError(try parse(backup(extra: ",\"floatingBoostProfiles\":\(setting)")))
        XCTAssertThrowsError(try parse(backup(version: 2, extra: ",\"floatingRingPresets\":\(setting)")))
        XCTAssertThrowsError(try parse(backup(extra: ",\"touchAimCalibrations\":[{\"id\":\"s\",\"name\":\"S\",\"schemaVersion\":6}]")))
        XCTAssertThrowsError(try parse(backup(extra: ",\"buttonAimProfiles\":false")))
        XCTAssertThrowsError(try parse(backup(extra: ",\"touchAimManualProfiles\":[{}]")))
        XCTAssertThrowsError(try parse(backup().replacingOccurrences(of: "\"formatVersion\":5", with: "\"formatVersion\":18")))
    }

    func testBackupMissingActiveAndDuplicateNamesAreRejected() {
        XCTAssertThrowsError(try parse(backup().replacingOccurrences(of: "\"activeControllerProfileName\":\"Original\"", with: "\"activeControllerProfileName\":\"Missing\"")))
        let source = "{\"fileType\":\"simplecontroller-profiles-backup\",\"backupVersion\":1,\"activeControllerProfileName\":\"Same\",\"controllerProfiles\":[{\"name\":\"Same\",\"profile\":\(profile())},{\"name\":\" same \",\"profile\":\(profile())}]}"
        XCTAssertThrowsError(try parse(source))
    }

    func testMissingOptionalPageDataIsReportedWithoutRepairingOriginal() throws {
        let source = #"{"pages":[{}]}"#
        let result = try parse(source)
        XCTAssertNil(result.profiles[0].pages[0].sourceID)
        XCTAssertNil(result.root["pages"]?.arrayValue?.first?["controls"])
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .sourceRepairNeeded })
        XCTAssertEqual(result.originalData, Data(source.utf8))
    }

    func testDuplicatePageIDsAreRejectedButUnicodeDistinctIDsAreNotCollapsed() throws {
        XCTAssertThrowsError(try parse(#"{"pages":[{"id":"x"},{"id":"x"}]}"#))
        XCTAssertEqual(try parse(#"{"pages":[{"id":"é"},{"id":"e\u0301"}]}"#).profiles[0].pages.count, 2)
    }

    func testOrientationUnknownsArePreservedAndWrongGeometryTypesReject() throws {
        let source = #"{"formatVersion":5,"homePageId":"p","pages":[{"id":"p","name":"P","controls":[],"portraitGeometry":{"canvasWidth":100,"canvasHeight":200,"controls":{"source/~":{"x":1,"y":2,"w":3,"h":4,"unknown":true}},"future":[null]}}]}"#
        let result = try parse(source)
        XCTAssertNotNil(result.profiles[0].pages[0].value["portraitGeometry"]?["future"])
        let invalid = source.replacingOccurrences(of: "\"w\":3", with: "\"w\":false")
        XCTAssertThrowsError(try parse(invalid)) { error in
            XCTAssertEqual((error as? AndroidProfileDocumentError)?.sourcePath, "/pages/0/portraitGeometry/controls/source~1~0/w")
        }
    }

    func testBoundedNestingRejectsDeepDocuments() throws {
        let allowed = String(repeating: "[", count: 63) + "0" + String(repeating: "]", count: 63)
        XCTAssertNoThrow(try parse(profile(",\"future\":\(allowed)")))
        let tooDeep = "[" + allowed + "]"
        XCTAssertThrowsError(try parse(profile(",\"future\":\(tooDeep)")))
    }

    func testCollectionAndTotalValueLimitsAreIndependent() {
        let oversized = "[" + Array(repeating: "0", count: AndroidProfileDocument.maximumCollectionCount + 1).joined(separator: ",") + "]"
        XCTAssertThrowsError(try parse(profile(",\"future\":\(oversized)")))
        let chunk = "[" + Array(repeating: "0", count: 90_000).joined(separator: ",") + "]"
        XCTAssertThrowsError(try parse(profile(",\"future\":[\(chunk),\(chunk),\(chunk)]")))
    }

    func testFull25MiBBoundaryIsAcceptedAndLargerInputRejected() throws {
        let prefix = "{\"pages\":[],\"unknown\":\""
        let suffix = "\"}"
        let fill = AndroidProfileDocument.maximumBytes - prefix.utf8.count - suffix.utf8.count
        var data = Data(prefix.utf8)
        data.append(Data(repeating: 97, count: fill)); data.append(Data(suffix.utf8))
        XCTAssertEqual(data.count, AndroidProfileDocument.maximumBytes)
        let result = try AndroidProfileDocument.parse(data)
        XCTAssertEqual(result.exportOriginalData(), data)
        data.append(32)
        XCTAssertThrowsError(try AndroidProfileDocument.parse(data))
    }

    func testObjectMemberOrderAndArrayOrderSurviveTreeEncoding() throws {
        let result = try parse(profile(#", "future":{"z":3,"a":[2,1],"m":0}"#))
        let encoded = try result.root.encodedData()
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""future":{"z":3,"a":[2,1],"m":0}"#))
    }
}

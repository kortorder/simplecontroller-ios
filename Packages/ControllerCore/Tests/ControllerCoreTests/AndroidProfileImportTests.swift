import Foundation
import XCTest
@testable import ControllerCore

final class AndroidProfileImportTests: XCTestCase {
    private func control(_ id: String = "c", type: String = "BUTTON", payload: String = "X360A", extra: String = "") -> String {
        #"{"id":"\#(id)","type":"\#(type)","x":20,"y":30,"w":120,"h":80,"payload":"\#(payload)"\#(extra)}"#
    }
    private func document(_ controls: [String], extraPage: String = "") throws -> AndroidProfileDocument {
        try .parse(Data(#"{"formatVersion":10,"homePageId":"p","pages":[{"id":"p","name":"Base","controls":[\#(controls.joined(separator: ","))]\#(extraPage)}]}"#.utf8))
    }
    private func plan(_ controls: [String]) throws -> AndroidProfileImportPlan {
        try .prepare(document(controls), archiveID: UUID())
    }
    func testSupportedButtonMapsPayloadAndHoldWithoutMutatingSource() throws {
        let doc = try document([control(extra: #", "holdToggle":true,"holdDurationMs":700,"swipeActivate":false"#)])
        let bytes = doc.originalData, id = UUID()
        let result = try AndroidProfileImportPlan.prepare(doc, archiveID: id)
        let c = try XCTUnwrap(result.profiles.first?.profile.controls.first)
        XCTAssertEqual(c.payload, "X360A"); XCTAssertTrue(c.buttonBehavior.holdToggle)
        XCTAssertEqual(c.buttonBehavior.holdMilliseconds, 700); XCTAssertFalse(c.swipeActivationEnabled)
        XCTAssertEqual(result.profiles[0].source.archiveID, id)
        XCTAssertEqual(result.profiles[0].source.controls.first?.sourcePath, "/pages/0/controls/0")
        XCTAssertEqual(doc.originalData, bytes); XCTAssertEqual(result.convertedControlCount, 1)
        XCTAssertEqual(result.profiles[0].profile.swipeMode, .off)
    }
    func testUnknownPayloadAndUnknownControlAreArchivedOnlyNotPartialButtons() throws {
        let result = try plan([control("one", payload: "X360A,FUTURE_ACTION"), control("two", type: "FUTURE_SENSOR"), control("three")])
        XCTAssertEqual(result.convertedControlCount, 1); XCTAssertEqual(result.archivedOnlyControlCount, 2)
        XCTAssertEqual(result.issues.filter { $0.kind == .archivedOnly }.count, 2)
    }
    func testUnsupportedFloatingActionsAndUnknownAimOutputsStayArchived() throws {
        for setting in [#", "buttonAimEnabled":true,"buttonAimOutput":"FUTURE""#, #", "floatingLocalAction":"FINISH""#] {
            let result = try plan([control(extra: setting)])
            XCTAssertEqual(result.convertedControlCount, 0, setting)
            XCTAssertEqual(result.archivedOnlyControlCount, 1, setting)
        }
    }
    func testDirectionalButtonStageDistancesPayloadsAndBaseActionAreMapped() throws {
        let result = try plan([control(extra: #", "buttonDirectional":{"enabled":true,"up":{"firstDistancePx":30,"secondDistancePx":70,"firstPayload":"X360B","secondPayload":"RT:0.5"}}"#)])
        let c = try XCTUnwrap(result.profiles.first?.profile.controls.first)
        XCTAssertTrue(c.buttonDirectional.enabled); XCTAssertEqual(c.payload, "X360A")
        XCTAssertEqual(c.buttonDirectional.directions[.up]?.firstDistance, 30)
        XCTAssertEqual(c.buttonDirectional.directions[.up]?.secondPayload, "RT:0.5")
        XCTAssertEqual(c.buttonDirectional.directions[.left]?.secondDistance, 96)
    }
    func testButtonAimAndAlternateTuningAreMappedWithoutResettingBase() throws {
        let result = try plan([control(extra: #", "buttonAimEnabled":true,"buttonAimOutput":"RIGHT_STICK","buttonAimSensitivity":2,"buttonAimStickProfile":"RADIAL_RESPONSE_CURVE","buttonAimStickUsesTouchPosition":true,"buttonAimPayloadTiming":"SEND_ON_RELEASE","buttonAimReleaseDelayMs":250,"buttonAimCancelOnBoundaryExit":true,"buttonAimRearmOnBoundaryReturn":true,"buttonAimOneShotAlternateEnabled":true,"buttonAimAlternatePayload":"X360B","buttonAimAlternateOutput":"GAME_MOUSE","buttonAimAlternatePayloadTiming":"IMMEDIATE","buttonAimAlternateResetHoldDurationMs":1500,"buttonAimAlternateBaseUnlatchDelayMs":300,"buttonAimAlternateDisplayName":"Reload","buttonAimAlternateMouseProfile":"LINEAR_RELATIVE","buttonAimAlternateInvertY":true"#)])
        let c = try XCTUnwrap(result.profiles.first?.profile.controls.first)
        XCTAssertTrue(c.buttonAim.enabled); XCTAssertEqual(c.buttonAim.tuning.output, .rightStick)
        XCTAssertEqual(c.buttonAim.tuning.stickResponse, .radial); XCTAssertEqual(c.buttonAim.tuning.origin, .controlCenter)
        XCTAssertEqual(c.buttonAim.payloadTiming, .sendOnRelease); XCTAssertEqual(c.buttonAim.releaseDelayMilliseconds, 250)
        XCTAssertTrue(c.buttonAim.cancelOnBoundaryExit); XCTAssertTrue(c.buttonAim.rearmOnBoundaryReturn)
        XCTAssertTrue(c.buttonAim.alternate.enabled); XCTAssertEqual(c.buttonAim.alternate.payload, "X360B")
        XCTAssertEqual(c.buttonAim.alternate.tuning.output, .gameMouse)
        XCTAssertEqual(c.buttonAim.alternate.resetHoldMilliseconds, 1500)
        XCTAssertEqual(c.buttonAim.alternate.baseUnlatchDelayMilliseconds, 300)
        XCTAssertEqual(c.buttonAim.alternate.displayName, "Reload")
        XCTAssertEqual(c.buttonAim.alternate.tuning.mouseResponse, .linearRelative)
        XCTAssertTrue(c.buttonAim.alternate.tuning.invertY)
    }
    func testUnsafeAdvancedModesAndWrongNestedTypesRemainArchived() throws {
        for setting in [#", "buttonAimEnabled":true,"autoTapEnabled":true"#,
                        #", "buttonDirectional":{"enabled":true,"up":false}"#,
                        #", "buttonDirectional":{"enabled":true,"up":{"firstPayload":12}}"#,
                        #", "buttonAimEnabled":true,"buttonAimOneShotAlternateEnabled":true,"buttonAimAlternatePayload":"WAIT_1000,X360B""#] {
            XCTAssertEqual(try plan([control(extra: setting)]).convertedControlCount, 0)
        }
    }
    func testCurvesResponseAndDirectionalStageDefaultsAreMapped() throws {
        let result = try plan([control(type: "RADIAL_CURVED_STICK", payload: "STICK_R", extra: #", "autoCenter":false,"sensitivity":1.5,"directionalMode":true"#)])
        let c = result.profiles[0].profile.controls[0]
        XCTAssertEqual(c.kind, .rightStick); XCTAssertEqual(c.stickResponse.mode, .radial)
        XCTAssertEqual(c.stickResponse.sensitivity, 1.5); XCTAssertFalse(c.stickBehavior.autoCenter)
        XCTAssertTrue(c.isDirectional); XCTAssertEqual(c.directionPayloads[.down]?.boostPayload, "S,CTRL")
        XCTAssertEqual(c.directionPayloads[.up]?.superBoostPayload, "W,SHIFT,SPACE")
    }
    func testExtendedBoostThresholdsAndOuterPayloadAreMapped() throws {
        let result = try plan([control(type: "CURVED_STICK", payload: "STICK_L", extra: #", "stickPlusMode":true,"extendedBoost":{"enabled":true,"mode":"ADD_OUTER_STAGE","regular":{"up":0.6},"superBoost":{"up":0.8},"outer":{"up":1.4},"outerCommands":{"up":"X360Y"}}"#)])
        let c = result.profiles[0].profile.controls[0]
        XCTAssertEqual(c.stickResponse.mode, .perAxis); XCTAssertTrue(c.extendedBoost.enabled)
        XCTAssertEqual(c.extendedBoost.directions[.up]?.outerThreshold, 1.4)
        XCTAssertEqual(c.extendedBoost.directions[.up]?.outerPayload, "X360Y")
    }
    func testTouchpadModePrecedenceAndSensitivityMatchSource() throws {
        for (extra, mode) in [("", TouchpadClickMode.none), (#", "holdLeftWhileTouch":true"#, .hold), (#", "holdLeftWhileTouch":true,"toggleLeftClick":true"#, .toggle), (#", "toggleLeftClick":true,"doubleTapClickLock":true"#, .doubleTapLock)] {
            let result = try plan([control(type: "TOUCHPAD", payload: "TOUCHPAD", extra: extra + #", "sensitivity":2"#)])
            let c = result.profiles[0].profile.controls[0]
            XCTAssertEqual(c.touchpadBehavior.clickMode, mode); XCTAssertEqual(c.touchpadBehavior.sensitivity, 2)
            XCTAssertTrue(result.issues.contains { $0.message.contains("iOS points") })
        }
    }
    func testUnsafeSettingsAndNonSustainedStagesStayArchived() throws {
        let items = [control("a", extra: #", "holdToggle":true,"autoTapEnabled":true"#),
                     control("b", type: "STICK", extra: #", "directionalMode":true,"upCommand":"WAIT_1000,X360A""#),
                     control("c", type: "TOUCHPAD", extra: #", "sensitivity":6"#),
                     control("d", extra: #", "holdDurationMs":1e500"#)]
        let result = try plan(items)
        XCTAssertEqual(result.convertedControlCount, 0); XCTAssertEqual(result.archivedOnlyControlCount, 4)
    }
    func testPageActionsRemapTargetsHomeAndPrevious() throws {
        let buttons = [control("goto", extra: #", "pageAction":"GO_TO","pageTargetId":"q""#),
                       control("toggle", extra: #", "pageAction":"TOGGLE","pageTargetId":"q""#),
                       control("back", extra: #", "pageAction":"RETURN""#),
                       control("home", extra: #", "pageAction":"HOME""#),
                       control("broken", extra: #", "pageAction":"GO_TO","pageTargetId":"missing""#)].joined(separator: ",")
        let data = Data(#"{"formatVersion":5,"homePageId":"q","pages":[{"id":"p","name":"P","controls":[\#(buttons)]},{"id":"q","name":"Q","controls":[]}]}"#.utf8)
        let result = try AndroidProfileImportPlan.prepare(.parse(data), archiveID: UUID())
        let p = result.profiles[0].profile, q = p.pages[1].id
        XCTAssertEqual(p.homePageID, q); XCTAssertEqual(p.controls.map(\.pageNavigation), [.goTo(q), .toggle(q), .back, .home])
        XCTAssertEqual(result.archivedOnlyControlCount, 1)
    }
    func testOrientationGeometryUsesCentersAndPreservesIndependentDimensions() throws {
        let geometry = #", "portraitGeometry":{"canvasWidth":400,"canvasHeight":800,"controls":{"c":{"x":100,"y":200,"w":80,"h":160}}},"landscapeGeometry":{"canvasWidth":800,"canvasHeight":400,"controls":{"c":{"x":600,"y":200,"w":80,"h":80}}}"#
        let result = try AndroidProfileImportPlan.prepare(document([control()], extraPage: geometry), archiveID: UUID())
        let p = result.profiles[0].profile
        XCTAssertEqual(p.portrait[0].position.x, 0.35, accuracy: 0.00001)
        XCTAssertEqual(p.portrait[0].position.y, 0.35, accuracy: 0.00001)
        XCTAssertEqual(p.landscape[0].position.x, 0.8, accuracy: 0.00001)
        XCTAssertEqual(p.landscape[0].position.y, 0.6, accuracy: 0.00001)
        XCTAssertEqual(p.controls[0].controlWidth!, 44, accuracy: 0.001)
        XCTAssertEqual(p.controls[0].controlHeight!, 85.6, accuracy: 0.001)
        XCTAssertTrue(result.issues.contains { $0.message.contains("minimum touch target") })
    }
    func testAbsentCanvasIsExplicitlyFittedWithoutLosingSourceGeometry() throws {
        let result = try plan([control()])
        XCTAssertTrue(result.issues.contains { $0.message.contains("canvas size was absent") })
        XCTAssertTrue(result.profiles[0].profile.portrait[0].position.isValid)
    }
    func testOversizedProfileIsArchivedWholeRatherThanDroppingLastControl() throws {
        let result = try plan((0..<65).map { control("c\($0)") })
        XCTAssertTrue(result.profiles.isEmpty); XCTAssertEqual(result.archivedOnlyControlCount, 65)
        XCTAssertEqual(result.archivedOnlyProfileCount, 1)
    }
    func testLegacyDuplicateIDsGetIndependentNativeIDsAndSourcePointers() throws {
        let doc = try AndroidProfileDocument.parse(Data("[\(control()),\(control())]".utf8))
        let result = try AndroidProfileImportPlan.prepare(doc, archiveID: UUID())
        XCTAssertEqual(Set(result.profiles[0].profile.controls.map(\.id)).count, 2)
        XCTAssertEqual(result.profiles[0].source.controls.map(\.sourcePath), ["/0", "/1"])
    }
    func testMalformedGeometryDoesNotCreatePlayableOutput() throws {
        let bad = control().replacingOccurrences(of: "\"w\":120", with: "\"w\":1e999")
        let result = try plan([bad]); XCTAssertEqual(result.convertedControlCount, 0)
    }
    func testSourceReferenceBindingRemapDropsDeletedControls() throws {
        let oldPage = UUID(), newPage = UUID(), oldControl = UUID(), newControl = UUID()
        let source = AndroidProfileSourceReference(archiveID: UUID(), sourceProfilePath: "/profile",
            pages: [.init(nativeID: oldPage, sourcePath: "/profile/pages/0")],
            controls: [.init(nativeID: oldControl, sourcePath: "/profile/pages/0/controls/0"), .init(nativeID: UUID(), sourcePath: "/profile/pages/0/controls/1")])
        let copy = source.remapped(pages: [oldPage: newPage], controls: [oldControl: newControl])
        XCTAssertEqual(copy.pages.map(\.nativeID), [newPage]); XCTAssertEqual(copy.controls.map(\.nativeID), [newControl])
        XCTAssertEqual(copy.archiveID, source.archiveID)
        XCTAssertNoThrow(try copy.validate(pageIDs: [newPage], controlIDs: [newControl]))
    }
    func testImportPreviewBoundsDiagnosticCountWithoutDroppingOriginal() throws {
        let controls = (0..<64).map { control("c\($0)", extra: #", "futureOption":true"#) }.joined(separator: ",")
        let profile = #"{"formatVersion":5,"homePageId":"p","pages":[{"id":"p","name":"Base","controls":[\#(controls)]}]}"#
        let json = #"{"fileType":"simplecontroller-profiles-backup","backupVersion":1,"activeControllerProfileName":"First","controllerProfiles":[{"name":"First","profile":\#(profile)},{"name":"Second","profile":\#(profile)},{"name":"Third","profile":\#(profile)},{"name":"Fourth","profile":\#(profile)}]}"#
        let bytes = Data(json.utf8), doc = try AndroidProfileDocument.parse(bytes)
        let result = try AndroidProfileImportPlan.prepare(doc, archiveID: UUID())
        XCTAssertEqual(result.convertedControlCount, 256)
        XCTAssertLessThanOrEqual(result.issues.count, 501)
        XCTAssertTrue(result.issues.last?.message.contains("additional notes") == true)
        XCTAssertEqual(doc.exportOriginalData(), bytes)
    }
    func testUnsupportedControlNameCannotMakeUnboundedPreviewText() throws {
        let source = control(type: "FUTURE", extra: ",\"name\":\"" + String(repeating: "x", count: 5_000) + "\"")
        let result = try plan([source])
        XCTAssertTrue(result.issues.allSatisfy { $0.message.count <= 1_025 })
        XCTAssertEqual(result.archivedOnlyControlCount, 1)
    }
    func testReleaseAllImportsAsImmediateSafetyActionWhileOriginalInactiveModesRemainExact() throws {
        let original = Data(#"{"name":"Safety","pages":[{"id":"page","name":"Main","controls":[{"id":"release","name":"Release","type":"BUTTON","payload":"RELEASE_ALL","holdToggle":true,"autoTapEnabled":true,"buttonAimEnabled":true,"x":1,"y":1,"w":44,"h":44}]}]}"#.utf8)
        let document = try AndroidProfileDocument.parse(original)
        let plan = try AndroidProfileImportPlan.prepare(document, archiveID: UUID())
        let c = try XCTUnwrap(plan.profiles.first?.profile.controls.first)
        XCTAssertTrue(c.isReleaseAllAction); XCTAssertFalse(c.buttonBehavior.holdToggle); XCTAssertFalse(c.autoTapEnabled); XCTAssertFalse(c.isAdvancedButton)
        XCTAssertEqual(document.exportOriginalData(), original)
    }

}

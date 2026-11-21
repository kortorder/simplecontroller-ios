import XCTest
@testable import ControllerCore

final class TouchAimStageTuningTests: XCTestCase {
    func testDwellConfirmsStationaryHighWithoutFiringSkippedPress() throws {
        var settings = TouchAimSettings()
        settings.threeStage.low.payload = "X360A"
        settings.threeStage.smoothing = 1
        settings.threeStage.high.tuning = .init(sensitivity: 0.137, confirmationMilliseconds: 150)
        settings.threeStage.aimOnlyTuning.confirmationMilliseconds = 100
        var detector = try TouchAimDetector(settings: settings)
        XCTAssertTrue(try detector.begin(metrics: .init(majorRadius: 8)).isEmpty)
        XCTAssertEqual(detector.level, .aimOnly)
        XCTAssertTrue(try detector.tick(at: 0.149).isEmpty)
        XCTAssertEqual(try detector.tick(at: 0.15), [.holdStage(.medium), .holdStage(.high)])
        XCTAssertTrue(try detector.observe(metrics: .init(majorRadius: 0), at: 0.20).isEmpty)
        XCTAssertEqual(detector.level, .high)
        XCTAssertTrue(try detector.observe(metrics: .init(majorRadius: 8), at: 0.25).isEmpty)
        XCTAssertNil(detector.nextDeadline)
        XCTAssertTrue(try detector.observe(metrics: .init(majorRadius: 0), at: 0.31).isEmpty)
        XCTAssertEqual(try detector.tick(at: 0.41), [.releaseStage(.high), .releaseStage(.medium)])
    }

    func testPreciseSensitivityFollowsConfirmedStageForSameFinger() throws {
        var settings = TouchAimSettings()
        settings.aim.output = .mouse
        settings.aim.mouseResponse = .linearRelative
        settings.aim.sensitivity = 1
        settings.threeStage.smoothing = 1
        settings.threeStage.medium.tuning = .init(sensitivity: 0.137, confirmationMilliseconds: 100)
        let id = UUID()
        var runtime = try TouchAimRuntime(configurations: [id: settings])
        func sample(_ x: Double, _ radius: Double, _ t: Double) -> TouchAimSample {
            .init(pointer: .init(x: x, y: 30, width: 200, height: 100), metrics: .init(majorRadius: radius), elapsed: t)
        }
        XCTAssertTrue(try runtime.begin(contact: 1, id: id, sample: sample(20, 1, 0), time: 0, occupied: [], retained: []))
        XCTAssertEqual(try runtime.move(contact: 1, samples: [sample(30, 4.5, 0.01)], time: 0.01).first?.dx, 10)
        try runtime.advance(to: 0.11)
        XCTAssertEqual(try XCTUnwrap(runtime.move(contact: 1, samples: [sample(40, 4.5, 0.12)], time: 0.12).first).dx, 1.37, accuracy: 0.000001)
        _ = try runtime.move(contact: 1, samples: [sample(50, 0, 0.13)], time: 0.13)
        XCTAssertEqual(try runtime.move(contact: 1, samples: [sample(60, 0, 0.14)], time: 0.14).first?.dx, 10)
    }

    func testAndroidTransferPreservesTuningAndOriginalAndRequiresItsVersion() throws {
        func bytes(_ format: Int) -> Data {
            Data("""
            {"formatVersion":\(format),"homePageId":"p","pages":[{"id":"p","name":"Walk","controls":[
            {"id":"t","type":"TOUCH_AIM","x":10,"y":20,"w":100,"h":100,"payload":"TOUCH_AIM",
            "touchLowSensitivity":null,"touchMediumSensitivity":0.137,"touchHighEnterConfirmationMs":125,
            "unknown":9007199254740993}]}]}
            """.utf8)
        }
        XCTAssertThrowsError(try AndroidProfileDocument.parse(bytes(13)))
        let document = try AndroidProfileDocument.parse(bytes(14))
        var profile = try XCTUnwrap(AndroidProfileImportPlan.prepare(document, archiveID: UUID()).profiles.first?.profile)
        let stage = profile.controls[0].touchAim.threeStage
        XCTAssertTrue(profile.controls[0].touchAim.requiresLocalSetup)
        XCTAssertNil(stage.low.tuning.sensitivity)
        XCTAssertEqual(stage.medium.tuning.sensitivity, 0.137)
        XCTAssertEqual(stage.high.tuning.confirmationMilliseconds, 125)
        let original = AndroidEditedExportPreview.prepare(profile: profile, original: document, source: profile.androidSources[0])
        XCTAssertEqual(original.data, bytes(14))
        profile.controls[0].touchAim.threeStage.medium.tuning.sensitivity = nil
        profile.controls[0].touchAim.threeStage.high.tuning.confirmationMilliseconds = 250
        let edited = AndroidEditedExportPreview.prepare(profile: profile, original: document, source: profile.androidSources[0])
        let updated = try AndroidProfileDocument.parse(XCTUnwrap(edited.data))
        let control = try XCTUnwrap(updated.profiles.first?.pages.first?.controls.first?.value)
        XCTAssertEqual(control["touchMediumSensitivity"], .null)
        XCTAssertEqual(control["touchHighEnterConfirmationMs"]?.numberValue?.rawValue, "250")
        XCTAssertEqual(control["unknown"]?.numberValue?.rawValue, "9007199254740993")
    }
}

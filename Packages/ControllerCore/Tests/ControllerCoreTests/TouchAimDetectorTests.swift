import Foundation
import XCTest
@testable import ControllerCore

final class TouchAimDetectorTests: XCTestCase {
    private func metrics(_ radius:Double)->TouchMetrics { .init(majorRadius:radius,radiusTolerance:0.5) }
    private func two(_ behavior:TouchAimShootBehavior = .hold)throws->TwoStateTouchAimDetector {
        try .init(configuration:.init(shootOn:5,shootOff:4,smoothing:1,enterMilliseconds:90,returnMilliseconds:120,behavior:behavior,hasAimPayload:true,hasShootPayload:true,keepAimWhileShooting:false))
    }
    func testMissingForceNeverBecomesSyntheticForceOrTransientAimPress() throws {
        let settings=TouchAimSettings(mode:.manualTwoState,metric:.normalizedForce,twoState:.init(aimPayload:"X360A"))
        var d=try TouchAimDetector(settings:settings)
        XCTAssertTrue(try d.begin(metrics:metrics(10)).isEmpty);XCTAssertEqual(d.state,.unavailable)
        XCTAssertTrue(try XCTUnwrap(d.issue).contains("supported force"));XCTAssertNil(d.nextDeadline)
    }
    func testRadiusToleranceIsNotAnIndependentActivationSignal() throws {
        var d=try TouchAimDetector(settings:.init(threeStage:.init(smoothing:1)))
        _ = try d.begin(metrics:.init(majorRadius:1,radiusTolerance:100))
        XCTAssertEqual(d.level,.aimOnly);XCTAssertEqual(d.filteredScore,1)
    }
    func testThreeStageCumulativeHoldsAndUpwardPresses() throws {
        var settings=TouchAimSettings();settings.threeStage.smoothing=1;settings.threeStage.low.payload="X360A"
        var d=try TouchAimDetector(settings:settings)
        XCTAssertEqual(try d.begin(metrics:metrics(6)),[.holdStage(.medium),.holdStage(.high),.pressStage(.low)])
        XCTAssertEqual(d.level,.high)
        XCTAssertEqual(try d.observe(metrics:metrics(3),at:0.1),[.releaseStage(.high),.releaseStage(.medium)])
        XCTAssertEqual(try d.observe(metrics:metrics(6),at:0.2),[.holdStage(.medium),.holdStage(.high)])
        XCTAssertEqual(d.end(),[.releaseStage(.high),.releaseStage(.medium)])
    }
    func testThreeStageCanKeepOnlyCurrentHold() throws {
        let settings=TouchAimSettings(threeStage:.init(low:.init(threshold:2,payload:"X360A"),smoothing:1,keepLowerHolds:false))
        var d=try TouchAimDetector(settings:settings)
        XCTAssertEqual(try d.begin(metrics:metrics(2)),[.holdStage(.low)])
        XCTAssertEqual(try d.observe(metrics:metrics(6),at:0.1),[.releaseStage(.low),.holdStage(.high)])
    }
    func testDescendingHysteresisCannotPromoteToHigherStage() throws {
        let s=TouchAimSettings(threeStage:.init(low:.init(threshold:2),medium:.init(threshold:2.01),high:.init(threshold:2.02),smoothing:1,hysteresis:0.25))
        var d=try TouchAimDetector(settings:s);_ = try d.begin(metrics:metrics(2));XCTAssertEqual(d.level,.low)
        _ = try d.observe(metrics:metrics(1.9),at:0.1);XCTAssertEqual(d.level,.low)
    }
    func testThreeStageSourcePerSampleSmoothingAndInclusiveBoundaries() throws {
        var d=try TouchAimDetector(settings:.init())
        _ = try d.begin(metrics:metrics(0));_ = try d.observe(metrics:metrics(10),at:0.020)
        XCTAssertEqual(d.filteredScore,3.5);XCTAssertEqual(d.level,.low)
        _ = try d.observe(metrics:metrics(10),at:0.040);XCTAssertEqual(d.filteredScore,5.775,accuracy:1e-12);XCTAssertEqual(d.level,.high)
    }
    func testTwoStateConfirmationHoldsReleaseAndRestore() throws {
        var d=try two();XCTAssertEqual(try d.begin(),[.holdAim]);XCTAssertTrue(try d.observe(score:5,at:0).isEmpty)
        XCTAssertEqual(d.nextDeadline,0.09);XCTAssertEqual(try d.tick(at:0.09),[.releaseAim,.holdShoot]);XCTAssertEqual(d.state,.shoot)
        _ = try d.observe(score:4,at:0.1);XCTAssertEqual(try d.tick(at:0.22),[.releaseShoot,.holdAim]);XCTAssertEqual(d.state,.aim)
    }
    func testTwoStateNoiseCancelsUncompletedConfirmation() throws {
        var d=try two();_ = try d.begin();_ = try d.observe(score:6,at:0);_ = try d.observe(score:4.99,at:0.08)
        XCTAssertNil(d.nextDeadline);XCTAssertTrue(try d.tick(at:1).isEmpty);XCTAssertEqual(d.state,.aim)
    }
    func testTwoStateSmoothingUsesElapsedTimeAndDuplicateSamplesDoNotMoveIt() throws {
        var d=try TwoStateTouchAimDetector(configuration:.init(shootOn:100,shootOff:90,smoothing:0.35))
        _ = try d.begin();_ = try d.observe(score:0,at:0);_ = try d.observe(score:10,at:0.02);XCTAssertEqual(d.filteredScore,3.5,accuracy:1e-12)
        _ = try d.observe(score:1000,at:0.02);XCTAssertEqual(d.filteredScore,3.5,accuracy:1e-12)
        _ = try d.observe(score:10,at:0.06);XCTAssertEqual(d.filteredScore,10-6.5*pow(0.65,2),accuracy:1e-12)
    }
    func testPressOnEnterDoesNotHoldShoot() throws {
        var d=try two(.pressOnEnter);_ = try d.begin();_ = try d.observe(score:6,at:0)
        XCTAssertEqual(try d.tick(at:0.09),[.releaseAim,.pressShoot]);XCTAssertTrue(d.end().isEmpty)
    }
    func testPressOnReturnRequiresObservedReturnAndNeverTerminalEvent() throws {
        var d=try two(.pressOnReturn);_ = try d.begin();_ = try d.observe(score:6,at:0);_ = try d.tick(at:0.09)
        XCTAssertFalse(d.end().contains(.pressShoot))
        _ = try d.begin();_ = try d.observe(score:6,at:0);_ = try d.tick(at:0.09);_ = try d.observe(score:4,at:0.1)
        XCTAssertEqual(try d.tick(at:0.22),[.pressShoot,.holdAim]);XCTAssertFalse(try d.tick(at:1).contains(.pressShoot))
    }
    func testInvalidMetricsAndBackwardsSamplesRejectBeforeMutation() throws {
        var d=try TouchAimDetector(settings:.init());_ = try d.begin(metrics:metrics(3),at:1)
        XCTAssertThrowsError(try d.observe(metrics:metrics(.nan),at:2));XCTAssertEqual(d.filteredScore,3)
        XCTAssertThrowsError(try d.observe(metrics:metrics(5),at:0.9));XCTAssertEqual(d.filteredScore,3)
        XCTAssertFalse(TouchMetrics(normalizedForce:1.01).isValid);XCTAssertFalse(TouchMetrics(majorRadius:-1).isValid)
    }
    func testNoOutputInspectorIsBoundedAndReportsAvailabilityHonestly() throws {
        var inspector=TouchAimInspector();for i in 0..<300 { try inspector.observe(metrics(Double(i))) }
        XCTAssertEqual(inspector.sampleCount,256);XCTAssertNil(inspector.summaries[.normalizedForce]);XCTAssertEqual(inspector.summaries[.majorRadius]?.minimum,44)
        XCTAssertThrowsError(try inspector.observe(.init(radiusTolerance:.infinity)));XCTAssertEqual(inspector.sampleCount,256)
        inspector.reset();XCTAssertTrue(inspector.summaries.isEmpty)
    }
    func testRawSamplesAreSeparateFromStrictPersistedSettings() throws {
        let s=TouchAimSettings();let data=try JSONEncoder().encode(s);XCTAssertEqual(try JSONDecoder().decode(TouchAimSettings.self,from:data),s)
        let text=String(decoding:data,as:UTF8.self);XCTAssertFalse(text.contains("recordedSamples"));XCTAssertFalse(text.contains("radiusTolerance"))
        var object=try JSONSerialization.jsonObject(with:data) as! [String:Any];object["rawSamples"]=[]
        XCTAssertThrowsError(try JSONDecoder().decode(TouchAimSettings.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    func testCalibratedModeRequiresNativeQualityAndSeparateValidation() throws {
        XCTAssertThrowsError(try TouchAimSettings(mode:.calibratedTwoState).validate())
        let t=TouchAimSensorTransform(metric:.majorRadius,center:2,scale:1)
        var c=TouchAimCalibrationProfile(transforms:[t],quality:.good)
        XCTAssertFalse(c.isApplicable);XCTAssertThrowsError(try TouchAimSettings(mode:.calibratedTwoState,calibration:c).validate())
        c.validationCompleted=true;XCTAssertTrue(c.isApplicable)
        XCTAssertNoThrow(try TouchAimSettings(mode:.calibratedTwoState,calibration:c).validate())
        c.quality = .unreliable;XCTAssertFalse(c.isApplicable)
    }
}

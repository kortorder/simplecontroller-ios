import Foundation
import XCTest
@testable import ControllerCore

final class TouchAimCalibrationTests: XCTestCase {
    private func pass(_ label:TouchAimCalibrationLabel,_ repetition:Int,radius:Double,force:Double?=nil)->TouchAimCalibrationPass {
        let samples=(0..<40).map { i in
            TouchAimCalibrationSample(metrics:.init(majorRadius:radius+sin(Double(i))*0.05,radiusTolerance:0.25,normalizedForce:force),elapsed:Double(i)/39,moving:i>=20)
        }
        return .init(label:label,repetition:repetition,samples:samples,duration:1)
    }
    private func goodPasses()->[TouchAimCalibrationPass] { [pass(.aim,0,radius:2),pass(.shoot,0,radius:6),pass(.aim,1,radius:2.02),pass(.shoot,1,radius:6.02)] }
    func testSeparatedRadiusPassesProduceUnappliedNativeRecommendation() throws {
        let result=try TouchAimCalibrationAnalyzer.analyze(goodPasses())
        XCTAssertEqual(result.profile.quality,.good);XCTAssertFalse(result.profile.isApplicable)
        XCTAssertEqual(result.profile.transforms.map(\.metric),[.majorRadius]);XCTAssertEqual(result.profile.summaries.count,4)
        XCTAssertEqual(result.profile.falseActivationRate,0);XCTAssertFalse(result.profile.validationCompleted)
    }
    func testSeparateValidationIsRequiredAndCanApproveTheDetector() throws {
        let trained=try TouchAimCalibrationAnalyzer.analyze(goodPasses()).profile
        let result=try TouchAimCalibrationAnalyzer.validate(trained,passes:[pass(.aim,2,radius:2.01),pass(.shoot,2,radius:6.01)])
        XCTAssertTrue(result.report.passed);XCTAssertTrue(result.profile.isApplicable);XCTAssertFalse(trained.isApplicable)
        var detector=try TouchAimDetector(settings:.init(mode:.calibratedTwoState,calibration:result.profile))
        _ = try detector.begin(metrics:.init(majorRadius:6));_ = try detector.tick(at:0.2);XCTAssertEqual(detector.state,.shoot)
    }
    func testFreshValidationWithAccidentalShootRemainsUnavailable() throws {
        let trained=try TouchAimCalibrationAnalyzer.analyze(goodPasses()).profile
        let result=try TouchAimCalibrationAnalyzer.validate(trained,passes:[pass(.aim,2,radius:6),pass(.shoot,2,radius:6)])
        XCTAssertFalse(result.report.passed);XCTAssertFalse(result.profile.isApplicable);XCTAssertGreaterThan(result.report.unexpectedTransitions,0)
    }
    func testConstantOrReversedMetricsCannotProduceUsableCalibration() throws {
        let constant=[pass(.aim,0,radius:2),pass(.shoot,0,radius:2),pass(.aim,1,radius:2),pass(.shoot,1,radius:2)]
        XCTAssertEqual(try TouchAimCalibrationAnalyzer.analyze(constant).profile.quality,.unreliable)
        let reversed=[pass(.aim,0,radius:2),pass(.shoot,0,radius:6),pass(.aim,1,radius:6),pass(.shoot,1,radius:2)]
        XCTAssertEqual(try TouchAimCalibrationAnalyzer.analyze(reversed).profile.quality,.unreliable)
    }
    func testIncompleteInvalidAndDuplicatePassesAreExplicitlyInsufficient() throws {
        XCTAssertEqual(try TouchAimCalibrationAnalyzer.analyze([]).profile.quality,.insufficient)
        var passes=goodPasses();passes[0].completed=false
        XCTAssertEqual(try TouchAimCalibrationAnalyzer.analyze(passes).profile.quality,.insufficient)
        passes=goodPasses();passes[0].samples[1].elapsed = -1
        XCTAssertEqual(try TouchAimCalibrationAnalyzer.analyze(passes).profile.quality,.insufficient)
        passes=goodPasses();passes[2]=passes[0]
        XCTAssertEqual(try TouchAimCalibrationAnalyzer.analyze(passes).profile.quality,.insufficient)
    }
    func testTrainingAndValidationNeedMovingAndStillCoverage() throws {
        var passes=goodPasses();passes[0].samples=passes[0].samples.map { var s=$0;s.moving=false;return s }
        XCTAssertEqual(try TouchAimCalibrationAnalyzer.analyze(passes).profile.quality,.insufficient)
        let trained=try TouchAimCalibrationAnalyzer.analyze(goodPasses()).profile
        XCTAssertThrowsError(try TouchAimCalibrationAnalyzer.validate(trained,passes:[passes[0],passes[1]]))
    }
    func testUnavailableForceIsNotInventedOrUsedAsASecondMetric() throws {
        let result=try TouchAimCalibrationAnalyzer.analyze(goodPasses()).profile
        XCTAssertEqual(result.transforms.map(\.metric),[.majorRadius])
        let force=TouchAimCalibrationProfile(transforms:[.init(metric:.normalizedForce,center:0.2,scale:0.1)],quality:.good)
        XCTAssertThrowsError(try TouchAimCalibrationAnalyzer.validate(force,passes:[pass(.aim,2,radius:2),pass(.shoot,2,radius:6)]))
    }
    func testPersistedCalibrationContainsSummariesButNoRawObservations() throws {
        let profile=try TouchAimCalibrationAnalyzer.analyze(goodPasses()).profile
        let data=try JSONEncoder().encode(profile),text=String(decoding:data,as:UTF8.self)
        XCTAssertEqual(try JSONDecoder().decode(TouchAimCalibrationProfile.self,from:data),profile)
        XCTAssertFalse(text.contains("radiusTolerance"));XCTAssertFalse(text.contains("samples"));XCTAssertFalse(text.contains("elapsed"))
        XCTAssertTrue(text.contains("sampleCount"));XCTAssertTrue(text.contains("radiusMedian"))
    }
}

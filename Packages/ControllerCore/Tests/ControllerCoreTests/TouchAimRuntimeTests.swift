import Foundation
import XCTest
@testable import ControllerCore

final class TouchAimRuntimeTests:XCTestCase {
    private let id=UUID()
    private func sample(_ radius:Double=1,_ elapsed:Double=0,x:Double=100,y:Double=100)->TouchAimSample {
        .init(pointer:.init(x:x,y:y,width:200,height:200),metrics:.init(majorRadius:radius),elapsed:elapsed)
    }
    private func runtime(_ settings:TouchAimSettings = .init())throws->TouchAimRuntime { try .init(configurations:[id:settings]) }
    private func start(_ runtime:inout TouchAimRuntime,_ radius:Double=1)throws {
        XCTAssertTrue(try runtime.begin(contact:1,id:id,sample:sample(radius),time:10,occupied:[],retained:[]))
    }
    func testIndependentStageLeasesReleaseOnlyDepartingStageAndMaxAcrossInstances() throws {
        var s=TouchAimSettings();s.threeStage.smoothing=1
        s.threeStage.low = .init(threshold:2,payload:"RT:0.8",action:.hold)
        s.threeStage.medium = .init(threshold:4,payload:"RT:0.3",action:.hold)
        let other=UUID();var r=try TouchAimRuntime(configurations:[id:s,other:s])
        try start(&r,4);XCTAssertEqual(r.claims(at:10).claims.pressure[.right],0.3)
        XCTAssertTrue(try r.begin(contact:2,id:other,sample:sample(2),time:10,occupied:[],retained:[]))
        XCTAssertEqual(r.claims(at:10).claims.pressure[.right],0.8)
        r.end(contact:2);XCTAssertEqual(r.claims(at:10).claims.pressure[.right],0.3)
        _ = try r.move(contact:1,samples:[sample(2,0.1)],time:10.1)
        XCTAssertEqual(r.claims(at:10.1).claims.pressure[.right],0.8)
    }
    func testThreeStagePressHasNinetyMillisecondLeaseAndDoesNotRepeatAtLevel() throws {
        var s=TouchAimSettings();s.threeStage.low.payload="X360A";s.threeStage.smoothing=1
        var r=try runtime(s);try start(&r,2)
        XCTAssertTrue(r.claims(at:10).claims.actions.contains(.a));XCTAssertEqual(r.nextDeadline(after:10),10.09)
        try r.advance(to:10.09);XCTAssertFalse(r.claims(at:10.09).claims.actions.contains(.a))
        _ = try r.move(contact:1,samples:[sample(3,0.1)],time:10.1)
        XCTAssertFalse(r.claims(at:10.1).claims.actions.contains(.a))
    }
    func testLateConfirmationDoesNotReplayExpiredPress() throws {
        let s=TouchAimSettings(mode:.manualTwoState,twoState:.init(smoothing:1,shootBehavior:.pressOnEnter))
        var r=try runtime(s);try start(&r,6);try r.advance(to:11)
        XCTAssertEqual(r.states[id],.shoot);XCTAssertFalse(r.claims(at:11).claims.hasOutput);XCTAssertNil(r.nextDeadline(after:11))
    }
    func testHeldConfirmationCanMatureWithoutMovement() throws {
        var r=try runtime(.init(mode:.manualTwoState,twoState:.init(smoothing:1)));try start(&r,6)
        XCTAssertEqual(r.nextDeadline(after:10),10.09);try r.advance(to:10.09)
        XCTAssertEqual(r.claims(at:10.09).claims.pressure[.right],1)
    }
    func testCoalescedLowSampleCancelsOverdueHighCandidateBeforeTimer() throws {
        var r=try runtime(.init(mode:.manualTwoState,twoState:.init(smoothing:1)));try start(&r,6)
        _ = try r.move(contact:1,samples:[sample(6,0.10),sample(1,0.11)],time:10.2)
        try r.advance(to:10.2)
        XCTAssertEqual(r.states[id],.aim);XCTAssertFalse(r.claims(at:10.2).claims.hasOutput)
    }
    func testObservationMayFollowTimerUsingEarlierSampleTimestampButNeverReverseSamples() throws {
        var r=try runtime(.init(mode:.manualTwoState,twoState:.init(smoothing:1)));try start(&r)
        try r.advance(to:10.1)
        _ = try r.move(contact:1,samples:[sample(2,0.08)],time:10.11)
        try r.advance(to:10.11)
        XCTAssertThrowsError(try r.move(contact:1,samples:[sample(3,0.07)],time:10.12))
        XCTAssertEqual(r.scores[id],2)
    }
    func testEntireInvalidBatchRejectsBeforeAnyMovementOrStageMutation() throws {
        var r=try runtime();try start(&r)
        var invalid=sample(6,0.2,x:150);invalid.metrics.majorRadius = .nan
        XCTAssertThrowsError(try r.move(contact:1,samples:[sample(6,0.1,x:120),invalid],time:10.2))
        XCTAssertEqual(r.scores[id],1);XCTAssertEqual(r.sessions[id]?.pointer.x,100)
        XCTAssertThrowsError(try r.move(contact:1,samples:Array(repeating:sample(),count:257),time:10.2))
    }
    func testMissingMetricNeutralizesWithoutFallbackOrPartialBatchMovement() throws {
        var r=try runtime();try start(&r,6)
        var missing=sample(1,0.2,x:140);missing.metrics = .init(normalizedForce:0.9)
        XCTAssertTrue(try r.move(contact:1,samples:[sample(6,0.1,x:120),missing],time:10.2).isEmpty)
        XCTAssertEqual(r.states[id],.unavailable);XCTAssertNotNil(r.issues[id]);XCTAssertFalse(r.claims(at:10.2).claims.hasOutput)
        XCTAssertTrue(r.active.isEmpty);XCTAssertNil(r.nextDeadline(after:10.2))
    }
    func testEndCancelsUnobservedConfirmationAndReturnShot() throws {
        var r=try runtime(.init(mode:.manualTwoState,twoState:.init(smoothing:1,shootBehavior:.pressOnReturn)));try start(&r,6)
        try r.advance(to:10.09);_ = try r.move(contact:1,samples:[sample(1,0.1)],time:10.1)
        r.end(contact:1);try r.advance(to:10.3)
        XCTAssertFalse(r.claims(at:10.3).claims.hasOutput);XCTAssertNil(r.nextDeadline(after:10.3))
    }
    func testAnalogueFirstOwnerAndRetainedTakeoverCentering() throws {
        var s=TouchAimSettings();s.aim.output = .leftStick
        var r=try runtime(s)
        XCTAssertFalse(try r.begin(contact:1,id:id,sample:sample(),time:10,occupied:[.leftStick],retained:[]))
        XCTAssertTrue(try r.begin(contact:1,id:id,sample:sample(x:150),time:10,occupied:[],retained:[]))
        try r.advance(to:10);XCTAssertEqual(r.analogs[id]?.position,.zero)
        _ = try r.move(contact:1,samples:[sample(1,0.1,x:150)],time:10.1)
        XCTAssertEqual(r.analogs[id]?.position.x,0.5)
        r.end(contact:1);XCTAssertTrue(r.analogs.isEmpty)
        XCTAssertTrue(try r.begin(contact:2,id:id,sample:sample(x:150),time:11,occupied:[],retained:[.leftStick]))
        XCTAssertEqual(r.analogs[id]?.position.x,0.5)
    }
    func testRecenterPreservesPayloadAndDisablesAnalogUntilNextTouch() throws {
        var s=TouchAimSettings();s.aim.output = .rightStick;s.threeStage.smoothing=1
        var r=try runtime(s);try start(&r,6)
        _ = try r.move(contact:1,samples:[sample(6,0.1,x:150)],time:10.1);r.recenter()
        _ = try r.move(contact:1,samples:[sample(6,0.2,x:180)],time:10.2)
        XCTAssertTrue(r.analogs.isEmpty);XCTAssertEqual(r.claims(at:10.2).claims.pressure[.right],1)
    }
    func testMouseIsLocalRelativeMovementAndSensitivityZeroDoesNotDisableStages() throws {
        var s=TouchAimSettings();s.aim.mouseResponse = .linearRelative;s.aim.sensitivity=2;s.threeStage.smoothing=1
        var r=try runtime(s);try start(&r)
        XCTAssertEqual(try r.move(contact:1,samples:[sample(6,0.1,x:103,y:96)],time:10.1),[.init(dx:6,dy:-8)])
        s.aim.sensitivity=0;r=try runtime(s);try start(&r,6)
        XCTAssertTrue(try r.move(contact:1,samples:[sample(6,0.1,x:120)],time:10.1).isEmpty)
        XCTAssertEqual(r.claims(at:10.1).claims.pressure[.right],1)
    }
    func testClearDropsAllSessionStateAndCalibrationIssues() throws {
        var r=try runtime(.init(metric:.normalizedForce));XCTAssertFalse(try r.begin(contact:1,id:id,sample:sample(),time:10,occupied:[],retained:[]))
        XCTAssertFalse(r.issues.isEmpty);r.clear();XCTAssertTrue(r.issues.isEmpty);XCTAssertTrue(r.states.isEmpty)
    }
    func testLeasePulseReplacesPriorPressureAndExpiresWithoutRestoringIt() throws {
        let lease=OwnedGesturePayloadLease(program:try .parse("RT:0.4,RT:1.0P0.3"),started:0)
        XCTAssertEqual(lease.claims(at:0.1).pressure[.right],1);XCTAssertNil(lease.claims(at:0.3).pressure[.right])
    }
    func testExplicitZeroInHigherStageOverridesLowerButNotIndependentInstance() throws {
        var s=TouchAimSettings();s.threeStage.smoothing=1
        s.threeStage.low = .init(threshold:2,payload:"RT:0.8",action:.hold)
        s.threeStage.medium = .init(threshold:4,payload:"RT:0.0",action:.hold)
        let other=UUID();var r=try TouchAimRuntime(configurations:[id:s,other:s]);try start(&r,4)
        XCTAssertNil(r.claims(at:10).claims.pressure[.right])
        XCTAssertTrue(try r.begin(contact:2,id:other,sample:sample(2),time:10,occupied:[],retained:[]))
        XCTAssertEqual(r.claims(at:10).claims.pressure[.right],0.8)
    }
    func testCompletedHigherStagePulseRestoresLowerStageLease() throws {
        var s=TouchAimSettings();s.threeStage.smoothing=1
        s.threeStage.low = .init(threshold:2,payload:"RT:0.4",action:.hold)
        s.threeStage.medium = .init(threshold:4,payload:"RT:1.0P0.3",action:.hold)
        var r=try runtime(s);try start(&r,4)
        XCTAssertEqual(r.claims(at:10).claims.pressure[.right],1)
        try r.advance(to:10.3);XCTAssertEqual(r.claims(at:10.3).claims.pressure[.right],0.4)
    }

}

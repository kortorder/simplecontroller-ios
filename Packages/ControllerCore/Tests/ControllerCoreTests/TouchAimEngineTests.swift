import Foundation
import XCTest
@testable import ControllerCore

final class TouchAimEngineTests:XCTestCase {
    private func profile(_ controls:[ProfileControl])throws->ControllerProfile {
        let points=controls.map{ProfilePlacement(id:$0.id,position:.init(x:0.5,y:0.5))}
        return try .init(controls:controls,portrait:points,landscape:points,turboEnabled:true,swipeMode:.controls)
    }
    private func sample(_ radius:Double=1,_ elapsed:Double=0,x:Double=100)->TouchAimSample {
        .init(pointer:.init(x:x,y:100,width:200,height:200),metrics:.init(majorRadius:radius),elapsed:elapsed)
    }
    private func control(_ output:ButtonAimOutput = .mouse)->ProfileControl {
        var c=ProfileControl(kind:.touchAim);c.touchAim.threeStage.smoothing=1;c.touchAim.aim.output=output
        return c
    }
    func testTouchAimOutputSharesDigitalKeyboardMouseAndPressureOwners() throws {
        var c=control();c.touchAim.threeStage.high.payload="RT:0.9,W,MOUSE_LEFT_DOWN,X360A"
        let b=ProfileControl(payload:"RT:0.3,W,MOUSE_LEFT_DOWN,X360A")
        var p=try profile([c,b]);p.turboEnabled=false
        var e=try ProfileInputEngine(profile:p);try e.begin(contact:2,control:b.id,at:0)
        try e.handle(.beginTouchAim(contact:1,control:c.id,sample:sample(6)),at:0)
        XCTAssertEqual(e.practiceState.rightTrigger,0.9);XCTAssertTrue(e.outputControls.contains(c.id))
        _=e.drainPracticeEvents();try e.cancel(contact:1,at:0.1)
        XCTAssertEqual(e.practiceState.rightTrigger,0.3);XCTAssertEqual(e.practiceState.heldKeys,[.w]);XCTAssertEqual(e.practiceState.heldMouseButtons,[.left])
        XCTAssertFalse(e.drainPracticeEvents().events.contains{if case .mouseUp = $0.kind{return true};return false})
        try e.end(contact:2,at:0.2);XCTAssertEqual(e.state,.neutral)
    }
    func testGlobalTurboCannotRepeatTouchAimStagePress() throws {
        var c=control();c.touchAim.threeStage.low.payload="X360A"
        var e=try ProfileInputEngine(profile:profile([c]));try e.beginTouchAim(contact:1,control:c.id,sample:sample(2),at:0)
        XCTAssertEqual(e.state.buttons,[.a]);try e.tick(at:0.1);XCTAssertEqual(e.state,.neutral);XCTAssertNil(e.nextDeadline)
    }
    func testTouchAimCurrentPageVisibilityAndPageChangeCancelPendingShoot() throws {
        var c=control();c.touchAim.mode = .manualTwoState;c.touchAim.twoState.smoothing=1
        var p=try profile([c]);let second=try p.addPage(name:"Other")
        var e=try ProfileInputEngine(profile:p);try e.beginTouchAim(contact:1,control:c.id,sample:sample(6),at:0)
        XCTAssertNotNil(e.nextDeadline);XCTAssertTrue(try e.selectPage(second,at:0.05));XCTAssertNil(e.nextDeadline)
        XCTAssertThrowsError(try e.beginTouchAim(contact:2,control:c.id,sample:sample(6),at:0.1))
        try e.tick(at:1);XCTAssertEqual(e.state,.neutral);XCTAssertTrue(e.touchAimStates.isEmpty)
    }
    func testDirectOnlyRoutingAndNoSyntheticAccessibilitySensor() throws {
        let c=control(),b=ProfileControl(actions:[.a]);let p=try profile([c,b])
        var e=try ProfileInputEngine(profile:p);try e.begin(contact:1,control:b.id,at:0)
        XCTAssertFalse(e.canHandoff(contact:1,to:c.id));XCTAssertThrowsError(try e.activate(c.id,at:0.1))
        XCTAssertThrowsError(try e.begin(contact:2,control:c.id,at:0.1))
        var r=try ProfileSwipeRouter(profile:p);try r.begin(contact:1,control:c.id,at:0)
        XCTAssertEqual(try r.decision(contact:1,hitControls:[b.id],at:0.1),.moveCurrent)
    }
    func testManualAndButtonAimCannotStealLiveTouchAimChannel() throws {
        let c=control(.leftStick),stick=ProfileControl(kind:.leftStick),button=ProfileControl(payload:"X360A",buttonAim:.init(enabled:true,tuning:.init(output:.leftStick)))
        var e=try ProfileInputEngine(profile:profile([c,stick,button]))
        try e.beginTouchAim(contact:1,control:c.id,sample:sample(),at:0)
        try e.moveTouchAimBatch(contact:1,samples:[sample(1,0.1,x:150)],at:0.1)
        try e.begin(contact:2,control:stick.id,position:.init(x:-1),at:0.2)
        XCTAssertFalse(e.isCapturedInputOwner(for:2));XCTAssertEqual(e.state.leftStick.x,0.5)
        try e.beginButton(contact:3,control:button.id,sample:.init(x:50,y:50,width:100,height:100),at:0.2)
        XCTAssertFalse(e.isCapturedInputOwner(for:3));XCTAssertEqual(e.state.leftStick.x,0.5)
        try e.end(contact:1,at:0.3);XCTAssertEqual(e.state.leftStick,.zero)
    }
    func testTouchAimCannotStealManualOrButtonAimChannel() throws {
        let c=control(.leftStick),stick=ProfileControl(kind:.leftStick),button=ProfileControl(payload:"X360A",buttonAim:.init(enabled:true,tuning:.init(output:.leftStick)))
        var e=try ProfileInputEngine(profile:profile([c,stick,button]));try e.begin(contact:1,control:stick.id,position:.init(x:0.7),at:0)
        try e.beginTouchAim(contact:2,control:c.id,sample:sample(),at:0.1)
        XCTAssertFalse(e.isCapturedInputOwner(for:2));XCTAssertEqual(e.state.leftStick.x,0.7)
        e.releaseAll();try e.beginButton(contact:1,control:button.id,sample:.init(x:50,y:50,width:100,height:100),at:0.2)
        try e.beginTouchAim(contact:2,control:c.id,sample:sample(),at:0.3);XCTAssertFalse(e.isCapturedInputOwner(for:2))
    }
    func testTouchAimRetainedTakeoverAndRecenterKeepIndependentButton() throws {
        let c=control(.rightStick),stick=ProfileControl(kind:.rightStick,stickBehavior:.init(autoCenter:false)),b=ProfileControl(actions:[.a])
        var p=try profile([c,stick,b]);p.turboEnabled=false;var e=try ProfileInputEngine(profile:p)
        try e.begin(contact:1,control:stick.id,position:.init(x:0.8),at:0);try e.end(contact:1,at:0.1)
        try e.beginTouchAim(contact:2,control:c.id,sample:sample(x:150),at:0.2)
        XCTAssertTrue(e.retainedSticks.isEmpty);XCTAssertEqual(e.state.rightStick.x,0.5)
        try e.begin(contact:3,control:b.id,at:0.3);e.recenterSticks()
        XCTAssertEqual(e.state.rightStick,.zero);XCTAssertEqual(e.state.buttons,[.a])
        try e.moveTouchAimBatch(contact:2,samples:[sample(1,0.2,x:180)],at:0.4);XCTAssertEqual(e.state.rightStick,.zero)
    }
    func testEndBeforeUnobservedDeadlineNeverCreatesReturnShotOrLateShoot() throws {
        var c=control();c.touchAim.mode = .manualTwoState;c.touchAim.twoState.smoothing=1;c.touchAim.twoState.shootBehavior = .pressOnEnter
        var e=try ProfileInputEngine(profile:profile([c]));try e.beginTouchAim(contact:1,control:c.id,sample:sample(6),at:0)
        try e.end(contact:1,at:1);XCTAssertEqual(e.state,.neutral);XCTAssertNil(e.nextDeadline)
        XCTAssertTrue(e.touchAimStates.isEmpty)
    }
    func testMissingForceProducesExplicitIssueWithoutCaptureOrAnyClaim() throws {
        var c=control();c.touchAim.metric = .normalizedForce
        var e=try ProfileInputEngine(profile:profile([c]));try e.beginTouchAim(contact:1,control:c.id,sample:sample(6),at:0)
        XCTAssertEqual(e.touchAimStates[c.id],.unavailable);XCTAssertNotNil(e.touchAimIssues[c.id]);XCTAssertFalse(e.isCapturedInputOwner(for:1));XCTAssertEqual(e.state,.neutral)
        try e.cancel(contact:1,at:0.1);XCTAssertNotNil(e.touchAimIssues[c.id]);XCTAssertEqual(e.touchAimStates[c.id],.unavailable)
        e.releaseAll();XCTAssertTrue(e.touchAimIssues.isEmpty)
    }
    func testAtomicBatchInvalidatesShootBeforeDelayedTimerAndRejectsBadSamples() throws {
        var c=control();c.touchAim.mode = .manualTwoState;c.touchAim.twoState.smoothing=1
        var e=try ProfileInputEngine(profile:profile([c]));try e.beginTouchAim(contact:1,control:c.id,sample:sample(6),at:0)
        try e.moveTouchAimBatch(contact:1,samples:[sample(6,0.1),sample(1,0.12)],at:0.2)
        XCTAssertEqual(e.touchAimStates[c.id],.aim);XCTAssertEqual(e.state,.neutral)
        var bad=sample(6,0.3);bad.metrics.majorRadius = .infinity
        XCTAssertThrowsError(try e.moveTouchAimBatch(contact:1,samples:[sample(6,0.25),bad],at:0.3));XCTAssertEqual(e.touchAimScores[c.id],1)
    }
    func testMouseAimIgnoresTouchpadScrollSwitchAndCancelDoesNotMove() throws {
        var c=control();c.touchAim.aim.mouseResponse = .linearRelative
        let toggle=ProfileControl(payload:"SCROLL_MODE_TOGGLE")
        var e=try ProfileInputEngine(profile:profile([c,toggle]));try e.activate(toggle.id,at:0)
        try e.beginTouchAim(contact:1,control:c.id,sample:sample(),at:0)
        try e.moveTouchAimBatch(contact:1,samples:[sample(1,0.1,x:110)],at:0.1)
        XCTAssertEqual(e.practiceState.pointerOffset.dx,10);XCTAssertEqual(e.practiceState.scrollOffset,0)
        try e.cancel(contact:1,at:0.2);XCTAssertEqual(e.practiceState.pointerOffset.dx,10)
        e.releaseAll();XCTAssertEqual(e.practiceState,.neutral)
    }
    func testApplyProfileClearsEveryTouchAimOwnerAndPendingConfirmation() throws {
        var c=control();c.touchAim.mode = .manualTwoState
        let p=try profile([c]);var e=try ProfileInputEngine(profile:p);try e.beginTouchAim(contact:1,control:c.id,sample:sample(6),at:0)
        try e.apply(profile:p);XCTAssertTrue(e.activeTouchAims.isEmpty);XCTAssertNil(e.nextDeadline);XCTAssertEqual(e.state,.neutral)
    }
}

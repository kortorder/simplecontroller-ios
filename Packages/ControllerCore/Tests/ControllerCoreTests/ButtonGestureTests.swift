import Foundation
import XCTest
@testable import ControllerCore

final class ButtonGestureTests: XCTestCase {
    private func profile(_ controls:[ProfileControl], turbo:Bool=false) throws -> ControllerProfile {
        let placements=controls.map{ProfilePlacement(id:$0.id,position:.init(x:0.5,y:0.5))}
        return try ControllerProfile(controls:controls,portrait:placements,landscape:placements,turboEnabled:turbo,swipeMode:.controls)
    }
    private func point(_ x:Double=50,_ y:Double=50)->ButtonPointerSample { .init(x:x,y:y,width:100,height:100) }
    private func aim(_ payload:String="X360A",timing:ButtonAimPayloadTiming = .immediate,hold:Bool=false,
                     output:ButtonAimOutput = .mouse,retained:Bool=false,alternate:Bool=false)->ProfileControl {
        .init(payload:payload,buttonAim:.init(enabled:true,payloadTiming:timing,tuning:.init(output:output,autoCenter:!retained),alternate:.init(enabled:alternate,payload:alternate ? "X360B":"")))
    }
    private func start(_ e:inout ProfileInputEngine,_ c:ProfileControl,_ t:Double=0,_ token:Int=1,_ sample:ButtonPointerSample?=nil)throws {
        try e.beginButton(contact:token,control:c.id,sample:sample ?? point(),at:t)
    }
    func testDirectionalStagesAreCumulativeAndIndependentFromBase() throws {
        var c=ProfileControl(actions:[.a],buttonDirectional:.init(enabled:true))
        c.buttonDirectional.directions[.right] = .init(firstDistance:48,secondDistance:96,firstPayload:"X360B",secondPayload:"X360X")
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c)
        XCTAssertEqual(e.state.buttons,[.a])
        try e.moveButtonBatch(contact:1,samples:[point(98)],at:0.1);XCTAssertEqual(e.state.buttons,[.a,.b])
        try e.moveButtonBatch(contact:1,samples:[point(146)],at:0.2);XCTAssertEqual(e.state.buttons,[.a,.b,.x])
        try e.moveButtonBatch(contact:1,samples:[point(142)],at:0.3);XCTAssertEqual(e.state.buttons,[.a,.b,.x])
        try e.moveButtonBatch(contact:1,samples:[point(141)],at:0.4);XCTAssertEqual(e.state.buttons,[.a,.b])
        try e.end(contact:1,at:0.5);XCTAssertEqual(e.state,.neutral)
    }
    func testDirectionalOppositeJumpNeverKeepsWrongDirection() throws {
        let settings=ButtonDirectionalSettings()
        let right=try settings.selection(dx:100,dy:0)
        XCTAssertEqual(right,.init(direction:.right,stage:2))
        XCTAssertEqual(try settings.selection(dx:-100,dy:0,previous:right),.init(direction:.left,stage:2))
    }
    func testDirectionalAxisHysteresisAndThresholdBoundaries() throws {
        let s=ButtonDirectionalSettings(),right=ButtonDirectionalSelection(direction:.right,stage:1)
        XCTAssertEqual(try s.selection(dx:60,dy:70,previous:right).direction,.right)
        XCTAssertEqual(try s.selection(dx:60,dy:72,previous:right).direction,.down)
        XCTAssertEqual(try s.selection(dx:44,dy:0,previous:right).stage,1)
        XCTAssertEqual(try s.selection(dx:43.9,dy:0,previous:right).stage,0)
        XCTAssertEqual(try s.selection(dx:47.9,dy:0).stage,0)
    }
    func testDirectionalOwnedKeyboardStageKeepsIndependentHold() throws {
        let plain=ProfileControl(payload:"W")
        var c=ProfileControl(buttonDirectional:.init(enabled:true));c.buttonDirectional.directions[.up]?.firstPayload="W,SHIFT"
        var e=try ProfileInputEngine(profile:profile([plain,c]));try e.begin(contact:2,control:plain.id,at:0);try start(&e,c,0.1)
        try e.moveButtonBatch(contact:1,samples:[point(50,0)],at:0.2)
        XCTAssertEqual(e.practiceState.heldKeys,[.w,.leftShift])
        try e.cancel(contact:1,at:0.3);XCTAssertEqual(e.practiceState.heldKeys,[.w])
    }
    func testImmediateAimStartsOnDownAndReleasesNormally() throws {
        let c=aim();var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c)
        XCTAssertEqual(e.state.buttons,[.a]);XCTAssertEqual(e.buttonAimStates[c.id],.aiming)
        try e.end(contact:1,at:0.1);XCTAssertEqual(e.state,.neutral)
    }
    func testAimHoldToggleStartsImmediatelyThenLatchesAndClears() throws {
        var c=aim();c.buttonBehavior = .init(holdToggle:true,holdMilliseconds:500)
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c)
        XCTAssertEqual(e.state.buttons,[.a]);try e.tick(at:0.5);XCTAssertTrue(e.latchedControls.contains(c.id))
        try e.end(contact:1,at:0.6);XCTAssertEqual(e.state.buttons,[.a])
        try start(&e,c,0.7);XCTAssertTrue(e.state.buttons.isEmpty)
        try e.end(contact:1,at:0.8);XCTAssertTrue(e.state.buttons.isEmpty)
    }
    func testSendOnReleaseUsesNinetyMillisecondOwnedPress() throws {
        let c=aim(timing:.sendOnRelease);var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c)
        XCTAssertTrue(e.state.buttons.isEmpty);try e.end(contact:1,at:0.1);XCTAssertEqual(e.state.buttons,[.a])
        try e.tick(at:0.189);XCTAssertEqual(e.state.buttons,[.a]);try e.tick(at:0.19);XCTAssertTrue(e.state.buttons.isEmpty)
    }
    func testDelayedHoldReadinessDoesNotEmitOrLatchBeforeLift() throws {
        var c=aim(timing:.sendOnRelease);c.buttonBehavior = .init(holdToggle:true)
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.tick(at:0.5)
        XCTAssertTrue(e.state.buttons.isEmpty);XCTAssertFalse(e.latchedControls.contains(c.id));XCTAssertEqual(e.buttonAimStates[c.id],.latchReady)
        try e.end(contact:1,at:0.6);XCTAssertTrue(e.latchedControls.contains(c.id));try e.tick(at:3);XCTAssertEqual(e.state.buttons,[.a])
    }
    func testCancelBeforeOverdueHoldNeverLatchesOrFires() throws {
        var c=aim(timing:.sendOnRelease);c.buttonBehavior = .init(holdToggle:true)
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.cancel(contact:1,at:5)
        XCTAssertEqual(e.state,.neutral);XCTAssertTrue(e.latchedControls.isEmpty);XCTAssertNil(e.nextDeadline)
    }
    func testReleaseDelayHoldsFinalAimUntilFire() throws {
        var c=aim(timing:.sendOnRelease,output:.rightStick);c.buttonAim.releaseDelayMilliseconds=200;c.buttonAim.tuning.origin = .controlCenter
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c,0,1,point(100));try e.end(contact:1,at:0.1)
        XCTAssertEqual(e.state.rightStick.x,1);XCTAssertTrue(e.state.buttons.isEmpty)
        try e.tick(at:0.3);XCTAssertEqual(e.state.rightStick,.zero);XCTAssertEqual(e.state.buttons,[.a]);try e.tick(at:0.39);XCTAssertEqual(e.state,.neutral)
    }
    func testLateDelayedTickDoesNotReplayExpiredFinitePress() throws {
        var c=aim(timing:.sendOnRelease);c.buttonAim.releaseDelayMilliseconds=200
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.end(contact:1,at:0.1);try e.tick(at:5)
        XCTAssertEqual(e.state,.neutral);XCTAssertNil(e.nextDeadline)
    }
    func testNewTouchCancelsPendingDelayBeforeDueTimer() throws {
        var c=aim(timing:.sendOnRelease);c.buttonAim.releaseDelayMilliseconds=200
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.end(contact:1,at:0.1);try start(&e,c,0.31)
        XCTAssertTrue(e.state.buttons.isEmpty);XCTAssertEqual(e.buttonAimStates[c.id],.armed)
    }
    func testBoundaryExitAndReturnStayCancelledUnlessOptedIn() throws {
        for rearm in [false,true] {
            var c=aim(timing:.sendOnRelease);c.buttonAim.cancelOnBoundaryExit=true;c.buttonAim.rearmOnBoundaryReturn=rearm
            var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c)
            try e.endButton(contact:1,finalSamples:[point(101),point()],at:0.1)
            XCTAssertEqual(e.state.buttons,rearm ? [.a]:[])
        }
    }
    func testBoundaryDoesNotStopAimAndDoesNotAffectImmediatePayload() throws {
        var c=aim(output:.rightStick);c.buttonAim.cancelOnBoundaryExit=true;c.buttonAim.tuning.origin = .controlCenter
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.moveButtonBatch(contact:1,samples:[point(150)],at:0.1)
        XCTAssertEqual(e.state.buttons,[.a]);XCTAssertEqual(e.state.rightStick.x,1)
    }
    func testBoundaryLateBatchCancelsHoldBeforeTimer() throws {
        var c=aim(timing:.sendOnRelease);c.buttonBehavior = .init(holdToggle:true);c.buttonAim.cancelOnBoundaryExit=true
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c)
        try e.moveButtonBatch(contact:1,samples:[point(101),point()],at:1)
        try e.end(contact:1,at:1.1);XCTAssertEqual(e.state,.neutral);XCTAssertTrue(e.latchedControls.isEmpty)
    }
    func testAlternateRemainsArmedAfterRepeatedShortCompletions() throws {
        let c=aim(alternate:true);var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.end(contact:1,at:0.1)
        XCTAssertEqual(e.buttonAlternatePhases[c.id],.alternateArmed)
        for t in [1.0,2.0] { try start(&e,c,t);XCTAssertEqual(e.state.buttons,[.b]);try e.end(contact:1,at:t+0.1);XCTAssertEqual(e.buttonAlternatePhases[c.id],.alternateArmed) }
    }
    func testAlternateResetRequiresThresholdAndIntentionalLift() throws {
        let c=aim(alternate:true);var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.end(contact:1,at:0.1)
        try start(&e,c,1);try e.tick(at:3);XCTAssertEqual(e.buttonAlternatePhases[c.id],.alternateArmed);XCTAssertEqual(e.buttonAimStates[c.id],.alternateResetReady)
        try e.end(contact:1,at:3.1);XCTAssertEqual(e.buttonAlternatePhases[c.id],.base)
    }
    func testAlternateCancelEntersRecoveryAndCannotSatisfyReset() throws {
        let c=aim(alternate:true);var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.end(contact:1,at:0.1)
        try start(&e,c,1);try e.tick(at:3);try e.cancel(contact:1,at:3.1)
        XCTAssertEqual(e.buttonAlternatePhases[c.id],.alternateRecovery);XCTAssertEqual(e.state,.neutral)
        try start(&e,c,4);try e.end(contact:1,at:4.1);XCTAssertEqual(e.buttonAlternatePhases[c.id],.alternateRecovery)
        try start(&e,c,5);try e.tick(at:7);try e.end(contact:1,at:7.1);XCTAssertEqual(e.buttonAlternatePhases[c.id],.base)
    }
    func testAlternateCancellationPreservesLatchedBaseAndIndependentOwners() throws {
        var c=aim(alternate:true);c.buttonBehavior = .init(holdToggle:true)
        let other=ProfileControl(actions:[.x]);var e=try ProfileInputEngine(profile:profile([c,other]))
        try start(&e,c);try e.tick(at:0.5);try e.end(contact:1,at:0.6);try e.begin(contact:2,control:other.id,at:0.7)
        try start(&e,c,1);XCTAssertEqual(e.state.buttons,[.a,.b,.x]);try e.cancel(contact:1,at:1.1)
        XCTAssertEqual(e.state.buttons,[.a,.x]);XCTAssertEqual(e.buttonAlternatePhases[c.id],.alternateRecovery)
    }
    func testAlternateTriggerOverridesOwnBaseButNotOtherInstance() throws {
        var c=aim("RT:0.9",alternate:true);c.buttonBehavior = .init(holdToggle:true);c.buttonAim.alternate.payload="RT:0.2"
        let other=ProfileControl(payload:"RT:0.5");var e=try ProfileInputEngine(profile:profile([c,other]));try start(&e,c);try e.tick(at:0.5);try e.end(contact:1,at:0.6)
        try start(&e,c,1);XCTAssertEqual(e.practiceState.rightTrigger,0.2)
        try e.begin(contact:2,control:other.id,at:1.1);XCTAssertEqual(e.practiceState.rightTrigger,0.5)
        try e.end(contact:1,at:1.2);XCTAssertEqual(e.practiceState.rightTrigger,0.9)
    }
    func testAlternateResetCanDelayBaseUnlatchWithoutRefiring() throws {
        var c=aim(alternate:true);c.buttonBehavior = .init(holdToggle:true);c.buttonAim.alternate.baseUnlatchDelayMilliseconds=300
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.tick(at:0.5);try e.end(contact:1,at:0.6)
        try start(&e,c,1);try e.tick(at:3);try e.end(contact:1,at:3.1);XCTAssertEqual(e.state.buttons,[.a])
        try e.tick(at:3.4);XCTAssertEqual(e.state,.neutral);XCTAssertEqual(e.buttonAlternatePhases[c.id],.base)
    }
    func testAlternateSendOnReleaseUsesFinitePressThenPhaseCompletion() throws {
        var c=aim(alternate:true);c.buttonAim.alternate.payloadTiming = .sendOnRelease
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.end(contact:1,at:0.1);try start(&e,c,1)
        XCTAssertTrue(e.state.buttons.isEmpty);try e.end(contact:1,at:1.1);XCTAssertEqual(e.state.buttons,[.b]);try e.tick(at:1.19)
        XCTAssertTrue(e.state.buttons.isEmpty);XCTAssertEqual(e.buttonAlternatePhases[c.id],.alternateArmed)
    }
    func testControlCenterAimUsesIndependentRectangleAxesAndUpConvention() throws {
        let t=ButtonAimTuning(output:.leftStick,origin:.controlCenter)
        XCTAssertEqual(ButtonGestureRuntime.vector(sample:.init(x:200,y:0,width:200,height:100),origin:point(),tuning:t),.init(x:1,y:1))
        var inverse=t;inverse.invertY=true
        XCTAssertEqual(ButtonGestureRuntime.vector(sample:.init(x:200,y:0,width:200,height:100),origin:point(),tuning:inverse),.init(x:1,y:-1))
    }
    func testTouchOriginUsesRadialDeadzoneAndFullDisplacement() throws {
        let t=ButtonAimTuning(output:.rightStick,fullDisplacement:108,deadzone:8)
        XCTAssertEqual(ButtonGestureRuntime.vector(sample:point(58),origin:point(),tuning:t),.zero)
        XCTAssertEqual(ButtonGestureRuntime.vector(sample:point(108),origin:point(),tuning:t).x,0.5,accuracy:1e-12)
        XCTAssertEqual(ButtonGestureRuntime.vector(sample:point(158),origin:point(),tuning:t).x,1)
    }
    func testDpadFourAndEightWayAimAreIndependentFromBase() throws {
        var c=aim(output:.dpad);var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c,0,1,point(100,0))
        XCTAssertEqual(e.state.buttons,[.a]);XCTAssertEqual(e.state.dpad,.upRight)
        c.buttonAim.tuning.dpadMode = .fourWay;try e.apply(profile:profile([c]));try start(&e,c,1,1,point(100,0));XCTAssertEqual(e.state.dpad,.right)
    }
    func testMouseLinearAndSmoothedAndScrollIndependence() throws {
        var c=aim();c.buttonAim.tuning.mouseResponse = .linearRelative
        let scroll=ProfileControl(payload:"SCROLL_MODE_TOGGLE");var e=try ProfileInputEngine(profile:profile([c,scroll]));try e.activate(scroll.id,at:0);try start(&e,c,0.1)
        try e.moveButtonBatch(contact:1,samples:[point(52,54),point(54,58)],at:0.2)
        XCTAssertEqual(e.practiceState.pointerOffset,.init(dx:4,dy:8));XCTAssertEqual(e.practiceState.scrollOffset,0)
        c.buttonAim.tuning.mouseResponse = .smoothedNonlinear;try e.apply(profile:profile([c]));try start(&e,c,1)
        try e.moveButtonBatch(contact:1,samples:[point(52,54)],at:1.1)
        XCTAssertEqual(e.practiceState.pointerOffset.dx,0.92,accuracy:1e-12);XCTAssertEqual(e.practiceState.pointerOffset.dy,1.72,accuracy:1e-12)
    }
    func testRetainedAimNeedsDeliberateTravelAndRecenterKeepsPayload() throws {
        let c=aim(output:.leftStick,retained:true);var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c)
        try e.moveButtonBatch(contact:1,samples:[point(58)],at:0.1);XCTAssertEqual(e.state.leftStick,.zero)
        try e.moveButtonBatch(contact:1,samples:[point(160)],at:0.2);let last=e.state.leftStick;XCTAssertGreaterThan(last.x,0)
        try e.end(contact:1,at:0.3);XCTAssertEqual(e.state.leftStick,last);XCTAssertEqual(e.retainedSticks[c.id],last)
        try start(&e,c,1);XCTAssertEqual(e.state.leftStick,last);e.recenterSticks();XCTAssertEqual(e.state.leftStick,.zero);XCTAssertEqual(e.state.buttons,[.a])
        try e.moveButtonBatch(contact:1,samples:[point(200)],at:1.1);XCTAssertEqual(e.state.leftStick,.zero)
    }
    func testActiveAnalogOwnersCannotBeStolenByAimOrStick() throws {
        let c=aim(output:.leftStick),stick=ProfileControl(kind:.leftStick)
        var e=try ProfileInputEngine(profile:profile([c,stick]));try e.begin(contact:2,control:stick.id,position:.init(x:0.6),at:0);try start(&e,c,0.1)
        XCTAssertNil(e.capturedControl(for:1));XCTAssertEqual(e.state.leftStick.x,0.6);XCTAssertTrue(e.state.buttons.isEmpty)
        e.releaseAll();try start(&e,c,1);try e.begin(contact:2,control:stick.id,position:.init(x:0.6),at:1.1);XCTAssertEqual(e.state.leftStick,.zero)
    }
    func testRetainedOrdinaryStickYieldsOnlyAfterAimMovement() throws {
        let c=aim(output:.leftStick),stick=ProfileControl(kind:.leftStick,stickBehavior:.init(autoCenter:false))
        var e=try ProfileInputEngine(profile:profile([c,stick]));try e.begin(contact:2,control:stick.id,position:.init(x:0.6),at:0);try e.end(contact:2,at:0.1);try start(&e,c,0.2)
        XCTAssertEqual(e.state.leftStick.x,0.6);try e.moveButtonBatch(contact:1,samples:[point(100)],at:0.3)
        XCTAssertNil(e.retainedSticks[stick.id]);XCTAssertNotEqual(e.state.leftStick.x,0.6)
    }
    func testReleaseAllClearsEveryGesturePhaseTimerAndRetainedClaim() throws {
        let c=aim(alternate:true);var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.end(contact:1,at:0.1);try start(&e,c,1)
        e.releaseAll();try e.tick(at:100);XCTAssertEqual(e.state,.neutral);XCTAssertTrue(e.buttonAimStates.isEmpty);XCTAssertNil(e.nextDeadline);XCTAssertTrue(e.drainButtonFeedback().isEmpty)
    }
    func testInvalidBatchRejectsWholePathBeforeTimersAndMovement() throws {
        let c=aim();var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c)
        XCTAssertThrowsError(try e.moveButtonBatch(contact:1,samples:[point(100),point(.nan)],at:1))
        XCTAssertEqual(e.practiceState.pointerOffset,.zero)
        XCTAssertThrowsError(try e.endButton(contact:1,finalSamples:Array(repeating:point(),count:257),at:2))
        XCTAssertEqual(e.state.buttons,[.a]);try e.cancel(contact:1,at:0.1);XCTAssertEqual(e.state,.neutral)
    }
    func testAdvancedButtonsAreCapturedDirectOnlyInEverySwipeMode() throws {
        let c=aim(),b=ProfileControl(actions:[.b]);var e=try ProfileInputEngine(profile:profile([c,b]));try start(&e,c)
        XCTAssertFalse(try e.handoff(contact:1,to:b.id,at:0.1));try e.begin(contact:2,control:b.id,at:0.2)
        XCTAssertFalse(try e.handoff(contact:2,to:c.id,at:0.3));XCTAssertFalse(c.acceptsSwipeEntry)
        var router=try ProfileSwipeRouter(profile:profile([c,b]));try router.begin(contact:1,control:c.id,at:0)
        XCTAssertEqual(try router.decision(contact:1,hitControls:[b.id],at:0.1),.moveCurrent)
    }
    func testImmediateTurboHasOwnerGapButDelayedAndAlternateIgnoreIt() throws {
        let c=aim(alternate:true);var e=try ProfileInputEngine(profile:profile([c],turbo:true));try start(&e,c)
        XCTAssertEqual(e.state.buttons,[.a]);try e.tick(at:0.011);XCTAssertTrue(e.state.buttons.isEmpty);try e.tick(at:0.016);XCTAssertEqual(e.state.buttons,[.a])
        try e.end(contact:1,at:0.02);try start(&e,c,1);try e.tick(at:1.011);XCTAssertEqual(e.state.buttons,[.b])
    }
    func testPulseClaimsExpireAndCancelWithoutReleasingOtherOwners() throws {
        let c=aim("RT:0.9P0.3"),other=ProfileControl(payload:"RT:0.4")
        var e=try ProfileInputEngine(profile:profile([c,other]));try start(&e,c);try e.begin(contact:2,control:other.id,at:0.1)
        XCTAssertEqual(e.practiceState.rightTrigger,0.9);try e.tick(at:0.3);XCTAssertEqual(e.practiceState.rightTrigger,0.4)
        try e.cancel(contact:1,at:0.4);XCTAssertEqual(e.practiceState.rightTrigger,0.4)
    }
    func testAccessibilityActivatesAdvancedBaseWithoutSyntheticMovement() throws {
        let c=aim();var e=try ProfileInputEngine(profile:profile([c]));try e.activate(c.id,at:0);XCTAssertEqual(e.state.buttons,[.a])
        try e.tick(at:0.15);XCTAssertEqual(e.state,.neutral);XCTAssertEqual(e.practiceState.pointerOffset,.zero)
    }
    func testBasePulseSurvivesNormalLiftWhileMixedActionsRelease() throws {
        let c=aim("X360A,RT:0.8P0.3")
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.end(contact:1,at:0.1)
        XCTAssertFalse(e.state.buttons.contains(.a));XCTAssertEqual(e.practiceState.rightTrigger,0.8)
        try e.tick(at:0.3);XCTAssertEqual(e.state,.neutral)
    }
    func testCancelNeverDetachesBasePulseAndAlternatePulseEndsOnLift() throws {
        var c=aim("RT:0.8P0.3",alternate:true);c.buttonAim.alternate.payload="LT:0.9P1"
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.cancel(contact:1,at:0.1)
        XCTAssertEqual(e.state,.neutral);XCTAssertNil(e.nextDeadline)
        try start(&e,c,1);try e.end(contact:1,at:1.1);try e.tick(at:1.3);try start(&e,c,2)
        XCTAssertEqual(e.practiceState.leftTrigger,0.9);try e.end(contact:1,at:2.1);XCTAssertEqual(e.practiceState.leftTrigger,0)
    }
    func testDirectionalAdditionsDisableGlobalTurboForAimBase() throws {
        var c=aim();c.buttonDirectional.enabled=true
        var e=try ProfileInputEngine(profile:profile([c],turbo:true));try start(&e,c);try e.tick(at:0.011)
        XCTAssertEqual(e.state.buttons,[.a])
    }

    func testCaptureAcceptanceDistinguishesIgnoredAnalogFinger() throws {
        let c=aim(output:.leftStick),stick=ProfileControl(kind:.leftStick)
        var e=try ProfileInputEngine(profile:profile([c,stick]));try start(&e,c)
        XCTAssertTrue(e.isCapturedInputOwner(for:1))
        try e.begin(contact:2,control:stick.id,position:.init(x:1),at:0.1)
        XCTAssertFalse(e.isCapturedInputOwner(for:2));try e.cancel(contact:2,at:0.2)
        XCTAssertTrue(e.isCapturedInputOwner(for:1));XCTAssertEqual(e.state.buttons,[.a])
    }
    func testDirectionalOnlyPublishesStageWithoutAimBadge() throws {
        var c=ProfileControl(buttonDirectional:.init(enabled:true));c.buttonDirectional.directions[.right]?.firstPayload="X360Y"
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.moveButtonBatch(contact:1,samples:[point(100)],at:0.1)
        XCTAssertNil(e.buttonAimStates[c.id]);XCTAssertEqual(e.buttonDirectionalSelections[c.id],.init(direction:.right,stage:1))
    }
    func testDeferredRetainedAimCanPressWhileAnotherStickIsLive() throws {
        let c=aim(output:.leftStick,retained:true),stick=ProfileControl(kind:.leftStick)
        var e=try ProfileInputEngine(profile:profile([c,stick]));try e.begin(contact:2,control:stick.id,position:.init(x:0.8),at:0)
        try start(&e,c,0.1);XCTAssertTrue(e.isCapturedInputOwner(for:1));XCTAssertEqual(e.state.buttons,[.a])
        try e.moveButtonBatch(contact:1,samples:[point(200)],at:0.2);XCTAssertEqual(e.state.leftStick.x,0.8)
        try e.end(contact:2,at:0.3);try e.moveButtonBatch(contact:1,samples:[point(200)],at:0.4);XCTAssertGreaterThan(e.state.leftStick.x,0)
    }
    func testAlternateOverridesStillRunningBasePulseThenRestoresIt() throws {
        var c=aim("RT:0.9P1",alternate:true);c.buttonAim.alternate.payload="RT:0.2"
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.end(contact:1,at:0.1);try start(&e,c,0.2)
        XCTAssertEqual(e.practiceState.rightTrigger,0.2);try e.end(contact:1,at:0.3);XCTAssertEqual(e.practiceState.rightTrigger,0.9)
        try e.tick(at:1);XCTAssertEqual(e.practiceState.rightTrigger,0)
    }

    func testShortAlternateTouchCannotCenterDeferredRetainedBaseAim() throws {
        var c=aim(output:.leftStick,retained:true,alternate:true)
        c.buttonAim.alternate.tuning = .init(output:.leftStick,autoCenter:true)
        var e=try ProfileInputEngine(profile:profile([c]));try start(&e,c);try e.moveButtonBatch(contact:1,samples:[point(150)],at:0.1);try e.end(contact:1,at:0.2)
        let retained=e.state.leftStick;XCTAssertGreaterThan(retained.x,0)
        try start(&e,c,1);try e.end(contact:1,at:1.1);XCTAssertEqual(e.state.leftStick,retained)
        try start(&e,c,2);try e.moveButtonBatch(contact:1,samples:[point(160)],at:2.1);try e.end(contact:1,at:2.2);XCTAssertEqual(e.state.leftStick,.zero)
    }

}

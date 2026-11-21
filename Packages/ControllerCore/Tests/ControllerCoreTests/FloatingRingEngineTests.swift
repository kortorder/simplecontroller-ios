import XCTest
@testable import ControllerCore

final class FloatingRingEngineTests: XCTestCase {
    private let touch = FloatingPoint(x:300,y:300), canvas = FloatingRect(x:0,y:0,width:700,height:900)
    private func fixture(config: FloatingRingConfig = .init(), controls: [ProfileControl] = []) throws -> (ProfileInputEngine, UUID, UUID) {
        let positions = controls.map { ProfilePlacement(id:$0.id,position:.init(x:0.5,y:0.5)) }
        var p = try ControllerProfile(controls:controls,portrait:positions,landscape:positions)
        let zone = FloatingRingZone(portraitGeometry:.init(canvasWidth:700,canvasHeight:900,zone:.init(x:0,y:0,width:700,height:900)),config:config)
        p.pages[0].floatingRingZones = [zone]; try p.validate()
        return (try .init(profile:p),zone.id,UUID())
    }
    private func begin(_ e: inout ProfileInputEngine, _ zone: UUID, _ session: UUID, contact: Int = 1, time: Double = 0) throws {
        XCTAssertTrue(try e.beginFloatingRing(contact:contact,zoneID:zone,sessionID:session,point:touch,usable:canvas,at:time))
    }
    private func sample(_ e: ProfileInputEngine, _ zone: UUID, _ x: Double, _ y: Double, _ elapsed: Double) -> FloatingRingSample {
        let s = e.floatingRingStates[zone]!
        return .init(point:.init(x:s.placement.origin.x+s.geometry.center.x+x,y:s.placement.origin.y+s.geometry.center.y+y),elapsed:elapsed)
    }
    func testRingDrivesRealGamepadAndPracticeOutputsThroughNormalEnd() throws {
        var c = FloatingRingConfig(); c.boost1.enabled = true; c.boost1.payload = "X360A,W,MOUSE_LEFT_DOWN,RT:0.5"
        var (e,z,s) = try fixture(config:c); try begin(&e,z,s)
        try e.moveFloatingRing(contact:1,sessionID:s,samples:[sample(e,z,130,0,0.1)],at:0.1)
        XCTAssertEqual(e.state.leftStick,.init(x:1)); XCTAssertTrue(e.state.buttons.contains(.a))
        XCTAssertEqual(e.practiceState.rightTrigger,0.5); XCTAssertEqual(e.practiceState.heldKeys,[.w]); XCTAssertEqual(e.practiceState.heldMouseButtons,[.left])
        XCTAssertTrue(e.outputControls.contains(z)); XCTAssertTrue(e.isCapturedInputOwner(for:1))
        try e.endFloatingRing(contact:1,sessionID:s,samples:[],at:0.2)
        XCTAssertEqual(e.state,.neutral); XCTAssertTrue(e.practiceState.heldKeys.isEmpty)
        XCTAssertNil(e.capturedControl(for:1)); XCTAssertTrue(e.floatingRingStates[z]!.visible)
    }
    func testRingMouseHistoryIgnoresTouchpadScrollMode() throws {
        var c = FloatingRingConfig(); c.startRole = .aim
        let toggle = ProfileControl(payload:"SCROLL_MODE_TOGGLE")
        var (e,z,s) = try fixture(config:c,controls:[toggle]); try e.begin(contact:2,control:toggle.id,at:0); try e.end(contact:2,at:0)
        try begin(&e,z,s); _ = e.drainPracticeEvents()
        try e.moveFloatingRing(contact:1,sessionID:s,samples:[sample(e,z,10,5,0.1)],at:0.1)
        XCTAssertEqual(e.practiceState.pointerOffset,.init(dx:10,dy:5)); XCTAssertEqual(e.practiceState.scrollOffset,0)
        XCTAssertTrue(e.drainPracticeEvents().events.contains { $0.kind == .pointerMoved(dx:10,dy:5) })
    }
    func testFirstLiveManualStickBlocksRingWithoutLaterSpringActivation() throws {
        let manual = ProfileControl(kind:.leftStick)
        var (e,z,s) = try fixture(controls:[manual]); try e.begin(contact:2,control:manual.id,position:.init(x:-1),at:0)
        try begin(&e,z,s); XCTAssertEqual(e.state.leftStick,.init(x:-1))
        try e.end(contact:2,at:0.1)
        try e.moveFloatingRing(contact:1,sessionID:s,samples:[sample(e,z,88,0,0.2)],at:0.2)
        XCTAssertEqual(e.state.leftStick,.zero); XCTAssertNotNil(e.floatingRingStates[z]?.issue)
        try e.cancelFloatingRing(contact:1,sessionID:s,at:0.3)
        let movement = sample(e,z,80,0,0).point
        XCTAssertTrue(try e.beginFloatingRing(contact:3,zoneID:z,sessionID:s,point:movement,usable:canvas,at:0.4))
        XCTAssertGreaterThan(e.state.leftStick.x,0.8)
    }
    func testLiveRingBlocksManualButtonAimAndTouchAimChannels() throws {
        let manual = ProfileControl(kind:.leftStick)
        let button = ProfileControl(payload:"X360B",buttonAim:.init(enabled:true,tuning:.init(output:.leftStick)))
        var sensor = ProfileControl(kind:.touchAim); sensor.touchAim.aim.output = .leftStick
        var (e,z,s) = try fixture(controls:[manual,button,sensor]); try begin(&e,z,s)
        try e.moveFloatingRing(contact:1,sessionID:s,samples:[sample(e,z,88,0,0.1)],at:0.1)
        try e.begin(contact:2,control:manual.id,position:.init(x:-1),at:0.2)
        XCTAssertFalse(e.isCapturedInputOwner(for:2)); XCTAssertEqual(e.state.leftStick,.init(x:1))
        try e.beginButton(contact:3,control:button.id,sample:.init(x:30,y:30,width:60,height:60),at:0.2)
        try e.moveButtonBatch(contact:3,samples:[.init(x:-100,y:30,width:60,height:60)],at:0.3)
        XCTAssertEqual(e.state.leftStick,.init(x:1))
        try e.beginTouchAim(contact:4,control:sensor.id,sample:.init(pointer:.init(x:100,y:100,width:200,height:200),metrics:.init(majorRadius:1),elapsed:0),at:0.3)
        try e.moveTouchAimBatch(contact:4,samples:[.init(pointer:.init(x:0,y:100,width:200,height:200),metrics:.init(majorRadius:1),elapsed:0.1)],at:0.4)
        XCTAssertEqual(e.state.leftStick,.init(x:1))
    }
    func testRetainedRingCanBeDeliberatelyReplacedAndCannotReappear() throws {
        var c = FloatingRingConfig(); c.movement.autoCenter = false
        let manual = ProfileControl(kind:.leftStick)
        var (e,z,s) = try fixture(config:c,controls:[manual]); try begin(&e,z,s)
        try e.endFloatingRing(contact:1,sessionID:s,samples:[sample(e,z,88,0,0.1)],at:0.1)
        XCTAssertEqual(e.state.leftStick,.init(x:1)); XCTAssertTrue(e.floatingRingStates[z]!.retained)
        try e.begin(contact:2,control:manual.id,position:.init(x:-1),at:0.2); XCTAssertEqual(e.state.leftStick,.init(x:-1))
        try e.end(contact:2,at:0.3); XCTAssertEqual(e.state.leftStick,.zero)
        XCTAssertFalse(e.floatingRingStates[z]!.retained)
    }
    func testRingCanReplaceRetainedManualAndButtonAimWithoutClobberingLiveOtherStick() throws {
        let left = ProfileControl(kind:.leftStick,stickBehavior:.init(autoCenter:false)), right = ProfileControl(kind:.rightStick)
        var (e,z,s) = try fixture(controls:[left,right])
        try e.begin(contact:2,control:left.id,position:.init(x:-1),at:0); try e.end(contact:2,at:0)
        try e.begin(contact:3,control:right.id,position:.init(y:1),at:0)
        try begin(&e,z,s); XCTAssertEqual(e.state.leftStick,.zero); XCTAssertEqual(e.state.rightStick,.init(y:1))
        XCTAssertNil(e.retainedSticks[left.id])
    }
    func testScopedFinishPreservesIndependentHoldAndSharedMouseOwner() throws {
        var c = FloatingRingConfig(); c.startRole = .aim; c.knobs[0].fire.adsPayload = "MOUSE_LEFT_DOWN"
        let independent = ProfileControl(payload:"MOUSE_LEFT_DOWN,X360B")
        var (e,z,s) = try fixture(config:c,controls:[independent]); try e.begin(contact:2,control:independent.id,at:0)
        try begin(&e,z,s); _ = e.drainPracticeEvents()
        try e.floatingRingAction(zoneID:z,sessionID:s,action:.finish,at:0.1)
        XCTAssertEqual(e.state.buttons,[.b]); XCTAssertEqual(e.practiceState.heldMouseButtons,[.left])
        XCTAssertFalse(e.drainPracticeEvents().events.contains { $0.kind == .mouseUp(.left) })
        XCTAssertTrue(e.floatingRingStates[z]!.finished)
    }
    func testReleaseAllClearsRingTimersAndStaleCallbackCannotReviveIt() throws {
        var c = FloatingRingConfig(); c.boost2.enabled = true; c.boost2.payload = "X360A"; c.boost2.activationDelayMilliseconds = 500
        var (e,z,s) = try fixture(config:c); try begin(&e,z,s)
        try e.moveFloatingRing(contact:1,sessionID:s,samples:[sample(e,z,180,0,0.1)],at:0.1)
        XCTAssertNotNil(e.nextDeadline); e.releaseAll()
        try e.moveFloatingRing(contact:1,sessionID:s,samples:[.init(point:touch,elapsed:1)],at:1); try e.tick(at:2)
        XCTAssertEqual(e.state,.neutral); XCTAssertNil(e.nextDeadline); XCTAssertTrue(e.floatingRingStates.isEmpty)
    }
    func testCancelAtReleaseDeadlineNeverSynthesizesShot() throws {
        var c = FloatingRingConfig(); c.startRole = .aim; c.knobs[0].fire.mode = .releaseShot; c.knobs[0].fire.firePayload = "X360A"
        var (e,z,s) = try fixture(config:c); try begin(&e,z,s)
        try e.cancelFloatingRing(contact:1,sessionID:s,at:10); try e.tick(at:20)
        XCTAssertEqual(e.state,.neutral); XCTAssertNil(e.nextDeadline)
    }
    func testRingPulseIsDrivenByEngineNextDeadlineAndHasVisibleOffGap() throws {
        var c = FloatingRingConfig(); c.startRole = .aim; c.knobs[0].fire.mode = .repeat; c.knobs[0].fire.firePayload = "X360A"
        var (e,z,s) = try fixture(config:c); try begin(&e,z,s)
        XCTAssertEqual(e.state.buttons,[.a]); XCTAssertEqual(e.nextDeadline,0.035)
        try e.tick(at:5); XCTAssertEqual(e.state,.neutral); XCTAssertEqual(e.nextDeadline,5.035)
        try e.tick(at:5.035); XCTAssertEqual(e.state.buttons,[.a]); XCTAssertEqual(e.nextDeadline,5.07)
    }
    func testFinishedSessionCannotReuseItsIDButNewSummonUsesFreshID() throws {
        var (e,z,s) = try fixture(); try begin(&e,z,s)
        try e.floatingRingAction(zoneID:z,sessionID:s,action:.finish,at:0.1)
        XCTAssertFalse(try e.beginFloatingRing(contact:2,zoneID:z,sessionID:s,point:touch,usable:canvas,at:0.2))
        let next = UUID(); try begin(&e,z,next,contact:2,time:0.2)
        try e.cancelFloatingRing(contact:2,sessionID:s,at:0.3)
        XCTAssertEqual(e.capturedControl(for:2),z)
        try e.floatingRingAction(zoneID:z,sessionID:s,action:.finish,at:0.3)
        XCTAssertFalse(e.floatingRingStates[z]!.finished)
    }
    func testCurrentPageVisibilityAndPageChangeNeutralization() throws {
        var (e,z,s) = try fixture(); var p = e.profile; let other = try p.addPage(name:"Other"); try e.apply(profile:p)
        try begin(&e,z,s); try e.moveFloatingRing(contact:1,sessionID:s,samples:[sample(e,z,88,0,0.1)],at:0.1)
        XCTAssertTrue(try e.selectPage(other,at:0.2)); XCTAssertEqual(e.state,.neutral); XCTAssertTrue(e.floatingRingStates.isEmpty)
        XCTAssertFalse(try e.beginFloatingRing(contact:2,zoneID:z,sessionID:UUID(),point:touch,usable:canvas,at:0.3))
    }
    func testRecenterClearsMovementAndBoostButPreservesIndependentButton() throws {
        var c = FloatingRingConfig(); c.movement.autoCenter = false; c.boost1.enabled = true; c.boost1.payload = "X360A"; c.boost1.retainOnLift = true
        let b = ProfileControl(actions:[.b],buttonBehavior:.init(holdToggle:true))
        var (e,z,s) = try fixture(config:c,controls:[b]); try e.begin(contact:2,control:b.id,at:0); try e.tick(at:0.5)
        try begin(&e,z,s,time:0.5)
        try e.moveFloatingRing(contact:1,sessionID:s,samples:[sample(e,z,130,0,0.05)],at:0.55)
        try e.endFloatingRing(contact:1,sessionID:s,samples:[sample(e,z,130,0,0.1)],at:0.6)
        XCTAssertTrue(e.state.buttons.contains(.a)); e.recenterSticks()
        XCTAssertEqual(e.state.leftStick,.zero); XCTAssertEqual(e.state.buttons,[.b])
    }
    func testRingMetadataDoesNotClaimInactivePayloads() throws {
        var c = FloatingRingConfig(); c.movement.enabled = false; c.aim.enabled = false
        c.boost1.payload = "W,RT:1"; XCTAssertFalse(c.hasAnyOutput)
        c.boost1.enabled = true; c.boost1.directTapEnabled = true; c.startRole = .boostOne
        XCTAssertTrue(c.hasDesktopOutputs); XCTAssertEqual(c.outputTargets,[.rightTrigger])
    }
}

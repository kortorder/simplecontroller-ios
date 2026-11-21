import Foundation
import ControllerCore

/// Executes the actual app model with the shared fake transport/clock; no UIKit or hardware.
@MainActor
func runCameraClientChecks(require: (Bool, String) -> Void, freshDefaults: () -> UserDefaults) throws {
    func fixture(_ controls: [ProfileControl], turbo: Bool = false) throws -> ControllerProfile {
        let positions = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
        return try ControllerProfile(controls: controls, portrait: positions, landscape: positions,
                                     turboEnabled: turbo, turboIntervalMilliseconds: 100)
    }
    func model(_ profile: ControllerProfile) throws -> (ProfileControllerViewModel, ProfileCheckClock, ProfileCheckTransport, UserDefaults) {
        let defaults = freshDefaults(), clock = ProfileCheckClock(), link = ProfileCheckTransport()
        defaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile])), forKey: ProfileControllerViewModel.libraryKey)
        let vm = ProfileControllerViewModel(defaults: defaults, transport: link, clock: { clock.time },
                                             automaticTimer: false, persistSettings: true)
        return (vm, clock, link, defaults)
    }
    @discardableResult
    func input(_ vm: ProfileControllerViewModel, _ event: ProfileInputEvent) -> Bool {
        vm.handleInput(event, epoch: vm.inputEpoch)
    }
    func connect(_ vm: ProfileControllerViewModel, _ link: ProfileCheckTransport) {
        vm.setBridgeProtocol(.scx1); vm.setMode(.bridge); vm.host = "192.168.1.80"; vm.portText = "42735"; vm.connect()
        let session = link.sent.last!.session
        link.reply(.init(kind: .ready, session: session, sequence: 0, hidReady: true))
    }
    func near(_ first: Double, _ second: Double) -> Bool { abs(first - second) < 1e-8 }
    let left = ProfileControl(kind: .leftStick), right = ProfileControl(kind: .rightStick)
    let follow = ProfileControl(payload: "CAMERA_FOLLOW", cameraFollowStrengthPercent: 125)
    let held = ProfileControl(actions: [.b])
    let (vm, clock, link, defaults) = try model(fixture([left,right,follow,held]))
    let original = defaults.data(forKey: ProfileControllerViewModel.libraryKey)
    require(vm.cameraFollowSnapshot?.requestedEnabled == false && vm.state.isNeutral, "Camera VM starts disarmed and neutral")
    input(vm, .accessibilityActivate(follow.id))
    require(vm.cameraFollowSnapshot?.requestedEnabled == true && vm.cameraFollowSnapshot?.strengthPercent == 125,
            "Camera command applies its own saved strength through the actual app model")
    input(vm, .begin(contact: 1, control: left.id, position: .init(x: 1)))
    clock.time = 10.199; vm.tickInput()
    require(vm.state.rightStick == .zero, "Camera app timer does not generate motion before 200 ms")
    clock.time = 10.2; vm.tickInput()
    require(vm.state.rightStick == .zero, "Camera activation deadline starts a fresh ramp without accumulated wait")
    clock.time = 10.21; vm.tickInput()
    require(vm.state.rightStick.x > 0 && vm.state.rightStick.x < 0.1, "Camera ramp deadline publishes a gradual Practice right stick")
    clock.time = 10.4; vm.tickInput()
    require(near(vm.state.rightStick.x, 0.5625) && vm.practiceState.gamepad == vm.state,
            "App state displays effective Practice assistance at the source-audited strength ceiling")
    require(link.sent.isEmpty && defaults.data(forKey: ProfileControllerViewModel.libraryKey) == original,
            "Practice Camera Follow writes neither bridge packets nor runtime state into saved profiles")
    input(vm, .begin(contact: 2, control: right.id, position: .zero))
    require(vm.cameraFollowSnapshot?.manualRightContactActive == true && vm.state.rightStick == .zero,
            "A centered actual right-stick touch suppresses generated movement in the app")
    input(vm, .end(contact: 2)); clock.time = 10.61; vm.tickInput(); clock.time = 10.8; vm.tickInput()
    require(vm.state.rightStick.x > 0, "Practice camera resumes only after a fresh activation ramp following neutral manual contact")
    input(vm, .begin(contact: 3, control: held.id, position: .zero)); vm.recenterSticks()
    require(vm.state.rightStick == .zero && vm.state.buttons == [.b] && vm.cameraFollowSnapshot?.requestedEnabled == true,
            "App Re-center clears generated movement while preserving independent buttons and the requested toggle")
    let staleEpoch = vm.inputEpoch; vm.releaseAll(); clock.time = 11
    vm.tickInput(epoch: staleEpoch)
    require(vm.cameraFollowSnapshot?.requestedEnabled == false && vm.state.isNeutral && vm.inputEpoch > staleEpoch,
            "Release all disarms Camera Follow and invalidates its old scheduled callbacks")
    vm.setCameraFollowEnabled(true); input(vm, .begin(contact: 4, control: left.id, position: .init(x: 1)))
    clock.time = 11.2; vm.tickInput(); clock.time = 11.4; vm.tickInput()
    connect(vm, link)
    require(vm.isReady && vm.cameraFollowSnapshot?.requestedEnabled == false && vm.state.isNeutral,
            "Entering bridge mode clears the previous Practice camera owner and requires no generated state")
    input(vm, .begin(contact: 5, control: left.id, position: .init(x: 1)))
    require(link.sent.last?.state?.leftStick.x == 1 && link.sent.last?.state?.rightStick == .zero,
            "Actual bridge packet carries physical left-stick input without Practice-generated right-stick input")
    let sendsBeforeCamera = link.sent.count
    vm.setCameraFollowEnabled(true)
    require(!input(vm, .accessibilityActivate(follow.id)) && vm.cameraFollowSnapshot?.requestedEnabled == false && link.sent.count == sendsBeforeCamera,
            "Bridge mode rejects local and global Camera Follow controls without sending synthetic output")
    vm.setMode(.practice); clock.time = 12; vm.tickInput()
    require(vm.cameraFollowSnapshot?.requestedEnabled == false && vm.state.isNeutral,
            "Returning to Practice cannot revive a Camera Follow command attempted in bridge mode")
    vm.setCameraFollowEnabled(true); vm.setForeground(false); vm.setForeground(true)
    require(vm.cameraFollowSnapshot?.requestedEnabled == false && vm.state.isNeutral,
            "Background interruption disarms Camera Follow before foreground input resumes")
    vm.setCameraFollowEnabled(true); vm.beginLayoutEditing()
    require(vm.cameraFollowSnapshot?.requestedEnabled == false && !vm.controlsEnabled,
            "Entering the editor disarms assistance and pauses control input")
    vm.cancelLayoutEditing()
    require(vm.state.isNeutral && vm.cameraFollowSnapshot?.requestedEnabled == false,
            "Canceling a layout draft never restores live camera movement")

    // Sticky suppression remains scoped to the producing control; the local End action
    // does not release its mouse claim or re-engage from the same held run.
    let mouse = ProfileControl(payload: "MOUSE_LEFT_DOWN", mouseSuppressCameraFollow: true)
    let click = ProfileControl(payload: "MOUSE_RIGHT_DOWN,MOUSE_RIGHT_UP", mouseSuppressCameraFollow: true)
    let endMouse = ProfileControl(floatingAction: .init(action: .endSuppression, target: .control(mouse.id)))
    let endClick = ProfileControl(floatingAction: .init(action: .endSuppression, target: .control(click.id)))
    let (suppression, suppressionClock, _, _) = try model(fixture([mouse,click,endMouse,endClick,held]))
    suppression.setCameraFollowEnabled(true)
    input(suppression, .begin(contact: 1, control: mouse.id, position: .zero))
    input(suppression, .begin(contact: 2, control: held.id, position: .zero))
    require(suppression.cameraFollowSnapshot?.mouseSuppressed == true, "Actual opted-in mouse output engages sticky suppression in the app")
    input(suppression, .accessibilityActivate(endMouse.id)); suppressionClock.time += 1; suppression.tickInput()
    require(suppression.cameraFollowSnapshot?.mouseSuppressed == false && suppression.practiceState.heldMouseButtons == [.left] && suppression.state.buttons == [.b],
            "Scoped End suppression preserves independently held mouse/buttons and blocks same-run re-acquisition")
    input(suppression, .end(contact: 1)); input(suppression, .begin(contact: 3, control: mouse.id, position: .zero))
    require(suppression.cameraFollowSnapshot?.mouseSuppressed == true, "A new direct mouse Down re-arms suppression after explicit End")
    input(suppression, .end(contact: 3)); suppressionClock.time += 0.1; suppression.tickInput()
    require(suppression.cameraFollowSnapshot?.mouseSuppressed == true && suppression.practiceState.heldMouseButtons.isEmpty,
            "Normal mouse lift releases output but deliberately retains sticky camera suppression")
    input(suppression, .begin(contact: 4, control: click.id, position: .zero)); input(suppression, .end(contact: 4))
    input(suppression, .accessibilityActivate(endMouse.id))
    require(suppression.cameraFollowSnapshot?.mouseSuppressed == true, "Ending one owner cannot clear an independent instantaneous click's suppression")
    input(suppression, .accessibilityActivate(endClick.id))
    require(suppression.cameraFollowSnapshot?.mouseSuppressed == false && suppression.state.buttons == [.b],
            "An explicit action can clear the click owner's suppression without global release")
    suppression.releaseAll()
    require(suppression.cameraFollowSnapshot?.requestedEnabled == false && suppression.cameraFollowSnapshot?.mouseSuppressed == false,
            "Global release removes all sticky suppression owners and disarms assistance")

    // Header space depends on saved capabilities, never on the live toggle.
    require(vm.hasCameraFollowOutputs, "Camera page reserves visible feedback while assistance is off")
    vm.setCameraFollowEnabled(true)
    require(vm.hasCameraFollowOutputs, "Enabling Camera cannot add a row or resize the active canvas")
    vm.releaseAll()
    var ringConfig = FloatingRingConfig()
    ringConfig.movement.output = .rightStick
    var ringProfile = try fixture([])
    let ringGeometry = FloatingZoneGeometry(canvasWidth: 337, canvasHeight: 420,
                                           zone: .init(x: 20, y: 20, width: 250, height: 300))
    ringProfile.pages[0].floatingRingZones = [.init(portraitGeometry: ringGeometry, config: ringConfig)]
    let (rightRing, _, _, _) = try model(ringProfile)
    require(!rightRing.hasCameraFollowOutputs, "Right-stick-only ring does not reserve left-source Camera feedback")
    ringConfig.movement.enabled = false
    ringConfig.startRole = .aim
    ringConfig.boost1.enabled = true
    ringConfig.boost1.payload = "LS:R100"
    ringProfile.pages[0].floatingRingZones[0].config = ringConfig
    let (macroRing, _, _, _) = try model(ringProfile)
    require(macroRing.hasCameraFollowOutputs, "Ring-only left-stick boost reserves Camera feedback without movement output")

    // A rejected sustained stage is visible and inert until a new deliberate stage activation.
    var direction = ProfileControl(kind: .leftStick, directionalEnabled: true)
    direction.directionPayloads[.up] = .init(normalPayload: "RS:R30,X360A", boostPayload: "RS:U60,X360B", superBoostPayload: "")
    let (macros, macroClock, _, _) = try model(fixture([right,direction]))
    input(macros, .begin(contact: 1, control: right.id, position: .init(x: -1)))
    input(macros, .begin(contact: 2, control: direction.id, position: .init(y: 0.3)))
    require(macros.state.rightStick == .init(x: -1) && macros.state.buttons == [.a] && macros.fixedStickIssues[direction.id] != nil,
            "App exposes a blocked sustained macro while preserving manual input and independent digital actions")
    input(macros, .end(contact: 1)); macroClock.time += 1; macros.tickInput()
    require(macros.state.rightStick == .zero && macros.fixedStickIssues[direction.id] != nil,
            "A blocked stage does not wake when the previous owner lifts or an overdue timer runs")
    input(macros, .move(contact: 2, position: .init(y: 0.6)))
    require(macros.state.rightStick == .init(y: 0.6) && macros.state.buttons == [.b] && macros.fixedStickIssues[direction.id] == nil,
            "A fresh directional stage acquires a free channel and clears its visible blocked-macro issue")
    macros.recenterSticks(); macroClock.time += 1; macros.tickInput()
    require(macros.state.isNeutral && macros.fixedStickIssues.isEmpty, "Re-center removes sustained stage output and its old diagnostic")

    // Advanced Base uses the same owned reservations through a Turbo OFF gap.
    let aim = ProfileControl(payload: "RS:R50,X360A", buttonAim: .init(enabled: true))
    let (turbo, turboClock, _, _) = try model(fixture([aim,right], turbo: true))
    let center = ButtonPointerSample(x: 50,y: 50,width: 100,height: 100)
    input(turbo, .beginButton(contact: 1, control: aim.id, sample: center))
    require(turbo.state.rightStick == .init(x: 0.5) && turbo.state.buttons == [.a], "Advanced Base macro reaches the actual app's Practice output")
    turboClock.time = 10.095; turbo.tickInput()
    require(turbo.state.rightStick == .zero && turbo.state.buttons.isEmpty, "Advanced Turbo off deadline publishes neutral without losing the macro reservation")
    require(!input(turbo, .beginStick(contact: 2, control: right.id, travel: .init(x: -1,y: 0))),
            "A second manual right-stick contact cannot steal an advanced macro's OFF-gap reservation")
    turboClock.time = 10.1; turbo.tickInput()
    require(turbo.state.rightStick == .init(x: 0.5), "The next Turbo phase returns only its own reserved vector")
    let beforeCancelEpoch = turbo.inputEpoch; turbo.releaseAll(); turboClock.time = 12; turbo.tickInput(epoch: beforeCancelEpoch)
    require(turbo.state.isNeutral && turbo.fixedStickIssues.isEmpty, "Canceled advanced macro timers and old callbacks cannot revive output")
}

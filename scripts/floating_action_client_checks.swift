import Foundation
import ControllerCore

@MainActor
func runFloatingActionClientChecks(require: (Bool, String) -> Void, freshDefaults: () -> UserDefaults) throws {
    let member = ProfileControl(name: "Floating member", actions: [.a])
    let independent = ProfileControl(name: "Independent B", actions: [.b])
    var profile = try ControllerProfile(name: "Scoped actions", globalHoldEnabled: true)
    for control in [member, independent] { try profile.addControl(control, toPage: profile.homePageID) }
    let zone = FloatingButtonZone(name: "Floating A", kind: .singleButton, memberIDs: [member.id], startMemberID: member.id,
        portraitGeometry: .init(canvasWidth: 400, canvasHeight: 800, zone: .init(x: 0, y: 0, width: 200, height: 300)))
    profile.pages[0].floatingButtonZones = [zone]
    let finish = ProfileControl(name: "Scoped finish", payload: "RELEASE_ALL", floatingAction: .init(action: .finish, target: .zone(zone.id)))
    let missing = ProfileControl(name: "Missing target", payload: "X360X", floatingAction: .init(action: .finish, target: .zone(UUID())))
    for control in [finish, missing] { try profile.addControl(control, toPage: profile.homePageID) }
    let defaults = freshDefaults(), clock = ProfileCheckClock(), link = ProfileCheckTransport()
    defaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile])), forKey: ProfileControllerViewModel.libraryKey)
    let model = ProfileControllerViewModel(defaults: defaults, transport: link, clock: { clock.time }, automaticTimer: false)
    @discardableResult func send(_ event: ProfileInputEvent) -> Bool { model.handleInput(event, epoch: model.inputEpoch) }
    let first = UUID()
    require(send(.registerFloatingButtonSession(zoneID: zone.id, sessionID: first)), "App accepts a current floating zone session before member input")
    require(!send(.registerFloatingButtonSession(zoneID: zone.id, sessionID: UUID())), "App rejects a different session while the current floating zone is active")
    send(.begin(contact: 2400, control: member.id, position: .zero)); send(.end(contact: 2400))
    send(.begin(contact: 2401, control: independent.id, position: .zero)); send(.end(contact: 2401))
    require(model.state.buttons == [.a, .b], "Floating and independent holds coexist before scoped Finish")
    let epoch = model.inputEpoch
    require(send(.begin(contact: 2402, control: finish.id, position: .zero)), "A direct assigned Finish is accepted as a local action")
    send(.end(contact: 2402))
    require(model.state.buttons == [.b] && model.inputEpoch == epoch && model.dismissedFloatingButtonSessions[zone.id] == first,
            "Assigned Finish dismisses exactly its session and preserves independent output and the app epoch despite a dormant RELEASE_ALL payload")
    require(!send(.registerFloatingButtonSession(zoneID: zone.id, sessionID: first)), "A dismissed floating session cannot register itself again")
    let second = UUID()
    require(send(.registerFloatingButtonSession(zoneID: zone.id, sessionID: second)), "A deliberate fresh floating session can register after Finish")
    send(.begin(contact: 2403, control: member.id, position: .zero)); send(.end(contact: 2403))
    send(.finishFloatingButtonSession(zoneID: zone.id, sessionID: first))
    require(model.state.buttons == [.a, .b] && model.dismissedFloatingButtonSessions[zone.id] != second,
            "Late Finish from an older session cannot release or dismiss the new floating instance")
    send(.accessibilityActivate(missing.id))
    require(model.state.buttons == [.a, .b] && model.inputEpoch == epoch, "An unavailable target is inert and its dormant Xbox payload does not execute")
    send(.accessibilityActivate(finish.id))
    require(model.state.buttons == [.b] && model.dismissedFloatingButtonSessions[zone.id] == second && model.inputEpoch == epoch,
            "Accessibility activation performs the same scoped Finish without a global reset")
    model.releaseAll()
    require(model.state.isNeutral && model.dismissedFloatingButtonSessions.isEmpty, "Release all clears floating presentation metadata with its epoch reset")
    require(!model.handleInput(.registerFloatingButtonSession(zoneID: zone.id, sessionID: UUID()), epoch: epoch), "Old canvas callbacks cannot register a floating instance after Release all")
    model.beginLayoutEditing()
    var changed = finish; changed.floatingAction = .init(action: .finish, target: .zone(UUID()))
    model.saveControl(changed); model.cancelLayoutEditing()
    require(model.profile.control(for: finish.id) == finish, "Cancel restores an assigned action and its exact target with the whole draft")
    let reloaded = ProfileControllerViewModel(defaults: defaults, transport: ProfileCheckTransport(), clock: { clock.time }, automaticTimer: false)
    require(reloaded.profile == profile && reloaded.state.isNeutral && reloaded.dismissedFloatingButtonSessions.isEmpty,
            "Scoped action settings and dormant payloads reload exactly without prior floating sessions")

    // A scoped action remains local while an ordinary supported button reaches the bridge.
    model.setBridgeProtocol(.scx1); model.setMode(.bridge); model.host = "192.168.1.80"; model.portText = "42735"; model.connect()
    let session = link.sent.last!.session
    link.reply(.init(kind: .ready, session: session, sequence: 0, hidReady: true))
    let bridgeSession = UUID()
    require(send(.registerFloatingButtonSession(zoneID: zone.id, sessionID: bridgeSession)), "Bridge-ready app accepts floating session registration")
    send(.begin(contact: 2410, control: member.id, position: .zero)); send(.end(contact: 2410))
    send(.begin(contact: 2411, control: independent.id, position: .zero)); send(.end(contact: 2411))
    send(.accessibilityActivate(finish.id))
    require(model.isReady && model.state.buttons == [.b] && link.sent.last?.state?.buttons == [.b],
            "Scoped Finish preserves the bridge connection and independent buttons while releasing its member")
    model.releaseAll()
}

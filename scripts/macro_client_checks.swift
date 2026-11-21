import Foundation
import ControllerCore

@MainActor
func runMacroClientChecks(require: (Bool, String) -> Void, freshDefaults: () -> UserDefaults) throws {
    var macro = ProfileControl(name: "Macro", payload: "X360A,X360B(D400)(U100)")
    macro.macroModeEnabled = true
    let ordinary = ProfileControl(name: "Independent A", actions: [.a])
    var profile = try ControllerProfile(name: "Macro checks")
    for control in [macro, ordinary] { try profile.addControl(control, toPage: profile.homePageID) }
    let otherPage = try profile.addPage(name: "Another page")
    let otherProfile = try ControllerProfile(name: "Preserved profile")
    let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile, otherProfile])
    let saved = try ControllerProfileLibraryCodec.encode(library)
    let defaults = freshDefaults()
    defaults.set(saved, forKey: ProfileControllerViewModel.libraryKey)
    let clock = ProfileCheckClock()
    func load() -> ProfileControllerViewModel {
        ProfileControllerViewModel(defaults: defaults, transport: ProfileCheckTransport(),
                                   clock: { clock.time }, automaticTimer: false)
    }
    let model = load()
    func send(_ event: ProfileInputEvent) { model.handleInput(event, epoch: model.inputEpoch) }
    func advance(_ time: TimeInterval) { clock.time = time; model.tickInput() }
    func tap(_ contact: Int = 1) {
        send(.begin(contact: contact, control: macro.id, position: .zero))
        send(.end(contact: contact))
    }
    require(defaults.data(forKey: ProfileControllerViewModel.libraryKey) == saved,
            "Loading a saved macro library preserves its exact stored bytes")
    tap()
    require(model.state.buttons == [.a], "A quick macro tap stays active after finger-up through the app adapter")
    advance(10.199)
    require(model.state.buttons == [.a], "The default macro press remains active just before 200 ms")
    advance(10.201)
    require(model.state.isNeutral, "The default macro press releases after 200 ms")
    advance(10.401)
    require(model.state.buttons == [.b], "The delayed macro step starts after finger-up")
    advance(10.502)
    require(model.state.isNeutral, "Explicit U duration releases the delayed macro step")

    advance(11)
    send(.begin(contact: 2, control: ordinary.id, position: .zero))
    tap(3)
    advance(11.201)
    require(model.state.buttons == [.a], "The macro deadline preserves another control's held A")
    send(.end(contact: 2))
    model.releaseAll()
    advance(12)
    require(model.state.isNeutral, "Release all cancels pending steps after both fingers lifted")

    tap(4)
    let oldEpoch = model.inputEpoch
    model.beginLayoutEditing()
    advance(13)
    model.tickInput(epoch: oldEpoch)
    require(model.state.isNeutral, "Starting editing cancels a macro and invalidates its old timer epoch")
    model.cancelLayoutEditing()
    require(model.library == library, "Canceling editing preserves every profile and macro setting")

    tap(5)
    model.setForeground(false)
    advance(14)
    model.setForeground(true)
    model.tickInput()
    require(model.state.isNeutral, "Returning from background does not resume a macro")

    tap(6)
    model.selectPage(otherPage)
    advance(15)
    require(model.state.isNeutral && model.currentPageID == otherPage,
            "Changing page clears macro presses and future steps")
    model.selectPage(profile.homePageID)

    model.beginLayoutEditing()
    var edited = macro
    edited.payload = "X360A(U350),X360B(D500)(U100)"
    model.saveControl(edited)
    model.saveLayoutEditing()
    let restarted = load()
    require(restarted.profile.control(for: macro.id)?.macroModeEnabled == true &&
            restarted.profile.control(for: macro.id)?.payload == edited.payload,
            "Normal layout Save and relaunch preserve Macro Mode and explicit U timing")
    require(restarted.library.profiles.first(where: { $0.id == otherProfile.id }) == otherProfile &&
            restarted.profile.control(for: ordinary.id) == ordinary,
            "Saving a macro leaves other profiles and controls identical")
    require(restarted.state.isNeutral, "Relaunch restores macro settings with outputs at rest")
}

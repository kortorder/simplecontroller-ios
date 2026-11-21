import Foundation
import ControllerCore

@MainActor
func runOrientationClientChecks(require: (Bool, String) -> Void, freshDefaults: () -> UserDefaults) throws {
    var profile = try ControllerProfile(name: "Orientation sizes")
    let button = ProfileControl(name: "Shared A", actions: [.a], diameter: 80)
    let pad = ProfileControl(name: "Pad", kind: .touchpad)
    for control in [button, pad] { try profile.addControl(control, toPage: profile.homePageID) }
    let defaults = freshDefaults(), clock = ProfileCheckClock()
    defaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile])), forKey: ProfileControllerViewModel.libraryKey)
    func load(_ store: UserDefaults) -> ProfileControllerViewModel {
        ProfileControllerViewModel(defaults: store, transport: ProfileCheckTransport(), clock: { clock.time }, automaticTimer: false)
    }
    let model = load(defaults)
    var sized = button
    sized.orientationDimensions = .init(portrait: .init(width: 90, height: 120), landscape: .init(width: 160, height: 70))
    var sizedPad = pad
    sizedPad.orientationDimensions = .init(portrait: .init(width: 260, height: 170), landscape: .init(width: 420, height: 90))
    model.beginLayoutEditing(); model.saveControl(sized); model.saveControl(sizedPad)
    require(model.profile.control(for: button.id)?.dimensions(for: .portrait) == .init(width: 90, height: 120) &&
            model.profile.control(for: button.id)?.dimensions(for: .landscape) == .init(width: 160, height: 70),
            "Control edits keep independent portrait and landscape dimensions in the whole layout draft")
    require(model.profile.control(for: button.id)?.resolvedWidth == 80 && model.profile.portrait == profile.portrait && model.profile.landscape == profile.landscape,
            "Separate sizes preserve the shared fallback size and both saved positions")
    model.cancelLayoutEditing()
    require(model.profile == profile, "Whole-profile Cancel restores every orientation size together")
    model.beginLayoutEditing(); model.saveControl(sized); model.saveControl(sizedPad); model.saveLayoutEditing()
    let saved = model.profile, savedBytes = defaults.data(forKey: ProfileControllerViewModel.libraryKey)
    let reloaded = load(defaults)
    require(reloaded.profile == saved && reloaded.profile.control(for: pad.id)?.dimensions(for: .landscape) == .init(width: 420, height: 90),
            "Per-orientation button and touchpad sizes survive a neutral reload")
    let measured = FloatingCanvasSnapshot(width: 300, height: 200, frames: [button.id: .init(x: 20, y: 20, width: 160, height: 70), pad.id: .init(x: 0, y: 100, width: 300, height: 90)])
    reloaded.recordCanvasSnapshot(measured, profile: reloaded.profile, pageID: reloaded.currentPageID, orientation: .landscape)
    require(reloaded.profile == saved && defaults.data(forKey: ProfileControllerViewModel.libraryKey) == savedBytes,
            "A fitted canvas measurement does not replace larger saved orientation dimensions")
    reloaded.beginLayoutEditing(); reloaded.duplicateControl(sized)
    let copy = reloaded.profile.controls.last!
    require(copy.id != sized.id && copy.orientationDimensions == sized.orientationDimensions && copy.actions == sized.actions,
            "Copying a control retains both orientation sizes under an independent identity")
    reloaded.cancelLayoutEditing()
    reloaded.beginLayoutEditing()
    var invalid = sized; invalid.orientationDimensions.landscape = .init(width: 1, height: 90)
    reloaded.saveControl(invalid)
    require(reloaded.profile == saved, "An invalid orientation size is rejected before changing the layout draft")
    var sharedAgain = sized; sharedAgain.orientationDimensions = .init()
    reloaded.saveControl(sharedAgain)
    require(reloaded.profile.control(for: sized.id)?.dimensions(for: .portrait) == .init(width: 80, height: 80) &&
            reloaded.profile.control(for: sized.id)?.dimensions(for: .landscape) == .init(width: 80, height: 80),
            "Returning to shared dimensions recovers the unchanged shared size in both orientations")
    reloaded.cancelLayoutEditing()
    require(reloaded.profile == saved, "Canceling the return to shared sizes restores both independent values")
    require(reloaded.duplicateProfile(saved.id), "A profile with orientation sizes can be duplicated")
    require(reloaded.profile.id != saved.id && reloaded.profile.controls.map(\.orientationDimensions) == saved.controls.map(\.orientationDimensions),
            "Profile duplication retains orientation dimensions while remapping profile and control identities")

    // Authentic18 data contains no new orientation field and must not change on load.
    let legacyDefaults = freshDefaults()
    var raw = try JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile]))) as! [String: Any]
    raw["version"] = 18
    var rawProfiles = raw["profiles"] as! [[String: Any]], rawControls = (raw["profiles"] as! [[String: Any]])[0]["controls"] as! [[String: Any]]
    for i in rawControls.indices {
        rawControls[i].removeValue(forKey: "orientationDimensions")
        rawControls[i].removeValue(forKey: "macroModeEnabled")
        rawControls[i].removeValue(forKey: "stickPlusRepeatIntervalMilliseconds")
    }
    rawProfiles[0]["controls"] = rawControls; raw["profiles"] = rawProfiles
    let bytes = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    legacyDefaults.set(bytes, forKey: ProfileControllerViewModel.libraryKey)
    let legacy = load(legacyDefaults)
    require(legacy.canEditLayout && legacy.profile == profile && legacyDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == bytes,
            "Format18 shared sizes load with their exact geometry and no saved-byte rewrite")
    legacy.beginLayoutEditing(); legacy.saveLayoutEditing()
    require(legacyDefaults.data(forKey: "controller.profiles.before-format-18") == bytes && legacy.profile == profile,
            "The first current-format save keeps the exact format18 recovery copy without changing shared sizes")
}

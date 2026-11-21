import Foundation
import ControllerCore

@MainActor
func runStarterClientChecks(require: (Bool, String) -> Void, freshDefaults: () -> UserDefaults) throws {
    func load(_ defaults: UserDefaults) -> ProfileControllerViewModel {
        ProfileControllerViewModel(defaults: defaults, transport: ProfileCheckTransport(), automaticTimer: false)
    }
    let resources = URL(fileURLWithPath: "profiles/Starters", isDirectory: true)
    let defaults = freshDefaults()
    let model = load(defaults)
    require(model.takeStarterWelcome() && !model.takeStarterWelcome(), "A new install offers the starter gallery once")
    let standard = model.library.activeProfile
    let stored = defaults.data(forKey: ProfileControllerViewModel.libraryKey)
    let upgrade = load(defaults)
    require(!upgrade.takeStarterWelcome() && upgrade.profile == standard &&
            defaults.data(forKey: ProfileControllerViewModel.libraryKey) == stored,
            "Launching with an existing library keeps its bytes and active selection")
    require(!model.useStarter(.shooter, resourceDirectory: nil) && model.profile == standard &&
            defaults.data(forKey: ProfileControllerViewModel.libraryKey) == stored,
            "Missing starter data preserves the library and reports an error")
    var names: [GameStarter: UUID] = [:]
    for starter in GameStarter.allCases {
        let templateData = try Data(contentsOf: resources.appendingPathComponent(starter.rawValue).appendingPathExtension("json"))
        let template = try ControllerProfileLibraryCodec.decode(templateData).activeProfile
        let previous = model.library.profiles
        require(model.useStarter(starter, resourceDirectory: resources), "Can select bundled \(starter.rawValue) starter")
        let added = model.profile
        require(model.library.profiles.dropLast().elementsEqual(previous) && added.name == starter.rawValue &&
                model.currentPageID == added.homePageID && model.state.isNeutral,
                "\(starter.rawValue) opens its first page at rest and all earlier profiles survive")
        require(added.id != template.id && Set(added.pages.map(\.id)).isDisjoint(with: template.pages.map(\.id)) &&
                Set(added.controls.map(\.id)).isDisjoint(with: template.controls.map(\.id)) &&
                added.controls.map(\.name) == template.controls.map(\.name),
                "\(starter.rawValue) gets fresh profile, page and control identities")
        names[starter] = added.id
    }
    let restart = load(defaults)
    require(restart.library == model.library && !restart.takeStarterWelcome(), "The selected starter and all older profiles survive relaunch")
    let shooter = model.library.profiles.first { $0.id == names[.shooter] }!
    require(model.useStarter(.shooter, resourceDirectory: resources), "A starter can be chosen again")
    require(model.profile.name == "Shooter 2" && model.profile.id != shooter.id &&
            Set(model.profile.controls.map(\.id)).isDisjoint(with: shooter.controls.map(\.id)),
            "Repeated choice creates a distinguishable independent copy")
    let second = model.profile.id
    require(model.renameProfile(second, name: "Custom controls") && model.library.profiles.first(where: { $0.id == shooter.id }) == shooter,
            "Editing a second copy leaves the first copy intact")
    model.beginLayoutEditing()
    require(!model.useStarter(.sports, resourceDirectory: resources) && model.library.activeProfileID == second,
            "Active editing prevents starter selection from discarding a draft")
    model.cancelLayoutEditing()

    let legacy = freshDefaults()
    legacy.set(try ControllerLayoutCodec.encode(.default), forKey: "controller.layout.v1")
    require(!load(legacy).takeStarterWelcome(), "Legacy layout migration bypasses the first-run gallery")
    let damaged = freshDefaults(), corrupt = Data([0])
    damaged.set(corrupt, forKey: ProfileControllerViewModel.libraryKey)
    let recovery = load(damaged)
    require(!recovery.takeStarterWelcome() && !recovery.useStarter(.racing, resourceDirectory: resources) &&
            damaged.data(forKey: ProfileControllerViewModel.libraryKey) == corrupt,
            "Protected profile data survives a rejected starter choice")
    let full = freshDefaults()
    let many = try (1...32).map { try ControllerProfile(name: "Saved \($0)") }
    let fullBytes = try ControllerProfileLibraryCodec.encode(.init(activeProfileID: many[0].id, profiles: many))
    full.set(fullBytes, forKey: ProfileControllerViewModel.libraryKey)
    let atLimit = load(full)
    require(!atLimit.useStarter(.racing, resourceDirectory: resources) && atLimit.profile == many[0] &&
            full.data(forKey: ProfileControllerViewModel.libraryKey) == fullBytes,
            "A full library retains all 32 saved profiles and the current selection")
}

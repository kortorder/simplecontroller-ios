import Foundation
import ControllerCore

/// Executes the actual app import/save path with isolated preferences and archive folders.
/// The caller owns assertion accounting and removal of the temporary UserDefaults suites.
@MainActor
func runAndroidPresetClientChecks(require: (Bool, String) -> Void,
                                 freshDefaults: () -> UserDefaults) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleController.AndroidPresetVMChecks." + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func model(_ defaults: UserDefaults, folder: String) -> ProfileControllerViewModel {
        let clock = ProfileCheckClock(), transport = ProfileCheckTransport()
        return ProfileControllerViewModel(defaults: defaults, transport: transport, clock: { clock.time },
            automaticTimer: false, persistSettings: true,
            androidArchiveDirectory: root.appendingPathComponent(folder, isDirectory: true))
    }
    func folderExists(_ folder: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path) }
    func backup(profileCount: Int = 2, oversizedProfile: Bool = false, presetName: String = "Saved movement") -> Data {
        let directionalCommands = [("up", "W"), ("right", "D"), ("down", "S"), ("left", "A")].flatMap { direction, key in
            [#""\#(direction)Command":"\#(key)""#, #""\#(direction)BoostCommand":"\#(key),SHIFT""#, #""\#(direction)SuperBoostCommand":"\#(key),SPACE""#]
        }.joined(separator: ",")
        let controls = oversizedProfile ? (0..<65).map { #"{"id":"c\#($0)","type":"BUTTON","name":"A","payload":"X360A","x":0,"y":0,"w":44,"h":44}"# }.joined(separator: ",") : ""
        let profiles = (0..<profileCount).map { #"{"name":"Android \#($0)","profile":{"formatVersion":10,"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[\#(controls)]}]}}"# }.joined(separator: ",")
        return Data(#" {"fileType":"simplecontroller-profiles-backup","backupVersion":3,"activeControllerProfileName":"Android 0","controllerProfiles":[\#(profiles)],"stickDirectionalProfiles":[{"schemaVersion":2,"id":"source-preset","name":"\#(presetName)","createdAtEpochMs":100,"updatedAtEpochMs":200,"mode":"WASD","settings":{\#(directionalCommands),"boostThreshold":0.5,"superBoostThreshold":0.75},"unknown":{"precise":9007199254740993}}]} "#.utf8)
    }

    // A multi-profile Android file owns one preset library. Preview and import must not
    // accidentally attach the same preset once per converted profile or write during preview.
    let bytes = backup(), defaults = freshDefaults()
    var local = ControllerProfileLibrary.default
    let selected = try ControllerProfile(name: "Keep selected")
    local.profiles.append(selected); local.activeProfileID = selected.id
    defaults.set(try ControllerProfileLibraryCodec.encode(local), forKey: ProfileControllerViewModel.libraryKey)
    let app = model(defaults, folder: "normal"), initial = app.library
    let before = defaults.data(forKey: ProfileControllerViewModel.libraryKey)
    let preview = try AndroidImportPreview.prepare(bytes, displayName: "Android settings.json")
    require(preview.plan.profiles.count == 2 && preview.plan.convertedPresetCount == 1,
            "Android preview counts one reusable preset independently of its two converted profiles")
    require(app.library == initial && defaults.data(forKey: ProfileControllerViewModel.libraryKey) == before && !folderExists("normal"),
            "Android preset preview changes neither preferences nor archive files")
    require(app.importAndroid(preview), "Android presets import through the actual app confirmation path")
    require(app.library.settingsPresets.entries.count == 1 && app.library.profiles.count == initial.profiles.count + 2,
            "Android settings are merged once for the whole backup, not once per converted profile")
    require(app.library.activeProfileID == selected.id && app.library.profiles.prefix(initial.profiles.count).elementsEqual(initial.profiles),
            "Android preset import keeps the existing selected profile and all existing profiles unchanged")
    let originals = app.androidOriginals()
    require(originals.count == 1 && app.exportAndroidOriginal(originals[0]) == bytes,
            "Preset conversion retains the exact Android original including unknown large integers")
    let committedIDs = Set(app.library.settingsPresets.entries.map(\.id))
    require(committedIDs.isDisjoint(with: preview.plan.settingsPresets.entries.map(\.id)),
            "Confirmed imported presets have independent IDs rather than preview or source identities")
    let reloaded = model(defaults, folder: "normal")
    require(reloaded.library == app.library, "Android imported presets and current selection survive a model reload")

    let repeatedPreview = try AndroidImportPreview.prepare(bytes, displayName: "Same original again.json")
    require(app.importAndroid(repeatedPreview), "Repeated Android preset import creates a fresh native copy")
    let entries = app.library.settingsPresets.entries
    require(entries.count == 2 && Set(entries.map(\.id)).count == 2 && Set(entries.map(\.name)).count == 2,
            "Repeated Android presets receive fresh IDs and distinct collision-safe names")
    require(entries.contains { committedIDs.contains($0.id) } && app.androidOriginals().count == 1,
            "Repeated Android import preserves earlier presets while deduplicating the one original archive")
    require(app.library.activeProfileID == selected.id, "Repeated preset import does not switch the active profile")
    if let portableBytes = app.exportProfiles() {
        let portable = try AndroidPortableBackup.decode(portableBytes)
        let portableLibrary = try ControllerProfileLibraryCodec.decode(portable.nativeLibraryData)
        require(portableLibrary.settingsPresets.entries.count == 2 && portable.archives.count == 1,
                "Portable backup stores converted presets once and bundles their exact original once")
        let restored = model(freshDefaults(), folder: "restored"), restoreSelection = restored.library.activeProfileID
        require(restored.importProfiles(portableBytes), "Portable backup restores Android-derived presets into a fresh app archive store")
        require(restored.library.settingsPresets.entries.count == 2 && restored.androidOriginals().count == 1 && restored.library.activeProfileID == restoreSelection,
                "Portable restore merges the preset library once and preserves destination selection")
    } else { require(false, "Portable export succeeds after Android preset conversion") }

    // Every source profile can be too large to convert while its separately saved settings
    // remain useful. The original is still archived and the native profile list stays intact.
    let settingsOnly = model(freshDefaults(), folder: "settingsOnly"), settingsOnlyInitial = settingsOnly.library
    let noProfileBytes = backup(profileCount: 1, oversizedProfile: true)
    let noProfilePreview = try AndroidImportPreview.prepare(noProfileBytes, displayName: "Large original with reusable settings.json")
    require(noProfilePreview.plan.profiles.isEmpty && noProfilePreview.plan.convertedPresetCount == 1,
            "Android preview can convert reusable settings when no controller profile fits native limits")
    require(settingsOnly.importAndroid(noProfilePreview), "Settings-only Android conversion is accepted by the app without inventing a profile")
    require(settingsOnly.library.profiles == settingsOnlyInitial.profiles && settingsOnly.library.activeProfileID == settingsOnlyInitial.activeProfileID && settingsOnly.library.settingsPresets.entries.count == 1,
            "Settings-only import adds one preset without changing any native profile or selection")
    let settingsOnlyOriginals = settingsOnly.androidOriginals()
    require(settingsOnlyOriginals.count == 1 && settingsOnly.exportAndroidOriginal(settingsOnlyOriginals[0]) == noProfileBytes,
            "A settings-only import archives every oversized source control exactly")

    // A colliding user preset is never overwritten by an Android preset with the same name.
    let collisionDefaults = freshDefaults(), value = preview.plan.settingsPresets.entries[0].value
    var collisionLibrary = ControllerProfileLibrary.default
    let saved = SettingsPreset(name: "Saved movement", createdAtMilliseconds: 5, value: value)
    try collisionLibrary.settingsPresets.save(saved)
    collisionDefaults.set(try ControllerProfileLibraryCodec.encode(collisionLibrary), forKey: ProfileControllerViewModel.libraryKey)
    let collision = model(collisionDefaults, folder: "collision")
    require(collision.importAndroid(preview), "Android preset import accepts a name collision by creating a new named copy")
    require(collision.library.settingsPresets.entry(saved.id) == saved && collision.library.settingsPresets.entries.count == 2,
            "Name collision leaves the exact existing user preset intact")
    require(collision.library.settingsPresets.entries.filter { $0.id != saved.id }.allSatisfy { $0.name != saved.name },
            "The new preset gets a distinct display name without replacing the existing entry")

    // Capacity is checked on the fully merged candidate before the archive store is touched.
    let fullDefaults = freshDefaults(); var fullLibrary = ControllerProfileLibrary.default
    fullLibrary.settingsPresets.entries = (0..<SettingsPresetLibrary.maximumPerCategory).map {
        SettingsPreset(name: "Existing \($0)", createdAtMilliseconds: 1, value: value)
    }
    let fullBytes = try ControllerProfileLibraryCodec.encode(fullLibrary)
    fullDefaults.set(fullBytes, forKey: ProfileControllerViewModel.libraryKey)
    let full = model(fullDefaults, folder: "capacity")
    require(!full.importAndroid(preview), "A full reusable-settings category rejects the entire Android import")
    require(full.library == fullLibrary && fullDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == fullBytes,
            "Preset capacity failure leaves all profiles, presets and saved bytes unchanged")
    require(!folderExists("capacity") && full.androidOriginals().isEmpty,
            "Preset capacity failure happens before creating any Android archive directory or file")
    require(full.message?.contains("unchanged") == true,
            "Preset capacity failure gives a user-visible unchanged-data explanation")
}

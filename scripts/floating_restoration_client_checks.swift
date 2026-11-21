import Foundation
import ControllerCore

@MainActor
func runFloatingRestorationClientChecks(require: (Bool, String) -> Void, freshDefaults: () -> UserDefaults) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleController-Restoration-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = Data(#"{"formatVersion":10,"homePageId":"p","pages":[{"id":"p","name":"Main","controls":[{"id":"a","name":"A","type":"BUTTON","x":80,"y":100,"w":80,"h":80,"payload":"X360A"}],"portraitGeometry":{"canvasWidth":400,"canvasHeight":800,"controls":{"a":{"x":80,"y":100,"w":80,"h":80}}},"landscapeGeometry":{"canvasWidth":800,"canvasHeight":400,"controls":{"a":{"x":360,"y":100,"w":180,"h":80}}},"floatingZones":[{"id":"zone","kind":"SINGLE_BUTTON","name":"Floating A","memberIds":["a"],"startMemberId":"a","portraitGeometry":{"canvasWidth":400,"canvasHeight":800,"zone":{"x":0,"y":0,"w":240,"h":240}},"landscapeGeometry":{"canvasWidth":800,"canvasHeight":400,"zone":{"x":0,"y":0,"w":240,"h":240}},"portraitMemberGeometry":{"a":{"x":10,"y":20,"w":44,"h":44}},"landscapeMemberGeometry":{"a":{"x":10,"y":20,"w":44,"h":44}},"portraitRestorationGeometry":{"a":{"x":200,"y":300,"w":100,"h":120}},"landscapeRestorationGeometry":{"a":{"x":600,"y":200,"w":100,"h":140}},"unknownRestoreMetadata":9007199254740993}]}]}"#.utf8)
    let defaults = freshDefaults(), clock = ProfileCheckClock()
    let model = ProfileControllerViewModel(defaults: defaults, transport: ProfileCheckTransport(), clock: { clock.time }, automaticTimer: false, androidArchiveDirectory: root.appendingPathComponent("originals"))
    let preview = try AndroidImportPreview.prepare(original, displayName: "Floating restore.json")
    require(model.importAndroid(preview), "Floating restoration fixture imports through the real archive/store app path")
    let imported = model.library.profiles.last!
    require(model.selectProfile(imported.id), "Imported floating profile can be selected for restoration")
    let zone = model.profile.pages[0].floatingButtonZones[0], member = model.profile.controls[0]
    let before = model.profile, savedBytes = defaults.data(forKey: ProfileControllerViewModel.libraryKey)
    model.beginLayoutEditing()
    let restored = try await model.restoreFloatingButtons(model.profile, zoneID: zone.id, pageID: model.currentPageID)
    require(model.profile == before && defaults.data(forKey: ProfileControllerViewModel.libraryKey) == savedBytes,
            "Reading imported restoration returns a new draft without modifying the editor or saved library")
    require(restored.pages[0].floatingButtonZones.isEmpty && restored.control(for: member.id)?.payload == member.payload,
            "Imported restoration removes only its floating zone and preserves the button's action")
    let base = imported.androidSources[0].exportBaseline!.controls[0]
    let pSize = restored.control(for: member.id)!.dimensions(for: .portrait), lSize = restored.control(for: member.id)!.dimensions(for: .landscape)
    require(abs(pSize.width - max(44, 100 * base.portrait.sizeScale)) < 1e-8 && abs(pSize.height - max(44, 120 * base.portrait.sizeScale)) < 1e-8 &&
            abs(lSize.width - max(44, 100 * base.landscape.sizeScale)) < 1e-8 && abs(lSize.height - max(44, 140 * base.landscape.sizeScale)) < 1e-8,
            "Both archived restoration sizes use their own original import-fit scale")
    require(restored.portrait[0].position == .init(x: 0.625, y: 0.45) && restored.landscape[0].position == .init(x: 0.8125, y: 0.675),
            "Both restoration maps restore their source-normalized centers")
    require(restored.androidSources.map(\.exportBaseline) == before.androidSources.map(\.exportBaseline) &&
            restored.androidSources[0].controls.first(where: { $0.nativeID == member.id })?.floatingRestoration?.orientations == Set([.portrait, .landscape]),
            "Restoration records exactly which orientations were restored while preserving immutable export baselines")
    model.saveFloatingDraft(restored); model.cancelLayoutEditing()
    require(model.profile == before && defaults.data(forKey: ProfileControllerViewModel.libraryKey) == savedBytes,
            "Cancel discards imported Unfloat and every restored dimension with the entire layout draft")
    model.beginLayoutEditing()
    let canceled = Task { @MainActor in try await model.restoreFloatingButtons(model.profile, zoneID: zone.id, pageID: model.currentPageID) }
    canceled.cancel()
    do { _ = try await canceled.value; require(false, "Canceled restoration must not publish a draft") }
    catch { require(model.profile == before, "Canceled archive restoration leaves the whole draft unchanged") }
    let finalDraft = try await model.restoreFloatingButtons(model.profile, zoneID: zone.id, pageID: model.currentPageID)
    model.saveFloatingDraft(finalDraft); model.saveLayoutEditing()
    let reloaded = ProfileControllerViewModel(defaults: defaults, transport: ProfileCheckTransport(), clock: { clock.time }, automaticTimer: false, androidArchiveDirectory: root.appendingPathComponent("originals"))
    require(reloaded.profile == finalDraft && reloaded.state.isNeutral, "Saved restored geometry survives a neutral app reload")
    let edited = await reloaded.prepareEditedAndroidExport(reloaded.profile.id)
    require(edited?.preview.canExport == true, "Restored imported buttons remain exportable as a reviewed Android copy")
    let result = try AndroidProfileDocument.parse(edited!.preview.data!)
    let page = result.profiles[0].pages[0].value
    require(page["floatingZones"]?.arrayValue?.isEmpty == true && page["portraitGeometry"]?["controls"]?["a"]?["w"]?.numberValue?.rawValue == "100" &&
            page["landscapeGeometry"]?["controls"]?["a"]?["h"]?.numberValue?.rawValue == "140",
            "Edited Android export restores the original source units after Unfloat")
    require(reloaded.exportAndroidOriginal(reloaded.library.androidSources[0]) == original, "Restoring and exporting edits never modifies the preserved Android original")

    let missingDefaults = freshDefaults()
    missingDefaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: before.id, profiles: [before], androidSources: model.library.androidSources)), forKey: ProfileControllerViewModel.libraryKey)
    let missing = ProfileControllerViewModel(defaults: missingDefaults, transport: ProfileCheckTransport(), clock: { clock.time }, automaticTimer: false, androidArchiveDirectory: root.appendingPathComponent("missing"))
    missing.beginLayoutEditing()
    do { _ = try await missing.restoreFloatingButtons(missing.profile, zoneID: zone.id, pageID: missing.currentPageID); require(false, "An imported restoration cannot guess when its archive is unavailable") }
    catch { require(missing.profile == before, "An unavailable original leaves imported floating controls and their draft untouched") }
}

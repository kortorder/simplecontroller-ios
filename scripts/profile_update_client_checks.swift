import Foundation
import ControllerCore

@MainActor
private final class UpdateTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    func open(host: String, port: UInt16) { onReady?() }
    func send(_ data: Data) {}
    func close(afterSending data: Data?) {}
}

@main
struct ProfileUpdateClientChecks {
    @MainActor
    static func main() throws {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--validate-swipes" {
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), format: nil) as! [String: Any]
            let raw = plist[ProfileControllerViewModel.libraryKey] as! Data
            let plan = try DebugButtonSwipeUpdate.prepare(expectedCurrentLibrarySHA256: DebugProfileLayoutUpdate.digest(raw), currentRaw: raw)
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
            let actual = try JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(plan.candidate))
            guard try DebugProfileLayoutUpdate.same(actual, expected) else { fatalError("Candidate differs from independent expected transformation") }
            print("PASS: private setting-only update validated read-only against independent expected JSON; \(plan.candidate.profiles.count) profiles, \(plan.buttonsEnabled) button flags and \(plan.profileModesEnabled) profile modes changed. No private contents printed or saved.")
            return
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--validate-package" {
            let packageURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            let currentURL = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
            let packageData = try DebugProfileLayoutUpdate.readPackage(packageURL, documents: packageURL.deletingLastPathComponent())
            let currentData = try DebugProfileLayoutUpdate.readPackage(currentURL, documents: currentURL.deletingLastPathComponent())
            let plan = try DebugProfileLayoutUpdate.prepare(packageData, currentRaw: currentData)
            print("PASS: private package validated read-only; \(plan.beforeCount) -> \(plan.candidate.profiles.count) profiles, \(plan.protectedCount) protected. No profile contents printed or saved.")
            return
        }
        guard CommandLine.arguments.count == 1 else { throw DebugProfileLayoutUpdate.Rejection(code: "invalid_checker_arguments") }
        var count = 0
        func require(_ good: Bool, _ label: String) {
            count += 1
            if !good { fatalError("FAIL \(count): \(label)") }
        }
        func makeProfile(_ name: String) throws -> ControllerProfile {
            var result = try ControllerProfile(name: name)
            try result.addControl(.init(name: "A", actions: [.a]), toPage: result.homePageID)
            return result
        }
        var baseProfiles = try ["My Controller", "GTA 6 Prep imported", "Touchpad test", "Feature check imported"].map(makeProfile)
        try baseProfiles[0].addControl(.init(name: "Menus", kind: .pageButton), toPage: baseProfiles[0].homePageID)
        let original = try ControllerProfileLibrary(activeProfileID: baseProfiles[0].id, profiles: baseProfiles)
        let raw = try ControllerProfileLibraryCodec.encode(original)
        var changed = original
        changed.profiles[0].portrait[0].position = .init(x: 0.1, y: 0.65)
        changed.profiles[0].controls[0].diameter = 48
        try changed.profiles[0].addControl(.init(name: "Menu", actions: [.menu]), toPage: changed.profiles[0].homePageID)
        changed.profiles.append(try makeProfile("Palworld"))
        func package(_ library: ControllerProfileLibrary, hash: String? = nil, protectedIDs: [String] = []) throws -> Data {
            let object = try JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library))
            return try JSONSerialization.data(withJSONObject: ["fileType": "simplecontroller-layout-update", "version": 1,
                "expectedCurrentLibrarySHA256": hash ?? DebugProfileLayoutUpdate.digest(raw),
                "protectedProfileIDs": protectedIDs, "library": object], options: [.sortedKeys])
        }
        func newModel() -> (ProfileControllerViewModel, UserDefaults) {
            let name = "sc025-layout-check-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.set(raw, forKey: ProfileControllerViewModel.libraryKey)
            defaults.set("preserve", forKey: "unrelated.setting")
            return (ProfileControllerViewModel(defaults: defaults, transport: UpdateTransport(), automaticTimer: false), defaults)
        }
        func rejected(_ data: Data, reason: String? = nil) throws {
            let (model, defaults) = newModel()
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let receipt = model.applyDebugProfileUpdate(data)
            require(receipt["status"] as? String == "rejected", "reject invalid update")
            if let reason { require(receipt["reason"] as? String == reason, "expected rejection \(reason)") }
            require(defaults.dictionaryRepresentation() as NSDictionary == before && model.library == original,
                    "rejected update changes no saved values or profiles")
        }
        for label in ["Controls", "All keys"] {
            var relabeled = changed; relabeled.profiles[0].controls[1].name = label
            let plan = try DebugProfileLayoutUpdate.prepare(package(relabeled), currentRaw: raw)
            require(plan.candidate == relabeled, "authorized navigation-only label \(label)")
        }
        var alteredNavigation = changed; alteredNavigation.profiles[0].controls[1].name = "Unapproved label"
        try rejected(package(alteredNavigation), reason: "control_behavior_changed")
        alteredNavigation = changed; alteredNavigation.profiles[0].controls[1].name = "All keys"
        alteredNavigation.profiles[0].controls[1].pageNavigation = .back
        try rejected(package(alteredNavigation), reason: "control_behavior_changed")
        try rejected(package(changed, hash: String(repeating: "0", count: 64)), reason: "stale_saved_library")
        try rejected(Data("invalid json".utf8))
        try rejected(Data(repeating: 32, count: DebugProfileLayoutUpdate.maximumBytes + 1), reason: "file_too_large")
        for index in 1...3 {
            var broken = changed; broken.profiles[index].portrait[0].position = .init(x: 0.9, y: 0.5)
            try rejected(package(broken), reason: "protected_profile_changed")
        }
        try rejected(package(changed, protectedIDs: [baseProfiles[0].id.uuidString]), reason: "protected_profile_changed")
        try rejected(package(changed, protectedIDs: [UUID().uuidString]), reason: "invalid_protected_ids")
        var broken = changed; broken.profiles[0].controls[0].payload = "X360B"
        try rejected(package(broken), reason: "control_behavior_changed")
        broken = changed; broken.profiles[0].controls[0].buttonBehavior.holdToggle = true
        try rejected(package(broken), reason: "control_behavior_changed")
        broken = changed; broken.profiles[0].controls[0].name = "Renamed gameplay action"
        try rejected(package(broken), reason: "control_behavior_changed")
        broken = changed; try broken.profiles[0].removeControl(baseProfiles[0].controls[0].id)
        try rejected(package(broken), reason: "control_removed")
        broken = changed; broken.profiles.remove(at: 3)
        try rejected(package(broken), reason: "profile_removed")
        broken = changed; broken.activeProfileID = baseProfiles[1].id
        try rejected(package(broken), reason: "library_metadata_changed")
        broken = changed; broken.profiles[0].turboEnabled = true
        try rejected(package(broken), reason: "profile_settings_changed")
        let (editing, editDefaults) = newModel(); editing.beginLayoutEditing()
        let editBefore = editDefaults.dictionaryRepresentation() as NSDictionary
        require(editing.applyDebugProfileUpdate(try package(changed))["status"] as? String == "rejected" &&
                editDefaults.dictionaryRepresentation() as NSDictionary == editBefore, "active draft blocks update")
        let (model, defaults) = newModel()
        let receipt = model.applyDebugProfileUpdate(try package(changed))
        require(receipt["status"] as? String == "applied" && model.library == changed, "valid update applied exactly")
        require(model.state.isNeutral && model.library.activeProfileID == original.activeProfileID, "neutral and active selection preserved")
        require(model.library.profiles[1...3].elementsEqual(original.profiles[1...3]), "all automatically protected profiles identical")
        require(model.recoveryDocuments.contains { $0.data == raw }, "exact raw backup retained")
        require(defaults.string(forKey: "unrelated.setting") == "preserve", "non-profile settings preserved")
        require(try ControllerProfileLibraryCodec.decode(defaults.data(forKey: ProfileControllerViewModel.libraryKey)!) == changed, "save persists candidate")
        let after = defaults.dictionaryRepresentation() as NSDictionary
        require(model.applyDebugProfileUpdate(try package(changed))["reason"] as? String == "stale_saved_library" &&
                defaults.dictionaryRepresentation() as NSDictionary == after, "replay rejected without another backup")
        for name in ["../outside.json", "/tmp/update.json", "folder/update.json", "x..json", "Profile-update-receipt.json", "update.txt"] {
            require(!DebugProfileLayoutUpdate.validBasename(name), "reject unsafe file name")
        }
        require(DebugProfileLayoutUpdate.validBasename("Left-side-update-0.25.json"), "valid direct-child file name")
        let docs = FileManager.default.temporaryDirectory.appendingPathComponent("sc025-update-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docs) }
        let file = docs.appendingPathComponent("update.json")
        try package(changed).write(to: file)
        let (ordinary, ordinaryDefaults) = newModel()
        ordinary.applyRequestedProfileUpdate(arguments: ["app"], documentsDirectory: docs)
        require(ordinaryDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == raw &&
                !FileManager.default.fileExists(atPath: docs.appendingPathComponent(DebugProfileLayoutUpdate.receiptName).path), "ordinary launch ignores package")
        let (launch, launchDefaults) = newModel()
        launch.applyRequestedProfileUpdate(arguments: ["app", "--apply-profile-update", "update.json"], documentsDirectory: docs)
        let receiptData = try Data(contentsOf: docs.appendingPathComponent(DebugProfileLayoutUpdate.receiptName))
        let launchReceipt = try JSONSerialization.jsonObject(with: receiptData) as! [String: Any]
        require(launchReceipt["status"] as? String == "applied" && launch.library == changed, "explicit launch reads Documents and applies")
        require(launchReceipt["library"] == nil && launchReceipt["profiles"] == nil, "receipt contains no full private library")
        let launchAfter = launchDefaults.dictionaryRepresentation() as NSDictionary
        launch.applyRequestedProfileUpdate(arguments: ["app", "--apply-profile-update", "update.json"], documentsDirectory: docs)
        let repeatedReceiptData = try Data(contentsOf: docs.appendingPathComponent(DebugProfileLayoutUpdate.receiptName))
        require(launchDefaults.dictionaryRepresentation() as NSDictionary == launchAfter &&
                repeatedReceiptData == receiptData, "launch handler executes once")
        let symlink = docs.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        do { _ = try DebugProfileLayoutUpdate.readPackage(symlink, documents: docs); require(false, "symlink rejected") }
        catch { require(true, "symlink rejected") }
        // The setting-only action covers all profiles, including names protected
        // from layout edits, while retaining every value outside the two switches.
        var swipeOriginal = original
        swipeOriginal.profiles[0].swipeMode = .off
        swipeOriginal.profiles[1].swipeMode = .controls
        swipeOriginal.profiles[2].swipeMode = .buttons
        swipeOriginal.profiles[3].swipeMode = .off
        for kind in [ProfileControlKind.leftStick, .rightStick, .recenter, .touchpad, .touchAim] {
            try swipeOriginal.profiles[0].addControl(.init(kind: kind, swipeActivationEnabled: false), toPage: swipeOriginal.profiles[0].homePageID)
        }
        var aim = ProfileControl(name: "Aim", payload: "X360A"); aim.buttonAim.enabled = true
        var directional = ProfileControl(name: "Directions", actions: [.a]); directional.buttonDirectional.enabled = true
        for control in [aim, directional, ProfileControl(name: "Scroll", payload: "SCROLL_MODE_TOGGLE"),
                        ProfileControl(name: "Release", payload: "RELEASE_ALL"), ProfileControl(name: "Camera", payload: "CAMERA_FOLLOW")] {
            try swipeOriginal.profiles[0].addControl(control, toPage: swipeOriginal.profiles[0].homePageID)
        }
        let member = swipeOriginal.profiles[0].controls[0]
        var zone = FloatingButtonZone(name: "Keep finish guard", kind: .singleButton, memberIDs: [member.id], startMemberID: member.id,
            groupSwipe: false, portraitGeometry: .init(canvasWidth: 400, canvasHeight: 800, zone: .init(x: 0, y: 0, width: 200, height: 300)))
        zone.finishIgnoresSwipes = true
        swipeOriginal.profiles[0].pages[0].floatingButtonZones = [zone]
        try swipeOriginal.profiles[0].addControl(.init(name: "Finish", payload: "RELEASE_ALL", floatingAction: .init(action: .finish, target: .zone(zone.id))),
            toPage: swipeOriginal.profiles[0].homePageID)
        for i in swipeOriginal.profiles.indices {
            for j in swipeOriginal.profiles[i].controls.indices { swipeOriginal.profiles[i].controls[j].swipeActivationEnabled = false }
        }
        let swipeRaw = try ControllerProfileLibraryCodec.encode(swipeOriginal)
        let swipeHash = DebugProfileLayoutUpdate.digest(swipeRaw)
        var swipeExpected = swipeOriginal
        for i in swipeExpected.profiles.indices {
            if swipeExpected.profiles[i].swipeMode == .off { swipeExpected.profiles[i].swipeMode = .buttons }
            for j in swipeExpected.profiles[i].controls.indices where swipeExpected.profiles[i].controls[j].kind == .button {
                swipeExpected.profiles[i].controls[j].swipeActivationEnabled = true
            }
        }
        let swipePlan = try DebugButtonSwipeUpdate.prepare(expectedCurrentLibrarySHA256: swipeHash, currentRaw: swipeRaw)
        require(swipePlan.candidate == swipeExpected, "only button flags and off profile modes change across every profile")
        require(swipePlan.buttonsEnabled == swipeOriginal.profiles.flatMap(\.controls).filter { $0.kind == .button }.count &&
                swipePlan.profileModesEnabled == 2, "exact change counts")
        require(swipePlan.candidate.profiles[1].swipeMode == .controls && swipePlan.candidate.profiles[2].swipeMode == .buttons,
                "existing slide-between-controls and slide-between-buttons modes preserved")
        require(swipePlan.candidate.profiles[0].pages[0].floatingButtonZones == [zone], "floating group mode, geometry and finish guard preserved")
        require(swipePlan.candidate.profiles.flatMap(\.controls).filter { $0.kind != .button }.allSatisfy { !$0.swipeActivationEnabled },
                "non-button switches untouched")
        require(swipePlan.candidate.profiles.flatMap(\.controls).filter { $0.isLocalAction || $0.isAdvancedButton || $0.isTouchAim }.allSatisfy { !$0.acceptsSwipeEntry },
                "local, advanced and Touch Aim entry protections unchanged")
        func swipeModel(_ data: Data = swipeRaw) -> (ProfileControllerViewModel, UserDefaults) {
            let defaults = UserDefaults(suiteName: "sc0251-swipe-check-\(UUID().uuidString)")!
            defaults.set(data, forKey: ProfileControllerViewModel.libraryKey)
            defaults.set("preserve", forKey: "unrelated.setting")
            return (ProfileControllerViewModel(defaults: defaults, transport: UpdateTransport(), automaticTimer: false), defaults)
        }
        for invalidHash in [String(repeating: "0", count: 64), "invalid", swipeHash.uppercased()] {
            let (model, defaults) = swipeModel(); let before = defaults.dictionaryRepresentation() as NSDictionary
            require(model.applyDebugButtonSwipeUpdate(expectedCurrentLibrarySHA256: invalidHash)["status"] as? String == "rejected" &&
                    defaults.dictionaryRepresentation() as NSDictionary == before && model.library == swipeOriginal, "bad/stale hash does not mutate data or create backup")
        }
        for data in [Data("invalid json".utf8), Data(repeating: 32, count: DebugProfileLayoutUpdate.maximumBytes + 1)] {
            do { _ = try DebugButtonSwipeUpdate.prepare(expectedCurrentLibrarySHA256: DebugProfileLayoutUpdate.digest(data), currentRaw: data); require(false, "invalid raw library rejected") }
            catch { require(true, "invalid raw library rejected") }
        }
        let (editingSwipe, editingSwipeDefaults) = swipeModel(); editingSwipe.beginLayoutEditing()
        let editingSwipeBefore = editingSwipeDefaults.dictionaryRepresentation() as NSDictionary
        require(editingSwipe.applyDebugButtonSwipeUpdate(expectedCurrentLibrarySHA256: swipeHash)["status"] as? String == "rejected" &&
                editingSwipeDefaults.dictionaryRepresentation() as NSDictionary == editingSwipeBefore, "draft blocks button update")
        let (staleModel, staleDefaults) = swipeModel()
        let otherRaw = try ControllerProfileLibraryCodec.encode(swipeExpected); staleDefaults.set(otherRaw, forKey: ProfileControllerViewModel.libraryKey)
        let staleBefore = staleDefaults.dictionaryRepresentation() as NSDictionary
        require(staleModel.applyDebugButtonSwipeUpdate(expectedCurrentLibrarySHA256: DebugProfileLayoutUpdate.digest(otherRaw))["reason"] as? String == "model_library_changed" &&
                staleDefaults.dictionaryRepresentation() as NSDictionary == staleBefore, "in-memory model mismatch blocks button update")
        let (swipeModelApplied, swipeDefaults) = swipeModel()
        let swipeReceipt = swipeModelApplied.applyDebugButtonSwipeUpdate(expectedCurrentLibrarySHA256: swipeHash)
        require(swipeReceipt["status"] as? String == "applied" && swipeModelApplied.library == swipeExpected && swipeModelApplied.state.isNeutral,
                "button update saves exact candidate and leaves neutral runtime")
        require(swipeModelApplied.recoveryDocuments.contains { $0.data == swipeRaw } && swipeDefaults.string(forKey: "unrelated.setting") == "preserve",
                "button update retains exact raw recovery and unrelated preferences")
        require(try ControllerProfileLibraryCodec.decode(swipeDefaults.data(forKey: ProfileControllerViewModel.libraryKey)!) == swipeExpected,
                "button update persists candidate")
        let appliedBefore = swipeDefaults.dictionaryRepresentation() as NSDictionary
        require(swipeModelApplied.applyDebugButtonSwipeUpdate(expectedCurrentLibrarySHA256: swipeHash)["reason"] as? String == "stale_saved_library" &&
                swipeDefaults.dictionaryRepresentation() as NSDictionary == appliedBefore, "old hash replay changes nothing")
        let currentHash = DebugProfileLayoutUpdate.digest(swipeDefaults.data(forKey: ProfileControllerViewModel.libraryKey)!)
        require(swipeModelApplied.applyDebugButtonSwipeUpdate(expectedCurrentLibrarySHA256: currentHash)["status"] as? String == "unchanged" &&
                swipeDefaults.dictionaryRepresentation() as NSDictionary == appliedBefore, "already enabled is no-op with no extra backup")
        let swipeReceiptURL = docs.appendingPathComponent(DebugButtonSwipeUpdate.receiptName)
        let (ordinarySwipe, ordinarySwipeDefaults) = swipeModel()
        ordinarySwipe.applyRequestedButtonSwipeUpdate(arguments: ["app"], documentsDirectory: docs)
        require(ordinarySwipeDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == swipeRaw && !FileManager.default.fileExists(atPath: swipeReceiptURL.path),
                "ordinary launch never enables swipe or writes receipt")
        let (launchSwipe, launchSwipeDefaults) = swipeModel()
        launchSwipe.applyRequestedButtonSwipeUpdate(arguments: ["app", DebugButtonSwipeUpdate.argument, swipeHash], documentsDirectory: docs)
        let swipeReceiptData = try Data(contentsOf: swipeReceiptURL)
        let savedSwipeReceipt = try JSONSerialization.jsonObject(with: swipeReceiptData) as! [String: Any]
        require(savedSwipeReceipt["status"] as? String == "applied" && launchSwipe.library == swipeExpected, "explicit swipe launch applies and writes distinct receipt")
        require(savedSwipeReceipt["profiles"] as? Int == swipeExpected.profiles.count && savedSwipeReceipt["library"] == nil, "swipe receipt contains counts, not private layouts")
        let launchSwipeBefore = launchSwipeDefaults.dictionaryRepresentation() as NSDictionary
        launchSwipe.applyRequestedButtonSwipeUpdate(arguments: ["app", DebugButtonSwipeUpdate.argument, swipeHash], documentsDirectory: docs)
        let repeatedSwipeReceiptData = try Data(contentsOf: swipeReceiptURL)
        require(launchSwipeDefaults.dictionaryRepresentation() as NSDictionary == launchSwipeBefore &&
                repeatedSwipeReceiptData == swipeReceiptData, "swipe launch handler executes once")
        for arguments in [["app", DebugButtonSwipeUpdate.argument], ["app", DebugButtonSwipeUpdate.argument, swipeHash, DebugButtonSwipeUpdate.argument, swipeHash],
                          ["app", DebugButtonSwipeUpdate.argument, swipeHash, "--apply-profile-update", "update.json"]] {
            let (model, defaults) = swipeModel(); let before = defaults.dictionaryRepresentation() as NSDictionary
            model.applyRequestedButtonSwipeUpdate(arguments: arguments, documentsDirectory: docs)
            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: swipeReceiptURL)) as! [String: Any]
            require(receipt["reason"] as? String == "invalid_launch_argument" && defaults.dictionaryRepresentation() as NSDictionary == before,
                    "missing/duplicate/mixed launch arguments rejected without mutation")
        }
        try FileManager.default.removeItem(at: swipeReceiptURL)
        try FileManager.default.createSymbolicLink(at: swipeReceiptURL, withDestinationURL: file)
        let (symlinkSwipe, symlinkSwipeDefaults) = swipeModel(); let symlinkBefore = symlinkSwipeDefaults.dictionaryRepresentation() as NSDictionary
        symlinkSwipe.applyRequestedButtonSwipeUpdate(arguments: ["app", DebugButtonSwipeUpdate.argument, swipeHash], documentsDirectory: docs)
        require(symlinkSwipeDefaults.dictionaryRepresentation() as NSDictionary == symlinkBefore, "receipt symlink blocks swipe mutation")
        print("PASS: \(count) DEBUG layout-update checks; no device or network output.")
    }
}

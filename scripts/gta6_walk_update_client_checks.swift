import Foundation
import ControllerCore

@MainActor
private final class WalkCheckTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    func open(host: String, port: UInt16) {}
    func send(_ data: Data) {}
    func close(afterSending data: Data?) {}
}
private struct WalkCheckFailure: Error, CustomStringConvertible { let description: String }

/// Uses isolated preferences and a fake transport. No real bridge output or phone writes.
@main
struct GTA6WalkUpdateClientChecks {
    @MainActor static func main() throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard paths.count == 2 else { throw WalkCheckFailure(description: "Expected package and original library paths") }
        let packageData = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
        let raw = try Data(contentsOf: URL(fileURLWithPath: paths[1]))
        let original = try ControllerProfileLibraryCodec.decode(raw)
        let plan = try DebugApprovedGTA6WalkUpdate.prepare(packageData, currentRaw: raw)
        let encoded = try ControllerProfileLibraryCodec.encode(plan.candidate)
        let expansionKey = "controller.profiles.recovery.before-storage-expansion"
        var checks = 0
        func require(_ value: Bool, _ label: String) throws {
            checks += 1
            if !value { throw WalkCheckFailure(description: "FAIL \(checks): \(label)") }
        }
        var suiteNames: [String] = []
        var directories: [URL] = []
        defer {
            for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
        func temporaryDirectory() throws -> URL {
            let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("sc-walk-check-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            directories.append(directory); return directory
        }
        let archiveRoot = try temporaryDirectory()
        func fresh(_ data: Data = raw) -> (ProfileControllerViewModel, UserDefaults) {
            let name = "sc-walk-check-\(UUID().uuidString)"; suiteNames.append(name)
            let defaults = UserDefaults(suiteName: name)!
            defaults.set(data, forKey: ProfileControllerViewModel.libraryKey)
            defaults.set("preserved", forKey: "unrelated.preference")
            defaults.set(Data([1, 255, 0, 3]), forKey: "unrelated.bytes")
            return (ProfileControllerViewModel(defaults: defaults, transport: WalkCheckTransport(), automaticTimer: false, androidArchiveDirectory: archiveRoot), defaults)
        }
        func reopen(_ defaults: UserDefaults) -> ProfileControllerViewModel {
            ProfileControllerViewModel(defaults: defaults, transport: WalkCheckTransport(), automaticTimer: false, androidArchiveDirectory: archiveRoot)
        }
        func outside(_ defaults: UserDefaults, allowed: Set<String>) -> NSDictionary {
            defaults.dictionaryRepresentation().filter { !allowed.contains($0.key) } as NSDictionary
        }
        try require(raw.count <= ControllerProfileLibraryCodec.legacyMaximumBytes &&
                    encoded.count > ControllerProfileLibraryCodec.legacyMaximumBytes &&
                    encoded.count < ControllerProfileLibraryCodec.maximumBytes, "Fixture crosses only the legacy storage bound")
        let package = try JSONSerialization.jsonObject(with: packageData) as! [String: Any]
        try require(try DebugProfileLayoutUpdate.same(package["library"]!, JSONSerialization.jsonObject(with: encoded)),
                    "Native encoding preserves all authored JSON values")
        try require(try ControllerProfileLibraryCodec.decode(encoded) == plan.candidate, "Large candidate codec roundtrip")

        // The actual Add → Save layout path that failed for this user's current library.
        let (editor, defaults) = fresh()
        let beforeEditor = defaults.dictionaryRepresentation() as NSDictionary
        try require(editor.library == original && editor.canEditLayout, "Fresh user library opens without migration")
        editor.beginLayoutEditing()
        let addedID = editor.addControl(kind: .button)
        try require(addedID != nil && editor.isEditingLayout, "Ordinary Add Button creates an editable draft")
        var expectedAdded = original
        expectedAdded.profiles[expectedAdded.profiles.firstIndex { $0.id == editor.profile.id }!] = editor.draft!
        let addedBytes = try ControllerProfileLibraryCodec.encode(expectedAdded)
        try require(addedBytes.count > ControllerProfileLibraryCodec.legacyMaximumBytes,
                    "One ordinary button reproduces the old over-limit document")
        try require(defaults.dictionaryRepresentation() as NSDictionary == beforeEditor, "Unsaved draft writes no preferences or backup")
        editor.saveLayoutEditing()
        try require(!editor.isEditingLayout && editor.library == expectedAdded,
                    "Save layout now succeeds above the old limit")
        try require(defaults.data(forKey: ProfileControllerViewModel.libraryKey) == addedBytes,
                    "Save writes the exact complete edited library")
        try require(defaults.data(forKey: expansionKey) == raw, "First crossing backs up exact original bytes")
        try require(outside(defaults, allowed: [ProfileControllerViewModel.libraryKey, expansionKey]) ==
                    (beforeEditor as! [String: Any]).filter { ![ProfileControllerViewModel.libraryKey, expansionKey].contains($0.key) } as NSDictionary,
                    "Ordinary save preserves unrelated preferences")
        let reopenedEditor = reopen(defaults)
        try require(reopenedEditor.library == expectedAdded && reopenedEditor.profile.control(for: addedID!) != nil,
                    "Ordinary reopen retains the user-added button and complete library")
        let afterFirst = defaults.dictionaryRepresentation() as NSDictionary
        reopenedEditor.beginLayoutEditing(); _ = reopenedEditor.addControl(kind: .button)
        reopenedEditor.cancelLayoutEditing()
        try require(reopenedEditor.library == expectedAdded && defaults.dictionaryRepresentation() as NSDictionary == afterFirst,
                    "Cancel leaves the saved large library and backup untouched")
        reopenedEditor.beginLayoutEditing(); _ = reopenedEditor.addControl(kind: .button); reopenedEditor.saveLayoutEditing()
        try require(defaults.data(forKey: expansionKey) == raw, "Later saves never replace the first crossing backup")
        try require(reopenedEditor.recoveryDocuments.contains { $0.id == expansionKey && $0.data == raw && $0.validationIssue == nil },
                    "Exact expansion backup is visible and restorable through normal recovery")
        let backup = reopenedEditor.exportProfiles()!
        try require(backup.count > ControllerProfileLibraryCodec.legacyMaximumBytes, "Normal native export handles the large library")
        let exportedLibrary = try ControllerProfileLibraryCodec.decode(backup)
        try require(exportedLibrary == reopenedEditor.library, "Export retains all profiles and data")
        let recoveryKey = "controller.profiles.recovery.large-test"
        let (recoveryModel, recoveryDefaults) = fresh()
        recoveryDefaults.set(backup, forKey: recoveryKey)
        let record = recoveryModel.recoveryDocuments.first { $0.id == recoveryKey }!
        try require(record.validationIssue == nil && recoveryModel.restoreRecoveryDocument(record), "Normal recovery accepts a library larger than 2MiB")
        try require(reopen(recoveryDefaults).library == exportedLibrary, "Recovered large library survives relaunch")
        let portable = try AndroidPortableBackup(nativeLibraryData: backup, archives: []).encodedData()
        let portableAgain = try AndroidPortableBackup.decode(portable)
        try require(portableAgain.nativeLibraryData == backup, "Portable backup keeps the large native document exact")
        let (importer, importDefaults) = fresh(try ControllerProfileLibraryCodec.encode(.default))
        let importerBeforeCount = importer.library.profiles.count
        try require(importer.importProfiles(portable) && importer.library.profiles.count == importerBeforeCount + exportedLibrary.profiles.count,
                    "Normal importer accepts large portable backups without dropping existing profiles")
        try require(reopen(importDefaults).library == importer.library, "Imported large portable backup survives relaunch")

        // Validate shared persistence backup behavior for preset saves and failures.
        let (failed, failedDefaults) = fresh()
        let beforeFailure = failedDefaults.dictionaryRepresentation() as NSDictionary
        var invalidPresets = failed.library.settingsPresets; invalidPresets.version = 999
        try require(!failed.saveSettingsPresets(invalidPresets) && failedDefaults.dictionaryRepresentation() as NSDictionary == beforeFailure,
                    "Failed save creates no backup and changes no persisted value")
        let (existingBackup, existingDefaults) = fresh()
        let retainedRecovery = Data("existing recovery must not be overwritten".utf8)
        existingDefaults.set(retainedRecovery, forKey: expansionKey)
        existingBackup.beginLayoutEditing(); _ = existingBackup.addControl(kind: .button); existingBackup.saveLayoutEditing()
        try require(existingDefaults.data(forKey: expansionKey) == retainedRecovery,
                    "A pre-existing recovery value is never overwritten, even if unreadable")
        let (presetModel, presetDefaults) = fresh()
        var presets = presetModel.library.settingsPresets
        let template = presetModel.profile.controls.first { $0.kind == .button }!
        for index in 0..<8 {
            let entry = try SettingsPreset.capture(template, category: .buttonAim, name: "Storage check \(index)", at: 100 + Int64(index))
            try presets.save(entry)
        }
        var presetCandidate = original; presetCandidate.settingsPresets = presets
        let presetBytes = try ControllerProfileLibraryCodec.encode(presetCandidate)
        try require(presetBytes.count > ControllerProfileLibraryCodec.legacyMaximumBytes,
                    "Preset-save fixture crosses the same legacy bound")
        try require(presetModel.saveSettingsPresets(presets) && presetDefaults.data(forKey: expansionKey) == raw &&
                    presetDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == presetBytes,
                    "Preset-save path also preserves exact old bytes before crossing")

        // Pinned one-time Walk update: only exact approved bytes may replace the library.
        let docs = try temporaryDirectory()
        let (ordinary, ordinaryDefaults) = fresh()
        let ordinaryBefore = ordinaryDefaults.dictionaryRepresentation() as NSDictionary
        ordinary.applyRequestedApprovedGTA6WalkUpdate(arguments: ["app"], documentsDirectory: docs)
        try require(ordinaryDefaults.dictionaryRepresentation() as NSDictionary == ordinaryBefore && ordinary.library == original,
                    "Normal launch does not invoke the maintenance update")
        try require(!FileManager.default.fileExists(atPath: docs.appendingPathComponent(DebugApprovedGTA6WalkUpdate.receiptName).path),
                    "Normal launch writes no maintenance receipt")
        var tampered = packageData; tampered.append(32)
        do { _ = try DebugApprovedGTA6WalkUpdate.prepare(tampered, currentRaw: raw); try require(false, "Tampered package rejected") }
        catch let error as DebugProfileLayoutUpdate.Rejection { try require(error.code == "unapproved_package", "Tampered package rejection") }
        var stale = raw; stale.append(32)
        do { _ = try DebugApprovedGTA6WalkUpdate.prepare(packageData, currentRaw: stale); try require(false, "Stale library rejected") }
        catch let error as DebugProfileLayoutUpdate.Rejection { try require(error.code == "stale_saved_library", "Stale library rejection") }
        let (model, appliedDefaults) = fresh()
        let selectedPage = model.currentPageID
        let preferencesBefore = appliedDefaults.dictionaryRepresentation()
        let result = model.applyApprovedGTA6WalkUpdate(packageData)
        try require(result["status"] as? String == "applied" && model.library == plan.candidate, "Exact approved Walk update applied")
        try require(model.currentPageID == selectedPage && model.state.isNeutral, "Active page preserved and all input neutral")
        try require(appliedDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == encoded, "Native saved bytes match the validated candidate")
        let backupKey = result["backupKey"] as? String ?? ""
        try require(backupKey.hasPrefix("controller.profiles.recovery.") && appliedDefaults.data(forKey: backupKey) == raw &&
                    appliedDefaults.data(forKey: expansionKey) == raw, "Maintenance and first-crossing backups both contain exact before bytes")
        let allowed = Set([ProfileControllerViewModel.libraryKey, backupKey, expansionKey])
        try require(preferencesBefore.filter { !allowed.contains($0.key) } as NSDictionary == outside(appliedDefaults, allowed: allowed),
                    "Walk update changes no unrelated preferences")
        try require(Set(appliedDefaults.dictionaryRepresentation().keys).subtracting(preferencesBefore.keys) == [backupKey, expansionKey],
                    "Only the two expected exact recovery entries are added")
        let afterSnapshot = appliedDefaults.dictionaryRepresentation() as NSDictionary
        try require(model.applyApprovedGTA6WalkUpdate(packageData)["reason"] as? String == "stale_saved_library" &&
                    appliedDefaults.dictionaryRepresentation() as NSDictionary == afterSnapshot, "Replay rejects without writes")
        let reopened = reopen(appliedDefaults)
        try require(reopened.library == plan.candidate, "Complete Walk candidate survives normal model reopen")
        reopened.applyRequestedApprovedGTA6WalkUpdate(arguments: ["app"], documentsDirectory: docs)
        try require(appliedDefaults.dictionaryRepresentation() as NSDictionary == afterSnapshot, "Normal reopen leaves all preferences unchanged")
        let file = docs.appendingPathComponent("update.json")
        try packageData.write(to: file, options: .atomic)
        let (fileModel, fileDefaults) = fresh()
        fileModel.applyRequestedApprovedGTA6WalkUpdate(arguments: ["app", DebugApprovedGTA6WalkUpdate.argument, "update.json"], documentsDirectory: docs)
        let receiptURL = docs.appendingPathComponent(DebugApprovedGTA6WalkUpdate.receiptName)
        let receiptData = try Data(contentsOf: receiptURL)
        let receipt = try JSONSerialization.jsonObject(with: receiptData) as! [String: Any]
        try require(receipt["status"] as? String == "applied" && fileDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == encoded,
                    "Explicit file update handles a package above the old limit and writes a successful receipt")
        try require(receipt["librarySHA256"] as? String == plan.encodedSHA256 && receipt["libraryBytes"] as? Int == encoded.count,
                    "Receipt reports actual saved hash and size")
        let fileSnapshot = fileDefaults.dictionaryRepresentation() as NSDictionary
        fileModel.applyRequestedApprovedGTA6WalkUpdate(arguments: ["app", DebugApprovedGTA6WalkUpdate.argument, "update.json"], documentsDirectory: docs)
        try require(fileDefaults.dictionaryRepresentation() as NSDictionary == fileSnapshot && Data(contentsOf: receiptURL) == receiptData,
                    "Repeated appearance cannot reapply or rewrite receipt")
        print("PASS: \(checks) Walk/storage app-model checks: actual Add-Save-reopen above old limit, Cancel, exact recovery, no-overwrite, failed-save no-op, native/portable export-import-recovery, preset saves, pinned update, receipts, replay/stale/tamper and normal-launch no-op.")
        print("Native candidate \(encoded.count) bytes, SHA256 \(plan.encodedSHA256); authored JSON semantics unchanged.")
        print("Ordinary Add Button saved \(addedBytes.count) bytes (\(addedBytes.count - ControllerProfileLibraryCodec.legacyMaximumBytes) above former limit).")
    }
}

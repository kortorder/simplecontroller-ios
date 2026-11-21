import Foundation
import ControllerCore

@MainActor private final class DurableSilentTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    func open(host: String, port: UInt16) {}
    func send(_ data: Data) {}
    func close(afterSending data: Data?) {}
}

private struct DurableFailure: Error, CustomStringConvertible {
    let description: String
}

/// Uses the real large legacy preference fixture only inside a temporary suite.
/// Every profile readback uses real files; no fixture values or layouts are logged.
@main struct DurableProfileModelChecks {
    @MainActor static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4 else {
            throw DurableFailure(description: "Expected package, before-library, complete legacy plist, report")
        }
        let package = try Data(contentsOf: URL(fileURLWithPath: args[0]))
        let raw = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let fixture = try PropertyListSerialization.propertyList(from: fixtureData, options: [], format: nil) as! [String: Any]
        let plan = try DebugApprovedGTA6DrivingUpdate.prepare(package, currentRaw: raw)
        let encoded = try ControllerProfileLibraryCodec.encode(plan.candidate)
        let original = try ControllerProfileLibraryCodec.decode(raw)
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            checks += 1
            if !condition { throw DurableFailure(description: "FAIL \(checks): \(label)") }
        }
        try require(fixture[ProfileControllerViewModel.libraryKey] as? Data == raw,
                    "Complete legacy fixture contains exactly the approved original library")
        try require(fixtureData.count > 16 * 1_024 * 1_024 && fixture[ControllerViewModel.connectionIntentKey] == nil,
                    "Actual legacy preference fixture reproduces large domain without a connection-intent side effect")
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("sc-durable-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var suites: [String] = []
        defer {
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: root)
        }
        func preferences(_ values: [String: Any]) -> (UserDefaults, String) {
            let name = "sc-durable-model-\(UUID().uuidString)"
            suites.append(name)
            let defaults = UserDefaults(suiteName: name)!
            defaults.setPersistentDomain(values, forName: name)
            return (defaults, name)
        }
        func domain(_ defaults: UserDefaults, _ suite: String) -> NSDictionary {
            defaults.persistentDomain(forName: suite)! as NSDictionary
        }
        var now: TimeInterval = 0
        func model(_ defaults: UserDefaults, _ directory: URL) -> ProfileControllerViewModel {
            ProfileControllerViewModel(defaults: defaults, transport: DurableSilentTransport(), clock: { now },
                automaticTimer: false, androidArchiveDirectory: root.appendingPathComponent("AndroidOriginals", isDirectory: true),
                profileStorageDirectory: directory)
        }
        func primary(_ directory: URL) -> URL { directory.appendingPathComponent("library.json") }
        func diskSnapshot(_ directory: URL) throws -> [String: Data] {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
            let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
            var files: [String: Data] = [:]
            for case let file as URL in iterator {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    files[String(file.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: file)
                }
            }
            return files
        }

        // Main migration case: all 17 MB of actual legacy preferences remain intact.
        let (defaults, suite) = preferences(fixture)
        let directory = root.appendingPathComponent("main/Profiles", isDirectory: true)
        let legacyDomain = domain(defaults, suite)
        let loaded = model(defaults, directory)
        try require(loaded.library == original && loaded.canEditLayout, "Missing primary falls back to exact valid legacy library")
        try require(domain(defaults, suite) == legacyDomain, "Legacy-only opening never rewrites any preference")
        loaded.applyRequestedApprovedGTA6DrivingUpdate(arguments: ["app"], documentsDirectory: root)
        let ordinaryDisk = try NativeProfileFileStore(directory: directory).loadLibrary()
        try require(ordinaryDisk == nil && domain(defaults, suite) == legacyDomain,
                    "Ordinary launch does not apply maintenance or create a replacement file")
        let applied = model(defaults, directory)
        let receipt = applied.applyApprovedGTA6DrivingUpdate(package)
        try require(receipt["status"] as? String == "applied", "Pinned candidate applies with durable file storage")
        let backupKey = receipt["backupKey"] as? String ?? ""
        let freshStore = NativeProfileFileStore(directory: directory)
        let saved = try freshStore.loadLibrary()
        try require(saved == encoded && (try Data(contentsOf: primary(directory))) == encoded,
                    "New store and direct disk read both return exact candidate bytes")
        try require(applied.library == plan.candidate && (try applied.currentLibraryData()) == encoded,
                    "App model and authoritative accessor use committed primary")
        try require(domain(defaults, suite) == legacyDomain && defaults.data(forKey: ProfileControllerViewModel.libraryKey) == raw,
                    "Every old preference including legacy main stays byte-identical")
        let storedMaintenanceBackup = try freshStore.recoveryData(for: backupKey)
        try require(storedMaintenanceBackup == raw, "Maintenance backup is an exact real recovery file")
        let formatBackup = try freshStore.recoveryData(for: "controller.profiles.before-format-22")
        try require(formatBackup == raw, "Format22 recovery is an exact real recovery file")
        let automaticBackupKey = "controller.profiles.recovery.file-" + DebugProfileLayoutUpdate.digest(raw)
        try require(try freshStore.recoveryData(for: automaticBackupKey) == raw,
                    "Automatic first file save preserves exact previous legacy bytes")
        let committedFiles = try diskSnapshot(directory)
        let replay = applied.applyApprovedGTA6DrivingUpdate(package)
        try require(replay["reason"] as? String == "stale_saved_library",
                    "Replay checks authoritative primary even though legacy defaults still match old pin")
        try require(try diskSnapshot(directory) == committedFiles && domain(defaults, suite) == legacyDomain,
                    "Rejected replay changes neither files nor legacy preferences")
        let reopened = model(UserDefaults(suiteName: suite)!, directory)
        try require(reopened.library == plan.candidate && reopened.canEditLayout && reopened.state.isNeutral,
                    "Fresh defaults/store/model reopen reads primary, never stale legacy data or runtime holds")
        let documents = reopened.recoveryDocuments
        try require(documents.contains { $0.id == backupKey && $0.data == raw && $0.validationIssue == nil },
                    "Native-file maintenance recovery is available in app")
        try require(documents.contains { $0.id == "controller.profiles.recovery.legacy-preferences" && $0.data == raw },
                    "Exact old main remains available as legacy-preferences recovery")
        if let oldRecovery = fixture.first(where: { $0.key.hasPrefix("controller.profiles.recovery.") && $0.value is Data }) {
            try require(documents.contains { $0.id == oldRecovery.key && $0.data == oldRecovery.value as? Data },
                        "Existing large preferences recovery entry remains accessible")
        }
        reopened.beginLayoutEditing()
        try require(reopened.addControl(kind: .button) != nil, "File-backed layout still permits adding a control")
        reopened.cancelLayoutEditing()
        try require(try diskSnapshot(directory) == committedFiles && domain(defaults, suite) == legacyDomain,
                    "Cancel leaves primary, all backup files and preferences unchanged")
        reopened.beginLayoutEditing()
        let addedID = reopened.addControl(kind: .button)!
        reopened.saveLayoutEditing()
        try require(!reopened.isEditingLayout && reopened.profile.control(for: addedID) != nil,
                    "Normal Save commits edited layout through file store")
        let savedAfterEdit = try NativeProfileFileStore(directory: directory).loadLibrary()!
        let editedReadback = try ControllerProfileLibraryCodec.decode(savedAfterEdit)
        try require(editedReadback == reopened.library && model(UserDefaults(suiteName: suite)!, directory).profile.control(for: addedID) != nil,
                    "Saved control survives actual disk decode and fresh model reopen")
        try require(domain(defaults, suite) == legacyDomain, "Normal Save also leaves every old preference untouched")
        let afterEditStore = NativeProfileFileStore(directory: directory)
        try require(try afterEditStore.recoveryData(for: backupKey) == raw &&
                    afterEditStore.recoveryData(for: "controller.profiles.before-format-22") == raw,
                    "Subsequent saves never overwrite original recovery files")
        let previousCandidateKey = "controller.profiles.recovery.file-" + DebugProfileLayoutUpdate.digest(encoded)
        try require(try afterEditStore.recoveryData(for: previousCandidateKey) == encoded,
                    "Normal Save preserves exact previous primary in automatic recovery")
        let exported = try unwrap(reopened.exportProfiles(), "Export unavailable")
        try require(try ControllerProfileLibraryCodec.decode(exported) == reopened.library,
                    "File-backed large library still exports losslessly")
        let fileRecovery = try unwrap(reopened.recoveryDocuments.first { $0.id == backupKey }, "File recovery unavailable")
        try require(reopened.restoreRecoveryDocument(fileRecovery), "Explicit restore accepts native-file recovery document")
        let restoredBytes = try NativeProfileFileStore(directory: directory).loadLibrary()!
        try require(try ControllerProfileLibraryCodec.decode(restoredBytes) == original &&
                    model(UserDefaults(suiteName: suite)!, directory).library == original,
                    "Explicit recovery restore commits complete old library and survives reopen")
        try require(domain(defaults, suite) == legacyDomain, "Recovery restore never rewrites legacy preferences")

        // Force a real filesystem failure before committing, without touching the
        // old primary: a regular file blocks creation of the Recovery directory.
        let smallFixture: [String: Any] = [ProfileControllerViewModel.libraryKey: raw, "preserved.bytes": Data([0, 1, 255])]
        let (failedDefaults, failedSuite) = preferences(smallFixture)
        let failedDir = root.appendingPathComponent("failure/Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)
        try encoded.write(to: primary(failedDir), options: .atomic)
        let failedModel = model(failedDefaults, failedDir)
        let failedDomain = domain(failedDefaults, failedSuite)
        failedModel.beginLayoutEditing()
        let pendingID = failedModel.addControl(kind: .button)!
        let pendingDraft = failedModel.profile
        let oldLibrary = failedModel.library
        let oldPage = failedModel.currentPageID
        let blocker = failedDir.appendingPathComponent("Recovery")
        try Data("file-blocker".utf8).write(to: blocker)
        failedModel.saveLayoutEditing()
        try require(failedModel.isEditingLayout && failedModel.profile == pendingDraft && failedModel.library == oldLibrary &&
                    failedModel.currentPageID == oldPage, "Write failure keeps the old model, selected page and full unsaved draft")
        try require(try Data(contentsOf: primary(failedDir)) == encoded && domain(failedDefaults, failedSuite) == failedDomain,
                    "Write failure leaves primary and old preferences exact")
        try require(failedModel.message != nil && model(UserDefaults(suiteName: failedSuite)!, failedDir).library == oldLibrary,
                    "Failure is visible and fresh model still sees last committed library")
        try FileManager.default.removeItem(at: blocker)
        failedModel.saveLayoutEditing()
        try require(!failedModel.isEditingLayout && model(UserDefaults(suiteName: failedSuite)!, failedDir).profile.control(for: pendingID) != nil,
                    "Retry after fixing storage saves the preserved draft")

        // Corrupt primary is authoritative and protected, never silently replaced
        // by the perfectly valid but older main value in legacy preferences.
        let (corruptDefaults, corruptSuite) = preferences(smallFixture)
        let corruptDir = root.appendingPathComponent("corruption/Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corrupt = Data("{corrupt-primary".utf8)
        try corrupt.write(to: primary(corruptDir))
        let corruptBefore = domain(corruptDefaults, corruptSuite)
        let protectedModel = model(corruptDefaults, corruptDir)
        try require(!protectedModel.canEditLayout && protectedModel.library != original,
                    "Corrupt primary blocks editing instead of silently falling back")
        try require(try NativeProfileFileStore(directory: corruptDir).loadLibrary() == corrupt &&
                    domain(corruptDefaults, corruptSuite) == corruptBefore,
                    "Opening corrupt primary preserves its exact bytes and old preferences")
        let corruptionRecovery = protectedModel.recoveryDocuments
        try require(corruptionRecovery.contains { $0.data == corrupt && $0.validationIssue != nil },
                    "Corrupt file bytes are available for exact recovery export")
        let legacyRecovery = try unwrap(corruptionRecovery.first { $0.id == "controller.profiles.recovery.legacy-preferences" },
                                        "Legacy recovery missing for corrupt primary")
        try require(legacyRecovery.data == raw && protectedModel.restoreRecoveryDocument(legacyRecovery),
                    "User-directed legacy recovery is available without automatic fallback")
        let repaired = try NativeProfileFileStore(directory: corruptDir).loadLibrary()!
        try require(try ControllerProfileLibraryCodec.decode(repaired) == original &&
                    model(UserDefaults(suiteName: corruptSuite)!, corruptDir).canEditLayout,
                    "Explicit legacy recovery repairs primary and permits normal reopen")
        let corruptBackups = try NativeProfileFileStore(directory: corruptDir).recoveryDocuments()
        try require(corruptBackups.values.contains(corrupt) && domain(corruptDefaults, corruptSuite) == corruptBefore,
                    "Explicit repair preserves corrupt bytes in a file backup and all old preferences")

        // Same argument-driven path used on the phone, now writing real files.
        let (launchDefaults, launchSuite) = preferences(smallFixture)
        let launchDir = root.appendingPathComponent("launch/Profiles", isDirectory: true)
        let launchDocs = root.appendingPathComponent("launch/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchDocs, withIntermediateDirectories: true)
        let packageFile = launchDocs.appendingPathComponent("Driving-update.json")
        try package.write(to: packageFile)
        let launchBefore = domain(launchDefaults, launchSuite)
        let launched = model(launchDefaults, launchDir)
        launched.applyRequestedApprovedGTA6DrivingUpdate(arguments: ["app", DebugApprovedGTA6DrivingUpdate.argument, packageFile.lastPathComponent],
                                                        documentsDirectory: launchDocs)
        let receiptFile = launchDocs.appendingPathComponent(DebugApprovedGTA6DrivingUpdate.receiptName)
        let launchReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptFile)) as! [String: Any]
        try require(launchReceipt["status"] as? String == "applied" &&
                    (try NativeProfileFileStore(directory: launchDir).loadLibrary()) == encoded,
                    "Explicit launch writes success receipt only after durable candidate commit")
        try require(domain(launchDefaults, launchSuite) == launchBefore &&
                    model(UserDefaults(suiteName: launchSuite)!, launchDir).library == plan.candidate,
                    "Explicit launch preserves all preferences and survives new model/store")
        let live = model(launchDefaults, launchDir)
        let face = live.currentPageControls.first { $0.doubleTapRepeatEnabled }!
        now = 10
        _ = live.handleInput(.begin(contact: 1, control: face.id, position: .zero), epoch: live.inputEpoch)
        now = 10.05; _ = live.handleInput(.end(contact: 1), epoch: live.inputEpoch)
        now = 10.15; _ = live.handleInput(.begin(contact: 2, control: face.id, position: .zero), epoch: live.inputEpoch)
        now = 10.20; _ = live.handleInput(.end(contact: 2), epoch: live.inputEpoch)
        try require(live.latchedControls.contains(face.id), "Durably loaded controls retain double-tap behavior")
        live.setForeground(false)
        try require(live.latchedControls.isEmpty && live.activeControls.isEmpty, "Background clears repeat owners")
        now = 11; live.setForeground(true); live.tickInput()
        try require(live.latchedControls.isEmpty && live.activeControls.isEmpty &&
                    model(UserDefaults(suiteName: launchSuite)!, launchDir).state.isNeutral,
                    "Foreground and fresh model do not resume old held inputs")

        let report: [String: Any] = ["status": "pass", "checks": checks,
            "legacyFixtureBytes": fixtureData.count, "legacyPreferenceKeys": fixture.count,
            "legacyPreferencesCompletelyUnchanged": true, "legacyMainRemainsExact": true,
            "freshFileStoreAndModelReadbackPassed": true, "fileRecoveryBackupsExact": true,
            "saveCancelReopenRecoveryPassed": true, "forcedWriteFailurePreservesDraftAndPrimary": true,
            "corruptPrimaryProtectedWithoutSilentFallback": true,
            "nativeCandidateBytes": encoded.count, "nativeCandidateSHA256": DebugProfileLayoutUpdate.digest(encoded)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        print("PASS: \(checks) durable app-model checks with \(fixtureData.count)-byte actual legacy fixture; no private values logged.")
        print("Native candidate: \(encoded.count) bytes, SHA256 \(DebugProfileLayoutUpdate.digest(encoded)).")
    }

    private static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw DurableFailure(description: label) }
        return value
    }
}

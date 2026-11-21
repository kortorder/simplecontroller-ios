import Foundation
import ControllerCore

@MainActor private final class SilentTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    func open(host: String, port: UInt16) {}
    func send(_ data: Data) {}
    func close(afterSending data: Data?) {}
}
private struct Failure: Error { let message: String }

@main struct DrivingModelChecks {
    @MainActor static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else { throw Failure(message: "Expected package, before, report") }
        let package = try Data(contentsOf: URL(fileURLWithPath: args[0]))
        let raw = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let plan = try DebugApprovedGTA6DrivingUpdate.prepare(package, currentRaw: raw)
        let encoded = try ControllerProfileLibraryCodec.encode(plan.candidate)
        let original = try ControllerProfileLibraryCodec.decode(raw)
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            checks += 1
            if !condition { throw Failure(message: message) }
        }
        let suite = "sc-driving-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let documents = URL(fileURLWithPath: "/private/tmp/sc-driving-documents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: documents) }
        defaults.set(raw, forKey: ProfileControllerViewModel.libraryKey)
        defaults.set(Data([1, 2, 9, 255]), forKey: "preserved.preferences")
        defaults.set(Data([9, 2]), forKey: "controller.profiles.recovery.before-storage-expansion")
        var now: TimeInterval = 0
        func make() -> ProfileControllerViewModel {
            ProfileControllerViewModel(defaults: defaults, transport: SilentTransport(), clock: { now }, automaticTimer: false,
                                       androidArchiveDirectory: documents.appendingPathComponent("originals"))
        }
        let before = defaults.dictionaryRepresentation() as NSDictionary
        let model = make()
        try require(model.library == original && model.canEditLayout, "Existing version22 library must load")
        try require(defaults.dictionaryRepresentation() as NSDictionary == before, "Opening alone must not rewrite saved data")
        model.applyRequestedApprovedGTA6DrivingUpdate(arguments: ["SimpleController"], documentsDirectory: documents)
        try require(defaults.dictionaryRepresentation() as NSDictionary == before, "Ordinary launch cannot apply maintenance")
        let apply = make()
        let receipt = apply.applyApprovedGTA6DrivingUpdate(package)
        try require(receipt["status"] as? String == "applied", "Approved update must apply")
        let backup = receipt["backupKey"] as! String
        try require(defaults.data(forKey: backup) == raw, "Exact maintenance backup")
        try require(defaults.data(forKey: "controller.profiles.before-format-22") == raw, "Exact format22 recovery backup")
        try require(defaults.data(forKey: "controller.profiles.recovery.before-storage-expansion") == Data([9, 2]), "Earlier capacity recovery preserved")
        try require(defaults.data(forKey: ProfileControllerViewModel.libraryKey) == encoded, "Exact candidate is saved")
        try require(apply.library == plan.candidate, "App model adopts complete candidate")
        let expectedKeys: Set<String> = [ProfileControllerViewModel.libraryKey, backup, "controller.profiles.before-format-22"]
        let unaffectedBefore = (before as! [String: Any]).filter { !expectedKeys.contains($0.key) } as NSDictionary
        let unaffectedAfter = defaults.dictionaryRepresentation().filter { !expectedKeys.contains($0.key) } as NSDictionary
        try require(unaffectedBefore == unaffectedAfter, "All unrelated preferences preserved")
        let after = defaults.dictionaryRepresentation() as NSDictionary
        let replay = apply.applyApprovedGTA6DrivingUpdate(package)
        try require(replay["status"] as? String == "rejected", "Replay is rejected")
        try require(defaults.dictionaryRepresentation() as NSDictionary == after, "Replay writes nothing")
        let reopened = make()
        try require(reopened.library == plan.candidate && reopened.canEditLayout, "Reopen retains all updated profiles")
        try require(reopened.recoveryDocuments.contains { $0.id == backup && $0.data == raw }, "Maintenance recovery is available")
        try require(reopened.recoveryDocuments.contains { $0.id == "controller.profiles.before-format-22" && $0.data == raw }, "Format recovery is available")
        reopened.beginLayoutEditing()
        let id = reopened.addControl(kind: .button)
        try require(id != nil, "Updated GTA still permits adding another button")
        reopened.cancelLayoutEditing()
        try require(defaults.dictionaryRepresentation() as NSDictionary == after, "Cancel does not alter saved layout")
        reopened.beginLayoutEditing()
        let savedID = reopened.addControl(kind: .button)!
        reopened.saveLayoutEditing()
        try require(!reopened.isEditingLayout, "Save succeeds after adding another button")
        try require(make().profile.control(for: savedID) != nil, "Added control survives normal reopen")
        try require(defaults.data(forKey: backup) == raw && defaults.data(forKey: "controller.profiles.before-format-22") == raw,
                    "Later saves do not replace original recovery")
        let safety = make()
        let face = safety.currentPageControls.first { $0.doubleTapRepeatEnabled }!
        now = 10
        try require(safety.handleInput(.begin(contact: 91, control: face.id, position: .zero), epoch: safety.inputEpoch), "App accepts face-button touch")
        now = 10.05
        _ = safety.handleInput(.end(contact: 91), epoch: safety.inputEpoch)
        now = 10.15
        _ = safety.handleInput(.begin(contact: 92, control: face.id, position: .zero), epoch: safety.inputEpoch)
        now = 10.20
        _ = safety.handleInput(.end(contact: 92), epoch: safety.inputEpoch)
        try require(safety.latchedControls.contains(face.id), "App model exposes double-tap repeat latch")
        safety.setForeground(false)
        try require(safety.latchedControls.isEmpty && safety.activeControls.isEmpty, "App inactive clears repeated outputs")
        now = 11
        safety.setForeground(true)
        safety.tickInput()
        try require(safety.latchedControls.isEmpty && safety.activeControls.isEmpty, "Returning to app does not resume repeat")
        var tampered = package; tampered.append(32)
        do { _ = try DebugApprovedGTA6DrivingUpdate.prepare(tampered, currentRaw: raw); throw Failure(message: "Tampered package accepted") }
        catch let rejection as DebugProfileLayoutUpdate.Rejection { try require(rejection.code == "unapproved_package", "Tampered package rejected by exact hash") }
        do { _ = try DebugApprovedGTA6DrivingUpdate.prepare(package, currentRaw: encoded); throw Failure(message: "Stale input accepted") }
        catch let rejection as DebugProfileLayoutUpdate.Rejection { try require(rejection.code == "stale_saved_library", "Stale library rejected") }
        // Exercise the explicit launch path and receipt without using the phone.
        defaults.set(raw, forKey: ProfileControllerViewModel.libraryKey)
        let file = documents.appendingPathComponent("Driving-update.json")
        try package.write(to: file)
        let launch = make()
        launch.applyRequestedApprovedGTA6DrivingUpdate(arguments: ["SimpleController", DebugApprovedGTA6DrivingUpdate.argument, file.lastPathComponent], documentsDirectory: documents)
        let launchReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: documents.appendingPathComponent(DebugApprovedGTA6DrivingUpdate.receiptName))) as! [String: Any]
        try require(launchReceipt["status"] as? String == "applied", "Explicit launch writes success receipt: \(launchReceipt)")
        try require(defaults.data(forKey: ProfileControllerViewModel.libraryKey) == encoded, "Launch path persists exact candidate")
        let report: [String: Any] = ["checks": checks, "status": "pass", "nativeBytes": encoded.count,
                                     "nativeSHA256": DebugProfileLayoutUpdate.digest(encoded), "profiles": plan.candidate.profiles.count,
                                     "controls": plan.candidate.profiles.reduce(0) { $0 + $1.controls.count }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[2]))
        print("PASS: \(checks) app-model preservation, recovery, maintenance, Save/Cancel/reopen checks")
    }
}

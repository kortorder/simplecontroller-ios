import Foundation
import ControllerCore

@MainActor
func runRecoveryClientChecks(require: (Bool, String) -> Void, freshDefaults: () -> UserDefaults) throws {
    let defaults = freshDefaults(), clock = ProfileCheckClock()
    var old = try ControllerProfile(name: "Recovered controls")
    try old.addControl(.init(name: "Old A", actions: [.a]), toPage: old.homePageID)
    let oldLibrary = try ControllerProfileLibrary(activeProfileID: old.id, profiles: [old])
    let oldBytes = try ControllerProfileLibraryCodec.encode(oldLibrary)
    let recoveryKey = "controller.profiles.before-delete.\(UUID().uuidString)"
    defaults.set(oldBytes, forKey: recoveryKey)
    defaults.set(Data("not a library".utf8), forKey: "controller.profiles.recovery.broken")
    defaults.set(Data("private unrelated setting".utf8), forKey: "account.private")
    let model = ProfileControllerViewModel(defaults: defaults, transport: ProfileCheckTransport(), clock: { clock.time }, automaticTimer: false)
    let beforeBytes = defaults.data(forKey: ProfileControllerViewModel.libraryKey)!
    let records = model.recoveryDocuments
    require(records.count == 2 && records.allSatisfy { $0.id != "account.private" }, "Recovery exposes only exact profile-recovery documents, never unrelated settings")
    let valid = records.first { $0.id == recoveryKey }!
    require(valid.data == oldBytes && valid.profileNames == [old.name] && valid.validationIssue == nil, "Recovery preview validates a copy without changing its bytes or profile names")
    let broken = records.first { $0.id == "controller.profiles.recovery.broken" }!
    require(broken.data == Data("not a library".utf8) && broken.profileNames == nil && broken.validationIssue != nil,
            "Invalid recovery data stays available verbatim for export while restoration remains unavailable")
    let beforeRejected = defaults.dictionaryRepresentation() as NSDictionary
    require(!model.restoreRecoveryDocument(broken) && (defaults.dictionaryRepresentation() as NSDictionary) == beforeRejected,
            "Invalid recovery restoration performs no saved mutation")
    let forged = ProfileRecoveryDocument(id: "account.private", title: "Unrelated", data: oldBytes, profileNames: [old.name], validationIssue: nil)
    require(!model.restoreRecoveryDocument(forged) && (defaults.dictionaryRepresentation() as NSDictionary) == beforeRejected,
            "An out-of-scope recovery snapshot cannot replace the library")
    model.beginLayoutEditing()
    require(!model.restoreRecoveryDocument(valid) && defaults.data(forKey: ProfileControllerViewModel.libraryKey) == beforeBytes,
            "Recovery cannot replace an in-progress layout draft")
    model.cancelLayoutEditing()
    let a = model.profile.controls.first { $0.actions == [.a] }!
    model.handleInput(.begin(contact: 2500, control: a.id, position: .zero), epoch: model.inputEpoch)
    let priorEpoch = model.inputEpoch
    require(model.restoreRecoveryDocument(valid) && model.library == oldLibrary && model.canEditLayout && model.state.isNeutral && model.inputEpoch > priorEpoch,
            "Validated recovery restores exact profiles and selection, clears live input, and invalidates old touch callbacks")
    require(model.recoveryDocuments.contains { $0.data == beforeBytes } && defaults.data(forKey: recoveryKey) == oldBytes,
            "Restoring keeps both the exact replaced library and the original recovery copy")
    let reloaded = ProfileControllerViewModel(defaults: defaults, transport: ProfileCheckTransport(), clock: { clock.time }, automaticTimer: false)
    require(reloaded.library == oldLibrary && reloaded.state.isNeutral, "Recovered profiles persist across a neutral relaunch")
    let changedSource = Data("changed source".utf8)
    defaults.set(changedSource, forKey: recoveryKey)
    let beforeStale = defaults.dictionaryRepresentation() as NSDictionary
    require(!model.restoreRecoveryDocument(valid) && (defaults.dictionaryRepresentation() as NSDictionary) == beforeStale,
            "A recovery snapshot cannot restore after its stored source changes")

    let protectedDefaults = freshDefaults(), badCurrent = Data("{\"version\":999}".utf8)
    protectedDefaults.set(badCurrent, forKey: ProfileControllerViewModel.libraryKey)
    protectedDefaults.set(oldBytes, forKey: recoveryKey)
    let protected = ProfileControllerViewModel(defaults: protectedDefaults, transport: ProfileCheckTransport(), clock: { clock.time }, automaticTimer: false)
    require(!protected.canEditLayout && protected.recoveryDocuments.contains { $0.id == ProfileControllerViewModel.libraryKey && $0.data == badCurrent },
            "Unreadable current profile data stays exportable even while normal editing and backup are blocked")
    let restore = protected.recoveryDocuments.first { $0.id == recoveryKey }!
    require(protected.restoreRecoveryDocument(restore) && protected.canEditLayout && protected.library == oldLibrary,
            "A known-good recovery copy can reopen a protected profile library without developer intervention")
    require(protected.recoveryDocuments.contains { $0.data == badCurrent }, "Recovery preserves the exact unreadable current document before replacing it")
}

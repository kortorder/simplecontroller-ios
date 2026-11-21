import SwiftUI
import UniformTypeIdentifiers
import ControllerCore

@MainActor
struct ProfileManagerView: View {
    @ObservedObject var model: ProfileControllerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var enteredName = ""
    @State private var renamingID: UUID?
    @State private var newUsesStandard = true
    @State private var deletingID: UUID?
    @State private var confirmingDelete = false
    @State private var showingExporter = false
    @State private var showingPresetManager = false
    @State private var recoveryPresentation: RecoveryPresentation?
    @State private var showingBulkDelete = false
    @State private var showingImporter = false
    @State private var readingImport = false
    @State private var importingAndroid = false
    @State private var androidPreview: AndroidImportPreview?
    @State private var editedAndroidPreview: AndroidEditedExportReview?
    @State private var pendingEditedFileExport = false
    @State private var originals: [AndroidSourceArchiveReference] = []
    @State private var exportFilename = "SimpleController-iPhone-profiles.json"
    @State private var exportDocument: NativeProfileDocument?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Each profile keeps its own controls, actions, sizes and positions. Switching profiles releases every held action.")
                    if let message = model.message {
                        Text(message).foregroundStyle(.orange)
                    }
                }
                Section {
                    NavigationLink {
                        GameStarterPicker(model: model, onFinish: { dismiss() })
                    } label: {
                        Label("Game starters", systemImage: "gamecontroller")
                            .frame(minHeight: 44)
                    }
                    .disabled(!model.canEditLayout || model.isEditingLayout || readingImport)
                }
                Section("Your profiles") {
                    ForEach(model.library.profiles) { profile in
                        HStack(spacing: 8) {
                            Button { _ = model.selectProfile(profile.id) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.name).foregroundStyle(.primary)
                                        Text("\(profile.controls.count) controls").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    if profile.id == model.library.activeProfileID {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(profile.name), \(profile.controls.count) controls")
                            .accessibilityValue(profile.id == model.library.activeProfileID ? "Selected" : "")
                            Menu {
                                Button("Rename") {
                                    renamingID = profile.id; enteredName = profile.name; naming = true
                                }
                                Button("Copy profile") { _ = model.duplicateProfile(profile.id) }
                                    .disabled(model.library.profiles.count >= 32)
                                if !profile.androidSources.isEmpty {
                                    Button("Export Android copy with edits") { prepareEditedExport(profile.id) }
                                }
                                Button("Delete profile", role: .destructive) {
                                    deletingID = profile.id; confirmingDelete = true
                                }
                                .disabled(model.library.profiles.count <= 1)
                            } label: {
                                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Options for \(profile.name)")
                        }
                    }
                }
                .disabled(readingImport)
                Section {
                    Button("New standard controller") { beginNew(standard: true) }
                    Button("New empty profile") { beginNew(standard: false) }
                } footer: {
                    Text("An empty profile lets you add just the controls you need. Close this screen, tap Edit, then Add. You can keep up to 32 profiles and \(ControllerProfile.maximumControls) controls per profile.")
                }
                .disabled(model.library.profiles.count >= 32 || readingImport)
                Section {
                    Button("Delete several profiles", role: .destructive) { showingBulkDelete = true }
                        .disabled(model.library.profiles.count <= 1 || !model.canEditLayout || readingImport)
                }
                Section {
                    Button("Export all profiles") {
                        guard let data = model.exportProfiles() else { return }
                        exportDocument = NativeProfileDocument(data: data)
                        exportFilename = "SimpleController-iPhone-profiles.json"
                        showingExporter = true
                    }
                    Button("Import iPhone profiles") { importingAndroid = false; showingImporter = true }
                    Button("Import Android profiles") { importingAndroid = true; showingImporter = true }
                    if readingImport { ProgressView("Preparing profile file…") }
                } header: {
                    Text("Profile backups")
                } footer: {
                    Text("Export saves every iPhone profile and preserved Android original, without connection settings or held input. Native profiles have a 16 MiB limit; backups including originals may be up to 40 MiB. Android import previews conversions before adding them. Originals are limited to 25 MiB in total. Imports keep your current profile selected.")
                }
                .disabled(!model.canEditLayout || model.isEditingLayout || readingImport)
                Section {
                    Button("Recovery documents") {
                        recoveryPresentation = RecoveryPresentation(documents: model.recoveryDocuments)
                    }
                        .disabled(model.isEditingLayout || readingImport)
                } footer: {
                    Text("Review copies kept before upgrades and deletions. Export any copy unchanged, or restore a validated profile library after reviewing it.")
                }
                Section {
                    Button("Manage reusable settings") { showingPresetManager = true }
                } header: { Text("Saved settings") }
                footer: { Text("Keep named stick, Button Aim, TouchAim and floating-control presets. Applying a preset changes a control draft; saving the preset library is a separate action.") }
                .disabled(!model.canEditLayout || readingImport)
                if !originals.isEmpty {
                    Section {
                        ForEach(originals) { reference in
                            Button {
                                guard let data = model.exportAndroidOriginal(reference) else { return }
                                exportDocument = NativeProfileDocument(data: data, kind: .androidOriginal)
                                exportFilename = "SimpleController-Android-original.json"
                                showingExporter = true
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Export original: \(reference.displayName)")
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(reference.byteCount), countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("Android originals") }
                    footer: {
                        Text("These are the exact files you imported. They retain unsupported settings. Your later iPhone edits are saved separately and included in Export all profiles.")
                    }
                }
            }
            .onAppear { originals = model.androidOriginals() }
            .sheet(isPresented: $showingPresetManager) {
                SettingsPresetManagerView(library: model.library.settingsPresets, onSave: model.saveSettingsPresets)
            }
            .sheet(item: $recoveryPresentation) { presentation in
                RecoveryDocumentsView(documents: presentation.documents, onRestore: model.restoreRecoveryDocument)
            }
            .sheet(isPresented: $showingBulkDelete) {
                ProfileBulkDeleteView(library: model.library, onDelete: model.deleteProfiles)
            }
            .sheet(item: $androidPreview) { preview in
                AndroidImportReviewView(model: model, preview: preview) { originals = model.androidOriginals() }
            }
            .sheet(item: $editedAndroidPreview, onDismiss: {
                if pendingEditedFileExport { pendingEditedFileExport = false; showingExporter = true }
            }) { review in
                AndroidEditedExportReviewView(review: review) { data, filename in
                    exportDocument = NativeProfileDocument(data: data, kind: .androidEdited)
                    exportFilename = filename
                    pendingEditedFileExport = true
                    editedAndroidPreview = nil
                }
            }
            .interactiveDismissDisabled(readingImport)
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(readingImport) }
            }
            .alert(renamingID == nil ? "New profile" : "Rename profile", isPresented: $naming) {
                TextField("Profile name", text: $enteredName)
                Button("Cancel", role: .cancel) { }
                Button(renamingID == nil ? "Create" : "Rename") {
                    let name = enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let id = renamingID { _ = model.renameProfile(id, name: name) }
                    else { _ = model.createProfile(name: name, standardControls: newUsesStandard) }
                }
                .disabled(enteredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || enteredName.count > 64)
            } message: { Text("Choose a name from 1 to 64 characters.") }
            .confirmationDialog("Delete this profile?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete profile", role: .destructive) {
                    if let id = deletingID { _ = model.deleteProfile(id) }
                }
                Button("Keep profile", role: .cancel) { }
            } message: {
                Text("Its controls will leave the profile list. A recovery copy is kept on this phone. Your other profiles stay available.")
            }
            .fileExporter(isPresented: $showingExporter, document: exportDocument,
                          contentType: .json, defaultFilename: exportFilename) { result in
                switch result {
                case .success:
                    switch exportDocument?.kind {
                    case .androidOriginal:
                        model.reportBackupMessage("Unchanged Android original exported. iPhone edits remain in the iPhone backup.")
                    case .androidEdited:
                        model.reportBackupMessage("Android copy with the reviewed edits exported. Your preserved original is unchanged.")
                    default:
                        model.reportBackupMessage("Profile backup exported, including every preserved Android original.")
                    }
                case .failure(let error):
                    reportFileError(error, action: "Export")
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    readingImport = true
                    let isAndroid = importingAndroid
                    Task { @MainActor in
                        defer { readingImport = false }
                        do {
                            let data = try await Task.detached(priority: .userInitiated) {
                                try NativeProfileDocument.readBounded(from: url, maximum: isAndroid
                                    ? AndroidProfileArchiveStore.maximumTotalBytes : AndroidPortableBackup.maximumBytes)
                            }.value
                            guard model.isManagingProfiles, !Task.isCancelled else { return }
                            if isAndroid {
                                let name = url.lastPathComponent
                                let preview = try await Task.detached(priority: .userInitiated) {
                                    try AndroidImportPreview.prepare(data, displayName: name)
                                }.value
                                guard model.isManagingProfiles, !Task.isCancelled else { return }
                                androidPreview = preview
                            } else {
                                _ = model.importProfiles(data)
                                originals = model.androidOriginals()
                            }
                        } catch {
                            reportFileError(error, action: "Import")
                        }
                    }
                case .failure(let error):
                    reportFileError(error, action: "Import")
                }
            }
        }
    }

    // Keep presentation and its snapshot together so the first sheet cannot capture an older array.
    private struct RecoveryPresentation: Identifiable {
        let id = UUID()
        let documents: [ProfileRecoveryDocument]
    }

    private func beginNew(standard: Bool) {
        renamingID = nil; newUsesStandard = standard; enteredName = ""; naming = true
    }

    private func prepareEditedExport(_ profileID: UUID) {
        pendingEditedFileExport = false; exportDocument = nil
        readingImport = true
        Task { @MainActor in
            defer { readingImport = false }
            let review = await model.prepareEditedAndroidExport(profileID)
            guard model.isManagingProfiles, !Task.isCancelled else { return }
            editedAndroidPreview = review
        }
    }

    private func reportFileError(_ error: Error, action: String) {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError {
            model.reportBackupMessage("\(action) canceled. Your profiles are unchanged.")
        } else {
            model.reportBackupMessage("\(action) could not finish. \(error.localizedDescription)")
        }
    }
}

@MainActor
struct GameStarterPicker: View {
    @ObservedObject var model: ProfileControllerViewModel
    var welcome = false
    var onFinish: () -> Void
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Choose a layout to try in Practice. Open Tools → Support for PC and console connection steps.")
                if model.library.profiles.count >= 32 {
                    Text("Your library has 32 profiles. Remove one in Profiles to add a starter.")
                        .foregroundStyle(.orange)
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            Section {
                ForEach(GameStarter.allCases) { starter in
                    Button {
                        if model.useStarter(starter) { onFinish() }
                        else { error = model.message }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(starter.rawValue).font(.headline)
                                Text(starter.summary).font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: starter.symbol) }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(starter.rawValue)
                    .accessibilityHint("\(starter.summary) Adds an editable copy and opens it on the controller.")
                    .disabled(model.library.profiles.count >= 32)
                }
            } footer: {
                Text("Each choice adds an editable copy to Profiles. Tap Edit to move a control or change its action. Xbox button assignments vary by game.")
            }
            if welcome {
                Section {
                    Button("Use standard controller", action: onFinish)
                        .frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("Game starters")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension GameStarter {
    var summary: String {
        switch self {
        case .shooter: "Move, aim and fire."
        case .racing: "Steer, accelerate and brake."
        case .sports: "Move and use the face buttons for plays."
        case .openWorld: "Explore on foot or drive."
        case .palworld: "Explore, battle, catch Pals and reach menus with one finger."
        }
    }
    var symbol: String {
        switch self {
        case .shooter: "scope"
        case .racing: "steeringwheel"
        case .sports: "sportscourt"
        case .openWorld: "map"
        case .palworld: "pawprint"
        }
    }
}

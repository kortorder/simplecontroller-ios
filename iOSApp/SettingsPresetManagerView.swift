import SwiftUI
import UniformTypeIdentifiers
import ControllerCore

extension SettingsPresetCategory {
    var presetTitle: String {
        switch self {
        case .stickDirectional: "Directional sticks"
        case .buttonAim: "Button Aim"
        case .touchAimManual: "Manual Touch Aim"
        case .touchCalibration: "Touch calibrations"
        case .floatingBoost: "Floating Boost"
        case .floatingRing: "Floating rings"
        }
    }
}

/// Edits one value draft. Root decides the persistence and input-stop boundary.
@MainActor
struct SettingsPresetManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SettingsPresetLibrary
    @State private var renameID: UUID?
    @State private var enteredName = ""
    @State private var showingRename = false
    @State private var deleteID: UUID?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDocument: SettingsPresetDocument?
    @State private var readingImport = false
    @State private var importID = UUID()
    let onSave: (SettingsPresetLibrary) -> Bool

    init(library: SettingsPresetLibrary, onSave: @escaping (SettingsPresetLibrary) -> Bool) {
        _draft = State(initialValue: library); self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Presets reuse settings on other controls. They contain no active touches, network connection or live button holds.")
                    Button("Import preset JSON") { showingImporter = true }.disabled(readingImport)
                    Button("Export this preset library") { prepareExport() }.disabled(readingImport)
                    if readingImport { ProgressView("Reading preset file…") }
                } footer: {
                    Text("Imports add separate copies with fresh names when needed. Save keeps library changes; Cancel leaves the saved library unchanged. Export includes this draft.")
                }
                ForEach(SettingsPresetCategory.allCases, id: \.self) { category in
                    Section {
                        let entries = draft.orderedEntries(in: category)
                        if entries.isEmpty { Text("No saved presets").foregroundStyle(.secondary) }
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                                if case let .touchCalibration(calibration) = entry.value {
                                    Text(calibration.isApplicable ? "Validated locally" : "Needs local validation before use")
                                        .font(.caption).foregroundStyle(calibration.isApplicable ? Color.secondary : Color.orange)
                                }
                                HStack {
                                    Button("Rename") { renameID = entry.id; enteredName = entry.name; showingRename = true }
                                    Spacer()
                                    Button("Delete", role: .destructive) { deleteID = entry.id }
                                }.buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(entry.name)
                        }
                    } header: { Text(category.presetTitle) }
                }
                if let statusMessage { Section { Text(statusMessage).fixedSize(horizontal: false, vertical: true) } }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) } }
                Section {
                    Text("Each category holds up to 64 unique names. Preset files are limited to 2 MiB. Imported touch calibrations keep their fitted summary but need a fresh no-output validation on this phone before use.")
                } header: { Text("Library limits") }
            }
            .navigationTitle("Settings presets").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { importID = UUID(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if onSave(draft) { dismiss() }
                        else { errorMessage = "The preset library could not be saved. Your draft is still here." }
                    }.disabled(readingImport)
                }
            }
            .alert("Rename preset", isPresented: $showingRename) {
                TextField("Preset name", text: $enteredName)
                Button("Cancel", role: .cancel) { }
                Button("Rename") {
                    guard let renameID else { return }
                    change { try $0.rename(renameID, to: enteredName, at: Self.now) }
                }
            } message: { Text("Use a unique name from 1 to 64 characters in this category.") }
            .confirmationDialog("Delete this preset?", isPresented: Binding(
                get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }), titleVisibility: .visible) {
                Button("Delete preset", role: .destructive) {
                    if let deleteID { change { try $0.delete(deleteID) } }
                    deleteID = nil
                }
                Button("Keep preset", role: .cancel) { deleteID = nil }
            } message: { Text("Controls already using these settings stay unchanged. Save commits this library deletion.") }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json], allowsMultipleSelection: false, onCompletion: importFile)
            .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .json,
                          defaultFilename: "simplecontroller-settings-presets") { result in
                switch result {
                case .success: statusMessage = "Preset library exported."
                case let .failure(error): report(error)
                }
                exportDocument = nil
            }
            .onDisappear { importID = UUID() }
        }
    }
    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func change(_ mutation: (inout SettingsPresetLibrary) throws -> Void) {
        var next = draft
        do { try mutation(&next); _ = try SettingsPresetLibraryCodec.encode(next); draft = next; errorMessage = nil; statusMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func prepareExport() {
        do { exportDocument = SettingsPresetDocument(data: try SettingsPresetLibraryCodec.encode(draft)); showingExporter = true; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func report(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
        errorMessage = error.localizedDescription
    }
    private func importFile(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error): report(error)
        case let .success(urls):
            guard let url = urls.first else { return }
            readingImport = true; let token = UUID(); importID = token
            Task { @MainActor in
                do {
                    let library = try await Task.detached(priority: .userInitiated) {
                        let data = try NativeProfileDocument.readBounded(from: url, maximum: SettingsPresetLibraryCodec.maximumBytes)
                        return try SettingsPresetLibraryCodec.decode(data)
                    }.value
                    guard token == importID else { return }
                    var next = draft
                    _ = try next.merge(library, at: Self.now)
                    draft = next; errorMessage = nil; readingImport = false
                    statusMessage = "Added \(library.entries.count) separate preset copies to this draft. Save keeps them. Imported calibrations need local validation."
                } catch {
                    guard token == importID else { return }
                    readingImport = false; errorMessage = "Nothing was imported. \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct SettingsPresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw SettingsPresetError("The selected preset file could not be read.") }
        _ = try SettingsPresetLibraryCodec.decode(data); self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        _ = try SettingsPresetLibraryCodec.decode(data)
        return FileWrapper(regularFileWithContents: data)
    }
}

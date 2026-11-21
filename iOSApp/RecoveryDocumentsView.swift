import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct RecoveryDocumentsView: View {
    let documents: [ProfileRecoveryDocument]
    let onRestore: (ProfileRecoveryDocument) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ProfileRecoveryDocument?
    @State private var confirmingRestore = false
    @State private var exportDocument: RawRecoveryDocument?
    @State private var exportType: UTType = .data
    @State private var exportName = "SimpleController-recovery.bin"
    @State private var showingExporter = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These are saved copies from earlier changes or data the app could not open. Export makes an exact copy without changing your current profiles.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Android original files are stored separately on this phone. Restoring a profile recovery copy does not recreate a missing original file. Use Export all profiles for a backup that includes available originals.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let message {
                        Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if documents.isEmpty {
                    Section { Text("There are no preserved profile documents on this phone yet.") }
                }
                ForEach(documents, id: \.id) { document in
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(document.title).font(.headline)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(document.data.count), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                            if let names = document.profileNames, document.validationIssue == nil {
                                Text("\(names.count) \(names.count == 1 ? "profile" : "profiles")")
                                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                                    Text(name).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                Label(document.validationIssue ?? "This document cannot be restored by this version of the app.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                Text("You can still export its exact raw data. It may need a compatible app version or separate recovery before use.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Button("Export this saved document") { prepareExport(document) }
                            .accessibilityHint("Saves the original bytes to Files without changing any profiles.")
                        Button("Restore these profiles", role: .destructive) {
                            selected = document; confirmingRestore = true
                        }
                        .disabled(document.validationIssue != nil || document.profileNames == nil)
                        .accessibilityHint("Replaces the entire current profile library after confirmation. The current library is preserved as another recovery copy.")
                    }
                }
            }
            .navigationTitle("Recovery documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Replace the current profile library?", isPresented: $confirmingRestore, titleVisibility: .visible) {
                Button("Restore saved library", role: .destructive) {
                    guard let selected else { return }
                    if onRestore(selected) { dismiss() }
                    else { message = "This saved document could not be restored. Your current profiles are unchanged. Close and reopen Recovery documents to refresh the list, or export the document for recovery." }
                }
                Button("Keep current profiles", role: .cancel) { selected = nil }
            } message: {
                if let selected, let names = selected.profileNames {
                    Text("This replaces every current profile and reusable setting with “\(selected.title)” (\(names.count) \(names.count == 1 ? "profile" : "profiles")). A recovery copy of your current saved data is kept first. All held controls will be released.")
                }
            }
            .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
                switch result {
                case .success: message = "The saved document was exported unchanged. Your current profiles are unchanged."
                case let .failure(error):
                    let cocoa = error as NSError
                    message = cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError
                        ? "Export canceled. Your saved documents and current profiles are unchanged."
                        : "Export could not finish. \(error.localizedDescription)"
                }
                exportDocument = nil
            }
        }
    }

    private func prepareExport(_ document: ProfileRecoveryDocument) {
        let native = document.validationIssue == nil && document.profileNames != nil
        exportDocument = RawRecoveryDocument(data: document.data)
        exportType = native ? .json : .data
        exportName = native ? "SimpleController-recovery.json" : "SimpleController-recovery.bin"
        message = native ? nil : "Exporting exact raw data as .bin. This preserves unreadable or newer data without claiming it is a usable iPhone profile."
        showingExporter = true
    }
}

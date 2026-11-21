import SwiftUI
import ControllerCore

@MainActor
struct AndroidImportReviewView: View {
    @ObservedObject var model: ProfileControllerViewModel
    let preview: AndroidImportPreview
    var onImported: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Import preview") {
                    Text(preview.displayName).font(.headline)
                    Text("\(preview.plan.profiles.count) iPhone \(preview.plan.profiles.count == 1 ? "profile" : "profiles") with \(preview.plan.convertedControlCount) \(preview.plan.convertedControlCount == 1 ? "control" : "controls") can be added.")
                    if preview.plan.convertedPresetCount > 0 {
                        Text("\(preview.plan.convertedPresetCount) reusable settings will be added as independent copies. Your existing presets stay unchanged.")
                    }
                    if preview.plan.archivedOnlyControlCount > 0 || preview.plan.archivedOnlyProfileCount > 0 {
                        Label("Archived only: \(preview.plan.archivedOnlyControlCount) \(preview.plan.archivedOnlyControlCount == 1 ? "control" : "controls"), \(preview.plan.archivedOnlyProfileCount) whole \(preview.plan.archivedOnlyProfileCount == 1 ? "profile" : "profiles"). These remain in the original file and are not added as working iPhone controls.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("The exact original file will be preserved on this iPhone, including unknown settings and reusable libraries. Your current profiles and selection stay in place.")
                    Text("Sizes are adapted to the iPhone canvas. Android touch calibration is not applied. Review the differences below before importing.")
                    if let importError { Text(importError).foregroundStyle(.orange) }
                }
                if !preview.plan.profiles.isEmpty {
                    Section("Profiles to add") {
                        ForEach(preview.plan.profiles, id: \.profile.id) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.profile.name)
                                Text("\(item.profile.pages.count) \(item.profile.pages.count == 1 ? "page" : "pages") · \(item.profile.controls.count) \(item.profile.controls.count == 1 ? "control" : "controls")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !preview.plan.issues.isEmpty {
                    Section("Changes and preserved settings") {
                        ForEach(Array(preview.plan.issues.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(issue.message)
                                if !issue.sourcePath.isEmpty {
                                    Text(issue.sourcePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Android import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(preview.plan.profiles.isEmpty && preview.plan.convertedPresetCount == 0 ? "Preserve original" : "Import") {
                        if model.importAndroid(preview) { onImported(); dismiss() }
                        else { importError = model.message }
                    }
                }
            }
        }
    }
}

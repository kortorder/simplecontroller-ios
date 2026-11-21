import SwiftUI
import ControllerCore

@MainActor
struct AndroidEditedExportReviewView: View {
    let review: AndroidEditedExportReview
    var onExport: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(review.profileName) {
                    Text("This creates a separate Android file with the supported edits below. The preserved original and your iPhone profiles stay unchanged.")
                    if review.preview.isUnchanged {
                        Text("No changes to apply. The exported file will match the original exactly.")
                    } else {
                        Text("\(review.preview.changedFieldCount) changed fields")
                        Text("Controls: \(review.preview.addedControlCount) added, \(review.preview.deletedControlCount) removed")
                        Text("Pages: \(review.preview.addedPageCount) added, \(review.preview.deletedPageCount) removed")
                    }
                    if !review.preview.canExport {
                        Text("This profile has edits that cannot be safely represented in Android format. Export is unavailable until those issues are resolved. Export all profiles still keeps the full iPhone version and original.")
                            .foregroundStyle(.orange)
                    }
                    if review.preview.deletedControlCount > 0 || review.preview.deletedPageCount > 0 {
                        Text("Removed converted records will also lose their extra settings in this edited copy. The unchanged original still retains them. Archived-only controls are not removed by deleting iPhone controls.")
                    }
                }
                if !review.preview.diagnostics.isEmpty {
                    Section("Review details") {
                        ForEach(Array(review.preview.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(diagnostic.message)
                                    .foregroundStyle(diagnostic.severity == .blocked ? .orange : .primary)
                                if !diagnostic.sourcePath.isEmpty {
                                    Text(diagnostic.sourcePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Android export preview").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        guard let data = review.preview.data else { return }
                        onExport(data, review.preview.suggestedFilename)
                    }.disabled(!review.preview.canExport)
                }
            }
        }
    }
}

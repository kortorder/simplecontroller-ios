import SwiftUI
import ControllerCore

@MainActor
struct ProfileBulkDeleteView: View {
    @Environment(\.dismiss) private var dismiss
    let library: ControllerProfileLibrary
    /// The parent revalidates the IDs against its latest library and persists once.
    let onDelete: (Set<UUID>) -> Bool
    @State private var selected: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    private var candidates: [ControllerProfile] { ControllerProfileBulkDeletion.candidates(in: library) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select inactive profiles to remove together. Your active profile is protected. Saved presets and preserved Android originals stay available.")
                    Button("Select all inactive profiles") { selected = Set(candidates.map(\.id)) }
                        .disabled(candidates.isEmpty)
                    Button("Clear selection") { selected = [] }.disabled(selected.isEmpty)
                }
                Section("Profiles") {
                    ForEach(library.profiles) { profile in
                        let active = profile.id == library.activeProfileID
                        Button {
                            if selected.contains(profile.id) { selected.remove(profile.id) } else { selected.insert(profile.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: active ? "lock.fill" : selected.contains(profile.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                    Text(active ? "Active — protected" : "\(profile.controls.count) controls")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(active)
                            .accessibilityValue(active ? "Protected" : selected.contains(profile.id) ? "Selected" : "Not selected")
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .navigationTitle("Delete profiles").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete (\(selected.count))", role: .destructive) { confirmingDelete = true }
                        .disabled(selected.isEmpty)
                }
            }
            .confirmationDialog("Delete \(selected.count) selected profiles?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete selected profiles", role: .destructive) {
                    do {
                        _ = try ControllerProfileBulkDeletion.prepare(library: library, selectedIDs: selected)
                        if onDelete(selected) { dismiss() }
                        else { errorMessage = "The selected profiles could not be deleted. Refresh the list and try again." }
                    } catch { errorMessage = error.localizedDescription }
                }
                Button("Keep profiles", role: .cancel) { }
            } message: {
                Text(library.profiles.filter { selected.contains($0.id) }.map(\.name).joined(separator: "\n"))
            }
        }
    }
}

import SwiftUI
import ControllerCore

/// Page management is a nested draft; the main Save layout remains the persistence boundary.
@MainActor
struct ProfilePagesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ControllerProfile
    @State private var selectedPageID: UUID
    @State private var naming = false
    @State private var renameID: UUID?
    @State private var enteredName = ""
    @State private var deleteID: UUID?
    @State private var errorMessage: String?
    let sourceProfiles: [ControllerProfile]
    let onSave: (ControllerProfile, UUID) -> Void

    init(profile: ControllerProfile, selectedPageID: UUID,
         sourceProfiles: [ControllerProfile], onSave: @escaping (ControllerProfile, UUID) -> Void) {
        _draft = State(initialValue: profile)
        _selectedPageID = State(initialValue: selectedPageID)
        self.sourceProfiles = sourceProfiles
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Add empty page") {
                        renameID = nil; enteredName = ""; naming = true
                    }
                    .disabled(draft.pages.count >= 32)
                    Menu("Copy a page from a saved profile") {
                        ForEach(sourceProfiles) { profile in
                            Menu(profile.name) {
                                ForEach(profile.pages) { page in
                                    Button(page.name) {
                                        change { selectedPageID = try $0.importPage(page.id, from: profile) }
                                    }
                                    .disabled(draft.controls.count + page.controlIDs.count > ControllerProfile.maximumControls)
                                }
                            }
                        }
                    }
                    .disabled(draft.pages.count >= 32)
                } header: { Text("Add pages") }
                ForEach(draft.pages) { page in
                    Section {
                        Button {
                            selectedPageID = page.id
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedPageID == page.id ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(page.name).foregroundStyle(.primary)
                                    Text("\(page.controlIDs.count) controls\(draft.homePageID == page.id ? " · Home" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit page, \(page.name)")
                        .accessibilityValue(selectedPageID == page.id ? "Selected" : "Not selected")
                        Button("Rename page") {
                            renameID = page.id; enteredName = page.name; naming = true
                        }
                        if page.id != draft.homePageID {
                            Button("Make Home page") { change { try $0.setHomePage(page.id) } }
                        }
                        Button("Copy page") {
                            change { selectedPageID = try $0.duplicatePage(page.id) }
                        }
                        .disabled(draft.pages.count >= 32 || draft.controls.count + page.controlIDs.count > ControllerProfile.maximumControls)
                        Button("Delete page", role: .destructive) { deleteID = page.id }
                            .disabled(draft.pages.count == 1)
                    }
                }
                Section {
                    Text("A copied page has separate controls. Links to that copied page follow its copy; links to other pages become Home.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Use pages for different situations, such as walking and driving. The app starts on Home. Switching pages releases all held controls.")
                    Text("Select the page you want to arrange, then tap Done. Add or move controls on that page in the main editor.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
                Section {
                    Text("Done updates the layout draft. Save layout keeps every page and control change. Cancel on the controller restores the saved profile.")
                    Text("Each profile can have 32 pages and \(ControllerProfile.maximumControls) controls in total. To move a control between pages, hold it in Edit and choose Place on page.")
                } header: { Text("Keeping your changes") }
            }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(draft, selectedPageID); dismiss() }
                }
            }
            .alert(renameID == nil ? "New page" : "Rename page", isPresented: $naming) {
                TextField("Page name", text: $enteredName)
                Button("Cancel", role: .cancel) { }
                Button(renameID == nil ? "Create" : "Rename") {
                    change {
                        if let id = renameID { try $0.renamePage(id, to: enteredName) }
                        else { selectedPageID = try $0.addPage(name: enteredName) }
                    }
                }
            } message: { Text("Choose a unique name from 1 to 64 characters.") }
            .confirmationDialog("Delete this page and its controls?", isPresented: Binding(
                get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }), titleVisibility: .visible) {
                Button("Delete page", role: .destructive) {
                    guard let id = deleteID else { return }
                    change {
                        try $0.deletePage(id)
                        if selectedPageID == id { selectedPageID = $0.homePageID }
                    }
                    deleteID = nil
                }
                Button("Keep page", role: .cancel) { deleteID = nil }
            } message: {
                Text("Buttons that linked to this page will go Home. This changes only the draft until Save layout; Cancel on the controller restores it.")
            }
        }
    }

    private func change(_ update: (inout ControllerProfile) throws -> Void) {
        var candidate = draft
        let previousSelection = selectedPageID
        do {
            try update(&candidate)
            try candidate.validate()
            draft = candidate; errorMessage = nil
        } catch {
            selectedPageID = previousSelection
            errorMessage = "This page change could not be applied. Check the name and the 32-page / \(ControllerProfile.maximumControls)-control limits. Your draft is unchanged."
        }
    }
}

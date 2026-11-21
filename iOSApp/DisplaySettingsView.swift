import SwiftUI
import ControllerCore

@MainActor
struct DisplaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ControllerPresentationPreferences
    @State private var editorOrientation: ControllerDisplayOrientation
    @State private var errorMessage: String?
    private let isEditing: Bool
    private let wrapInNavigationStack: Bool
    private let onSave: (ControllerPresentationPreferences, ControllerDisplayOrientation) -> Bool

    init(preferences: ControllerPresentationPreferences, editorOrientation: ControllerDisplayOrientation = .automatic,
         isEditing: Bool = false, wrapInNavigationStack: Bool = true,
         onSave: @escaping (ControllerPresentationPreferences, ControllerDisplayOrientation) -> Bool) {
        _draft = State(initialValue: preferences); _editorOrientation = State(initialValue: editorOrientation)
        self.isEditing = isEditing; self.wrapInNavigationStack = wrapInNavigationStack; self.onSave = onSave
    }
    var body: some View {
        if wrapInNavigationStack { NavigationStack { content } }
        else { content }
    }
    private var content: some View {
            Form {
                Section {
                    ForEach(ControllerThemePreference.allCases, id: \.self) { theme in
                        choice(theme.displayName, selected: draft.theme == theme) { draft.theme = theme }
                    }
                } header: { Text("Appearance") }
                footer: { Text("System follows your iPhone's light or dark appearance.") }
                Section {
                    orientationChoices(selection: $draft.playOrientation)
                } header: { Text("Play orientation") }
                footer: {
                    Text("This choice is saved for this app. Automatic follows the orientations iOS allows; Portrait or Landscape requests that orientation while playing. Landscape supports either side.")
                }
                if isEditing {
                    Section {
                        orientationChoices(selection: $editorOrientation)
                    } header: { Text("This editing session") }
                    footer: {
                        Text("Choose which orientation to edit now. This temporary choice ends when you leave layout editing. Portrait and landscape keep their own positions; the saved Play choice applies afterward.")
                    }
                } else {
                    Section { Text("While editing a layout, this screen also lets you request Portrait or Landscape without changing your saved Play orientation.") }
                }
                Section {
                    Text("Changing orientation releases controls before requesting a rotation. iOS may decline a request on the current display. The app keeps drawing the actual orientation and reports a failed request.")
                    Text("Display preferences stay on this phone and are not part of profile backups. Controller settings and saved positions are unchanged.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .navigationTitle("Display settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try draft.validate()
                            if onSave(draft, editorOrientation) { dismiss() }
                            else { errorMessage = "The display settings could not be saved. Your previous settings are unchanged." }
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
    }
    @ViewBuilder private func orientationChoices(selection: Binding<ControllerDisplayOrientation>) -> some View {
        ForEach(ControllerDisplayOrientation.allCases, id: \.self) { value in
            choice(value.displayName, selected: selection.wrappedValue == value) { selection.wrappedValue = value }
        }
    }
    private func choice(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(label).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

extension ControllerThemePreference {
    var displayName: String { switch self { case .dark: "Dark"; case .light: "Light"; case .system: "System" } }
    var colorScheme: ColorScheme? { switch self { case .dark: .dark; case .light: .light; case .system: nil } }
}
extension ControllerDisplayOrientation {
    var displayName: String { switch self { case .automatic: "Automatic"; case .portrait: "Portrait"; case .landscape: "Landscape" } }
}

import SwiftUI
import ControllerCore

@MainActor
struct SaveControlPresetView: View {
    @Environment(\.dismiss) private var dismiss
    let control: ProfileControl
    let library: SettingsPresetLibrary
    let onSave: (SettingsPresetLibrary) -> Bool
    @State private var selectedCategory: SettingsPresetCategory
    @State private var name: String
    @State private var errorMessage: String?

    init(control: ProfileControl, library: SettingsPresetLibrary,
         onSave: @escaping (SettingsPresetLibrary) -> Bool) {
        self.control = control; self.library = library; self.onSave = onSave
        _selectedCategory = State(initialValue: control.kind.isStick ? .stickDirectional : control.isTouchAim ?
            (control.touchAim.mode == .calibratedTwoState ? .touchCalibration : .touchAimManual) : .buttonAim)
        _name = State(initialValue: control.name)
    }
    private var categories: [SettingsPresetCategory] {
        if control.kind.isStick { return [.stickDirectional] }
        if control.kind == .button { return [.buttonAim] }
        if control.isTouchAim { return [.touchAimManual, .touchCalibration] }
        return []
    }
    private var proposed: Result<SettingsPresetLibrary, Error> {
        Result {
            guard categories.contains(selectedCategory) else { throw SettingsPresetError("This control has no reusable settings category.") }
            let entry = try SettingsPreset.capture(control, category: selectedCategory, name: name,
                                                   at: Int64(Date().timeIntervalSince1970 * 1000))
            var next = library; try next.save(entry); return next
        }
    }
    private var validationMessage: String? {
        if case let .failure(error) = proposed { return error.localizedDescription }; return nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Preset name", text: $name).textInputAutocapitalization(.words)
                    ForEach(categories, id: \.self) { category in
                        Button { selectedCategory = category; errorMessage = nil } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectedCategory == category ? "checkmark.circle.fill" : "circle")
                                Text(category.presetTitle).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(selectedCategory == category ? "Selected" : "Not selected")
                    }
                } header: { Text("Save settings from \(control.name)") }
                Section {
                    Text("The preset copies this control's current settings. It does not move or rename this control and does not save the controller layout draft.")
                    if selectedCategory == .stickDirectional {
                        Text("Save from Directional or Stick+ mode. Applying later can keep the target's mode or switch it explicitly; sensitivity, auto-center and Stick+ repeat are not copied.")
                    } else if selectedCategory == .buttonAim {
                        Text("Saves Base and Alternate tuning and actions. When applying, choose aiming feel only or complete settings.")
                    } else if selectedCategory == .touchAimManual {
                        Text("Saves the selected manual mode and aiming settings. Calibrated mode belongs in Touch calibrations instead.")
                    } else if selectedCategory == .touchCalibration {
                        Text("Only a native calibration that passed local no-output validation can be saved. Raw touch recordings are excluded.")
                    }
                }
                if let message = validationMessage ?? errorMessage {
                    Section { Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .navigationTitle("Save preset").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        switch proposed {
                        case let .success(next):
                            if onSave(next) { dismiss() }
                            else { errorMessage = "The preset could not be saved. The saved library is unchanged." }
                        case let .failure(error): errorMessage = error.localizedDescription
                        }
                    }.disabled(validationMessage != nil)
                }
            }
        }
    }
}

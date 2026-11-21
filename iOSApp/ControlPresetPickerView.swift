import SwiftUI
import ControllerCore

@MainActor
struct ControlPresetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let control: ProfileControl
    let library: SettingsPresetLibrary
    let onApply: (ProfileControl) -> Bool
    let onValidateCalibration: (SettingsPreset) -> Void
    @State private var errorMessage: String?

    private var categories: [SettingsPresetCategory] {
        if control.kind.isStick { return [.stickDirectional] }
        if control.kind == .button { return [.buttonAim] }
        if control.isTouchAim { return [.touchAimManual, .touchCalibration] }
        return []
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Apply saved settings to \(control.name). Its name, position, size and identity stay the same.")
                    Text("Applying updates the control draft. Finish the control editor and Save layout to keep the change.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if categories.isEmpty {
                    Section { Text("This control does not use a reusable settings category. Floating presets are applied from the ring editor.") }
                }
                ForEach(categories, id: \.self) { category in
                    Section {
                        let entries = library.orderedEntries(in: category)
                        if entries.isEmpty { Text("No presets saved in this category.").foregroundStyle(.secondary) }
                        ForEach(entries) { entry in
                            DisclosureGroup {
                                applyChoices(entry)
                            } label: {
                                Text(entry.name).fixedSize(horizontal: false, vertical: true)
                                    .frame(minHeight: 44, alignment: .leading)
                            }
                        }
                    } header: { Text(category.presetTitle) }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) } }
            }
            .navigationTitle("Apply preset").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    @ViewBuilder private func applyChoices(_ entry: SettingsPreset) -> some View {
        switch entry.value {
        case let .stickDirectional(preset):
            Text("Copies direction actions, thresholds and Extended Boost. Sensitivity, response curve, auto-center and this control's Stick+ repeat choice stay as they are.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Apply settings; keep current mode") { apply { try preset.apply(to: &$0, scope: .settingsOnly) } }
            Button(preset.mode == .directional ? "Apply settings and use Directional mode" : "Apply settings and use Stick+") {
                apply { try preset.apply(to: &$0, scope: .settingsAndMode) }
            }
        case let .buttonAim(preset):
            Text("Tuning only changes Base and Alternate aiming feel. Complete also replaces payloads, Hold Toggle, timing and Alternate behavior. Both enable Button Aim and turn off Auto-Tap.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Apply aiming feel only") { apply { try preset.apply(to: &$0, scope: .tuningOnly) } }
            Button("Apply complete Button Aim settings") { apply { try preset.apply(to: &$0, scope: .complete) } }
        case let .touchAimManual(preset):
            Text("Uses \(preset.mode == .manualThreeStage ? "manual three-stage" : "manual two-state") settings and clears this control's applied calibration. The inactive manual mode stays unchanged.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Apply manual Touch Aim settings") { apply { try preset.apply(to: &$0) } }
        case let .touchCalibration(calibration):
            Text("\(calibration.quality.rawValue.capitalized) calibration. Aim output, payloads and geometry stay unchanged.")
                .font(.footnote).foregroundStyle(.secondary)
            if calibration.isApplicable {
                Button("Apply validated calibration") { apply { try entry.value.applyCalibration(to: &$0) } }
            } else {
                Text("This calibration must pass fresh no-output validation on this phone before it can activate controls.")
                    .font(.footnote).foregroundStyle(.orange)
                Button("Validate on this phone") { onValidateCalibration(entry) }
            }
        case .floatingBoost, .floatingRing:
            Text("Apply this preset from the floating ring editor.").foregroundStyle(.secondary)
        }
    }
    private func apply(_ mutation: (inout ProfileControl) throws -> Void) {
        var next = control
        do {
            try mutation(&next); try next.validate()
            if onApply(next) { dismiss() }
            else { errorMessage = "These settings could not be applied. The control draft is unchanged." }
        } catch { errorMessage = error.localizedDescription }
    }
}

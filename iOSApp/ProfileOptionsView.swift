import SwiftUI
import ControllerCore

@MainActor
struct ProfileOptionsView: View {
    @State private var draft: ControllerProfile
    @State private var centeringMessage: String?
    @Environment(\.dismiss) private var dismiss
    let onSave: (ControllerProfile) -> Void

    init(profile: ControllerProfile, onSave: @escaping (ControllerProfile) -> Void) {
        _draft = State(initialValue: profile)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile name") {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }
                Section {
                    swipeModeRow(.off)
                    swipeModeRow(.buttons)
                    swipeModeRow(.controls)
                    Text(swipeModeDescription)
                        .fixedSize(horizontal: false, vertical: true)
                    if draft.swipeMode == .controls {
                        Text("Sticks use your final finger direction when you move to another control or lift.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text("Sliding between controls") }
                footer: {
                    Text("Re-center and Scroll mode toggle require a direct tap. Sliding onto them never activates their actions.")
                }
                Section {
                    Toggle("Tap ordinary buttons to hold", isOn: $draft.globalHoldEnabled)
                } header: { Text("Hold shortcut") }
                footer: {
                    Text("An ordinary button presses immediately and stays held after you lift. Tap it again to release. Each button keeps its own hold. Buttons using Hold to toggle, Auto-Tap, Turbo or advanced gestures keep their own behavior. Release all clears every hold.")
                }
                Section {
                    Button("Make sticks return to center") { setCentering(true) }
                    Button("Keep stick positions after release") { setCentering(false) }
                    if let centeringMessage { Text(centeringMessage).foregroundStyle(.secondary) }
                } header: { Text("Centering shortcut • Snap") }
                footer: {
                    Text("Applies to the sticks and enabled Button Aim controls on every page in this profile. It changes their individual Auto-center settings in this draft. TouchAim always centers when you lift. Re-center and Release all can stop retained positions while playing.")
                }
                Section {
                    Toggle("Turbo", isOn: $draft.turboEnabled)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repeat interval: \(draft.turboIntervalMilliseconds) ms")
                        Slider(value: Binding(get: { Double(draft.turboIntervalMilliseconds) }, set: {
                            draft.turboIntervalMilliseconds = Int($0.rounded())
                        }), in: 10...1_000, step: 1)
                        .accessibilityLabel("Turbo interval")
                        .accessibilityValue("\(draft.turboIntervalMilliseconds) milliseconds")
                        Stepper("Adjust interval", value: $draft.turboIntervalMilliseconds, in: 10...1_000)
                    }
                    .disabled(!draft.turboEnabled)
                } header: { Text("Repeat while touching") }
                footer: {
                    Text("Turbo repeats immediate button and trigger actions while you touch a control. It takes precedence over Hold Toggle. Controls with WAIT or Pulse keep their own sequence behavior; Auto-tap controls use their own repeat settings.")
                }
                Section {
                    Text("Done updates the profile draft. Tap Save layout on the controller screen to keep all profile options and centering changes. Cancel there restores the saved profile.")
                }
                if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.name.count > 64 {
                    Text("Choose a name from 1 to 64 characters.").foregroundStyle(.orange)
                }
            }
            .navigationTitle("Profile options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(draft); dismiss() }
                        .disabled((try? draft.validate()) == nil)
                }
            }
        }
    }

    private func setCentering(_ enabled: Bool) {
        do {
            let count = try draft.setAllAutoCenter(enabled)
            centeringMessage = count == 0 ? "These controls already use that setting." : "Updated \(count) \(count == 1 ? "control" : "controls") in this draft. Tap Done, then Save layout to keep it."
        } catch { centeringMessage = error.localizedDescription }
    }

    private func swipeModeRow(_ mode: ProfileSwipeMode) -> some View {
        Button {
            draft.swipeMode = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: draft.swipeMode == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(draft.swipeMode == mode ? Color.accentColor : Color.secondary)
                Text(swipeModeTitle(mode))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swipeModeTitle(mode))
        .accessibilityValue(draft.swipeMode == mode ? "Selected" : "Not selected")
        .accessibilityHint("Chooses how a touch moves between controls in this profile.")
    }

    private func swipeModeTitle(_ mode: ProfileSwipeMode) -> String {
        switch mode {
        case .off: "Keep touch on starting control"
        case .buttons: "Slide between buttons"
        case .controls: "Slide between controls"
        }
    }

    private var swipeModeDescription: String {
        switch draft.swipeMode {
        case .off:
            "The control you start on keeps your touch until you lift. Sliding onto another control does not activate it."
        case .buttons:
            "Leaving a button releases your touch from it. Sliding onto another button activates it. Sticks and touchpads keep tracking your touch until you lift."
        case .controls:
            "Slide between buttons, sticks and touchpads. Buttons and sticks keep their current output across empty space. Touchpads keep tracking outside until another enabled control is entered. Where controls overlap, the current control keeps your touch until you move outside it. Sliding back onto a control may wait briefly before it activates again."
        }
    }
}

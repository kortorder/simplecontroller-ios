import SwiftUI
import ControllerCore

/// Edits one control locally. Only Done passes a validated copy to the caller.
@MainActor
struct BehaviorSettingsView: View {
    let control: ControllerControlID
    private let configuration: ControllerBehaviors
    private let onSave: (ControllerBehaviors) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var buttonDraft: ButtonBehavior
    @State private var stickDraft: StickBehavior
    @State private var direction: StickDirection = .up
    @State private var normalExpanded = false
    @State private var boostExpanded = false
    @State private var superExpanded = false

    init(control: ControllerControlID, configuration: ControllerBehaviors,
         onSave: @escaping (ControllerBehaviors) -> Void) {
        self.control = control
        self.configuration = configuration
        self.onSave = onSave
        _buttonDraft = State(initialValue: control.isStick ? .init() : configuration.button(for: control))
        _stickDraft = State(initialValue: control.isStick ? configuration.stick(for: control) : .init())
    }

    var body: some View {
        NavigationStack {
            Form {
                if control.isStick {
                    stickSettings
                } else {
                    buttonSettings
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } header: { Text("Check these settings") }
                }

                Section {
                    Text("Settings apply after you tap Done. Release all clears held buttons and retained stick positions.")
                    if control.isStick || [.leftTrigger, .rightTrigger, .guide, .share].contains(control) {
                        Text("These LT and RT actions are full presses. They work in Practice, with the Windows PC receiver, or with the matching console trigger output selected in Bridge settings. Xbox logo and Share remain Practice only.")
                    }
                } header: { Text("Before using") }
            }
            .navigationTitle("\(title(for: control)) behavior")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        guard let updated = validatedConfiguration else { return }
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(validatedConfiguration == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var buttonSettings: some View {
        Section {
            Toggle("Hold to toggle", isOn: $buttonDraft.holdToggle)
                .accessibilityHint("Hold for the chosen duration to latch this control on. Tap again to turn it off.")

            Stepper(value: $buttonDraft.holdMilliseconds, in: 50...5_000, step: 50) {
                LabeledContent("Hold duration", value: "\(buttonDraft.holdMilliseconds) ms")
            }
            .disabled(!buttonDraft.holdToggle)
            .accessibilityLabel("Hold duration")
            .accessibilityValue("\(buttonDraft.holdMilliseconds) milliseconds")
        } header: {
            Text("Button action")
        } footer: {
            if buttonDraft.holdToggle {
                Text("Hold for \(buttonDraft.holdMilliseconds) ms to turn on. A shorter tap sends nothing. Once on, tap again to turn off.")
            } else {
                Text("The control stays on while you touch it and releases when you lift your finger.")
            }
        }
    }

    @ViewBuilder
    private var stickSettings: some View {
        Section {
            Toggle("Auto-center", isOn: $stickDraft.autoCenter)
        } header: {
            Text("When you lift your finger")
        } footer: {
            Text(stickDraft.autoCenter
                 ? "The stick returns to center and its directional actions release."
                 : "The stick keeps its last position and directional actions after you lift your finger. Move it back to center, tap Re-center, or tap Release all to clear it.")
        }

        Section {
            Toggle("Stick+ directional actions", isOn: $stickDraft.stickPlusEnabled)
            if stickDraft.stickPlusEnabled {
                thresholdRow("Boost above", value: boostThreshold)
                thresholdRow("Super boost above", value: superThreshold)
                Text("Each stage replaces the previous stage; include the same action in both lists to keep it held. Diagonal movement can activate two directions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Stick+")
        } footer: {
            Text("Choose controls for normal movement and for movement beyond each distance along a direction. Super boost must start beyond boost. Directional actions start only beyond 10% from center along that direction.")
        }

        if stickDraft.stickPlusEnabled {
            Section {
                Picker("Direction", selection: $direction) {
                    ForEach(StickDirection.allCases, id: \.self) { direction in
                        Text(directionTitle(direction)).tag(direction)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: direction) { _, _ in
                    normalExpanded = false
                    boostExpanded = false
                    superExpanded = false
                }

                actionDisclosure(stage: .normal, expanded: $normalExpanded)
                actionDisclosure(stage: .boost, expanded: $boostExpanded)
                actionDisclosure(stage: .superBoost, expanded: $superExpanded)
            } header: {
                Text("Actions for \(directionTitle(direction).lowercased())")
            } footer: {
                Text("Select any combination for each stage. An empty list holds no extra controls. These choices do not change the selected buttons’ own settings.")
            }

            Section {
                Button("Apply forward example") { applyForwardExample() }
                Text("Up: no extra action through 50%; left stick click above 50% through 95%; above 95%, release left stick click and hold A. This replaces only the Up action lists and sets both thresholds. It is an example, not a game preset.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Optional example")
            }
        }
    }

    private func thresholdRow(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(label, value: percentage(value.wrappedValue))
            Slider(value: value, in: 0...1, step: 0.01)
                .accessibilityLabel(label)
                .accessibilityValue(percentage(value.wrappedValue))
        }
        .padding(.vertical, 4)
    }

    private enum ActionStage: String {
        case normal = "Normal"
        case boost = "Boost"
        case superBoost = "Super boost"
    }

    private func actionDisclosure(stage: ActionStage, expanded: Binding<Bool>) -> some View {
        let selected = actions(stage: stage)
        return DisclosureGroup(isExpanded: expanded) {
            ForEach(ControllerControlID.allCases.filter { !$0.isStick }, id: \.self) { action in
                Button {
                    var updated = actions(stage: stage)
                    if updated.contains(action) { updated.remove(action) }
                    else { updated.insert(action) }
                    setActions(updated, stage: stage)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(action) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selected.contains(action) ? Color.accentColor : Color.secondary)
                        Text(title(for: action))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        if isPracticeOnly(action) {
                            Text("Practice only")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(for: action))
                .accessibilityValue(selected.contains(action) ? "Selected" : "Not selected")
                .accessibilityHint("Double tap to change this \(stage.rawValue.lowercased()) action.")
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(stage.rawValue) actions")
                Text(actionSummary(selected))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var boostThreshold: Binding<Double> {
        Binding(get: { finiteSliderValue(stickDraft.boostThreshold) }, set: { newValue in
            stickDraft.boostThreshold = min(newValue, max(0, stickDraft.superBoostThreshold - 0.01))
        })
    }

    private var superThreshold: Binding<Double> {
        Binding(get: { finiteSliderValue(stickDraft.superBoostThreshold) }, set: { newValue in
            stickDraft.superBoostThreshold = max(newValue, min(1, stickDraft.boostThreshold + 0.01))
        })
    }

    private var validatedConfiguration: ControllerBehaviors? {
        var updated = configuration
        do {
            if control.isStick { try updated.setStick(stickDraft, for: control) }
            else { try updated.setButton(buttonDraft, for: control) }
            try updated.validate()
            return updated
        } catch {
            return nil
        }
    }

    private var validationMessage: String? {
        guard validatedConfiguration == nil else { return nil }
        if control.isStick {
            return "Choose finite distances from 0% to 100%, with super boost above boost, and valid button actions."
        }
        return "Choose a hold duration from 50 to 5,000 milliseconds."
    }

    private func actions(stage: ActionStage) -> Set<ControllerControlID> {
        let mapping = stickDraft.directions[direction] ?? .init()
        switch stage {
        case .normal: return mapping.normalControls
        case .boost: return mapping.boostControls
        case .superBoost: return mapping.superBoostControls
        }
    }

    private func setActions(_ actions: Set<ControllerControlID>, stage: ActionStage) {
        var mapping = stickDraft.directions[direction] ?? .init()
        switch stage {
        case .normal: mapping.normalControls = actions
        case .boost: mapping.boostControls = actions
        case .superBoost: mapping.superBoostControls = actions
        }
        stickDraft.directions[direction] = mapping
    }

    private func applyForwardExample() {
        stickDraft.stickPlusEnabled = true
        stickDraft.boostThreshold = 0.5
        stickDraft.superBoostThreshold = 0.95
        var mapping = stickDraft.directions[.up] ?? .init()
        mapping.normalControls = []
        mapping.boostControls = [.leftStickClick]
        mapping.superBoostControls = [.a]
        stickDraft.directions[.up] = mapping
        direction = .up
    }

    private func actionSummary(_ actions: Set<ControllerControlID>) -> String {
        let titles = ControllerControlID.allCases.filter { actions.contains($0) }.map { title(for: $0) }
        return titles.isEmpty ? "None selected" : titles.joined(separator: ", ")
    }

    private func finiteSliderValue(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func directionTitle(_ direction: StickDirection) -> String {
        switch direction {
        case .up: return "Up"
        case .right: return "Right"
        case .down: return "Down"
        case .left: return "Left"
        }
    }

    private func isPracticeOnly(_ control: ControllerControlID) -> Bool {
        [.guide, .share].contains(control)
    }

    private func title(for control: ControllerControlID) -> String {
        switch control {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .leftBumper: return "LB"
        case .rightBumper: return "RB"
        case .leftTrigger: return "LT"
        case .rightTrigger: return "RT"
        case .leftStickClick: return "Left stick click"
        case .rightStickClick: return "Right stick click"
        case .view: return "View"
        case .menu: return "Menu"
        case .guide: return "Xbox"
        case .share: return "Share"
        case .dpadUp: return "D-pad up"
        case .dpadRight: return "D-pad right"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .leftStick: return "Left stick"
        case .rightStick: return "Right stick"
        }
    }
}

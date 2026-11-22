import SwiftUI
import ControllerCore

@MainActor
struct TouchAimSettingsView: View {
    @Binding var settings: TouchAimSettings
    var onInspect: () -> Void
    var onCalibrate: () -> Void
    var onValidateExisting: (() -> Void)? = nil
    @State private var confirmingManualSetup = false

    var body: some View {
        Group {
            if settings.requiresLocalSetup {
                Section {
                    Label("Local setup required", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                    Text("Aim movement is available, but sensor-selected actions stay off. Imported measurements and thresholds have not been checked on this iPhone.")
                    Text("Open Touch inspector, review the manual thresholds below, and enable them only when you are ready to test them in Practice. Or complete a native calibration with fresh validation.")
                    Button("I reviewed these manual settings — enable actions") { confirmingManualSetup = true }
                        .disabled(settings.mode == .calibratedTwoState || manualSetupError != nil)
                    if let manualSetupError { Text(manualSetupError).font(.footnote).foregroundStyle(.orange) }
                } header: { Text("Before using sensor actions") }
                .confirmationDialog("Enable these manual sensor actions?", isPresented: $confirmingManualSetup,
                                    titleVisibility: .visible) {
                    Button("Enable manual actions") { settings.requiresLocalSetup = false }
                    Button("Keep actions off", role: .cancel) { }
                } message: {
                    Text("This uses the manual thresholds shown here without automatic calibration. Done and Save layout keep the choice. Check the response in Practice before relying on it.")
                }
            }
            Section {
                Text("Move one finger to aim while its contact measurement selects additional actions. Start with Touch inspector: contact size is not pressure, and force is available only when iOS explicitly supports it.")
                Button("Open touch inspector", action: onInspect)
                Button("Calibrate Aim and Shoot", action: onCalibrate)
            } header: { Text("TouchAim") }
            Section("Detection mode") {
                choice("Three manual stages", selected: settings.mode == .manualThreeStage) { settings.mode = .manualThreeStage }
                choice("Manual Aim / Shoot", selected: settings.mode == .manualTwoState) { settings.mode = .manualTwoState }
                choice("Calibrated Aim / Shoot", selected: settings.mode == .calibratedTwoState) { settings.mode = .calibratedTwoState }
                    .disabled(settings.calibration?.isApplicable != true)
                if let calibration = settings.calibration {
                    Text("\(calibration.name): \(calibration.quality.rawValue.capitalized) • \(calibration.validationCompleted ? "validation completed" : "validation required")")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let onValidateExisting {
                        Button("Validate saved calibration on this phone", action: onValidateExisting)
                    }
                    Button("Remove calibration", role: .destructive) {
                        settings.calibration = nil
                        if settings.mode == .calibratedTwoState { settings.mode = .manualTwoState }
                    }
                }
            }
            if settings.mode != .calibratedTwoState {
                Section("Measured signal") {
                    Picker("Metric", selection: $settings.metric) {
                        Text("Contact radius").tag(TouchAimMetric.majorRadius)
                        Text("Force, if available").tag(TouchAimMetric.normalizedForce)
                    }.pickerStyle(.menu)
                    decimal("Metric scale", value: $settings.metricScale)
                    Text("The threshold signal is this metric multiplied by its scale. Use the inspector's measured range to choose thresholds. Unavailable measurements release this control's actions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if settings.mode == .manualThreeStage {
                Section("Three stages") {
                    DisclosureGroup("Aim only") {
                        stageTuning("Aim only", value: $settings.threeStage.aimOnlyTuning)
                    }
                    stage("Low", value: $settings.threeStage.low)
                    stage("Medium", value: $settings.threeStage.medium)
                    stage("High", value: $settings.threeStage.high)
                    Toggle("Keep lower stage holds", isOn: $settings.threeStage.keepLowerHolds)
                    smoothing($settings.threeStage.smoothing)
                    decimal("Return hysteresis", value: $settings.threeStage.hysteresis)
                    Text("Thresholds must increase from Low to High. Press sends a brief action on entry. Hold lasts while the stage applies. Hysteresis prevents small sensor changes from repeatedly switching stages.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("Aim and Shoot actions") {
                    payload("Aim payload", text: $settings.twoState.aimPayload)
                    payload("Shoot payload", text: $settings.twoState.shootPayload)
                    Toggle("Keep Aim action while shooting", isOn: $settings.twoState.keepAimWhileShooting)
                    Picker("Shoot behavior", selection: $settings.twoState.shootBehavior) {
                        Text("Hold while shooting").tag(TouchAimShootBehavior.hold)
                        Text("Press when entering Shoot").tag(TouchAimShootBehavior.pressOnEnter)
                        Text("Press when returning to Aim").tag(TouchAimShootBehavior.pressOnReturn)
                    }.pickerStyle(.menu)
                    decimal("Exact Shoot sensitivity", value: $settings.twoState.shootSensitivity)
                    Text("Shoot aim sensitivity: \(settings.twoState.shootSensitivity.formatted(.number.precision(.fractionLength(2))))")
                    Slider(value: $settings.twoState.shootSensitivity, in: 0...5, step: 0.05)
                        .accessibilityLabel("Shoot aim sensitivity")
                    Text("A return-to-Aim press requires a measured transition while your finger remains down. Lifting or cancellation never creates that press.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if settings.mode == .manualTwoState {
                    Section("Aim / Shoot thresholds") {
                        decimal("Enter Shoot above", value: $settings.twoState.shootOn)
                        decimal("Return to Aim below", value: $settings.twoState.shootOff)
                        smoothing($settings.twoState.smoothing)
                        time("Confirm Shoot", value: $settings.twoState.enterMilliseconds)
                        time("Confirm Aim", value: $settings.twoState.returnMilliseconds)
                        Text("The return threshold must be lower than the entry threshold. Confirmation times reduce accidental switching.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let calibration = settings.calibration {
                    Section("Calibrated boundaries") {
                        Text("Enter \(calibration.shootOn.formatted(.number.precision(.fractionLength(3)))) • Return \(calibration.shootOff.formatted(.number.precision(.fractionLength(3))))")
                        Text("Confirm Shoot \(calibration.enterMilliseconds) ms • Aim \(calibration.returnMilliseconds) ms")
                        Text("These boundaries use the calibrated score. Manual thresholds remain saved for manual mode.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Aim movement") {
                ButtonAimTuningEditor(tuning: $settings.aim, allowDpad: false, allowRetainedAim: false)
            }
            Section {
                Text("TouchAim starts only with a direct finger touch. It does not accept sliding from another control or simulated accessibility taps. Lifting centers aim. A Hold Release Delay can keep a trigger pressed briefly after you lift. Release all, editing and leaving the app cancel pending actions.")
                Text("Payloads accept held controller, keyboard and mouse actions and trigger Pulse. WAIT, mouse UP and local commands are not supported here. Keyboard and mouse preview in Practice and work with a compatible computer receiver; Windows supports adjustable triggers, while Mac maps triggers to mouse clicks. For consoles, select the matching trigger output and Pico firmware: USB buttons send full presses; the Cronus Zen route or analog circuit supports adjustable pressure.")
            }
        }
    }
    private var manualSetupError: String? {
        guard settings.mode != .calibratedTwoState else { return nil }
        var candidate = settings; candidate.requiresLocalSetup = false
        do { try candidate.validate(); return nil } catch { return error.localizedDescription }
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(selected ? "Selected" : "Not selected")
    }
    private func decimal(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(title, value: value, format: .number).keyboardType(.decimalPad).accessibilityLabel(title)
        }
    }
    private func smoothing(_ value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("Smoothing: \(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))")
            Slider(value: value, in: 0.05...1, step: 0.05).accessibilityLabel("Sensor smoothing")
        }
    }
    private func time(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(value.wrappedValue) ms")
            TextField(title, value: value, format: .number).keyboardType(.numberPad).accessibilityLabel(title)
            Stepper("Change time", value: value, in: 1...2000, step: 10).accessibilityLabel(title)
        }
    }
    private func payload(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            TextField("No additional action", text: text, axis: .vertical).lineLimit(2...5)
                .font(.body.monospaced()).keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(title)
        }
    }
    private func stageTuning(_ title: String, value: Binding<TouchAimStageTuning>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stage aim sensitivity")
            TextField("Use main sensitivity", value: value.sensitivity, format: .number.precision(.fractionLength(0...8)))
                .keyboardType(.decimalPad)
                .accessibilityLabel("\(title) aim sensitivity")
            Text("Confirm entry (ms)")
            TextField("0", value: value.confirmationMilliseconds, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .accessibilityLabel("\(title) entry confirmation in milliseconds")
            Text("Leave sensitivity blank to follow the main setting. Set a time to require a steady touch before entering this stage.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func stage(_ title: String, value: Binding<TouchAimStage>) -> some View {
        DisclosureGroup(title) {
            decimal("\(title) threshold", value: value.threshold)
            payload("\(title) payload", text: value.payload)
            stageTuning(title, value: value.tuning)
            Picker("Action behavior", selection: value.action) {
                Text("Press once on entry").tag(TouchAimStageAction.press)
                Text("Hold").tag(TouchAimStageAction.hold)
            }.pickerStyle(.menu)
        }
    }
}

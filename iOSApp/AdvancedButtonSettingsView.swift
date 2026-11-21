import SwiftUI
import ControllerCore

/// Edits the same parent control draft; nothing executes while a settings sheet is open.
@MainActor
struct AdvancedButtonSettingsView: View {
    @Binding var control: ProfileControl
    @State private var direction: StickDirection = .up

    var body: some View {
        Group {
            Section {
                Toggle("Directional button", isOn: Binding(
                    get: { control.buttonDirectional.enabled },
                    set: { enabled in
                        control.buttonDirectional.enabled = enabled
                        if enabled {
                            control.macroModeEnabled = false
                            control.doubleTapRepeatEnabled = false
                            control.centerLeftStickBeforePress = false
                        }
                    }))
                    .disabled(control.autoTapEnabled && !control.buttonDirectional.enabled)
                if control.buttonDirectional.enabled {
                    Picker("Direction", selection: $direction) {
                        ForEach(StickDirection.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.pickerStyle(.menu)
                    distance("First action distance", value: stage(\.firstDistance), range: 1...1199)
                    payload("First action payload", text: stageText(\.firstPayload))
                    distance("Second action distance", value: stage(\.secondDistance), range: 2...1200)
                    payload("Second action payload", text: stageText(\.secondPayload))
                    Text("Start on this button and drag in a direction. First adds its payload to the button's normal action; Second adds both directional payloads. Moving back or changing direction releases the additions that no longer apply.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !control.buttonAim.enabled {
                        Text("Turn off Hold to toggle and Auto-Tap for directional-only buttons. This mode controls its own holds and ignores global Turbo.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Actions while dragging") }
            Section {
                Toggle("Button Aim", isOn: Binding(
                    get: { control.buttonAim.enabled },
                    set: { enabled in
                        control.buttonAim.enabled = enabled
                        if enabled {
                            control.macroModeEnabled = false
                            control.doubleTapRepeatEnabled = false
                            control.centerLeftStickBeforePress = false
                        }
                    }))
                    .disabled(control.autoTapEnabled && !control.buttonAim.enabled)
                if control.buttonAim.enabled {
                    Picker("Send button action", selection: $control.buttonAim.payloadTiming) {
                        Text("When touched").tag(ButtonAimPayloadTiming.immediate)
                        Text("When released").tag(ButtonAimPayloadTiming.sendOnRelease)
                    }.pickerStyle(.menu)
                    if control.buttonAim.payloadTiming == .sendOnRelease {
                        milliseconds("Delay after release", value: $control.buttonAim.releaseDelayMilliseconds)
                        Toggle("Cancel action outside button", isOn: $control.buttonAim.cancelOnBoundaryExit)
                        if control.buttonAim.cancelOnBoundaryExit {
                            Toggle("Re-arm when finger returns", isOn: $control.buttonAim.rearmOnBoundaryReturn)
                        }
                        Text("Aim while touching, then lift deliberately to send the action. Leaving the button's bounding rectangle can cancel it. Interruptions and canceled touches never fire the release action.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("The normal button action starts immediately while your finger also aims. Hold to toggle can keep the action held after the chosen hold duration.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Aim movement settings") {
                        ButtonAimTuningEditor(tuning: $control.buttonAim.tuning)
                    }
                    alternateSettings
                }
                if control.autoTapEnabled {
                    Text("Turn off Auto-Tap above before enabling directional actions or Button Aim.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Aim and press with one touch") }
            footer: {
                Text("Advanced buttons keep the original touch until you lift; sliding into or out of another control does not activate it. Their payloads accept held actions and trigger Pulse, but not WAIT, mouse UP or local commands.")
            }
        }
    }

    private var alternateSettings: some View {
        Group {
            Toggle("Alternate action", isOn: $control.buttonAim.alternate.enabled)
            if control.buttonAim.alternate.enabled {
                DisclosureGroup("Alternate settings") {
                    TextField("Alternate name (optional)", text: $control.buttonAim.alternate.displayName)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                    payload("Alternate payload", text: $control.buttonAim.alternate.payload)
                    Picker("Send alternate action", selection: $control.buttonAim.alternate.payloadTiming) {
                        Text("When touched").tag(ButtonAimPayloadTiming.immediate)
                        Text("When released").tag(ButtonAimPayloadTiming.sendOnRelease)
                    }.pickerStyle(.menu)
                    milliseconds("Hold to reset", value: $control.buttonAim.alternate.resetHoldMilliseconds)
                    milliseconds("Delay before releasing base", value: $control.buttonAim.alternate.baseUnlatchDelayMilliseconds)
                    DisclosureGroup("Alternate aim movement") {
                        ButtonAimTuningEditor(tuning: $control.buttonAim.alternate.tuning)
                    }
                    Text("After the base action arms Alternate, later touches use the alternate action. It stays in that phase until you hold for the reset time and lift deliberately. Release all resets every phase. A canceled touch never counts as a successful reset.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func stage(_ key: WritableKeyPath<ButtonDirectionStages, Double>) -> Binding<Double> {
        Binding(get: { (control.buttonDirectional.directions[direction] ?? .init())[keyPath: key] }, set: { value in
            var settings = control.buttonDirectional.directions[direction] ?? .init()
            settings[keyPath: key] = value
            if key == \.firstDistance { settings.firstDistance = min(value, settings.secondDistance - 1) }
            if key == \.secondDistance { settings.secondDistance = max(value, settings.firstDistance + 1) }
            control.buttonDirectional.directions[direction] = settings
        })
    }
    private func stageText(_ key: WritableKeyPath<ButtonDirectionStages, String>) -> Binding<String> {
        Binding(get: { (control.buttonDirectional.directions[direction] ?? .init())[keyPath: key] }, set: { value in
            var settings = control.buttonDirectional.directions[direction] ?? .init()
            settings[keyPath: key] = value; control.buttonDirectional.directions[direction] = settings
        })
    }
    private func payload(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            TextField("X360A", text: text, axis: .vertical).lineLimit(2...5)
                .font(.body.monospaced()).keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(title)
        }
    }
    private func distance(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title): \(Int(value.wrappedValue.rounded())) points")
            Slider(value: value, in: range, step: 1).accessibilityLabel(title)
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
            Stepper("Change distance", value: value, in: range, step: 1).accessibilityLabel(title)
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
        }
    }
    private func milliseconds(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title): \(value.wrappedValue) ms")
            TextField(title, value: value, format: .number).keyboardType(.numberPad).accessibilityLabel(title)
            Stepper("Change time", value: value, in: 0...60_000, step: 50).accessibilityLabel(title)
                .accessibilityValue("\(value.wrappedValue) milliseconds")
        }
    }
}

@MainActor
struct ButtonAimTuningEditor: View {
    @Binding var tuning: ButtonAimTuning
    var allowDpad = true
    var allowRetainedAim = true
    var body: some View {
        Group {
            Picker("Aim output", selection: $tuning.output) {
                Text("Mouse • Practice").tag(ButtonAimOutput.mouse)
                Text("Game mouse • Practice").tag(ButtonAimOutput.gameMouse)
                Text("Left stick").tag(ButtonAimOutput.leftStick)
                Text("Right stick").tag(ButtonAimOutput.rightStick)
                if allowDpad { Text("D-pad").tag(ButtonAimOutput.dpad) }
            }.pickerStyle(.menu)
            if tuning.output != .dpad {
            Text("Aim sensitivity (0–5)")
            TextField("Aim sensitivity", value: $tuning.sensitivity, format: .number.precision(.fractionLength(0...8)))
                .keyboardType(.decimalPad).accessibilityLabel("Exact aim sensitivity")
            Slider(value: $tuning.sensitivity, in: 0...5, step: 0.05).accessibilityLabel("Aim sensitivity")
                .accessibilityValue(tuning.sensitivity.formatted(.number.precision(.fractionLength(2))))
            Toggle("Invert vertical movement", isOn: $tuning.invertY)
            }
            if tuning.output.isMouse {
                Picker("Mouse response", selection: $tuning.mouseResponse) {
                    Text("Linear relative").tag(ButtonAimMouseResponse.linearRelative)
                    Text("Smoothed curve").tag(ButtonAimMouseResponse.smoothedNonlinear)
                }.pickerStyle(.menu)
                Text("Mouse movement is shown in Practice. The Xbox bridge cannot send desktop mouse input.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if tuning.output == .dpad {
                Picker("D-pad directions", selection: $tuning.dpadMode) {
                    Text("Four").tag(ButtonAimDpadMode.fourWay)
                    Text("Eight, including diagonals").tag(ButtonAimDpadMode.eightWay)
                }.pickerStyle(.menu)
                origin("D-pad origin", value: $tuning.dpadOrigin)
                pointSetting("D-pad activation distance", value: $tuning.dpadActivationDistance, range: 0...1200)
            } else {
                Picker("Stick response", selection: $tuning.stickResponse) {
                    Text("Linear").tag(StickResponseMode.linear)
                    Text("Curved per axis").tag(StickResponseMode.perAxis)
                    Text("Curved radial").tag(StickResponseMode.radial)
                }.pickerStyle(.menu)
                origin("Aim origin", value: $tuning.origin)
                if tuning.origin == .initialTouch {
                    pointSetting("Full stick distance", value: fullDistance, range: 1...1200)
                    pointSetting("Deadzone", value: deadzone, range: 0...1199)
                } else {
                    Text("Button center uses half the button's width and height as each axis's full distance. The initial-touch distance and deadzone stay saved for that mode.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if allowRetainedAim {
                    Toggle("Center aim on release", isOn: $tuning.autoCenter)
                    Text("When centering is off, a normal lift can keep the stick position. Re-center, Release all and interruptions clear it.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("This control always centers its aim when you lift.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Toggle("Touch feedback", isOn: $tuning.hapticsEnabled)
        }
    }
    private var fullDistance: Binding<Double> {
        Binding(get: { tuning.fullDisplacement }, set: { tuning.fullDisplacement = max($0, tuning.deadzone + 1) })
    }
    private var deadzone: Binding<Double> {
        Binding(get: { tuning.deadzone }, set: { tuning.deadzone = min($0, tuning.fullDisplacement - 1) })
    }
    private func origin(_ title: String, value: Binding<ButtonAimOrigin>) -> some View {
        Picker(title, selection: value) {
            Text("Where the touch starts").tag(ButtonAimOrigin.initialTouch)
            Text("Button center").tag(ButtonAimOrigin.controlCenter)
        }.pickerStyle(.menu)
    }
    private func pointSetting(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title): \(Int(value.wrappedValue.rounded())) points")
            Slider(value: value, in: range, step: 1).accessibilityLabel(title)
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
            Stepper("Change distance", value: value, in: range, step: 1).accessibilityLabel(title)
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
        }
    }
}

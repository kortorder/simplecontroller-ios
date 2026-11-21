import SwiftUI
import ControllerCore

/// The sheet edits a local copy; its parent retains the layout-level Save/Cancel decision.
@MainActor
struct ProfileControlEditor: View {
    private let onSave: (ProfileControl, UUID?) -> Void
    private let onDuplicate: (ProfileControl, UUID?) -> Void
    private let onDelete: (UUID) -> Void
    private let onSavePresets: (SettingsPresetLibrary) -> Bool
    private let canDuplicate: Bool
    private let pages: [ProfilePage]
    private let availableControls: [ProfileControl]
    private let initialSizeOrientation: ControllerOrientation
    @State private var selectedPageID: UUID?
    @State private var pagePlacementExpanded = false

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProfileControl
    @State private var direction: StickDirection = .up
    @State private var buttonActionsExpanded = false
    @State private var normalExpanded = false
    @State private var boostExpanded = false
    @State private var superExpanded = false
    @State private var confirmingDelete = false
    private enum EditorSheet: String, Identifiable {
        case inspector, calibration, applyPreset, savePreset
        var id: String { rawValue }
    }
    @State private var presentedSheet: EditorSheet?
    @State private var presetLibrary: SettingsPresetLibrary
    @State private var calibrationToValidate: TouchAimCalibrationProfile?
    @State private var calibrationPresetID: UUID?
    @State private var pendingCalibrationPreset: SettingsPreset?
    @State private var saveError: String?
    @State private var rememberedPayload: String?
    @State private var rememberedStickPlusRepeatInterval = 200
    @State private var rememberedStagePayloads: [String: String] = [:]

    init(control: ProfileControl, pages: [ProfilePage] = [], availableControls: [ProfileControl] = [], orientation: ControllerOrientation = .portrait, pageID: UUID? = nil,
         canDuplicate: Bool = true,
         settingsPresets: SettingsPresetLibrary = .empty,
         onSavePresets: @escaping (SettingsPresetLibrary) -> Bool = { _ in false },
         onSave: @escaping (ProfileControl, UUID?) -> Void,
         onDuplicate: @escaping (ProfileControl, UUID?) -> Void,
         onDelete: @escaping (UUID) -> Void) {
        _draft = State(initialValue: control)
        self.pages = pages
        self.availableControls = availableControls
        self.initialSizeOrientation = orientation
        _selectedPageID = State(initialValue: pageID)
        _rememberedPayload = State(initialValue: control.payload)
        _rememberedStickPlusRepeatInterval = State(initialValue: control.stickPlusRepeatIntervalMilliseconds ?? 200)
        self.canDuplicate = canDuplicate
        _presetLibrary = State(initialValue: settingsPresets)
        self.onSavePresets = onSavePresets
        self.onSave = onSave
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                editorSections
            }
            .navigationTitle("Edit control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit(copy: false) }
                        .disabled(validationMessage != nil)
                }
            }
            .sheet(item: $presentedSheet, onDismiss: presentPendingCalibration) { sheetContent($0) }
            .confirmationDialog("Delete this control?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete control", role: .destructive) {
                    onDelete(draft.id)
                    dismiss()
                }
                Button("Keep control", role: .cancel) { }
            } message: {
                Text("This removes it from the layout draft. Save layout keeps the removal; Cancel on the controller screen restores the previous layout.")
            }
        }
    }

    @ViewBuilder private var editorSections: some View {
        appearanceSettings
        if pages.count > 1 {
            Section {
                DisclosureGroup(isExpanded: $pagePlacementExpanded) {
                    ForEach(pages) { page in
                        selectionRow(page.name, selected: selectedPageID == page.id) { selectedPageID = page.id }
                    }
                } label: {
                    Text("Place on page: \(pages.first { $0.id == selectedPageID }?.name ?? "Choose page")")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        switch draft.kind {
        case .button:
            FloatingActionSettingsView(control: $draft,
                page: pages.first { $0.id == selectedPageID }, controls: availableControls)
            if !draft.isFloatingAction {
                buttonSettings
                if (!draft.isCameraFollowAction && !draft.isAutoCenterAction) || draft.isAdvancedButton { AdvancedButtonSettingsView(control: $draft) }
            }
        case .leftStick, .rightStick:
            stickSettings
        case .touchpad:
            touchpadSettings
        case .touchAim:
            TouchAimSettingsView(settings: $draft.touchAim, onInspect: { presentedSheet = .inspector },
                                 onCalibrate: { showCalibration(nil) },
                                 onValidateExisting: { showCalibration(draft.touchAim.calibration) })
        case .pageButton:
            pageNavigationSettings
        case .recenter:
            Section {
                Text("Tapping this control centers the sticks and releases their directional actions. Buttons held separately stay held. Release all clears every held control.")
            } header: { Text("Re-center action") }
        }

        if draft.kind != .recenter && draft.kind != .pageButton && !draft.isFloatingAction {
            CameraFollowSettingsView(control: $draft, onActionChanged: {
                rememberedPayload = draft.payload; saveError = nil
            })
        }

        if !draft.isFloatingAction && (draft.kind == .button || draft.kind.isStick || draft.isTouchAim) {
            Section {
                Button("Apply reusable settings") { presentedSheet = .applyPreset }
                Button("Save these settings as a preset") { presentedSheet = .savePreset }
                    .disabled(validationMessage != nil)
                Text("Applying changes this control's draft. Saving a preset updates the reusable library separately and does not save the layout draft.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Reusable settings") }
        }

        if let message = validationMessage ?? saveError {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("Check these settings") }
        }

        Section {
            Text("Done updates this control in your layout draft. Then use Save layout on the controller screen to keep the changes, or Cancel there to restore the previous layout.")
            Text("Cancel here discards only the changes in this sheet. Name, output and behavior apply to both orientations. Positions differ; sizes can be shared or set separately for portrait and landscape.")
            if draft.kind == .button || draft.kind.isStick {
                Text("LT and RT pressure and Pulse work in Practice and with the Windows PC receiver. For consoles, USB buttons send full presses; adjustable output needs the selected Cronus Zen route or analog trigger circuit and matching Pico firmware. Xbox logo and Share remain Practice only.")
                Text("Practice previews keyboard and mouse actions on this phone. Windows PC mode sends them to the free receiver. The console bridge does not send keyboard or mouse input.")
            }
        } header: { Text("Keeping your changes") }

        Section {
            Button("Copy this control") { commit(copy: true) }
                .disabled(validationMessage != nil || !canDuplicate)
                .accessibilityHint("Adds a separate control using these settings to your layout draft.")
            Button("Delete this control", role: .destructive) {
                confirmingDelete = true
            }
        } footer: {
            Text("Copy uses the settings shown here. Copy and Delete change the layout draft; Save layout keeps that draft, while Cancel restores the previous layout.")
            if !canDuplicate { Text("This profile has \(ControllerProfile.maximumControls) controls. Delete a control before adding another copy.") }
        }
    }

    @ViewBuilder private func sheetContent(_ sheet: EditorSheet) -> some View {
        switch sheet {
        case .inspector:
            TouchAimInspectorView()
        case .calibration:
            TouchAimCalibrationView(existingCalibration: calibrationToValidate,
                savedPresetName: calibrationPresetID.flatMap { presetLibrary.entry($0)?.name },
                onSaveValidatedPreset: presetValidationSaver,
                onApply: { calibration in
                    // Other draft fields may still be invalid; preserve the completed fit
                    // while normal Done validation continues to guard the whole control.
                    draft.touchAim.calibration = calibration; draft.touchAim.mode = .calibratedTwoState
                    draft.touchAim.requiresLocalSetup = false; saveError = nil
                })
        case .applyPreset:
            ControlPresetPickerView(control: draft, library: presetLibrary, onApply: { next in
                draft = next; rememberedPayload = next.payload; rememberedStagePayloads = [:]
                saveError = nil; return true
            }, onValidateCalibration: { preset in
                pendingCalibrationPreset = preset; presentedSheet = nil
            })
        case .savePreset:
            SaveControlPresetView(control: draft, library: presetLibrary, onSave: savePresetLibrary)
        }
    }

    private func savePresetLibrary(_ next: SettingsPresetLibrary) -> Bool {
        guard onSavePresets(next) else { return false }
        presetLibrary = next; return true
    }
    private func showCalibration(_ existing: TouchAimCalibrationProfile?) {
        calibrationToValidate = existing; calibrationPresetID = nil; presentedSheet = .calibration
    }
    private func presentPendingCalibration() {
        guard let pending = pendingCalibrationPreset,
              case let .touchCalibration(calibration) = pending.value else { return }
        pendingCalibrationPreset = nil
        calibrationToValidate = calibration; calibrationPresetID = pending.id; presentedSheet = .calibration
    }
    private var presetValidationSaver: ((TouchAimCalibrationProfile) -> Bool)? {
        guard calibrationPresetID != nil else { return nil }
        return { updateValidatedPreset($0) }
    }
    private func updateValidatedPreset(_ calibration: TouchAimCalibrationProfile) -> Bool {
        guard let id = calibrationPresetID, let existing = presetLibrary.entry(id) else { return false }
        do {
            var next = presetLibrary
            try next.replaceValue(id, with: .captureCalibration(calibration),
                                  at: max(existing.updatedAtMilliseconds, Int64(Date().timeIntervalSince1970 * 1000)))
            return savePresetLibrary(next)
        } catch { saveError = error.localizedDescription; return false }
    }

    private func selectionRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var navigationStyle: Int {
        switch draft.pageNavigation ?? .home {
        case .goTo: return 0
        case .toggle: return 1
        case .back: return 2
        case .home: return 3
        }
    }
    private var navigationTarget: UUID? {
        switch draft.pageNavigation {
        case .goTo(let id), .toggle(let id): return id
        default: return pages.first?.id
        }
    }
    private var pageNavigationSettings: some View {
        Group {
            Section("Page action") {
                selectionRow("Go to a page", selected: navigationStyle == 0) {
                    if let id = navigationTarget { draft.pageNavigation = .goTo(id) }
                }
                selectionRow("Toggle with previous page", selected: navigationStyle == 1) {
                    if let id = navigationTarget { draft.pageNavigation = .toggle(id) }
                }
                selectionRow("Return to previous page", selected: navigationStyle == 2) { draft.pageNavigation = .back }
                selectionRow("Go Home", selected: navigationStyle == 3) { draft.pageNavigation = .home }
            }
            if navigationStyle < 2 {
                Section("Destination page") {
                    ForEach(pages) { page in
                        selectionRow(page.name, selected: navigationTarget == page.id) {
                            draft.pageNavigation = navigationStyle == 0 ? .goTo(page.id) : .toggle(page.id)
                        }
                    }
                }
            }
            Section {
                Text("Touch this button directly to change pages. Sliding onto it never changes the page. Every page change releases held buttons, sticks and touchpad locks.")
                Text("Toggle opens the chosen page, or returns to the previous page if you are already there. Return also goes to the previous page. Both use Home when there is no previous page. The app opens on Home.")
            } header: { Text("How page buttons work") }
        }
    }

    private var appearanceSettings: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                TextField("Control name", text: $draft.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Control name")
                Text("1 to 64 characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ControlOrientationSizeSettings(control: $draft, initialOrientation: initialSizeOrientation)
            if !draft.orientationDimensions.isEmpty {
                Text("The sizes above affect only their chosen orientation. Your shared size is kept in case you turn separate sizes off.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if draft.kind == .touchpad {
                dimensionRow("Width", value: $draft.touchpadWidth)
                dimensionRow("Height", value: $draft.touchpadHeight)
                Text("Each dimension can be 44 to 1,200 points. A pad larger than the available screen fits within the canvas; its saved size is kept for both orientations.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if draft.isTouchAim {
                controlDimensionRow("Width", value: controlDimension(\.controlWidth))
                controlDimensionRow("Height", value: controlDimension(\.controlHeight))
            } else {
                Toggle("Independent width and height", isOn: independentDimensions)
                if draft.controlWidth != nil || draft.controlHeight != nil {
                    controlDimensionRow("Width", value: controlDimension(\.controlWidth))
                    controlDimensionRow("Height", value: controlDimension(\.controlHeight))
                    Text(isStick ? "The stick becomes an oval. Each axis uses half its own dimension as the full travel distance." : "This control uses a rounded rectangle. Saved dimensions are fitted to the available canvas.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Size: \(Int(sizeValue.wrappedValue.rounded())) points")
                    Slider(value: sizeValue, in: sizeRange, step: 1)
                        .accessibilityLabel("Control size")
                        .accessibilityValue("\(Int(sizeValue.wrappedValue.rounded())) points")
                    Text("\(Int(sizeRange.lowerBound)) to \(Int(sizeRange.upperBound)) points, in both orientations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                }
            }
        } header: { Text("Appearance") }
    }

    private var independentDimensions: Binding<Bool> {
        Binding(get: { draft.controlWidth != nil || draft.controlHeight != nil }, set: { enabled in
            draft.controlWidth = enabled ? draft.resolvedWidth : nil
            draft.controlHeight = enabled ? draft.resolvedHeight : nil
        })
    }
    private func controlDimension(_ key: WritableKeyPath<ProfileControl, Double?>) -> Binding<Double> {
        Binding(get: { key == \.controlWidth ? draft.resolvedWidth : draft.resolvedHeight }, set: { draft[keyPath: key] = $0 })
    }
    private func controlDimensionRow(_ title: String, value: Binding<Double>) -> some View {
        let range = (isStick ? 104.0 : 44.0)...1200.0
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(title): \(Int(value.wrappedValue.rounded())) points")
            Slider(value: value, in: range, step: 1).accessibilityLabel("Control \(title.lowercased())")
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
            Stepper("Change \(title.lowercased())", value: value, in: range, step: 1)
                .accessibilityLabel("Control \(title.lowercased())").accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
        }
    }

    private func dimensionRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title): \(Int(value.wrappedValue.rounded())) points")
            Slider(value: value, in: 44...1_200, step: 1)
                .accessibilityLabel("Touchpad \(title.lowercased())")
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
            Stepper("Change \(title.lowercased())", value: value, in: 44...1_200, step: 1)
                .accessibilityLabel("Touchpad \(title.lowercased())")
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
        }
        .padding(.vertical, 4)
    }

    private var touchpadSettings: some View {
        Group {
            Section {
                Text("Sensitivity: \(draft.touchpadBehavior.sensitivity.formatted(.number.precision(.fractionLength(2))))")
                Slider(value: $draft.touchpadBehavior.sensitivity, in: 0...5, step: 0.01)
                    .accessibilityLabel("Touchpad sensitivity")
                    .accessibilityValue(draft.touchpadBehavior.sensitivity.formatted(.number.precision(.fractionLength(2))))
                Stepper("Change sensitivity", value: $draft.touchpadBehavior.sensitivity, in: 0...5, step: 0.01)
                    .accessibilityLabel("Touchpad sensitivity")
                    .accessibilityValue(draft.touchpadBehavior.sensitivity.formatted(.number.precision(.fractionLength(2))))
                Text("1 is the default. Higher values move farther. Zero stops movement and scrolling while keeping clicks available.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Movement") }
            Section {
                ForEach(TouchpadClickMode.allCases, id: \.self) { mode in
                    Button {
                        draft.touchpadBehavior.clickMode = mode
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: draft.touchpadBehavior.clickMode == mode ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(draft.touchpadBehavior.clickMode == mode ? Color.accentColor : Color.secondary)
                            Text(touchpadModeTitle(mode))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(touchpadModeTitle(mode))
                    .accessibilityValue(draft.touchpadBehavior.clickMode == mode ? "Selected" : "Not selected")
                    .accessibilityHint("Selects the left-click behavior for this touchpad.")
                }
                Text(touchpadModeDescription)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A locked left button stays held after you lift your finger. Release all clears every lock and pending click. Re-center only stops sticks.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Click behavior") }
            Section {
                Text("Add a regular button with the payload SCROLL_MODE_TOGGLE. Tap it to switch all touchpads between pointer movement and vertical scrolling. Release all returns to pointer mode.")
                Text("For a right click, add a button with MOUSE_RIGHT_DOWN,MOUSE_RIGHT_UP. Use MOUSE_MIDDLE_DOWN,MOUSE_MIDDLE_UP for a middle click.")
                Text("Practice previews touchpad movement, clicks and scrolling without moving another device. Windows PC mode sends them to the receiver to control the PC. The console bridge does not send touchpad input.")
            } header: { Text("Scrolling and other clicks") }
        }
    }

    private func touchpadModeTitle(_ mode: TouchpadClickMode) -> String {
        switch mode {
        case .none: "Move only"
        case .hold: "Hold while touching"
        case .toggle: "Tap to lock / unlock"
        case .doubleTapLock: "Tap click / double-tap lock"
        }
    }

    private var touchpadModeDescription: String {
        switch draft.touchpadBehavior.clickMode {
        case .none:
            return "Move with one finger. Touching or tapping this pad does not click."
        case .hold:
            return "The left mouse button stays down while you touch this pad. Lift your finger to release it."
        case .toggle:
            return "Touch once to start a left-button lock after 0.75 seconds; you can lift before it starts. Touch again to cancel the pending lock or unlock it."
        case .doubleTapLock:
            return "A brief tap clicks. For a lock, tap once, touch again within 0.12 seconds and hold for 0.38 seconds with little movement. A brief tap on a locked pad unlocks it. Moving more than 20 points or lifting early cancels a pending lock."
        }
    }

    private var buttonSettings: some View {
        Group {
            Section {
                Toggle(isOn: $draft.swipeActivationEnabled) {
                    Text("Allow activation by sliding")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(draft.isAdvancedButton || draft.isCameraFollowAction || draft.isAutoCenterAction)
                .accessibilityHint(draft.isAutoCenterAction
                    ? "Auto-center requires a direct tap. This saved sliding choice does not apply while this is an auto-center action."
                    : "When off, sliding onto this button does not activate it. Direct touches and sliding away still work.")
            } header: { Text("Sliding onto this button") }
            footer: {
                Text(draft.isAutoCenterAction
                     ? "Auto-center always requires a direct tap. The sliding choice is kept for use if you choose a different action."
                     : "Turn this off to prevent slide entry. You can still touch the button directly and slide away from it. The profile's swipe choice controls whether sliding is enabled.")
                if draft.isAdvancedButton {
                    Text("Directional buttons and Button Aim always keep their starting touch and reject sliding entry. This setting is kept for use if you turn those modes off.")
                }
                if draft.isCameraFollowAction {
                    Text("Camera Follow requires a direct tap. Preview it in Practice or use it with the Windows PC receiver; it is unavailable through the console bridge.")
                }
                if draft.isScrollModeToggle {
                    Text("Scroll mode toggle always requires a direct tap, regardless of this setting.")
                }
            }
            Section {
                Toggle("Custom payload", isOn: customPayloadEnabled)
                    .accessibilityHint("Use controller, keyboard or mouse commands instead of the checkbox actions. Keyboard and mouse preview in Practice and work with the Windows PC receiver; the console bridge does not send them.")
                if draft.payload != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Payload")
                        TextField("X360A,WAIT_1000,X360B", text: payloadText, axis: .vertical)
                            .lineLimit(3...8)
                            .font(.body.monospaced())
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Button payload")
                            .accessibilityHint("Separate actions and WAIT commands with commas. Keyboard and mouse preview in Practice and work with the Windows PC receiver; the console bridge does not send them. Trigger Pulse uses P followed by seconds.")
                        if let error = payloadValidationMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    payloadExamples
                } else {
                    actionDisclosure("Button actions", selection: $draft.actions,
                                     expanded: $buttonActionsExpanded)
                }
            } header: { Text("What this button does") }
            footer: {
                if draft.payload != nil {
                    Text("The custom payload replaces this button's checkbox actions. Turning it off returns to those saved choices.")
                    Text("Keyboard and mouse preview in Practice and work with the Windows PC receiver; the console bridge does not send them. UP is the keyboard Up arrow; X360UP is controller D-pad Up.")
                } else {
                    Text("Select one or more controller actions to hold together. No selection means this button sends no action. Each copy has its own settings.")
                }
            }
            Section {
                DisclosureGroup("Auto-center while playing") {
                    Button("Use auto-center toggle") { useAutoCenterAction("AUTO_CENTER_TOGGLE") }
                    Button("Use auto-center on") { useAutoCenterAction("AUTO_CENTER_ON") }
                    Button("Use auto-center off") { useAutoCenterAction("AUTO_CENTER_OFF") }
                    Text("A direct tap changes auto-center for this profile’s sticks and stick-output Button Aim pads on every page. It does not change your saved settings. Turning it on centers movement left behind after lifting; a finger still down keeps control until lift.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("The button shows ON, OFF or MIXED. A toggle changes mixed settings to ON first. Leaving Edit, switching profiles or restarting the app returns to the saved settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if draft.payload != nil {
                Section {
                    Button("Use scroll toggle") {
                        draft.payload = "SCROLL_MODE_TOGGLE"
                        rememberedPayload = draft.payload
                        draft.buttonBehavior.holdToggle = false
                        draft.autoTapEnabled = false
                        draft.macroModeEnabled = false
                        draft.doubleTapRepeatEnabled = false; draft.centerLeftStickBeforePress = false
                        saveError = nil
                    }
                    Text("Replaces this payload and turns off Macro Mode, Hold to toggle and Auto-Tap. A tap switches all touchpads between pointer movement and scrolling. This action ignores global Turbo.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Use Release all") {
                        draft.payload = "RELEASE_ALL"; rememberedPayload = draft.payload
                        draft.buttonBehavior.holdToggle = false; draft.autoTapEnabled = false
                        draft.macroModeEnabled = false
                        draft.doubleTapRepeatEnabled = false; draft.centerLeftStickBeforePress = false
                        draft.buttonAim.enabled = false; draft.buttonDirectional.enabled = false
                        saveError = nil
                    }
                    Text("Makes this a movable Release all button. Directly tapping it clears every held action, timer and floating session. The bridge prepares a fresh neutral connection automatically; touch a control again when it is ready.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                payloadTimingHelp
            }
            Section {
                Toggle("Macro Mode", isOn: macroModeEnabled)
                    .disabled(draft.isLocalAction || draft.isScrollModeToggle)
                    .accessibilityHint("One tap completes the sequence after you lift. Each action defaults to a 200 millisecond press.")
                Toggle("Hold to toggle", isOn: holdToggleEnabled)
                    .disabled(draft.isAutoCenterAction || draft.isReleaseAllAction || (draft.isCameraFollowAction && !draft.buttonBehavior.holdToggle) || (draft.buttonDirectional.enabled && !draft.buttonAim.enabled && !draft.buttonBehavior.holdToggle))
                    .accessibilityHint("Hold for the chosen time to latch all selected actions. Tap again to turn them off.")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hold duration: \(draft.buttonBehavior.holdMilliseconds) ms")
                    Stepper("Change hold duration", value: $draft.buttonBehavior.holdMilliseconds,
                            in: 50...5_000, step: 50)
                        .accessibilityLabel("Hold duration")
                        .accessibilityValue("\(draft.buttonBehavior.holdMilliseconds) milliseconds")
                }
                .disabled(!draft.buttonBehavior.holdToggle)
                Toggle("Double-tap to repeat", isOn: doubleTapRepeatEnabled)
                    .disabled(draft.isLocalAction)
                    .accessibilityHint("Tap twice quickly to keep repeating. Tap once to stop. A single tap presses normally, and Hold to toggle can still latch a steady press.")
                Toggle("Toggle Auto-Tap", isOn: autoTapEnabled)
                    .disabled(draft.isAutoCenterAction || draft.isReleaseAllAction || (draft.isCameraFollowAction && !draft.autoTapEnabled) || (draft.isAdvancedButton && !draft.autoTapEnabled))
                    .accessibilityHint("Tap once to start repeating this button, then tap again to stop. Turning this on turns Hold to toggle off.")
                if draft.autoTapEnabled || draft.doubleTapRepeatEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tap interval: \(draft.autoTapIntervalMilliseconds) ms")
                        Slider(value: Binding(get: { Double(draft.autoTapIntervalMilliseconds) }, set: {
                            draft.autoTapIntervalMilliseconds = Int($0.rounded())
                        }), in: 16...1_000, step: 1)
                            .accessibilityLabel("Auto-Tap interval")
                            .accessibilityValue("\(draft.autoTapIntervalMilliseconds) milliseconds")
                        Stepper("Change tap interval", value: $draft.autoTapIntervalMilliseconds,
                                in: 16...1_000, step: 1)
                            .accessibilityLabel("Auto-Tap interval")
                            .accessibilityValue("\(draft.autoTapIntervalMilliseconds) milliseconds")
                        Text("16 to 1,000 ms between the start of each tap")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Center left stick before pressing", isOn: $draft.centerLeftStickBeforePress)
                    .disabled(draft.isLocalAction || draft.isAdvancedButton)
                if draft.centerLeftStickBeforePress {
                    Text("Stops left-stick movement before this button starts. Right-stick aiming and other held buttons stay active.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Button behavior") }
            footer: {
                if draft.macroModeEnabled {
                    Text("Tap once to complete the sequence after lifting. Each action presses for 200 ms unless its payload sets a U duration or trigger Pulse. Extra taps during a run are ignored. Release all stops the sequence.")
                    Text("Macro Mode uses one run per tap and ignores global Hold and Turbo. Turning it on selects this behavior for the button.")
                } else if draft.doubleTapRepeatEnabled {
                    Text("A single tap presses normally. Two quick taps start repeating; each tap must be under 250 ms and the second must start within 300 ms. Tap once to stop. With Hold to toggle enabled, holding for the selected duration latches a steady press instead. Release all also stops both modes.")
                    Text("At 100 ms, repeat sends 10 presses per second with 50 ms pressed and 50 ms released. This button ignores global Hold and Turbo. Use ordinary presses without payload timing modifiers.")
                } else if draft.autoTapEnabled {
                    Text("Tap once to repeat, then tap again to stop. Each press lasts half the interval, up to 50 ms. Release all also stops it. Auto-Tap cannot use WAIT or Pulse.")
                } else if draft.buttonAim.enabled {
                    Text("Button Aim uses its own action timing below. With When touched, even a short touch sends the action; Hold to toggle latches it after the chosen duration. With When released, the threshold arms a latch that starts on intentional lift.")
                } else if draft.buttonDirectional.enabled {
                    Text("Directional-only buttons require Hold to toggle and Auto-Tap to be off. They manage their own held actions and ignore global Turbo.")
                } else if draft.buttonBehavior.holdToggle {
                    Text("Hold for \(draft.buttonBehavior.holdMilliseconds) ms to turn on. A shorter touch sends nothing. Once held on, tap this control again to turn it off.")
                } else {
                    Text("Ordinary actions stay on while you touch this control and release when you lift your finger. A started Pulse finishes at its own deadline.")
                }
            }
        }
    }

    private func useAutoCenterAction(_ payload: String) {
        draft.payload = payload
        rememberedPayload = payload
        draft.macroModeEnabled = false
        draft.buttonBehavior.holdToggle = false
        draft.autoTapEnabled = false
        draft.doubleTapRepeatEnabled = false
        draft.centerLeftStickBeforePress = false
        draft.buttonAim.enabled = false
        draft.buttonAim.alternate.enabled = false
        draft.buttonDirectional.enabled = false
        saveError = nil
    }

    private var payloadExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Examples").font(.subheadline.weight(.semibold))
            Text("X360A,WAIT_1000,X360B").font(.footnote.monospaced()).textSelection(.enabled)
            Text("In ordinary mode, A starts immediately and B is added after 1 second if the control is still held. Macro Mode uses D delays for its sequence.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("RT:1.0P0.3").font(.footnote.monospaced()).textSelection(.enabled)
            Text("A full right-trigger Pulse lasting 0.3 seconds in ordinary mode.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("RT:0.5").font(.footnote.monospaced()).textSelection(.enabled)
            Text("Hold the right trigger at half pressure.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("LS:UP50,RS:RIGHT100").font(.footnote.monospaced()).textSelection(.enabled)
            Text("An ordinary button holds the left stick halfway forward and the right stick fully right. Use LS or RS, a direction (UP, DOWN, LEFT, RIGHT, UR, UL, BR or BL), and 0–100 percent. The first live touch keeps its stick channel; another held command cannot take it over.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("SHIFT,W").font(.footnote.monospaced()).textSelection(.enabled)
            Text("Preview Shift and W together in Practice, or send them with the Windows PC receiver.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("X360A(U100),X360A(D500)(U100),X360B(D800)(U100)")
                .font(.footnote.monospaced()).textSelection(.enabled)
            Text("With Macro Mode on, one tap presses A for 100 ms, A again at 500 ms, then B at 800 ms. Each press releases automatically.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("MOUSE_RIGHT_DOWN,MOUSE_RIGHT_UP").font(.footnote.monospaced()).textSelection(.enabled)
            Text("Press and release the right mouse button in order. The Practice event list shows this click even though the final button state is released. A mouse button held by another control stays held.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("MOUSE_RIGHT_DOWN").font(.footnote.monospaced()).textSelection(.enabled)
            Text("Hold the right mouse button while touching this control; lifting releases its hold.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    private var payloadTimingHelp: some View {
        Section {
            DisclosureGroup("Time individual actions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("(I) starts on activation. (SOR) taps once on normal release.")
                    Text("(D100) waits 100 milliseconds before starting. (R200) repeats every 200 milliseconds. (HRD200) holds for another 200 milliseconds after release.")
                    Text("(U100) releases an action 100 milliseconds after it starts. In ordinary mode, lifting early can still release it. Macro Mode completes each press after you lift.")
                    Text("Each D delay counts from activation, or from lift for SOR. Commands with the same D start together. Commas separate actions without adding waiting time.")
                    Text("Macro Mode defaults to a 200 ms press and requires a sequence that ends. Use U or trigger Pulse to choose a press length. R repetition requires ordinary mode. For separate taps of the same action, leave a gap between their presses.")
                    Text("LT:0.5,RT:0.7(D100)(R200)").font(.body.monospaced()).textSelection(.enabled)
                    Text("This example holds Aim, then starts repeated fire after a tenth of a second. Release all cancels the timers.")
                }
            }
            Text("WAIT is available in ordinary mode and is measured in milliseconds. Lifting cancels its later actions unless Hold to toggle is latched. Use D delays for a Macro Mode sequence.")
            Text("A single Pulse finishes after a normal finger lift. Release all and interruptions cancel it immediately.")
            Text("With Hold to toggle, Pulse time is the whole repeating cycle: P0.3 means 0.15 seconds pressed, then 0.15 seconds released. Tap the latched button again to stop.")
            Text("Auto-Tap cannot use WAIT or Pulse. Global Turbo skips buttons containing either command. SCROLL_MODE_TOGGLE must be the only command, requires Macro Mode, Hold to toggle and Auto-Tap to be off, and ignores global Turbo.")
        } header: { Text("Timing") }
    }

    private var customPayloadEnabled: Binding<Bool> {
        Binding(get: { draft.payload != nil }, set: { enabled in
            if enabled {
                let source = ControllerPayloadProgram.source(for: draft.actions)
                draft.payload = rememberedPayload ?? (source.isEmpty ? "X360A" : source)
            } else {
                rememberedPayload = draft.payload
                draft.payload = nil
            }
            saveError = nil
        })
    }

    private var payloadText: Binding<String> {
        Binding(get: { draft.payload ?? "" }, set: {
            rememberedPayload = $0
            draft.payload = $0
            saveError = nil
        })
    }

    private var macroModeEnabled: Binding<Bool> {
        Binding(get: { draft.macroModeEnabled }, set: { enabled in
            draft.macroModeEnabled = enabled
            if enabled {
                draft.buttonBehavior.holdToggle = false
                draft.autoTapEnabled = false
                draft.doubleTapRepeatEnabled = false
                draft.buttonAim.enabled = false
                draft.buttonDirectional.enabled = false
            }
            saveError = nil
        })
    }

    private var holdToggleEnabled: Binding<Bool> {
        Binding(get: { draft.buttonBehavior.holdToggle }, set: {
            draft.buttonBehavior.holdToggle = $0
            if $0 {
                draft.autoTapEnabled = false
                draft.macroModeEnabled = false
            }
            saveError = nil
        })
    }

    private var autoTapEnabled: Binding<Bool> {
        Binding(get: { draft.autoTapEnabled }, set: {
            draft.autoTapEnabled = $0
            if $0 {
                draft.buttonBehavior.holdToggle = false
                draft.macroModeEnabled = false
                draft.doubleTapRepeatEnabled = false
            }
            saveError = nil
        })
    }

    private var doubleTapRepeatEnabled: Binding<Bool> {
        Binding(get: { draft.doubleTapRepeatEnabled }, set: { enabled in
            draft.doubleTapRepeatEnabled = enabled
            if enabled {
                draft.autoTapEnabled = false
                draft.macroModeEnabled = false
                draft.buttonAim.enabled = false
                draft.buttonDirectional.enabled = false
            }
            saveError = nil
        })
    }

    private var payloadValidationMessage: String? {
        guard draft.kind == .button, draft.payload != nil else { return nil }
        do {
            let program = try draft.payloadProgram()
            if draft.macroModeEnabled { try program.validateMacroMode() }
            if draft.autoTapEnabled && program.containsWaitOrPulse {
                return "Auto-Tap cannot use WAIT or Pulse. Turn Auto-Tap off or remove those commands."
            }
            if program.steps.contains(where: { if case .scrollModeToggle = $0 { true } else { false } }) && (draft.autoTapEnabled || draft.buttonBehavior.holdToggle) {
                return "Scroll toggle cannot use Hold to toggle or Auto-Tap. Turn both off."
            }
            return nil
        } catch { return error.localizedDescription }
    }

    private var stickSettings: some View {
        Group {
            Section {
                Picker("Input mode", selection: stickMode) {
                    Text("Analog stick").tag(StickMode.analog)
                    Text("Stick+").tag(StickMode.stickPlus)
                    Text("Directional / WASD").tag(StickMode.directional)
                }
                .pickerStyle(.menu)
                if !draft.isDirectional {
                    Picker("Analog output", selection: $draft.kind) {
                        Text("Left stick").tag(ProfileControlKind.leftStick)
                        Text("Right stick").tag(ProfileControlKind.rightStick)
                    }
                    .pickerStyle(.menu)
                }
                Text(stickModeDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Auto-center", isOn: $draft.stickBehavior.autoCenter)
            } header: { Text("Stick behavior") }
            footer: {
                Text(draft.stickBehavior.autoCenter
                     ? "The stick returns to center and its directional actions release when you lift your finger."
                     : "The stick keeps its position and directional actions after a normal finger lift. Move it to center, tap Re-center, or tap Release all to clear it. Interruptions still clear held input.")
            }
            stickResponseSettings
            if usesDirectionalActions {
                if !draft.isDirectional {
                    stickPlusRepeatSettings
                    Section {
                        Toggle("Deliberate edge reactivation", isOn: Binding(get: {
                            draft.stickPlusEdgeRearmHysteresis != nil
                        }, set: { enabled in
                            draft.stickPlusEdgeRearmHysteresis = enabled ? 0.04 : nil
                            saveError = nil
                        }))
                        Text("Move inward before an edge tap can fire again. This avoids extra taps when your finger wavers at a stage boundary. Auto-center toggles always require this inward movement.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("Edge actions") }
                }
                Section {
                    thresholdRow("Boost above", value: boostThreshold)
                    thresholdRow("Super boost above", value: superThreshold)
                    if draft.extendedBoost.enabled && draft.extendedBoost.mode == .replaceThresholds {
                        Text("Extended Boost overrides these two shared distances with the per-direction distances below.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Each stage replaces the previous one. Include an action in both stages to keep it active across that change. Diagonal movement can activate two directions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { Text("Directional stages") }
                footer: {
                    Text("Directional actions begin only beyond 10% from center along that direction. Boost and Super apply only above their thresholds, with Super beyond Boost.")
                }
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
                    stageEditor(.normal, expanded: $normalExpanded)
                    stageEditor(.boost, expanded: $boostExpanded)
                    stageEditor(.superBoost, expanded: $superExpanded)
                } header: { Text("Actions for \(directionTitle(direction).lowercased())") }
                footer: {
                    Text("An empty stage holds no actions. Custom payloads replace that stage's checkbox actions; turning Custom off restores the saved choices. These actions do not use the settings of other on-screen buttons.")
                    Text("Stages accept controller actions, trigger pressure, keyboard keys and mouse DOWN commands. Add (U100) to tap an action for 100 ms. A stage may also use an auto-center command by itself. WAIT, ordinary Pulse and mouse UP are unavailable. Keyboard and mouse preview in Practice and work with the Windows PC receiver; the console bridge does not send them.")
                }
                extendedBoostSettings
                Section {
                    Button("Apply WASD preset") { applyWASDPreset() }
                    Text("Selects Directional mode and replaces all 12 stage payloads. Normal: Up W, Down S, Left A, Right D. Boost: add Shift, or Ctrl for Down. Super: also add Space. Sets thresholds to 50% and 75%. The previous checkbox selections stay saved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Apply forward example") { applyForwardExample() }
                    Text("Selects Stick+. Up: no extra action through 50%; left stick click above 50% through 95%; above 95%, release left stick click and activate A. Replaces only the Up actions, clears its custom payloads and sets both thresholds. Other directions are kept. This is an example, not a game preset.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { Text("Optional presets") }
            }
        }
    }

    private var stickPlusRepeatSettings: some View {
        Section {
            Toggle("Repeat Stick+ buttons", isOn: stickPlusRepeatEnabled)
                .accessibilityHint("Repeats the configured Stick+ controller buttons without turning on global Turbo.")
            if draft.stickPlusRepeatIntervalMilliseconds != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Repeat interval: \(stickPlusRepeatInterval.wrappedValue) ms")
                    Slider(value: Binding(get: { Double(stickPlusRepeatInterval.wrappedValue) }, set: {
                        stickPlusRepeatInterval.wrappedValue = Int($0.rounded())
                    }), in: 16...1_000, step: 1)
                        .accessibilityLabel("Stick+ repeat interval")
                        .accessibilityValue("\(stickPlusRepeatInterval.wrappedValue) milliseconds")
                    Stepper("Change repeat interval", value: stickPlusRepeatInterval,
                            in: 16...1_000, step: 1)
                        .accessibilityLabel("Stick+ repeat interval")
                        .accessibilityValue("\(stickPlusRepeatInterval.wrappedValue) milliseconds")
                    Text("16 to 1,000 ms between the start of each press")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("The first press starts immediately. Each press lasts half the interval, up to 50 ms. Only this stick's configured digital controller actions repeat; analog movement and other stage outputs keep their usual behavior.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(draft.stickBehavior.autoCenter
                     ? "Repeating ends when this stick centers on lift. Move to a stage without the action, tap Re-center, or tap Release all to stop it sooner."
                     : "With Auto-center off, repetition continues at the retained position after you lift. Move to a stage without the action, tap Re-center, or tap Release all to stop it. Interruptions also clear it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Stick+ repeat") }
        footer: {
            Text("Use this for actions that need repeated presses, such as a configured A action. It does not turn on global Turbo. Changing input mode keeps this choice, but it runs only in Stick+ mode.")
        }
    }

    private var stickPlusRepeatEnabled: Binding<Bool> {
        Binding(get: { draft.stickPlusRepeatIntervalMilliseconds != nil }, set: { enabled in
            if enabled {
                draft.stickPlusRepeatIntervalMilliseconds = rememberedStickPlusRepeatInterval
            } else {
                rememberedStickPlusRepeatInterval = draft.stickPlusRepeatIntervalMilliseconds ?? rememberedStickPlusRepeatInterval
                draft.stickPlusRepeatIntervalMilliseconds = nil
            }
            saveError = nil
        })
    }

    private var stickPlusRepeatInterval: Binding<Int> {
        Binding(get: { draft.stickPlusRepeatIntervalMilliseconds ?? rememberedStickPlusRepeatInterval }, set: { value in
            rememberedStickPlusRepeatInterval = value
            draft.stickPlusRepeatIntervalMilliseconds = value
            saveError = nil
        })
    }

    private var stickResponseSettings: some View {
        Section {
            DisclosureGroup("Sensitivity and response") {
                Picker("Response", selection: $draft.stickResponse.mode) {
                    Text("Linear").tag(StickResponseMode.linear)
                    Text("Curved per axis").tag(StickResponseMode.perAxis)
                    Text("Curved radial").tag(StickResponseMode.radial)
                }.pickerStyle(.menu)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sensitivity: \(draft.stickResponse.sensitivity.formatted(.number.precision(.fractionLength(2))))")
                    Slider(value: $draft.stickResponse.sensitivity, in: 0...5, step: 0.05)
                        .accessibilityLabel("Stick sensitivity")
                        .accessibilityValue(draft.stickResponse.sensitivity.formatted(.number.precision(.fractionLength(2))))
                }
                Text("1 is the default. Linear multiplies movement; curves change how quickly it grows. Radial keeps diagonal direction and limits its combined strength. Zero stops analog output.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("In Linear mode, sensitivity also affects ordinary directional stage distances. Curved modes use physical distance for stages. Extended Boost always uses physical finger distance.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Stick response") }
    }

    private var extendedBoostSettings: some View {
        Section {
            Toggle("Extended Boost", isOn: $draft.extendedBoost.enabled)
            if draft.extendedBoost.enabled {
                Picker("Extended mode", selection: $draft.extendedBoost.mode) {
                    Text("Replace stage distances").tag(ExtendedBoostMode.replaceThresholds)
                    Text("Add outer stage").tag(ExtendedBoostMode.addOuterStage)
                }.pickerStyle(.menu)
                Picker("Extended direction", selection: $direction) {
                    ForEach(StickDirection.allCases, id: \.self) { direction in
                        Text(directionTitle(direction)).tag(direction)
                    }
                }.pickerStyle(.menu)
                if draft.extendedBoost.mode == .replaceThresholds {
                    extendedDistanceRow("Boost above", value: extendedDistance(\.regularThreshold), range: 0.1...4.99)
                    extendedDistanceRow("Super boost above", value: extendedDistance(\.superThreshold), range: 0.11...5)
                } else {
                    extendedDistanceRow("Outer stage above", value: extendedDistance(\.outerThreshold), range: 1.01...5)
                    TextField("Blank uses Super boost actions", text: outerPayloadText, axis: .vertical)
                        .lineLimit(2...5).font(.body.monospaced())
                        .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("\(directionTitle(direction)) outer stage payload")
                    Text("The outer payload replaces Super boost beyond this distance. Leave it blank to keep Super boost. Use held actions such as X360A or W; WAIT and Pulse are unavailable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("100% is the stick's edge; 125% is a quarter of a radius beyond it. Continue dragging outside the stick without lifting. The knob stays at the edge while your finger can reach the extra stages. Give this stick enough empty space, or use Keep touch on starting control to prevent a slide into another control.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Beyond the stick edge") }
        footer: { Text("Each direction has its own distances and outer payload. Disabling Extended Boost keeps its settings for later.") }
    }

    private func extendedDistanceRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title): \(percentage(value.wrappedValue))")
            Slider(value: value, in: range, step: 0.01)
                .accessibilityLabel("\(directionTitle(direction)) extended \(title.lowercased())")
                .accessibilityValue(percentage(value.wrappedValue))
        }
    }
    private func extendedDistance(_ key: WritableKeyPath<ExtendedBoostDirectionSettings, Double>) -> Binding<Double> {
        Binding(get: { (draft.extendedBoost.directions[direction] ?? .init())[keyPath: key] }, set: { value in
            var settings = draft.extendedBoost.directions[direction] ?? .init()
            settings[keyPath: key] = value
            if key == \.regularThreshold { settings.regularThreshold = min(value, settings.superThreshold - 0.01) }
            if key == \.superThreshold { settings.superThreshold = max(value, settings.regularThreshold + 0.01) }
            draft.extendedBoost.directions[direction] = settings
            saveError = nil
        })
    }
    private var outerPayloadText: Binding<String> {
        Binding(get: { draft.extendedBoost.directions[direction]?.outerPayload ?? "" }, set: { value in
            var settings = draft.extendedBoost.directions[direction] ?? .init()
            settings.outerPayload = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
            draft.extendedBoost.directions[direction] = settings
            saveError = nil
        })
    }

    private enum StickMode: Hashable { case analog, stickPlus, directional }
    private var stickMode: Binding<StickMode> {
        Binding(get: {
            if draft.isDirectional { return .directional }
            return draft.stickBehavior.stickPlusEnabled ? .stickPlus : .analog
        }, set: { mode in
            draft.directionalEnabled = mode == .directional
            draft.stickBehavior.stickPlusEnabled = mode == .stickPlus
            saveError = nil
        })
    }
    private var usesDirectionalActions: Bool {
        draft.isDirectional || draft.stickBehavior.stickPlusEnabled
    }
    private var stickModeDescription: String {
        switch stickMode.wrappedValue {
        case .analog:
            return "Moves the selected controller stick. Directional mappings are kept for later use."
        case .stickPlus:
            return "Moves the selected controller stick and adds the actions configured for each direction and distance. Changing modes keeps your mappings."
        case .directional:
            return "Sends only the configured directional actions, with no analog stick movement. Changing modes keeps your mappings. Use the optional WASD preset below to preview keyboard controls in Practice or send them with the Windows PC receiver."
        }
    }

    @ViewBuilder
    private func stageEditor(_ stage: StickStage, expanded: Binding<Bool>) -> some View {
        let title = stageTitle(stage)
        Toggle("Custom \(title.lowercased()) payload", isOn: stageCustomEnabled(stage))
            .accessibilityLabel("\(directionTitle(direction)) \(title.lowercased()) custom payload")
            .accessibilityHint("Replaces this stage's controller checkbox actions. Turning it off restores those choices.")
        if stagePayload(stage) != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) payload")
                TextField("W,SHIFT", text: stagePayloadText(stage), axis: .vertical)
                    .lineLimit(2...5)
                    .font(.body.monospaced())
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("\(directionTitle(direction)) \(title.lowercased()) payload")
                    .accessibilityHint("Enter comma-separated held actions, or leave empty for no actions. Keyboard and mouse preview in Practice and work with the Windows PC receiver; the console bridge does not send them.")
                Menu("Use auto-center for this stage") {
                    Button("Toggle auto-center") { stagePayloadText(stage).wrappedValue = "AUTO_CENTER_TOGGLE" }
                    Button("Turn auto-center on") { stagePayloadText(stage).wrappedValue = "AUTO_CENTER_ON" }
                    Button("Turn auto-center off") { stagePayloadText(stage).wrappedValue = "AUTO_CENTER_OFF" }
                }
                .accessibilityLabel("\(directionTitle(direction)) \(title.lowercased()) auto-center action")
                if let error = stageValidationMessage(stage) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            actionDisclosure("\(title) actions", selection: stageActions(stage), expanded: expanded)
        }
    }

    private func actionDisclosure(_ label: String, selection: Binding<Set<ControllerControlID>>,
                                  expanded: Binding<Bool>) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            ForEach(ControllerControlID.allCases.filter { !$0.isStick }, id: \.self) { action in
                let selected = selection.wrappedValue.contains(action)
                Button {
                    var actions = selection.wrappedValue
                    if selected { actions.remove(action) }
                    else { actions.insert(action) }
                    selection.wrappedValue = actions
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.displayName)
                                .foregroundStyle(.primary)
                            if isPracticeOnly(action) {
                                Text("Practice only")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.displayName)
                .accessibilityValue(selected ? "Selected" : "Not selected")
                .accessibilityHint(isPracticeOnly(action)
                                   ? "Practice only. Double tap to change this action."
                                   : "Double tap to change this action.")
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                Text(actionSummary(selection.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func thresholdRow(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(label): \(percentage(value.wrappedValue))")
            Slider(value: value, in: 0...1, step: 0.01)
                .accessibilityLabel(label)
                .accessibilityValue(percentage(value.wrappedValue))
        }
        .padding(.vertical, 4)
    }

    private var isStick: Bool { draft.kind == .leftStick || draft.kind == .rightStick }
    private var sizeRange: ClosedRange<Double> { isStick ? 104...300 : 44...200 }
    private var sizeValue: Binding<Double> {
        Binding(get: {
            let size = draft.diameter.isFinite ? draft.diameter : sizeRange.lowerBound
            return min(sizeRange.upperBound, max(sizeRange.lowerBound, size))
        }, set: { draft.diameter = $0 })
    }
    private var boostThreshold: Binding<Double> {
        Binding(get: { finiteSliderValue(draft.stickBehavior.boostThreshold) }, set: { value in
            draft.stickBehavior.boostThreshold = min(value, max(0, draft.stickBehavior.superBoostThreshold - 0.01))
        })
    }
    private var superThreshold: Binding<Double> {
        Binding(get: { finiteSliderValue(draft.stickBehavior.superBoostThreshold) }, set: { value in
            draft.stickBehavior.superBoostThreshold = max(value, min(1, draft.stickBehavior.boostThreshold + 0.01))
        })
    }

    private func stageActions(_ stage: StickStage) -> Binding<Set<ControllerControlID>> {
        Binding(get: {
            let mapping = draft.stickBehavior.directions[direction] ?? .init()
            switch stage {
            case .normal: return mapping.normalControls
            case .boost: return mapping.boostControls
            case .superBoost: return mapping.superBoostControls
            }
        }, set: { actions in
            var mapping = draft.stickBehavior.directions[direction] ?? .init()
            switch stage {
            case .normal: mapping.normalControls = actions
            case .boost: mapping.boostControls = actions
            case .superBoost: mapping.superBoostControls = actions
            }
            draft.stickBehavior.directions[direction] = mapping
            saveError = nil
        })
    }

    private func stageTitle(_ stage: StickStage) -> String {
        switch stage {
        case .normal: return "Normal"
        case .boost: return "Boost"
        case .superBoost: return "Super boost"
        }
    }
    private func stagePayloadKey(_ stage: StickStage, direction: StickDirection) -> String {
        "\(direction.rawValue):\(stageTitle(stage))"
    }
    private func stagePayload(_ stage: StickStage) -> String? {
        let payloads = draft.directionPayloads[direction] ?? .init()
        switch stage {
        case .normal: return payloads.normalPayload
        case .boost: return payloads.boostPayload
        case .superBoost: return payloads.superBoostPayload
        }
    }
    private func setStagePayload(_ payload: String?, stage: StickStage) {
        var payloads = draft.directionPayloads[direction] ?? .init()
        switch stage {
        case .normal: payloads.normalPayload = payload
        case .boost: payloads.boostPayload = payload
        case .superBoost: payloads.superBoostPayload = payload
        }
        draft.directionPayloads[direction] = payloads
        saveError = nil
    }
    private func stageCustomEnabled(_ stage: StickStage) -> Binding<Bool> {
        Binding(get: { stagePayload(stage) != nil }, set: { enabled in
            let key = stagePayloadKey(stage, direction: direction)
            if enabled {
                let source = ControllerPayloadProgram.source(for: stageActions(stage).wrappedValue)
                setStagePayload(rememberedStagePayloads[key] ?? source, stage: stage)
            } else {
                rememberedStagePayloads[key] = stagePayload(stage)
                setStagePayload(nil, stage: stage)
            }
        })
    }
    private func stagePayloadText(_ stage: StickStage) -> Binding<String> {
        Binding(get: { stagePayload(stage) ?? "" }, set: { payload in
            rememberedStagePayloads[stagePayloadKey(stage, direction: direction)] = payload
            setStagePayload(payload, stage: stage)
        })
    }
    private func stageValidationMessage(_ stage: StickStage) -> String? {
        do {
            _ = try draft.stageProgram(direction: direction, stage: stage)
            return nil
        } catch { return error.localizedDescription }
    }

    private func applyWASDPreset() {
        draft.directionalEnabled = true
        draft.stickBehavior.stickPlusEnabled = false
        draft.stickBehavior.boostThreshold = 0.5
        draft.stickBehavior.superBoostThreshold = 0.75
        for (direction, key, modifier) in [
            (StickDirection.up, "W", "SHIFT"), (.down, "S", "CTRL"),
            (.left, "A", "SHIFT"), (.right, "D", "SHIFT")
        ] {
            draft.directionPayloads[direction] = .init(
                normalPayload: key,
                boostPayload: "\(key),\(modifier)",
                superBoostPayload: "\(key),\(modifier),SPACE")
            for stage in [StickStage.normal, .boost, .superBoost] {
                rememberedStagePayloads.removeValue(forKey: stagePayloadKey(stage, direction: direction))
            }
        }
        direction = .up
        saveError = nil
    }

    private func applyForwardExample() {
        draft.directionalEnabled = false
        draft.stickBehavior.stickPlusEnabled = true
        draft.stickBehavior.boostThreshold = 0.5
        draft.stickBehavior.superBoostThreshold = 0.95
        var mapping = draft.stickBehavior.directions[.up] ?? .init()
        mapping.normalControls = []
        mapping.boostControls = [.leftStickClick]
        mapping.superBoostControls = [.a]
        draft.stickBehavior.directions[.up] = mapping
        draft.directionPayloads[.up] = .init()
        for stage in [StickStage.normal, .boost, .superBoost] {
            rememberedStagePayloads.removeValue(forKey: stagePayloadKey(stage, direction: .up))
        }
        direction = .up
        saveError = nil
    }

    private var validationMessage: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.name.count > 64 {
            return "Enter a control name with 1 to 64 characters."
        }
        if !draft.diameter.isFinite || !sizeRange.contains(draft.diameter) {
            return "Choose a size from \(Int(sizeRange.lowerBound)) to \(Int(sizeRange.upperBound)) points."
        }
        if !(50...5_000).contains(draft.buttonBehavior.holdMilliseconds) {
            return "Choose a hold duration from 50 to 5,000 milliseconds."
        }
        if !(16...1_000).contains(draft.autoTapIntervalMilliseconds) {
            return "Choose an Auto-Tap interval from 16 to 1,000 milliseconds."
        }
        if let interval = draft.stickPlusRepeatIntervalMilliseconds, !(16...1_000).contains(interval) {
            return "Choose a Stick+ repeat interval from 16 to 1,000 milliseconds."
        }
        if draft.autoTapEnabled && draft.buttonBehavior.holdToggle {
            return "Choose either Hold to toggle or Auto-Tap for this button."
        }
        if let payloadError = payloadValidationMessage { return payloadError }
        if !draft.stickBehavior.boostThreshold.isFinite || !draft.stickBehavior.superBoostThreshold.isFinite ||
            !(0...1).contains(draft.stickBehavior.boostThreshold) ||
            !(0...1).contains(draft.stickBehavior.superBoostThreshold) ||
            draft.stickBehavior.boostThreshold >= draft.stickBehavior.superBoostThreshold {
            return "Choose distances from 0% to 100%, with Super boost above Boost."
        }
        do { try draft.validate(); return nil }
        catch {
            return (error as? LocalizedError)?.errorDescription
                ?? "These settings are not valid. Check the control actions and behavior before saving."
        }
    }

    private func commit(copy: Bool) {
        do {
            try draft.validate()
            saveError = nil
            if copy { onDuplicate(draft, selectedPageID) }
            else { onSave(draft, selectedPageID) }
            dismiss()
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription
                ?? "The control could not be saved. Check its name, size, actions and behavior."
        }
    }
    private func actionSummary(_ actions: Set<ControllerControlID>) -> String {
        let names = ControllerControlID.allCases.filter { actions.contains($0) }.map(\.displayName)
        return names.isEmpty ? "No actions selected" : names.joined(separator: ", ")
    }
    private func directionTitle(_ direction: StickDirection) -> String {
        switch direction {
        case .up: return "Up"
        case .right: return "Right"
        case .down: return "Down"
        case .left: return "Left"
        }
    }
    private func finiteSliderValue(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
    private func percentage(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
    private func isPracticeOnly(_ action: ControllerControlID) -> Bool {
        [.guide, .share].contains(action)
    }
}

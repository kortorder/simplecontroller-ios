import ControllerCore
import SwiftUI

/// Whole-profile local draft. Done applies it to the parent's edit draft; Save layout is still required.
@MainActor
struct FloatingRingEditorView: View {
    private let pageID: UUID
    private let zoneID: UUID
    private let snapshots: [ControllerOrientation: FloatingCanvasSnapshot]
    private let onSavePresets: (SettingsPresetLibrary) -> Bool
    private let onSave: (ControllerProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ControllerProfile
    @State private var orientation: ControllerOrientation = .portrait
    @State private var editedBank: RingBoostBank = .movement
    @State private var editSharedActions = true
    private var selectedActionsBank: RingBoostBank? {
        config.boostBanks?.enabled == true || !editSharedActions ? editedBank : nil
    }
    private var otherBank: RingBoostBank { editedBank == .aim ? .movement : .aim }
    @State private var knobID = "aim_1"
    @State private var actionError: String?
    @State private var presets: SettingsPresetLibrary
    @State private var presetName = ""
    @State private var includeAimActions = true
    @State private var pendingRingPreset: SettingsPreset?
    @State private var confirmingDelete = false
    @State private var presetStatus: String?

    init(profile: ControllerProfile, pageID: UUID, zoneID: UUID,
         snapshots: [ControllerOrientation: FloatingCanvasSnapshot], settingsPresets: SettingsPresetLibrary = .empty,
         onSavePresets: @escaping (SettingsPresetLibrary) -> Bool = { _ in false },
         onSave: @escaping (ControllerProfile) -> Void) {
        self.pageID = pageID; self.zoneID = zoneID; self.snapshots = snapshots; self.onSavePresets = onSavePresets; self.onSave = onSave
        _draft = State(initialValue: profile)
        _presets = State(initialValue: settingsPresets)
        _presetName = State(initialValue: profile.page(for: pageID)?.floatingRingZones.first(where: { $0.id == zoneID })?.name ?? "Ring")
        _orientation = State(initialValue: snapshots[.portrait] != nil ? .portrait : .landscape)
        _knobID = State(initialValue: profile.page(for: pageID)?.floatingRingZones.first(where: { $0.id == zoneID })?.config.startKnobID ?? "aim_1")
    }
    private var zone: FloatingRingZone? { draft.page(for: pageID)?.floatingRingZones.first { $0.id == zoneID } }
    private var config: FloatingRingConfig { zone?.config ?? .init() }
    private var selectedKnob: RingAimKnob { config.knob(knobID) ?? config.knobs.first ?? .init() }
    private var validationMessage: String? {
        guard zone != nil else { return "This ring is no longer on the page." }
        do { try draft.validate(); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ring name", text: zoneBinding(\.name))
                    Toggle("Activation zone enabled", isOn: zoneBinding(\.enabled))
                    Toggle("Finish ignores swipes", isOn: zoneBinding(\.finishIgnoresSwipes))
                    Text("Changes stay in this editor until Done. Then tap Save layout to keep the whole profile draft.").font(.footnote)
                } header: { Text("Floating ring") }
                activationSection
                startSection
                movementSection
                aimSection
                knobsSection
                boostBanksSection
                boostSection(.one)
                boostSection(.two)
                transitionsSection
                presetsSection
                Section {
                    Text("Boost 1 and Boost 2 are cumulative radial layers. Ring actions manage their own press and release timing. Fixed-stick commands share the same first-touch ownership as movement and aim.")
                    Text("Use Practice to check the outputs. For adjustable LT and RT on Xbox, select the compatible trigger hardware in Bridge settings. Keyboard and mouse outputs appear in Practice.")
                    Text("Finish cancels only this ring. Release all cancels every input. Cancellation and leaving the app never produce a release shot.")
                } header: { Text("Before using") }
                if let message = actionError ?? validationMessage {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                Section {
                    Button("Delete this ring", role: .destructive) { confirmingDelete = true }
                    Text("Deletion changes the profile draft. Save layout keeps it; Cancel layout restores it.").font(.footnote)
                }
            }
            .navigationTitle("Ring settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { guard validationMessage == nil else { return }; onSave(draft); dismiss() }
                        .disabled(validationMessage != nil)
                }
            }
            .confirmationDialog("Replace this ring's settings and activation areas?", isPresented: .init(get: { pendingRingPreset != nil }, set: { if !$0 { pendingRingPreset = nil } }), titleVisibility: .visible) {
                if let entry = pendingRingPreset {
                    Button("Apply \(entry.name)", role: .destructive) { applyRingPreset(entry); pendingRingPreset = nil }
                }
                Button("Cancel", role: .cancel) { pendingRingPreset = nil }
            } message: {
                Text("This replaces all ring settings, knob positions and both orientation activation areas in the draft. The ring keeps its name and identity. Done and Save layout are still required.")
            }
            .confirmationDialog("Delete this floating ring?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete ring from draft", role: .destructive) { deleteRing() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This applies the deletion to the profile draft. Cancel layout can still restore the saved ring.") }
        }
    }
    private var activationSection: some View {
        Section {
            Picker("Orientation", selection: $orientation) {
                Text("Portrait").tag(ControllerOrientation.portrait)
                Text("Landscape").tag(ControllerOrientation.landscape)
            }.pickerStyle(.segmented)
            if let snapshot = snapshots[orientation] {
                if zone?.geometry(for: orientation) == nil {
                    Button("Create activation zone for this orientation") { prepareOrientation(snapshot) }
                    Text("Uses this orientation's measured canvas. Only the activation rectangle scales; ring target sizes stay in points.").font(.footnote)
                } else {
                    FloatingActivationPreview(rectangle: rectangleBinding, snapshot: snapshot)
                        .frame(height: 180)
                        .accessibilityLabel("Activation zone preview")
                        .accessibilityHint("Drag the rectangle to move it. Position and size controls are below.")
                    points("Left", value: rectangleField(\.x), range: 0...max(0, snapshot.width - rectangleBinding.wrappedValue.width))
                    points("Top", value: rectangleField(\.y), range: 0...max(0, snapshot.height - rectangleBinding.wrappedValue.height))
                    points("Width", value: rectangleField(\.width), range: 1...snapshot.width)
                    points("Height", value: rectangleField(\.height), range: 1...snapshot.height)
                    Text("Measured canvas: \(Int(snapshot.width)) × \(Int(snapshot.height)) points. Dragging this rectangle does not move a surfaced ring or change any control output.").font(.footnote)
                    if let geometry = try? FloatingRingGeometry(config: config),
                       geometry.width > snapshot.width || geometry.height > snapshot.height {
                        Label("The ring and Finish target will not fit this orientation. Reduce the ring radii before using it here.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            } else {
                Text("Close this editor, rotate the layout to \(orientation == .portrait ? "portrait" : "landscape"), then reopen it to measure that canvas. No device dimensions are guessed.")
            }
        } header: { Text("Activation zone") }
    }
    private var startSection: some View {
        Section {
            Picker("Starting role", selection: configBinding(\.startRole)) {
                Text("Movement").tag(FloatingStartRole.movement); Text("Aim").tag(FloatingStartRole.aim)
                Text("Boost 1 direct area").tag(FloatingStartRole.boostOne); Text("Boost 2 direct area").tag(FloatingStartRole.boostTwo)
            }
            Picker("Starting aim knob", selection: configBinding(\.startKnobID)) {
                ForEach(config.knobs, id: \.id) { Text($0.name.isEmpty ? $0.id : $0.name).tag($0.id) }
            }
            points("Inner aim radius", value: configBinding(\.innerRadius), range: 1...30_000)
            points("Movement radius", value: configBinding(\.movementRadius), range: 1...30_000)
            Text("The chosen starting role sits under your first touch. Edge fitting shifts the whole ring without shrinking it. Finish always has a 48-point target.").font(.footnote)
        } header: { Text("Summon and size") }
    }
    private var movementSection: some View {
        Section {
            Toggle("Movement layer", isOn: configBinding(\.movement.enabled))
            DisclosureGroup("Movement settings") {
                Picker("Output", selection: configBinding(\.movement.output)) {
                    Text("Left stick").tag(ButtonAimOutput.leftStick); Text("Right stick").tag(ButtonAimOutput.rightStick)
                }
                sensitivity("Sensitivity", value: configBinding(\.movement.sensitivity))
                responsePicker(configBinding(\.movement.response))
                Toggle("Auto-center on lift", isOn: configBinding(\.movement.autoCenter))
                Toggle("Movement participates in boosts", isOn: configBinding(\.movement.participateInBoosts))
                Toggle("Exclude from camera follow", isOn: configBinding(\.movement.excludeFromCameraFollow))
                normalized("Starting horizontal", value: configBinding(\.movement.initialX))
                normalized("Starting vertical", value: configBinding(\.movement.initialY))
                Text("Positive horizontal is right; positive vertical is down. The starting vector must fit inside the unit circle. Turning auto-center off retains movement after a normal lift; cancellation still releases it.").font(.footnote)
            }
        } header: { Text("Movement") }
    }
    private var aimSection: some View {
        Section {
            Toggle("Aim layer", isOn: configBinding(\.aim.enabled))
            DisclosureGroup("Aim response") {
                Picker("Aim output", selection: configBinding(\.aim.tuning.output)) {
                    Text("Mouse · Practice").tag(ButtonAimOutput.mouse)
                    Text("Game Mouse · Practice").tag(ButtonAimOutput.gameMouse)
                    Text("Right stick").tag(ButtonAimOutput.rightStick)
                }
                sensitivity("Aim sensitivity", value: configBinding(\.aim.tuning.sensitivity))
                Toggle("Invert vertical aim", isOn: configBinding(\.aim.tuning.invertY))
                responsePicker(configBinding(\.aim.tuning.stickResponse))
                Picker("Mouse response", selection: configBinding(\.aim.tuning.mouseResponse)) {
                    Text("Linear relative").tag(ButtonAimMouseResponse.linearRelative)
                    Text("Smoothed curve").tag(ButtonAimMouseResponse.smoothedNonlinear)
                }
                Picker("Stick origin", selection: configBinding(\.aim.tuning.origin)) {
                    Text("First touch").tag(ButtonAimOrigin.initialTouch); Text("Control center").tag(ButtonAimOrigin.controlCenter)
                }
                points("Full displacement", value: configBinding(\.aim.tuning.fullDisplacement), range: 1...1200)
                points("Deadzone", value: configBinding(\.aim.tuning.deadzone), range: 0...1200)
                Toggle("Auto-center aim on lift", isOn: configBinding(\.aim.tuning.autoCenter))
                Toggle("Touch feedback", isOn: configBinding(\.aim.tuning.hapticsEnabled))
                Toggle("Continue aiming outside inner area", isOn: configBinding(\.aim.continueOutside))
                Toggle("Aim participates in boosts", isOn: configBinding(\.aim.participateInBoosts))
                Toggle("Suppress camera follow while aiming", isOn: configBinding(\.aim.suppressCameraFollow))
                Text("If outside aiming is off, leaving the inner area centers aim while retaining its owner. Returning starts from a new neutral grab.").font(.footnote)
            }
            DisclosureGroup("Fine aim after returning from a boost") {
                Toggle("Fine aim", isOn: configBinding(\.aim.fine.enabled))
                sensitivity("Fine sensitivity", value: configBinding(\.aim.fine.sensitivity))
                stageChoices(configBinding(\.aim.fine.qualifyingStages))
                Toggle("Keep fine aim with qualifying latched action", isOn: configBinding(\.aim.fine.persistWhileAdsLatched))
            }
        } header: { Text("Aim") }
    }
    private var knobsSection: some View {
        Section {
            Picker("Selected knob", selection: $knobID) {
                ForEach(config.knobs, id: \.id) { Text($0.name.isEmpty ? $0.id : $0.name).tag($0.id) }
            }
            FloatingKnobPreview(config: configBinding(\.self), selectedID: $knobID).frame(height: 240)
                .accessibilityLabel("Aim knob layout preview")
            Text("Drag a knob to reposition it inside the aim circle. Position controls below provide another way to move it. The preview is scaled; saved sizes remain in points.").font(.footnote)
            TextField("Knob name", text: knobBinding(\.name))
            Toggle("Knob enabled", isOn: knobBinding(\.enabled))
            normalized("Knob horizontal", value: knobBinding(\.x)); normalized("Knob vertical", value: knobBinding(\.y))
            points("Knob touch diameter", value: knobBinding(\.targetDiameter), range: 1...60_000)
            HStack {
                Button("Add knob") { addKnob() }.disabled(config.knobs.count >= 3)
                Spacer()
                Button("Delete selected knob", role: .destructive) { deleteKnob() }.disabled(config.knobs.count <= 1)
            }
            DisclosureGroup("Selected knob's ADS and fire actions") {
                RingPayloadField(title: "ADS actions", text: knobBinding(\.fire.adsPayload))
                Picker("Fire mode", selection: knobBinding(\.fire.mode)) {
                    Text("None").tag(RingFireMode.none); Text("Hold").tag(RingFireMode.hold)
                    Text("Tap once").tag(RingFireMode.tap); Text("Shot on normal lift").tag(RingFireMode.releaseShot)
                    Text("Repeat").tag(RingFireMode.repeat)
                }
                RingPayloadField(title: "Fire actions", text: knobBinding(\.fire.firePayload))
                milliseconds("Fire press", value: knobBinding(\.fire.pulsePressMilliseconds), range: 1...60_000)
                milliseconds("Fire release gap", value: knobBinding(\.fire.pulseGapMilliseconds), range: 1...60_000)
                Toggle("Retain ADS on normal lift", isOn: knobBinding(\.fire.retainADSOnLift))
                Toggle("Retain held or repeated fire on lift", isOn: knobBinding(\.fire.retainFireOnLift))
                Toggle("Continue ADS outside inner area", isOn: knobBinding(\.fire.continueADSOutside))
                Toggle("Continue fire outside inner area", isOn: knobBinding(\.fire.continueFireOutside))
                Toggle("Cancel release shot after leaving inner area", isOn: knobBinding(\.fire.cancelReleaseShotOnBoundaryExit))
                Toggle("Re-arm release shot on return", isOn: knobBinding(\.fire.rearmReleaseShotOnBoundaryReturn))
                Text("A release shot requires a normal lift while armed. Finish, cancellation, editing and app interruptions never fire it. ADS and fire must use separate outputs.").font(.footnote)
            }
            DisclosureGroup("Fire after returning from a boost") {
                Toggle("Qualified return fire", isOn: knobBinding(\.fire.returnFire.enabled))
                stageChoices(knobBinding(\.fire.returnFire.qualifyingStages))
                milliseconds("Return delay", value: knobBinding(\.fire.returnFire.delayMilliseconds), range: 0...60_000)
                Toggle("Start fire delay when entering Boost", isOn: knobBinding(\.fire.returnFire.startOnBoostEntry))
                Toggle("Cancel pending return fire on exit", isOn: knobBinding(\.fire.returnFire.cancelOnExit))
            }
        } header: { Text("Aim knobs · one to three") }
    }
    private var boostBanksSection: some View {
        Section {
            Toggle("Compact boosts while aiming", isOn: configBinding(\.compactAimBoosts))
            Toggle("Boost 1 immediately outside Movement", isOn: configBinding(\.adjacentMovementBoosts))
            Toggle("Separate Movement and Aim boost actions", isOn: banksBinding(\.enabled))
            Picker("Starting role to edit", selection: $editedBank) {
                Text("Movement").tag(RingBoostBank.movement)
                Text("Aim").tag(RingBoostBank.aim)
            }
            if config.boostBanks?.enabled != true {
                Toggle("Edit shared actions", isOn: $editSharedActions)
            }
            if config.startRole == .boostOne || config.startRole == .boostTwo {
                Picker("Direct touch uses actions for", selection: banksBinding(\.directStartBank)) {
                    Text("Movement").tag(RingBoostBank.movement)
                    Text("Aim").tag(RingBoostBank.aim)
                }
            }
            Menu("Copy from the \(otherBank.rawValue.capitalized) bank") {
                Button("Copy action settings and timing") { copyBank(geometryOnly: false) }
                Button("Copy radial distances and thicknesses") { copyBank(geometryOnly: true) }
            }
            Toggle("Custom radial geometry", isOn: bankBinding(\.geometry.enabled))
            if config.seededBoostBanks()[editedBank].geometry.enabled {
                bandSize("Boost 1 distance from center", bankBinding(\.geometry.boost1Distance))
                bandSize("Boost 1 thickness", bankBinding(\.geometry.boost1Thickness))
                bandSize("Boost 2 thickness", bankBinding(\.geometry.boost2Thickness))
                bandSize("Direct tap start distance", bankBinding(\.geometry.directStartDistance))
            }
            if let snapshot = snapshots[orientation], zone?.geometry(for: orientation) != nil,
               let ring = try? FloatingRingGeometry(config: config),
               let placement = ring.place(at: rectangleBinding.wrappedValue.center, usable: snapshot.usable) {
                FloatingBoostPreview(ring: ring, placement: placement, bank: editedBank, snapshot: snapshot)
                Text("The preview places the ring at the center of your activation area. Reach changes with the starting touch.").font(.footnote)
            }
        } header: { Text("Boost distance and actions") }
    }
    private func copyBank(geometryOnly: Bool) {
        updateZone { zone in
            var banks = zone.config.seededBoostBanks()
            let source = banks[otherBank]
            var target = banks[editedBank]
            if geometryOnly {
                let enabled = target.geometry.enabled
                target.geometry = source.geometry
                target.geometry.enabled = enabled
            } else {
                let firstEnabled = target.boost1.enabled, secondEnabled = target.boost2.enabled
                target.boost1 = source.boost1; target.boost1.enabled = firstEnabled
                target.boost2 = source.boost2; target.boost2.enabled = secondEnabled
            }
            banks[editedBank] = target; zone.config.boostBanks = banks
            if !geometryOnly { editSharedActions = false }
        }
    }
    private func bandSize(_ title: String, _ binding: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title) {
                TextField(title, value: binding, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            Slider(value: binding, in: 1...max(400, binding.wrappedValue), step: 1).accessibilityLabel(title)
        }
    }
    private func boostSection(_ stage: RingBoostStage) -> some View {
        Section {
            Toggle("Boost \(stage == .one ? "1" : "2") enabled", isOn: boostBinding(stage, \.enabled))
            DisclosureGroup("Distance, direction and actions") {
                points("Activation distance", value: boostBinding(stage, \.distance), range: 1...65_000)
                points("Exit hysteresis", value: boostBinding(stage, \.hysteresis), range: 0...65_000)
                Picker("Action", selection: boostBinding(stage, \.action)) {
                    Text("Tap").tag(RingAction.tap); Text("Hold").tag(RingAction.hold); Text("Repeat").tag(RingAction.repeat)
                }
                RingPayloadField(title: "Default actions", text: boostBinding(stage, \.payload))
                DisclosureGroup("Directional overrides · blank uses default") {
                    RingPayloadField(title: "Up", text: boostBinding(stage, \.directionalPayloads.up))
                    RingPayloadField(title: "Right", text: boostBinding(stage, \.directionalPayloads.right))
                    RingPayloadField(title: "Down", text: boostBinding(stage, \.directionalPayloads.down))
                    RingPayloadField(title: "Left", text: boostBinding(stage, \.directionalPayloads.left))
                }
                milliseconds("Press duration", value: boostBinding(stage, \.pulsePressMilliseconds), range: 1...60_000)
                milliseconds("Release gap", value: boostBinding(stage, \.pulseGapMilliseconds), range: 1...60_000)
                Toggle("Latch Hold after leaving band", isOn: boostBinding(stage, \.latchOnExit))
                Toggle("Continue Repeat after leaving band", isOn: boostBinding(stage, \.repeatAfterExit))
                Toggle("Retain on normal lift", isOn: boostBinding(stage, \.retainOnLift))
                if stage == .two {
                    Toggle("Skip Boost 2 delay on direct touch", isOn: boostBinding(stage, \.skipDelayOnDirectTouch))
                    milliseconds("Activation delay", value: boostBinding(stage, \.activationDelayMilliseconds), range: 0...60_000)
                    Toggle("Cancel pending delay on exit", isOn: boostBinding(stage, \.cancelDelayOnExit))
                }
                Text("Distances are radial points from the ring center. The preview shows the active distances for the selected starting role. Both stages can hold actions together. Direction changes use a 12-point margin.").font(.footnote)
            }
            DisclosureGroup("Direct activation band") {
                Toggle("Direct tap enabled", isOn: boostBinding(stage, \.directTapEnabled))
                points("Inner edge", value: boostBinding(stage, \.directInnerDistance), range: 1...65_000)
                points("Outer edge", value: boostBinding(stage, \.directOuterDistance), range: 1...65_536)
                Text("The direct band is finite and can extend outside the visible circle. Ordinary visible controls take priority over it.").font(.footnote)
            }
        } header: { Text("Boost \(stage == .one ? "1" : "2")") }
    }
    private var transitionsSection: some View {
        Section {
            Toggle("Start aiming immediately on direct Boost touch", isOn: configBinding(\.directBoostStartsAim))
            Toggle("Direct boost can enter aim", isOn: configBinding(\.directBoostToAim))
            Picker("Destination aim knob", selection: configBinding(\.directBoostAimKnobID)) {
                ForEach(config.knobs, id: \.id) { Text($0.name.isEmpty ? $0.id : $0.name).tag($0.id) }
            }
            Toggle("Direct Boost 2 can return through Boost 1", isOn: configBinding(\.directBoostTwoToOne))
            Text("Entering aim from a direct boost adds aim only. It does not start fresh ADS or ordinary fire. Qualified return fire runs only if explicitly configured.").font(.footnote)
        } header: { Text("Direct-area transitions") }
    }
    @ViewBuilder private var presetsSection: some View {
        Section {
            TextField("Preset name", text: $presetName)
            Toggle("Include aim actions in boost preset", isOn: $includeAimActions)
            Button("Save boost preset") { savePreset(wholeRing: false) }.disabled(validationMessage != nil)
            Button("Save complete ring preset") { savePreset(wholeRing: true) }.disabled(validationMessage != nil)
            Text("Saving a preset writes the reusable settings library immediately. It does not save this layout draft, and Cancel does not remove a preset you saved.").font(.footnote)
            if let presetStatus { Text(presetStatus).foregroundStyle(.secondary) }
        } header: { Text("Save reusable settings") }
        Section {
            let entries = presets.orderedEntries(in: .floatingBoost)
            if entries.isEmpty {
                Text("No saved boost presets are available.").foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    if case let .floatingBoost(value) = entry.value {
                        Menu(entry.name) {
                            Button("Apply boost settings") { applyPreset(value, aim: false) }
                            if value.aim != nil { Button("Apply aim actions by knob slot") { applyPreset(value, aim: true) } }
                        }
                    }
                }
            }
            Text("Boost-only apply keeps your enable switches and non-boost settings. Aim-action apply keeps knob identities, positions and enable switches, and requires the same knob count.").font(.footnote)
        } header: { Text("Saved boost presets") }
        Section {
            let entries = presets.orderedEntries(in: .floatingRing)
            if entries.isEmpty { Text("No complete ring presets are available.").foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                Button("Apply \(entry.name)") { pendingRingPreset = entry }
            }
            Text("A complete preset includes inactive settings, knob geometry and both activation areas. Applying it requires confirmation and keeps this ring's name and identity.").font(.footnote)
        } header: { Text("Saved complete rings") }
    }
    private func zoneBinding<Value>(_ path: WritableKeyPath<FloatingRingZone, Value>) -> Binding<Value> {
        .init(get: { (zone ?? .init())[keyPath: path] }, set: { value in updateZone { $0[keyPath: path] = value } })
    }
    private func configBinding<Value>(_ path: WritableKeyPath<FloatingRingConfig, Value>) -> Binding<Value> {
        .init(get: { config[keyPath: path] }, set: { value in updateZone { $0.config[keyPath: path] = value } })
    }
    private func knobBinding<Value>(_ path: WritableKeyPath<RingAimKnob, Value>) -> Binding<Value> {
        .init(get: { selectedKnob[keyPath: path] }, set: { value in
            updateZone { zone in
                guard let index = zone.config.knobs.firstIndex(where: { $0.id == selectedKnob.id }) else { return }
                zone.config.knobs[index][keyPath: path] = value
            }
        })
    }
    private func banksBinding<Value>(_ path: WritableKeyPath<RingBoostBanks, Value>) -> Binding<Value> {
        .init(get: { config.seededBoostBanks()[keyPath: path] }, set: { value in
            updateZone { zone in
                var banks = zone.config.seededBoostBanks()
                banks[keyPath: path] = value; zone.config.boostBanks = banks
            }
        })
    }
    private func bankBinding<Value>(_ path: WritableKeyPath<RingBoostBankSettings, Value>) -> Binding<Value> {
        .init(get: { config.seededBoostBanks()[editedBank][keyPath: path] }, set: { value in
            updateZone { zone in
                var banks = zone.config.seededBoostBanks()
                banks[editedBank][keyPath: path] = value; zone.config.boostBanks = banks
            }
        })
    }
    private func boostBinding<Value>(_ stage: RingBoostStage, _ path: WritableKeyPath<RingBoostSettings, Value>) -> Binding<Value> {
        if selectedActionsBank != nil {
            return bankBinding((stage == .one ? \RingBoostBankSettings.boost1 : \RingBoostBankSettings.boost2).appending(path: path))
        }
        return configBinding((stage == .one ? \FloatingRingConfig.boost1 : \FloatingRingConfig.boost2).appending(path: path))
    }
    private func updateZone(_ change: (inout FloatingRingZone) -> Void) {
        guard let page = draft.pages.firstIndex(where: { $0.id == pageID }),
              let index = draft.pages[page].floatingRingZones.firstIndex(where: { $0.id == zoneID }) else { return }
        var copy = draft.pages[page].floatingRingZones[index]; change(&copy)
        draft.pages[page].floatingRingZones[index] = copy; actionError = nil
    }
    private var rectangleBinding: Binding<FloatingRect> {
        .init(get: {
            guard let geometry = zone?.geometry(for: orientation) else { return .init(x: 0, y: 0, width: 100, height: 100) }
            if let snapshot = snapshots[orientation],
               let resolved = try? geometry.resolved(canvasWidth: snapshot.width, canvasHeight: snapshot.height) { return resolved }
            return geometry.zone
        }, set: { rect in
            guard let snapshot = snapshots[orientation] else { return }
            updateZone { zone in
                let geometry = FloatingZoneGeometry(canvasWidth: snapshot.width, canvasHeight: snapshot.height, zone: rect)
                if orientation == .portrait { zone.portraitGeometry = geometry } else { zone.landscapeGeometry = geometry }
            }
        })
    }
    private func rectangleField(_ path: WritableKeyPath<FloatingRect, Double>) -> Binding<Double> {
        .init(get: { rectangleBinding.wrappedValue[keyPath: path] }, set: { value in
            guard let snapshot = snapshots[orientation] else { return }
            var rect = rectangleBinding.wrappedValue; rect[keyPath: path] = value
            rect.width = min(snapshot.width, max(1, rect.width)); rect.height = min(snapshot.height, max(1, rect.height))
            rect.x = min(snapshot.width - rect.width, max(0, rect.x)); rect.y = min(snapshot.height - rect.height, max(0, rect.y))
            rectangleBinding.wrappedValue = rect
        })
    }
    private func prepareOrientation(_ snapshot: FloatingCanvasSnapshot) {
        do {
            try snapshot.validate()
            let alternate = zone?.geometry(for: orientation == .portrait ? .landscape : .portrait)
            let rect = try alternate?.resolved(canvasWidth: snapshot.width, canvasHeight: snapshot.height)
                ?? FloatingRect(x: 0, y: 0, width: min(180, snapshot.width), height: min(180, snapshot.height))
            rectangleBinding.wrappedValue = rect
        } catch { actionError = error.localizedDescription }
    }
    private func addKnob() {
        guard config.knobs.count < 3 else { return }
        let id = UUID().uuidString, index = config.knobs.count, diameter = min(48, config.innerRadius * 0.6)
        updateZone { $0.config.knobs.append(.init(id: id, name: "Aim \(index + 1)", x: index == 1 ? 0.4 : -0.4, targetDiameter: diameter)) }
        knobID = id
    }
    private func deleteKnob() {
        guard config.knobs.count > 1 else { return }
        let removed = selectedKnob.id
        updateZone { zone in
            zone.config.knobs.removeAll { $0.id == removed }
            let fallback = zone.config.knobs[0].id
            if zone.config.startKnobID == removed { zone.config.startKnobID = fallback }
            if zone.config.directBoostAimKnobID == removed { zone.config.directBoostAimKnobID = fallback }
        }
        knobID = config.knobs[0].id
    }
    private func applyPreset(_ value: FloatingBoostPreset, aim: Bool) {
        do {
            var next = config
            if aim { try value.applyAimActions(to: &next) } else { try value.applyBoostSettings(to: &next, bank: selectedActionsBank) }
            updateZone { $0.config = next }
        } catch { actionError = error.localizedDescription }
    }
    private func savePreset(wholeRing: Bool) {
        do {
            guard let zone else { return }
            let value: SettingsPresetValue = wholeRing ? .floatingRing(zone) : .floatingBoost(try .capture(config, includeAimActions: includeAimActions, bank: selectedActionsBank))
            let entry = SettingsPreset(name: presetName.trimmingCharacters(in: .whitespacesAndNewlines),
                                       createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000), value: value)
            var next = presets; try next.save(entry)
            guard onSavePresets(next) else { throw SettingsPresetError("The preset could not be saved. The saved library is unchanged.") }
            presets = next; presetStatus = "Saved \(entry.name)."; actionError = nil
        } catch { actionError = error.localizedDescription; presetStatus = nil }
    }
    private func applyRingPreset(_ entry: SettingsPreset) {
        do {
            guard let current = zone else { return }
            var replacement = try entry.value.instantiateRing(name: current.name)
            replacement.id = current.id
            try replacement.validate()
            updateZone { $0 = replacement }
            knobID = replacement.config.startKnobID
        } catch { actionError = error.localizedDescription }
    }
    private func deleteRing() {
        guard let index = draft.pages.firstIndex(where: { $0.id == pageID }) else { return }
        draft.pages[index].floatingRingZones.removeAll { $0.id == zoneID }
        do { try draft.validate(); onSave(draft); dismiss() } catch { actionError = error.localizedDescription }
    }
    private func points(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 1) { LabeledContent(title, value: "\(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1)))) pt") }
    }
    private func milliseconds(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range, step: 5) { LabeledContent(title, value: "\(value.wrappedValue) ms") }
    }
    private func sensitivity(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
            Slider(value: value, in: 0...5, step: 0.05).accessibilityLabel(title)
        }
    }
    private func normalized(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
            Slider(value: value, in: -1...1, step: 0.01).accessibilityLabel(title)
        }
    }
    private func responsePicker(_ value: Binding<StickResponseMode>) -> some View {
        Picker("Stick response", selection: value) {
            Text("Linear").tag(StickResponseMode.linear); Text("Per-axis curve").tag(StickResponseMode.perAxis)
            Text("Radial curve").tag(StickResponseMode.radial)
        }
    }
    private func stageChoices(_ value: Binding<Set<RingBoostStage>>) -> some View {
        ForEach(RingBoostStage.allCases, id: \.self) { stage in
            Toggle("Qualify after Boost \(stage == .one ? "1" : "2")", isOn: .init(get: { value.wrappedValue.contains(stage) }, set: { enabled in
                var next = value.wrappedValue; if enabled { next.insert(stage) } else { next.remove(stage) }; value.wrappedValue = next
            }))
        }
    }
}

private struct RingPayloadField: View {
    var title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline)
            TextField("No actions", text: $text, axis: .vertical).lineLimit(1...3)
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                .accessibilityLabel(title)
            Menu("Add action") {
                ForEach(ControllerControlID.allCases.filter { !$0.isStick }, id: \.self) { control in
                    Button(control.displayName) { append(ControllerPayloadProgram.source(for: [control])) }
                }
                Menu("Fixed stick direction") {
                    ForEach(FixedStickChannel.allCases, id: \.self) { channel in
                        Menu(channel == .left ? "Left stick" : "Right stick") {
                            ForEach(FixedStickMacro.Direction.allCases, id: \.self) { direction in
                                Menu(directionName(direction)) {
                                    ForEach([25, 50, 75, 100], id: \.self) { percent in
                                        Button("\(percent)%") {
                                            if let macro = try? FixedStickMacro(channel: channel, direction: direction, percentage: percent) { append(macro.source) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Menu("Keyboard / mouse · Practice") {
                    ForEach(["W", "A", "S", "D", "LSHIFT", "SPACE", "MOUSE_LEFT_DOWN", "MOUSE_RIGHT_DOWN"], id: \.self) { command in Button(command) { append(command) } }
                }
                Button("Clear actions", role: .destructive) { text = "" }
            }
        }.padding(.vertical, 3)
    }
    private func append(_ command: String) { text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? command : text + ", " + command }
    private func directionName(_ direction: FixedStickMacro.Direction) -> String {
        switch direction {
        case .up: "Up"; case .right: "Right"; case .down: "Down"; case .left: "Left"
        case .upRight: "Up-right"; case .upLeft: "Up-left"; case .downRight: "Down-right"; case .downLeft: "Down-left"
        }
    }
}

private struct FloatingBoostPreview: View {
    let ring: FloatingRingGeometry
    let placement: FloatingRingPlacement
    let bank: RingBoostBank
    let snapshot: FloatingCanvasSnapshot

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / snapshot.width, size.height / snapshot.height)
            let frame = CGRect(x: (size.width - snapshot.width * scale)/2, y: 0,
                               width: snapshot.width * scale, height: snapshot.height * scale)
            let canvas = Path(roundedRect: frame, cornerRadius: 5)
            context.fill(canvas, with: .color(.secondary.opacity(0.1)))
            context.clip(to: canvas)
            let x = frame.minX + (placement.origin.x + ring.center.x) * scale
            let y = frame.minY + (placement.origin.y + ring.center.y) * scale
            func circle(_ radius: Double) -> Path {
                let r = radius * scale
                return Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2*r, height: 2*r))
            }
            context.fill(circle(bank == .aim ? ring.config.innerRadius : ring.config.movementRadius),
                         with: .color(.blue.opacity(0.2)))
            for stage in RingBoostStage.allCases {
                let color = stage == .one ? Color.orange : Color.purple
                let setting = ring.config.boost(stage, bank: bank)
                if setting.directTapEnabled {
                    let direct = ring.directBand(stage, bank: bank)
                    let midpoint = (direct.upperBound + direct.lowerBound)/2
                    context.stroke(circle(midpoint), with: .color(color.opacity(0.18)),
                                   lineWidth: (direct.upperBound - direct.lowerBound) * scale)
                }
                context.stroke(circle(ring.boostDistance(stage, bank: bank)), with: .color(color),
                               style: StrokeStyle(lineWidth: 2, dash: stage == .two ? [4, 3] : []))
            }
        }
        .frame(height: 190)
        .accessibilityHidden(true)
        ForEach(RingBoostStage.allCases, id: \.self) { stage in
            let settings = ring.config.boost(stage, bank: bank)
            let radius = ring.boostDistance(stage, bank: bank)
            let unreachable = ring.unreachableDirections(stage, origin: placement.origin, usable: snapshot.usable, bank: bank)
            VStack(alignment: .leading) {
                Text("Boost \(stage == .one ? "1 (solid)" : "2 (dashed)") · \(radius.formatted()) pt\(settings.enabled ? "" : " · Off")")
                if !unreachable.isEmpty {
                    Text("Beyond this canvas: " + StickDirection.allCases.filter(unreachable.contains).map { $0.rawValue.capitalized }.joined(separator: ", "))
                }
            }.font(.footnote)
        }
    }
}

private struct FloatingActivationPreview: View {
    @Binding var rectangle: FloatingRect
    let snapshot: FloatingCanvasSnapshot
    @State private var start: FloatingRect?
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / max(1, snapshot.width), proxy.size.height / max(1, snapshot.height))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)).frame(width: snapshot.width * scale, height: snapshot.height * scale)
                RoundedRectangle(cornerRadius: 7).fill(Color.cyan.opacity(0.3)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.cyan, lineWidth: 2))
                    .frame(width: rectangle.width * scale, height: rectangle.height * scale)
                    .offset(x: rectangle.x * scale, y: rectangle.y * scale)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if start == nil { start = rectangle }
                        guard let start else { return }; var next = start
                        next.x = min(snapshot.width - next.width, max(0, start.x + value.translation.width / scale))
                        next.y = min(snapshot.height - next.height, max(0, start.y + value.translation.height / scale)); rectangle = next
                    }.onEnded { _ in start = nil })
            }
        }
    }
}

private struct FloatingKnobPreview: View {
    @Binding var config: FloatingRingConfig
    @Binding var selectedID: String
    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2 - 12
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Circle().fill(Color.blue.opacity(0.1)).overlay(Circle().stroke(Color.blue, lineWidth: 1)).frame(width: radius * 2, height: radius * 2).position(center)
                ForEach(config.knobs, id: \.id) { knob in
                    let size = max(24, min(radius * 2, knob.targetDiameter / max(1, config.innerRadius) * radius))
                    Circle().fill(knob.enabled ? Color.cyan.opacity(0.4) : Color.gray.opacity(0.3))
                        .overlay(Circle().stroke(knob.id == selectedID ? Color.orange : Color.blue, lineWidth: knob.id == selectedID ? 3 : 1))
                        .overlay(Text(knob.name.isEmpty ? "Aim" : knob.name).font(.caption2).lineLimit(1).padding(3))
                        .frame(width: size, height: size).position(x: center.x + knob.x * radius, y: center.y + knob.y * radius)
                        .onTapGesture { selectedID = knob.id }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("floating-knob-preview")).onChanged { value in
                            selectedID = knob.id
                            guard let index = config.knobs.firstIndex(where: { $0.id == knob.id }), radius > 0 else { return }
                            var x = (value.location.x - center.x) / radius, y = (value.location.y - center.y) / radius
                            let limit = max(0, 1 - knob.targetDiameter / (2 * max(1, config.innerRadius))), distance = hypot(x, y)
                            if distance > limit && distance > 0 { x *= limit / distance; y *= limit / distance }
                            config.knobs[index].x = x; config.knobs[index].y = y
                        })
                        .accessibilityLabel(knob.name.isEmpty ? "Aim knob" : knob.name)
                }
            }.coordinateSpace(name: "floating-knob-preview")
        }
    }
}

import SwiftUI
import ControllerCore

@MainActor
struct FloatingControlsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ControllerProfile
    let pageID: UUID
    let snapshots: [ControllerOrientation: FloatingCanvasSnapshot]
    var settingsPresets: SettingsPresetLibrary = .empty
    let onSavePresets: (SettingsPresetLibrary) -> Bool
    let onUnfloat: (ControllerProfile, UUID, UUID) async throws -> ControllerProfile
    let onSave: (ControllerProfile) -> Void
    @State private var creatingButtons = false
    @State private var editing: FloatingEditorSelection?
    @State private var error: String?

    init(profile: ControllerProfile, pageID: UUID, snapshots: [ControllerOrientation: FloatingCanvasSnapshot],
         settingsPresets: SettingsPresetLibrary = .empty, onSavePresets: @escaping (SettingsPresetLibrary) -> Bool = { _ in false },
         onUnfloat: @escaping (ControllerProfile, UUID, UUID) async throws -> ControllerProfile = { profile, zoneID, pageID in
             var next = profile; try next.unfloatButtons(zoneID, on: pageID); return next
         },
         onSave: @escaping (ControllerProfile) -> Void) {
        _draft = State(initialValue: profile); self.pageID = pageID; self.snapshots = snapshots
        self.settingsPresets = settingsPresets; self.onSavePresets = onSavePresets; self.onSave = onSave
        self.onUnfloat = onUnfloat
    }
    private var page: ProfilePage? { draft.page(for: pageID) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("A floating control appears near where you touch its activation area. Its normal layout stays saved for restoring later. Finish clears only that floating control; Release all clears everything.")
                    Text("Changes here belong to the layout draft. Tap Done, then Save layout to keep them.")
                    if snapshots.isEmpty {
                        Text("This page has not been measured yet. Close this screen, view the controller in the orientation you want, and open Floating controls again.").foregroundStyle(.orange)
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                }
                Section("Floating buttons and groups") {
                    if let page {
                        ForEach(page.floatingButtonZones, id: \.id) { zone in
                            Button { editing = .buttons(zone.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(zone.name)
                                    Text("\(zone.memberIDs.count) \(zone.memberIDs.count == 1 ? "button" : "buttons") • \(zone.enabled ? "Enabled" : "Disabled")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44, alignment: .leading)
                            }
                        }
                    }
                    Button("Make buttons float") { creatingButtons = true }
                        .disabled(snapshots.isEmpty || availableButtons.isEmpty)
                }
                Section("Floating rings") {
                    if let page {
                        ForEach(page.floatingRingZones, id: \.id) { zone in
                            Button { editing = .ring(zone.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(zone.name)
                                    Text(zone.enabled ? "Enabled" : "Disabled").font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44, alignment: .leading)
                            }
                        }
                    }
                    Button("Add a floating ring") { addRing() }.disabled(snapshots.isEmpty)
                }
                Section {
                    Text("Only activation areas scale with the available screen. Buttons, spacing and ring targets keep their saved sizes. An arrangement that cannot fit will not activate; make it smaller or choose another orientation.")
                    Text("To measure another orientation, finish this screen, rotate the controller, then reopen Floating controls.")
                }
            }
            .navigationTitle("Floating controls").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(draft); dismiss() }.disabled((try? draft.validate()) == nil)
                }
            }
            .sheet(isPresented: $creatingButtons) {
                FloatingButtonCreationView(profile: draft, pageID: pageID, snapshots: snapshots) { updated, id in
                    draft = updated
                    // The created zone remains in this screen's draft, ready to edit in the list.
                    error = "Created \(updated.page(for: pageID)?.floatingButtonZones.first { $0.id == id }?.name ?? "floating control"). Open it below to position its activation area and buttons."
                }
            }
            .sheet(item: $editing) { selection in
                switch selection {
                case .buttons(let id):
                    FloatingButtonZoneEditor(profile: draft, pageID: pageID, zoneID: id, snapshots: snapshots,
                                             onUnfloat: onUnfloat, onSave: { draft = $0 })
                case .ring(let id):
                    FloatingRingEditorView(profile: draft, pageID: pageID, zoneID: id,
                                           snapshots: snapshots, settingsPresets: settingsPresets, onSavePresets: onSavePresets, onSave: { draft = $0 })
                }
            }
        }
    }
    private var availableButtons: [ProfileControl] {
        let used = page?.floatingMemberIDs ?? []
        return draft.controls(on: pageID).filter { $0.kind == .button && !used.contains($0.id) }
    }
    private func addRing() {
        guard let pageIndex = draft.pages.firstIndex(where: { $0.id == pageID }) else { return }
        var ring = FloatingRingZone()
        for (orientation, snapshot) in snapshots {
            let rectangle = FloatingRect(x: snapshot.width * 0.25, y: snapshot.height * 0.25,
                                         width: snapshot.width * 0.5, height: snapshot.height * 0.5)
            let geometry = FloatingZoneGeometry(canvasWidth: snapshot.width, canvasHeight: snapshot.height, zone: rectangle)
            if orientation == .portrait { ring.portraitGeometry = geometry } else { ring.landscapeGeometry = geometry }
        }
        var next = draft; next.pages[pageIndex].floatingRingZones.append(ring)
        do { try next.validate(); draft = next; editing = .ring(ring.id) }
        catch { self.error = error.localizedDescription }
    }
}

private enum FloatingEditorSelection: Identifiable {
    case buttons(UUID), ring(UUID)
    var id: UUID { switch self { case .buttons(let id), .ring(let id): id } }
}

@MainActor
private struct FloatingButtonCreationView: View {
    let profile: ControllerProfile
    let pageID: UUID
    let snapshots: [ControllerOrientation: FloatingCanvasSnapshot]
    let onCreated: (ControllerProfile, UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Floating buttons"
    @State private var selected = Set<UUID>()
    @State private var startID: UUID?
    @State private var groupSwipe = false
    @State private var error: String?
    private var buttons: [ProfileControl] {
        let used = profile.page(for: pageID)?.floatingMemberIDs ?? []
        return profile.controls(on: pageID).filter { $0.kind == .button && !used.contains($0.id) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Floating control name", text: $name) }
                Section("Choose buttons on this page") {
                    ForEach(buttons) { button in
                        Button {
                            if selected.contains(button.id) { selected.remove(button.id); if startID == button.id { startID = nil } }
                            else { selected.insert(button.id) }
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: selected.contains(button.id) ? "checkmark.circle.fill" : "circle")
                                Text(button.name).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityValue(selected.contains(button.id) ? "Selected" : "Not selected")
                    }
                }
                if selected.count > 1 {
                    Section("When the group appears") {
                        Picker("First touch", selection: $startID) {
                            Text("Show the group without pressing").tag(UUID?.none)
                            ForEach(buttons.filter { selected.contains($0.id) }) { Text("Press \($0.name)").tag(Optional($0.id)) }
                        }.pickerStyle(.menu)
                        Toggle("Slide between group buttons", isOn: $groupSwipe)
                    }
                }
                Section {
                    Text("One selected button becomes a single floating button. Multiple buttons become a group with their current spacing. Their original controls and positions stay saved. Finish needs an extra 48 points below the group.")
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .navigationTitle("Make buttons float").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(selected.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 64)
                }
            }
        }
    }
    private func create() {
        do {
            var next = profile
            let ids = buttons.filter { selected.contains($0.id) }.map(\.id)
            let id = try next.convertToFloatingButtons(on: pageID, memberIDs: ids,
                kind: ids.count == 1 ? .singleButton : .buttonGroup,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), startMemberID: startID,
                groupSwipe: groupSwipe, snapshots: snapshots)
            onCreated(next, id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct FloatingButtonZoneEditor: View {
    @State private var draft: ControllerProfile
    let pageID: UUID
    let zoneID: UUID
    let snapshots: [ControllerOrientation: FloatingCanvasSnapshot]
    let onSave: (ControllerProfile) -> Void
    let onUnfloat: (ControllerProfile, UUID, UUID) async throws -> ControllerProfile
    @Environment(\.dismiss) private var dismiss
    @State private var orientation: ControllerOrientation
    @State private var editMembers = false
    @State private var selectedMember: UUID?
    @State private var error: String?
    @State private var restoring = false
    @State private var restorationTask: Task<Void, Never>?
    init(profile: ControllerProfile, pageID: UUID, zoneID: UUID,
         snapshots: [ControllerOrientation: FloatingCanvasSnapshot],
         onUnfloat: @escaping (ControllerProfile, UUID, UUID) async throws -> ControllerProfile,
         onSave: @escaping (ControllerProfile) -> Void) {
        _draft = State(initialValue: profile); self.pageID = pageID; self.zoneID = zoneID
        self.snapshots = snapshots; self.onSave = onSave
        self.onUnfloat = onUnfloat
        _orientation = State(initialValue: snapshots[.portrait] != nil ? .portrait : .landscape)
    }
    private var pageIndex: Int? { draft.pages.firstIndex { $0.id == pageID } }
    private var zone: FloatingButtonZone? { draft.page(for: pageID)?.floatingButtonZones.first { $0.id == zoneID } }
    private var snapshot: FloatingCanvasSnapshot? { snapshots[orientation] }
    private var rectangle: FloatingRect? {
        guard let geometry = zone?.geometry(for: orientation), let snapshot else { return nil }
        return try? geometry.resolved(canvasWidth: snapshot.width, canvasHeight: snapshot.height)
    }
    var body: some View {
        NavigationStack {
            Form {
                if let zone {
                    Section("Floating control") {
                        TextField("Name", text: zoneBinding(\.name, fallback: zone.name))
                        Toggle("Enabled", isOn: zoneBinding(\.enabled, fallback: zone.enabled))
                        Toggle("Finish ignores swipes", isOn: zoneBinding(\.finishIgnoresSwipes, fallback: zone.finishIgnoresSwipes))
                        if zone.kind == .buttonGroup {
                            Picker("First touch", selection: zoneBinding(\.startMemberID, fallback: zone.startMemberID)) {
                                Text("Show without pressing").tag(UUID?.none)
                                ForEach(zone.memberIDs, id: \.self) { id in
                                    Text("Press \(draft.control(for: id)?.name ?? "Button")").tag(Optional(id))
                                }
                            }.pickerStyle(.menu)
                            Toggle("Slide between group buttons", isOn: zoneBinding(\.groupSwipe, fallback: zone.groupSwipe))
                        }
                        Text("Disabled zones keep their buttons hidden. Use Restore original buttons below to put them back on the normal controller.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Orientation") {
                        Picker("Edit orientation", selection: $orientation) {
                            Text("Portrait").tag(ControllerOrientation.portrait)
                            Text("Landscape").tag(ControllerOrientation.landscape)
                        }.pickerStyle(.segmented)
                        if snapshot == nil {
                            Text("View the controller in this orientation first so the app can measure its actual available space. Close this screen, rotate, then reopen it.")
                        } else if rectangle == nil {
                            Button("Prepare this orientation") { prepareOrientation() }
                            Text("Copies the activation area using this measured canvas. Button sizes and spacing stay unchanged.")
                        }
                    }
                    if let snapshot, let rectangle {
                        Section {
                            Picker("Move", selection: $editMembers) {
                                Text("Activation area").tag(false)
                                Text("Individual buttons").tag(true)
                            }.pickerStyle(.segmented)
                            FloatingButtonLayoutPreview(snapshot: snapshot, rectangle: rectangle,
                                members: (try? zone.resolvedMembers(for: orientation, canonical: snapshot.frames)) ?? [],
                                labels: Dictionary(uniqueKeysWithValues: draft.controls.map { ($0.id, $0.name) }),
                                editingMembers: editMembers, selectedMember: $selectedMember,
                                onMoveZone: setRectangle, onMoveMember: setMember)
                                .frame(height: 260)
                            Text(editMembers ? "Drag each button to arrange the summoned group. The original normal layout stays saved." : "Drag the outlined activation area. Touching that area while playing summons the control near your finger.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if editMembers {
                                Picker("Button to size", selection: $selectedMember) {
                                    Text("Choose a button").tag(UUID?.none)
                                    ForEach(zone.memberIDs, id: \.self) { id in Text(draft.control(for: id)?.name ?? "Button").tag(Optional(id)) }
                                }.pickerStyle(.menu)
                                if let id = selectedMember,
                                   let frame = (try? zone.resolvedMembers(for: orientation, canonical: snapshot.frames))?.first(where: { $0.id == id })?.frame {
                                    dimension("Button width", value: frame.width, maximum: min(1200, snapshot.width)) { value in
                                        var next = frame; next.width = value; setMember(id, next)
                                    }
                                    dimension("Button height", value: frame.height, maximum: min(1200, snapshot.height - 48)) { value in
                                        var next = frame; next.height = value; setMember(id, next)
                                    }
                                }
                            } else {
                                dimension("Area width", value: rectangle.width, maximum: snapshot.width) { value in
                                    var next = rectangle; next.width = value; next.x = min(next.x, snapshot.width - value); setRectangle(next)
                                }
                                dimension("Area height", value: rectangle.height, maximum: snapshot.height) { value in
                                    var next = rectangle; next.height = value; next.y = min(next.y, snapshot.height - value); setRectangle(next)
                                }
                            }
                        } header: { Text("Position and size") }
                    }
                    Section {
                        Button("Restore original buttons") {
                            restoring = true; error = nil
                            restorationTask = Task { @MainActor in
                                defer { restoring = false; restorationTask = nil }
                                do {
                                    let restored = try await onUnfloat(draft, zoneID, pageID)
                                    try Task.checkCancellation()
                                    draft = restored; onSave(restored); dismiss()
                                } catch {
                                    if !Task.isCancelled { self.error = error.localizedDescription }
                                }
                            }
                        }
                        if restoring { ProgressView("Restoring original layout…") }
                        Text("Removes this floating zone and restores its buttons at their original normal positions and sizes. Imported buttons use the preserved Android restoration layout, fitted to this iPhone. Names, actions and other settings remain. Save layout keeps the change; Cancel on the controller restores the previous layout.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .disabled(restoring)
            .interactiveDismissDisabled(restoring)
            .onDisappear { restorationTask?.cancel() }
            .navigationTitle("Edit floating buttons").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(restoring) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(draft); dismiss() }.disabled(restoring || (try? draft.validate()) == nil)
                }
            }
        }
    }
    private func zoneBinding<T>(_ path: WritableKeyPath<FloatingButtonZone, T>, fallback: T) -> Binding<T> {
        Binding(get: { zone?[keyPath: path] ?? fallback }, set: { value in
            guard let pageIndex, let index = draft.pages[pageIndex].floatingButtonZones.firstIndex(where: { $0.id == zoneID }) else { return }
            draft.pages[pageIndex].floatingButtonZones[index][keyPath: path] = value
        })
    }
    private func prepareOrientation() {
        guard let snapshot else { return }
        do { try draft.prepareFloatingButtonOrientation(zoneID, on: pageID, orientation: orientation, snapshot: snapshot); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func setRectangle(_ value: FloatingRect) {
        guard let snapshot else { return }
        do {
            try draft.setFloatingZoneGeometry(zoneID, on: pageID, orientation: orientation, rectangle: value,
                                              canvasWidth: snapshot.width, canvasHeight: snapshot.height); error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func setMember(_ id: UUID, _ value: FloatingRect) {
        guard let snapshot else { return }
        do { try draft.setFloatingMemberFrame(id, zoneID: zoneID, on: pageID, orientation: orientation, frame: value, snapshot: snapshot); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func dimension(_ title: String, value: Double, maximum: Double, onChange: @escaping (Double) -> Void) -> some View {
        let lower = min(44, maximum)
        return VStack(alignment: .leading) {
            Text("\(title): \(Int(value.rounded())) points")
            Slider(value: Binding(get: { min(maximum, max(lower, value)) }, set: { onChange($0) }), in: lower...max(lower + 1, maximum), step: 1)
                .accessibilityLabel(title).accessibilityValue("\(Int(value.rounded())) points")
        }
    }
}

/// Preview uses the measured canvas aspect ratio; drag deltas are converted back to iOS points.
@MainActor
private struct FloatingButtonLayoutPreview: View {
    let snapshot: FloatingCanvasSnapshot
    let rectangle: FloatingRect
    let members: [FloatingMemberGeometry]
    let labels: [UUID: String]
    let editingMembers: Bool
    @Binding var selectedMember: UUID?
    let onMoveZone: (FloatingRect) -> Void
    let onMoveMember: (UUID, FloatingRect) -> Void
    @State private var dragStart: FloatingRect?
    @State private var draggedMember: UUID?

    var body: some View {
        GeometryReader { space in
            let scale = min(space.size.width / snapshot.width, space.size.height / snapshot.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10))
                if !editingMembers {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.teal, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .background(Color.teal.opacity(0.12)).frame(width: rectangle.width * scale, height: rectangle.height * scale)
                        .offset(x: rectangle.x * scale, y: rectangle.y * scale)
                }
                ForEach(members, id: \.id) { member in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(member.id == selectedMember && editingMembers ? Color.orange.opacity(0.35) : Color.teal.opacity(0.25))
                        .overlay { Text(labels[member.id] ?? "Button").font(.caption2).lineLimit(2).padding(3) }
                        .frame(width: member.frame.width * scale, height: member.frame.height * scale)
                        .offset(x: member.frame.x * scale, y: member.frame.y * scale)
                }
            }
            .frame(width: snapshot.width * scale, height: snapshot.height * scale)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragStart == nil {
                    if editingMembers {
                        let point = FloatingPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                        guard let member = members.reversed().first(where: { $0.frame.contains(point) }) else { return }
                        draggedMember = member.id; selectedMember = member.id; dragStart = member.frame
                    } else { dragStart = rectangle }
                }
                guard var frame = dragStart else { return }
                frame.x = min(max(0, frame.x + value.translation.width / scale), max(0, snapshot.width - frame.width))
                frame.y = min(max(0, frame.y + value.translation.height / scale), max(0, snapshot.height - frame.height))
                if editingMembers, let id = draggedMember { onMoveMember(id, frame) }
                else if !editingMembers { onMoveZone(frame) }
            }.onEnded { _ in dragStart = nil; draggedMember = nil })
            .accessibilityLabel(editingMembers ? "Floating button arrangement preview" : "Floating activation area preview")
            .accessibilityHint("Drag the area or a button to move it. Size controls are below the preview.")
        }
    }
}

import SwiftUI
import ControllerCore

struct PracticeOutputSnapshot: Identifiable {
    let id = UUID()
    let state: PracticeOutputState
    let events: [PracticeOutputEvent]
    let omittedCount: Int
}

enum PracticeOutputFormatting {
    static func keys(_ state: PracticeOutputState) -> String {
        names(state.heldKeys.map(\.rawValue))
    }

    static func mouse(_ state: PracticeOutputState) -> String {
        names(state.heldMouseButtons.map(\.rawValue))
    }

    static func names(_ values: [String]) -> String {
        values.isEmpty ? "None" : values.sorted().joined(separator: " + ")
    }

    static func amount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    static func pointer(_ state: PracticeOutputState) -> String {
        "X \(amount(state.pointerOffset.dx)), Y \(amount(state.pointerOffset.dy))"
    }

    static func event(_ event: PracticeOutputEvent) -> String {
        switch event.kind {
        case .keyDown(let key): "Key \(key.rawValue) down"
        case .keyUp(let key): "Key \(key.rawValue) up"
        case .mouseDown(let button): "Mouse \(button.rawValue.lowercased()) down"
        case .mouseUp(let button): "Mouse \(button.rawValue.lowercased()) up"
        case .pointerMoved(let dx, let dy): "Pointer: X \(amount(dx)), Y \(amount(dy))"
        case .scrolled(let delta): "Scroll: \(amount(delta))"
        case .scrollModeChanged(let enabled): enabled ? "Scroll mode on" : "Pointer mode on"
        case .reset: "All input cleared"
        }
    }
}

/// Shared, visible camera state; it does not assign generated output to a
/// manual stick instance or change touch ownership.
enum CameraFollowPresentation {
    static func badge(_ snapshot: CameraFollowPracticeSnapshot?) -> String {
        guard let snapshot, snapshot.requestedEnabled else { return "OFF" }
        if snapshot.suppressed || [.manual, .manualOverride, .macro, .suppressed].contains(snapshot.source) { return "PAUSED" }
        return "ON"
    }

    static func status(_ snapshot: CameraFollowPracticeSnapshot?) -> String {
        guard let snapshot, snapshot.requestedEnabled else { return "Camera off" }
        if snapshot.mouseSuppressed { return "Camera paused by mouse" }
        if snapshot.manualRightContactActive || snapshot.source == .manual { return "Camera paused by aiming" }
        if snapshot.source == .manualOverride { return "Camera waiting after aiming" }
        if snapshot.source == .macro { return "Camera paused by stick command" }
        if snapshot.source == .suppressed { return "Camera paused by control" }
        return snapshot.source == .cameraFollow ? "Camera following" : "Camera on; move left stick"
    }
}

struct PracticeOutputHeader: View {
    let state: PracticeOutputState
    let showDesktop: Bool
    let showPointer: Bool
    let lastEvent: PracticeOutputEvent?
    var showCameraFollow = false
    var cameraFollowSnapshot: CameraFollowPracticeSnapshot? = nil

    var body: some View {
        VStack(spacing: 1) {
            if showCameraFollow {
                let generated = cameraFollowSnapshot?.generatedRightStick ?? .zero
                Text("Camera \(CameraFollowPresentation.badge(cameraFollowSnapshot)) · auto RS \(PracticeOutputFormatting.amount(generated.x)), \(PracticeOutputFormatting.amount(generated.y))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: 15)
                    .foregroundStyle(CameraFollowPresentation.badge(cameraFollowSnapshot) == "PAUSED" ? Color.orange : Color.primary)
            }
            HStack(spacing: 12) {
                Text("LT \(Int((state.leftTrigger * 100).rounded()))%  RT \(Int((state.rightTrigger * 100).rounded()))%")
                    .fixedSize()
                if showDesktop {
                    Text("Keys: \(PracticeOutputFormatting.keys(state))")
                        .lineLimit(1)
                }
            }
            if showDesktop {
                HStack(spacing: 12) {
                    Text("Mouse: \(PracticeOutputFormatting.mouse(state))")
                        .lineLimit(1)
                    if let lastEvent {
                        Text(PracticeOutputFormatting.event(lastEvent))
                            .lineLimit(1)
                    }
                }
            }
            if showPointer {
                HStack(spacing: 12) {
                    Text(PracticeOutputFormatting.pointer(state))
                        .lineLimit(1)
                    Text("Scroll \(state.scrollModeEnabled ? "ON" : "OFF") · \(PracticeOutputFormatting.amount(state.scrollOffset))")
                        .lineLimit(1)
                }
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .allowsHitTesting(false)
    }

    private var accessibilitySummary: String {
        var text = "Trigger pressure: left \(Int(state.leftTrigger * 100)) percent, right \(Int(state.rightTrigger * 100)) percent."
        if showCameraFollow {
            let generated = cameraFollowSnapshot?.generatedRightStick ?? .zero
            text += " \(CameraFollowPresentation.status(cameraFollowSnapshot)). Generated right stick horizontal \(PracticeOutputFormatting.amount(generated.x)), vertical \(PracticeOutputFormatting.amount(generated.y))."
        }
        if showDesktop {
            text += " Keys held: \(PracticeOutputFormatting.keys(state)). Mouse buttons held: \(PracticeOutputFormatting.mouse(state))."
            if let lastEvent { text += " Last event: \(PracticeOutputFormatting.event(lastEvent))." }
        }
        if showPointer {
            text += " Pointer displacement: \(PracticeOutputFormatting.pointer(state)). Scroll mode \(state.scrollModeEnabled ? "on" : "off"), total \(PracticeOutputFormatting.amount(state.scrollOffset)). Relative movement units."
        }
        return text
    }
}

struct PracticeOutputHistoryView: View {
    let snapshot: PracticeOutputSnapshot
    let clearHistory: () -> Void
    @State private var cleared = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Opening this view released all controls. The values below were captured just before it opened.")
                    Text("This history previews keyboard and mouse actions in Practice, where nothing is sent. computer receiver mode sends those actions to its receiver; the console bridge does not send them.")
                }
                Section("At capture") {
                    LabeledContent("Keys", value: PracticeOutputFormatting.keys(snapshot.state))
                    LabeledContent("Mouse buttons", value: PracticeOutputFormatting.mouse(snapshot.state))
                    LabeledContent("Left trigger", value: "\(Int(snapshot.state.leftTrigger * 100))%")
                    LabeledContent("Right trigger", value: "\(Int(snapshot.state.rightTrigger * 100))%")
                    LabeledContent("Pointer displacement", value: PracticeOutputFormatting.pointer(snapshot.state))
                    LabeledContent("Scroll displacement", value: PracticeOutputFormatting.amount(snapshot.state.scrollOffset))
                    LabeledContent("Touchpad mode", value: snapshot.state.scrollModeEnabled ? "Scrolling" : "Pointer")
                    Text("Displacements are relative Practice units based on finger movement and sensitivity. Positive X moves right, positive Y moves down. Upward touchpad movement produces positive scrolling. Release all resets these totals.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if cleared || snapshot.events.isEmpty {
                        Text("No keyboard or mouse events yet.")
                    } else {
                        ForEach(snapshot.events, id: \.sequence) { event in
                            Text(PracticeOutputFormatting.event(event))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } header: {
                    Text("Recent events · oldest first")
                } footer: {
                    Text("The most recent 32 events are shown. A click appears as down followed by up, even when both happen in one sequence. Release all keeps this history; changing modes or saving profiles clears it.")
                    if !cleared && snapshot.omittedCount > 0 {
                        Text("\(snapshot.omittedCount) earlier events are not shown.")
                    }
                }
            }
            .navigationTitle("Practice output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Clear history") {
                        clearHistory()
                        cleared = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

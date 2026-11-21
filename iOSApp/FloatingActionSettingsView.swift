import SwiftUI
import ControllerCore

/// Edits one explicit identity; a missing target never silently becomes another control.
@MainActor
struct FloatingActionSettingsView: View {
    @Binding var control: ProfileControl
    let page: ProfilePage?
    let controls: [ProfileControl]
    @State private var expanded = false

    private struct TargetChoice: Identifiable {
        let target: ProfileFloatingActionTarget
        let title: String
        var id: String {
            switch target {
            case let .zone(id): return "zone-\(id)"
            case let .control(id): return "control-\(id)"
            }
        }
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                Toggle("Use a floating-control action", isOn: Binding(
                    get: { control.floatingAction != nil }, set: { setEnabled($0) }))
                    .disabled(control.floatingAction == nil && firstBinding == nil)
                if let binding = control.floatingAction {
                    ForEach(FloatingLocalAction.allCases, id: \.self) { action in
                        choiceRow(actionTitle(action), selected: binding.action == action) { select(action) }
                            .disabled(targets(for: action).isEmpty && binding.action != action)
                    }
                    Text("Target").font(.subheadline.weight(.semibold))
                    let choices = targets(for: binding.action)
                    ForEach(choices) { choice in
                        choiceRow(choice.title, selected: binding.target == choice.target) {
                            assign(.init(action: binding.action, target: choice.target))
                        }
                    }
                    if !choices.contains(where: { $0.target == binding.target }) {
                        Label("The saved target is unavailable on this page. This button will do nothing until you select an available target.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Use a direct tap. This action ignores global Hold and Turbo and cannot start by sliding. It affects only the selected control; an inactive floating control stays inactive.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Your ordinary payload and checkbox actions are kept but do not run while this option is on. Turning it on disables Macro Mode, Hold to toggle, Auto-Tap, Directional button and Button Aim.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(firstBinding == nil
                         ? "Create a floating control, or add another control on this page, before assigning an action."
                         : "Make a movable button that finishes a floating control, stops a ring's firing, releases its ADS action, or ends Camera Follow suppression.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } label: {
                Text(control.floatingAction.map { actionTitle($0.action) } ?? "Floating-control action")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var firstBinding: ProfileFloatingActionBinding? {
        for action in FloatingLocalAction.allCases {
            if let target = targets(for: action).first { return .init(action: action, target: target.target) }
        }
        return nil
    }

    private func targets(for action: FloatingLocalAction) -> [TargetChoice] {
        guard let page else { return [] }
        var result: [TargetChoice] = []
        if action == .finish {
            result += page.floatingButtonZones.map { .init(target: .zone($0.id), title: $0.name) }
        }
        result += page.floatingRingZones.map { .init(target: .zone($0.id), title: $0.name) }
        if action == .endSuppression {
            let ids = Set(page.controlIDs)
            result += controls.filter { ids.contains($0.id) && $0.id != control.id && !$0.isLocalAction }
                .map { .init(target: .control($0.id), title: $0.name) }
        }
        return result
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled, let binding = firstBinding { assign(binding); expanded = true }
        else if !enabled { control.floatingAction = nil }
    }
    private func select(_ action: FloatingLocalAction) {
        let choices = targets(for: action)
        guard let first = choices.first else { return }
        let target = choices.first { $0.target == control.floatingAction?.target }?.target ?? first.target
        assign(.init(action: action, target: target))
    }
    private func assign(_ binding: ProfileFloatingActionBinding) {
        control.floatingAction = binding
        control.macroModeEnabled = false
        control.buttonBehavior.holdToggle = false; control.autoTapEnabled = false
        control.buttonDirectional.enabled = false; control.buttonAim.enabled = false
        control.buttonAim.alternate.enabled = false; control.buttonAim.payloadTiming = .immediate
    }
    private func actionTitle(_ action: FloatingLocalAction) -> String {
        switch action {
        case .finish: "Finish floating control"
        case .stopFire: "Stop firing"
        case .releaseADS: "Release ADS"
        case .endSuppression: "End camera suppression"
        }
    }
    private func choiceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

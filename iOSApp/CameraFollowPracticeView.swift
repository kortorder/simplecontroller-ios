import SwiftUI
import ControllerCore

struct CameraFollowPracticeView: View {
    let snapshot: CameraFollowPracticeSnapshot
    let enabled: Bool
    let onEnable: (Bool) -> Void
    let onStrength: (Double) -> Void

    var body: some View {
        Group {
            Button {
                onEnable(!snapshot.requestedEnabled)
            } label: {
                HStack {
                    Label("Camera Follow", systemImage: "camera")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(CameraFollowPresentation.badge(snapshot))
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Camera Follow")
            .accessibilityValue(CameraFollowPresentation.badge(snapshot).capitalized)
            .accessibilityHint("Tap to turn Camera Follow on or off in Practice.")
            .disabled(!enabled)

            VStack(alignment: .leading, spacing: 8) {
                Text(status).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if snapshot.requestedEnabled {
                    Text("Right stick: X \(amount(snapshot.rightStick.x)) · Y \(amount(snapshot.rightStick.y))")
                        .font(.caption.monospacedDigit())
                        .accessibilityLabel("Practice right stick horizontal \(amount(snapshot.rightStick.x)), vertical \(amount(snapshot.rightStick.y))")
                }
                Text("Strength: \(Int(snapshot.strengthPercent.rounded()))%").font(.subheadline.weight(.semibold))
                Slider(value: Binding(get: { snapshot.strengthPercent }, set: { onStrength($0) }), in: 0...200, step: 1)
                    .accessibilityLabel("Camera Follow strength")
                    .accessibilityValue("\(Int(snapshot.strengthPercent.rounded())) percent")
                    .disabled(!enabled)
                Text("Camera buttons use their saved strength. Release all turns Camera Follow off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func amount(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
    private var status: String {
        guard snapshot.requestedEnabled else { return "Off. Turn it on to try camera assistance with your left stick." }
        if snapshot.mouseSuppressed { return "Paused by a mouse action. Release all, then turn Camera Follow on again to resume." }
        if snapshot.manualRightContactActive { return "Paused while another control owns the right stick." }
        switch snapshot.source {
        case .cameraFollow: return "Following left-stick movement. Your own aiming takes priority."
        case .macro: return "A fixed stick command has control of the right stick."
        case .manual: return "Your own right-stick movement has control."
        case .manualOverride: return "Waiting briefly after your own aiming."
        case .suppressed: return "Paused by the current control."
        case .neutral: return "Ready. Move an eligible left-stick control to try it."
        }
    }
}

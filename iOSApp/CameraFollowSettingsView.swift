import SwiftUI
import ControllerCore

/// Settings only: the parent engine enables execution for Practice or a compatible computer receiver.
@MainActor
struct CameraFollowSettingsView: View {
    @Binding var control: ProfileControl
    var onActionChanged: () -> Void = { }
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                if control.kind == .button {
                    Button("Use Camera Follow toggle") { use("CAMERA_FOLLOW") }
                    Button("Use Camera Follow on") { use("CAMERA_FOLLOW:1") }
                    Button("Use Camera Follow off") { use("CAMERA_FOLLOW:0") }
                    Text("These choices replace this button's custom payload and turn off Macro Mode, Hold to toggle, Auto-Tap, Directional button and Button Aim. Saved checkbox actions remain available if you turn Custom payload off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if control.isCameraFollowAction {
                    Text("Strength: \(control.cameraFollowStrengthPercent.formatted(.number.precision(.fractionLength(0...2))))%")
                    Slider(value: $control.cameraFollowStrengthPercent, in: 0...200, step: 1)
                        .accessibilityLabel("Camera Follow strength")
                    Stepper("Change strength", value: $control.cameraFollowStrengthPercent, in: 0...200, step: 1)
                        .accessibilityValue("\(control.cameraFollowStrengthPercent.formatted()) percent")
                    Text("This button applies its strength when tapped. 100% uses the original response; zero stops generated turning without disabling your own stick input. These actions require a direct tap and ignore global Hold and Turbo.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if control.kind != .recenter && control.kind != .pageButton && !control.isLocalAction {
                    Toggle("Exclude movement from Camera Follow", isOn: $control.excludeFromCameraFollow)
                    Text("When this control supplies the left-stick movement, that movement will not steer the camera. The setting also applies if the movement is retained after lift.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Mouse output pauses Camera Follow", isOn: $control.mouseSuppressCameraFollow)
                    Text("The first mouse output from this control pauses Camera Follow. Lifting your finger does not resume it. Use Release all, then enable Camera Follow again. Other controls keep their own mouse ownership.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Camera Follow generates gentle horizontal right-stick movement from left-stick travel. Preview it in Practice or send it with a compatible computer receiver. A manual right-stick touch takes priority, even when centered. The console bridge does not send this generated movement.")
                    .font(.footnote).foregroundStyle(.secondary)
            } label: {
                Text(control.isCameraFollowAction ? "Camera Follow action" : "Camera Follow")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func use(_ payload: String) {
        control.payload = payload
        control.macroModeEnabled = false
        control.buttonBehavior.holdToggle = false; control.autoTapEnabled = false
        control.buttonDirectional.enabled = false; control.buttonAim.enabled = false
        expanded = true; onActionChanged()
    }
}

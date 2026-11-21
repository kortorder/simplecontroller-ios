import Foundation

extension ProfileControl {
    /// Global Hold applies only to ordinary buttons. Explicit Hold Toggle, AutoTap, advanced gestures
    /// and local safety/navigation actions keep their own behavior.
    public var supportsGlobalHold: Bool {
        kind == .button && !buttonBehavior.holdToggle && !autoTapEnabled && !isAdvancedButton &&
            !isLocalAction && ((try? payloadProgram().hasAnyOutput) == true)
    }
}

extension ControllerProfile {
    func usesGlobalHold(for control: ProfileControl) -> Bool {
        guard globalHoldEnabled, control.supportsGlobalHold, let program = try? control.payloadProgram() else { return false }
        return !(turboEnabled && !program.containsWaitOrPulse)
    }
}

import Foundation

extension ControllerProfile {
    /// An explicit draft edit, not a persistent global override. Touch Aim always centers.
    /// Returns the number of controls changed; validation is atomic before replacing the profile.
    @discardableResult
    public mutating func setAllAutoCenter(_ enabled: Bool) throws -> Int {
        var draft = self, changed = 0
        for index in draft.controls.indices {
            var control = draft.controls[index]
            let before = control
            if control.kind.isStick { control.stickBehavior.autoCenter = enabled }
            if control.kind == .button && control.buttonAim.enabled {
                control.buttonAim.tuning.autoCenter = enabled
                control.buttonAim.alternate.tuning.autoCenter = enabled
            }
            if control != before { changed += 1; draft.controls[index] = control }
        }
        try draft.validate()
        self = draft
        return changed
    }
}

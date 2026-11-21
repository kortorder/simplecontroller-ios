import UIKit

/// Semantic dynamic colors shared by SwiftUI chrome and the custom UIKit canvas.
/// Root applies the selected color scheme; System resolves from the current traits.
@MainActor
enum ControllerAppearancePalette {
    static let background = dynamic(dark: (0.035, 0.06, 0.11), light: (0.94, 0.96, 0.98))
    static let canvasBackground = dynamic(dark: (0.035, 0.065, 0.12), light: (0.98, 0.99, 1))
    static let well = dynamic(dark: (0.075, 0.13, 0.20), light: (0.86, 0.91, 0.95))
    static let accent = dynamic(dark: (0.35, 0.93, 0.76), light: (0.02, 0.38, 0.30))
    static let cyan = dynamic(dark: (0.28, 0.84, 0.94), light: (0.02, 0.36, 0.48))
    static let green = dynamic(dark: (0.55, 0.93, 0.61), light: (0.12, 0.38, 0.17))
    static let muted = dynamic(dark: (0.60, 0.69, 0.78), light: (0.30, 0.37, 0.44))
    static let selection = dynamic(dark: (1, 0.77, 0.32), light: (0.51, 0.30, 0.02))
    static let label = UIColor.label
    static let inverseLabel = dynamic(dark: (0.035, 0.065, 0.12), light: (1, 1, 1))

    private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
        }
    }
}

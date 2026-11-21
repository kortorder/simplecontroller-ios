import SwiftUI
import ControllerCore

@MainActor
struct ControlOrientationSizeSettings: View {
    @Binding var control: ProfileControl
    @State private var orientation: ControllerOrientation
    @State private var confirmingShared = false

    init(control: Binding<ProfileControl>, initialOrientation: ControllerOrientation) {
        _control = control; _orientation = State(initialValue: initialOrientation)
    }

    var body: some View {
        Group {
            Toggle("Separate portrait and landscape sizes", isOn: Binding(
                get: { !control.orientationDimensions.isEmpty }, set: { setSeparate($0) }))
                .confirmationDialog("Return to the shared size?", isPresented: $confirmingShared, titleVisibility: .visible) {
                    Button("Use shared size") { control.orientationDimensions = .init() }
                    Button("Keep separate sizes", role: .cancel) { }
                } message: {
                    Text("Both orientations will use the shared size of \(Int(control.resolvedWidth.rounded())) × \(Int(control.resolvedHeight.rounded())) points. The separate sizes will be removed from this draft. Cancel the control editor to discard this change.")
                }
            if !control.orientationDimensions.isEmpty {
                ForEach([ControllerOrientation.portrait, .landscape], id: \.self) { value in
                    Button {
                        orientation = value
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: orientation == value ? "checkmark.circle.fill" : "circle")
                            Text(value == .portrait ? "Portrait size" : "Landscape size").foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(orientation == value ? "Selected" : "Not selected")
                }
                dimensionRow("Width", width: true)
                dimensionRow("Height", width: false)
                Text("Saved size: \(sizeSummary(.portrait)) portrait; \(sizeSummary(.landscape)) landscape. A larger control fits within the available screen without changing its saved size.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setSeparate(_ enabled: Bool) {
        if enabled {
            let portrait = control.dimensions(for: .portrait), landscape = control.dimensions(for: .landscape)
            control.orientationDimensions = .init(portrait: portrait, landscape: landscape)
        } else { confirmingShared = true }
    }
    private func dimension(_ width: Bool) -> Binding<Double> {
        Binding(get: {
            let size = control.dimensions(for: orientation)
            return width ? size.width : size.height
        }, set: { value in
            var size = control.dimensions(for: orientation)
            if width { size.width = value } else { size.height = value }
            control.orientationDimensions.set(size, for: orientation)
        })
    }
    private func dimensionRow(_ title: String, width: Bool) -> some View {
        let value = dimension(width), range = control.minimumDiameter...1200.0
        let scope = orientation == .portrait ? "Portrait" : "Landscape"
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(scope) \(title.lowercased()): \(Int(value.wrappedValue.rounded())) points")
                .fixedSize(horizontal: false, vertical: true)
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel("\(scope) control \(title.lowercased())")
            Stepper("Change \(title.lowercased())", value: value, in: range, step: 1)
                .accessibilityLabel("\(scope) control \(title.lowercased())")
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) points")
        }.padding(.vertical, 4)
    }
    private func sizeSummary(_ orientation: ControllerOrientation) -> String {
        let size = control.dimensions(for: orientation)
        return "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }
}

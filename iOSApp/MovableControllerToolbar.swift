import SwiftUI
import ControllerCore

@MainActor
final class ControllerToolbarPositionModel: ObservableObject {
    static let shared = ControllerToolbarPositionModel()
    @Published private(set) var positions: [String: ControllerToolbarAnchor] = [:]
    @Published private(set) var verticalToolbars: [String: Bool] = [:]
    @Published private(set) var topMenuMinimized = false
    @Published private(set) var actionsMenuMinimized = false
    private let store: ControllerToolbarPositionStore
    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimpleController", isDirectory: true)
        store = ControllerToolbarPositionStore(url: folder.appendingPathComponent("toolbar-positions.json"))
        let settings = (try? store.loadSettings()) ?? .init()
        positions = settings.positions
        verticalToolbars = settings.verticalToolbars
        topMenuMinimized = settings.topMenuMinimized
        actionsMenuMinimized = settings.actionsMenuMinimized
    }
    func save(_ anchor: ControllerToolbarAnchor, key: String) throws {
        var next = positions; next[key] = anchor
        try store.save(next)
        positions = next
    }
    func resetAll() throws {
        try store.save([:])
        positions = [:]
    }
    func setVertical(_ value: Bool, for toolbarID: String) throws {
        try store.saveVertical(value, for: toolbarID)
        verticalToolbars[toolbarID] = value
    }
    func setTopMenuMinimized(_ value: Bool) throws {
        try store.saveTopMenuMinimized(value)
        topMenuMinimized = value
    }
    func setActionsMenuMinimized(_ value: Bool) throws {
        try store.saveActionsMenuMinimized(value)
        actionsMenuMinimized = value
    }
}

/// A completed drag only moves this button. Opening the menu requires a tap
/// that stayed within the small movement tolerance for its whole contact.
@MainActor
struct MovableControllerMenuButton: View {
    let orientation: ControllerOrientation
    let screenSize: CGSize
    let safeInsets: EdgeInsets
    var id: String = "menuButton"
    var label: String = "Open menu"
    var symbol: String = "line.3.horizontal"
    var defaultAnchor: CGPoint = CGPoint(x: 1, y: 0)
    var onMove: () -> Void = {}
    let reopen: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var positions = ControllerToolbarPositionModel.shared
    @State private var dragStart: ControllerToolbarAnchor?
    @State private var dragAnchor: ControllerToolbarAnchor?
    @State private var isDragging = false
    @State private var saveError: String?

    private var key: String { "\(id).\(orientation.rawValue)" }
    private var anchor: ControllerToolbarAnchor {
        dragAnchor ?? positions.positions[key] ?? .init(x: Double(defaultAnchor.x), y: Double(defaultAnchor.y))
    }
    private var geometry: ControllerToolbarGeometry {
        ControllerToolbarGeometry(screenWidth: Double(screenSize.width), screenHeight: Double(screenSize.height),
            safeTop: Double(safeInsets.top), safeBottom: Double(safeInsets.bottom),
            safeLeft: Double(safeInsets.leading), safeRight: Double(safeInsets.trailing),
            requestedWidth: 44, requestedHeight: 44)
    }

    var body: some View {
        let center = geometry.center(for: anchor)
        accessibleCircle
            .position(x: CGFloat(center.x), y: CGFloat(center.y))
            .onChange(of: orientation) { _, _ in cancelDrag() }
            .onChange(of: screenSize) { _, _ in cancelDrag() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cancelDrag() }
            }
            .onDisappear { cancelDrag() }
            .alert("Menu position not saved", isPresented: errorPresented) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
    }

    private var circleVisual: some View {
        Circle()
            .fill(.regularMaterial)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
            .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    private var interactiveCircle: some View {
        circleVisual
            .gesture(menuGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("toolbar.\(id)")
            .accessibilityHint("Tap to show the menu. Drag to move this button.")
            .accessibilityAddTraits(.isButton)
    }

    private var accessibleCircle: some View {
        interactiveCircle
            .accessibilityAction { openMenu() }
            .accessibilityAction(named: Text("Move to top")) { move(x: anchor.x, y: 0) }
            .accessibilityAction(named: Text("Move to bottom")) { move(x: anchor.x, y: 1) }
            .accessibilityAction(named: Text("Move to left")) { move(x: 0, y: anchor.y) }
            .accessibilityAction(named: Text("Move to right")) { move(x: 1, y: anchor.y) }
            .accessibilityAction(named: Text("Reset position")) { move(x: Double(defaultAnchor.x), y: Double(defaultAnchor.y)) }
    }

    private var menuGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in dragChanged(value) }
            .onEnded { value in dragEnded(value) }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private func crossesDragThreshold(_ translation: CGSize) -> Bool {
        let dx = Double(translation.width), dy = Double(translation.height)
        return dx * dx + dy * dy > 36
    }

    private func movedAnchor(from start: ControllerToolbarAnchor, by translation: CGSize) -> ControllerToolbarAnchor {
        geometry.moved(start, dx: Double(translation.width), dy: Double(translation.height))
    }

    private func dragChanged(_ value: DragGesture.Value) {
        guard scenePhase == .active else { cancelDrag(); return }
        if dragStart == nil { dragStart = anchor }
        if !isDragging && crossesDragThreshold(value.translation) {
            isDragging = true
            onMove()
        }
        if isDragging {
            dragAnchor = movedAnchor(from: dragStart ?? anchor, by: value.translation)
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        guard scenePhase == .active, let start = dragStart else { cancelDrag(); return }
        let dragged = isDragging || crossesDragThreshold(value.translation)
        if dragged {
            let final = movedAnchor(from: start, by: value.translation)
            if !isDragging { onMove() }
            save(final)
        } else { openMenu() }
        cancelDrag()
    }

    private func openMenu() { cancelDrag(); onMove(); reopen() }
    private func move(x: Double, y: Double) { cancelDrag(); onMove(); save(.init(x: x, y: y)) }
    private func save(_ value: ControllerToolbarAnchor) {
        do { try positions.save(value, key: key) }
        catch { saveError = error.localizedDescription }
    }
    private func cancelDrag() { dragStart = nil; dragAnchor = nil; isDragging = false }
}

private struct ToolbarContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Only the visible handle moves the panel. Controller touches beneath its
/// surrounding transparent area continue to reach the full-screen canvas.
@MainActor
struct MovableControllerToolbar<Content: View>: View {
    let id: String
    let title: String
    let orientation: ControllerOrientation
    let screenSize: CGSize
    let safeInsets: EdgeInsets
    let defaultAnchor: CGPoint
    let width: CGFloat
    var allowsVertical: Bool = true
    var verticalWidth: CGFloat = 84
    var onMove: () -> Void = {}
    var onMinimize: (() -> Void)? = nil
    @ViewBuilder let content: (Bool) -> Content
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var positions = ControllerToolbarPositionModel.shared
    @State private var contentHeight: CGFloat = 100
    @State private var dragAnchor: ControllerToolbarAnchor?
    @State private var dragStart: ControllerToolbarAnchor?
    @State private var saveError: String?
    @State private var showingPositions = false

    private var key: String { "\(id).\(orientation.rawValue)" }
    private var isVertical: Bool { allowsVertical && positions.verticalToolbars[id] == true }
    private var anchor: ControllerToolbarAnchor {
        dragAnchor ?? positions.positions[key] ?? .init(x: defaultAnchor.x, y: defaultAnchor.y)
    }
    private var geometry: ControllerToolbarGeometry {
        .init(screenWidth: screenSize.width, screenHeight: screenSize.height,
              safeTop: safeInsets.top, safeBottom: safeInsets.bottom, safeLeft: safeInsets.leading, safeRight: safeInsets.trailing,
              requestedWidth: isVertical ? min(width, verticalWidth) : width, requestedHeight: contentHeight + 36)
    }
    private var scrollHeight: CGFloat { max(0, geometry.height - 36) }
    private var isOverflowing: Bool { contentHeight > scrollHeight + 1 }

    var body: some View {
        let center = geometry.center(for: anchor)
        VStack(spacing: 0) {
            compactHeader
            ScrollView(.vertical) {
                content(isVertical)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ToolbarContentHeightKey.self, value: proxy.size.height)
                    })
            }
            .scrollDisabled(!isOverflowing)
            .scrollIndicators(isOverflowing ? .visible : .hidden)
            .frame(height: scrollHeight)
            .overlay(alignment: .bottomTrailing) {
                if isOverflowing {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.caption).padding(3).background(.regularMaterial, in: Circle())
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        }
        .frame(width: geometry.width, height: geometry.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.18), lineWidth: 1).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .position(x: center.x, y: center.y)
        .onPreferenceChange(ToolbarContentHeightKey.self) { value in
            if value.isFinite && abs(value - contentHeight) > 0.5 { contentHeight = max(0, value) }
        }
        .onChange(of: orientation) { _, _ in cancelDrag() }
        .onChange(of: screenSize) { _, _ in cancelDrag() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelDrag() }
        }
        .onDisappear { cancelDrag() }
        .sheet(isPresented: $showingPositions) {
            NavigationStack {
                List {
                    if allowsVertical {
                        Section {
                            Toggle("Vertical toolbar", isOn: Binding(get: { isVertical }, set: { value in
                                cancelDrag()
                                onMove()
                                do { try positions.setVertical(value, for: id) }
                                catch { saveError = error.localizedDescription }
                            }))
                            .accessibilityIdentifier("toolbar.\(id).vertical")
                        } footer: {
                            Text("Off: buttons run horizontally. On: buttons stack vertically. This choice applies in portrait and landscape.")
                        }
                    }
                    Section {
                        positionChoice("Top") { move(x: anchor.x, y: 0) }
                        positionChoice("Bottom") { move(x: anchor.x, y: 1) }
                        positionChoice("Left") { move(x: 0, y: anchor.y) }
                        positionChoice("Right") { move(x: 1, y: anchor.y) }
                    } header: { Text("Move \(title)") }
                    footer: { Text("Choose a screen edge, or drag the toolbar's Move handle to place it anywhere.") }
                    Section {
                        positionChoice("Reset position") { move(x: defaultAnchor.x, y: defaultAnchor.y) }
                        positionChoice("Reset all toolbars") {
                            do { try positions.resetAll() }
                            catch { saveError = error.localizedDescription }
                        }
                    } footer: { Text("Portrait and landscape positions are saved separately. Reset all toolbars restores positions in both orientations and keeps your horizontal or vertical choice.") }
                }
                .accessibilityIdentifier("toolbar.position.list")
                .navigationTitle("Toolbar position")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingPositions = false }
                    }
                }
                .alert("Toolbar position not saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                    Button("OK", role: .cancel) { saveError = nil }
                } message: { Text(saveError ?? "") }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert("Toolbar position not saved", isPresented: Binding(get: { saveError != nil && !showingPositions }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private var compactHeader: some View {
        HStack(spacing: 0) {
            dragHandle
            Button {
                cancelDrag()
                onMove()
                showingPositions = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) position")
            .accessibilityIdentifier("toolbar.\(id).position")
            if let onMinimize {
                Button {
                    cancelDrag()
                    onMove()
                    onMinimize()
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize \(title) menu")
                .accessibilityIdentifier("toolbar.\(id).minimize")
            }
        }
        .frame(height: 28)
        .background(Color.primary.opacity(0.045))
    }

    private var dragHandle: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .gesture(toolbarDragGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Move \(title)")
            .accessibilityHint("Drag this handle, or open toolbar positions.")
            .accessibilityAction(named: "Move to top") { move(x: anchor.x, y: 0) }
            .accessibilityAction(named: "Move to bottom") { move(x: anchor.x, y: 1) }
            .accessibilityAction(named: "Move to left") { move(x: 0, y: anchor.y) }
            .accessibilityAction(named: "Move to right") { move(x: 1, y: anchor.y) }
    }

    private var toolbarDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if dragStart == nil { dragStart = anchor; onMove() }
                dragAnchor = geometry.moved(dragStart ?? anchor, dx: Double(value.translation.width), dy: Double(value.translation.height))
            }
            .onEnded { _ in
                if let dragAnchor { save(dragAnchor) }
                cancelDrag()
            }
    }

    private func positionChoice(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            if saveError == nil { showingPositions = false }
        } label: {
            Text(label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    // A system interruption can cancel a DragGesture without calling onEnded.
    // Restore the last saved anchor rather than retaining an unfinished drag.
    private func cancelDrag() { dragAnchor = nil; dragStart = nil }
    private func move(x: Double, y: Double) { onMove(); save(.init(x: x, y: y)) }
    private func save(_ anchor: ControllerToolbarAnchor) {
        do { try positions.save(anchor, key: key) }
        catch { saveError = error.localizedDescription }
    }
}

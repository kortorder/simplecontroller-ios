import ControllerCore
import SwiftUI
import UIKit

/// UIKit owns live touches; saved geometry is independent of game input.
struct ControllerCanvas: UIViewRepresentable {
    var state: GamepadState
    var enabled: Bool
    var layout: ControllerLayout
    var orientation: ControllerOrientation
    var editing: Bool
    var allowExtendedControls: Bool
    var latchedControls: Set<ControllerControlID>
    var retainedSticks: Set<ControllerControlID>
    var onLayoutChange: (ControllerLayout) -> Void
    var onInput: (ControllerInputEvent) -> Void
    var onConfigure: ((ControllerControlID) -> Void)? = nil

    func makeUIView(context: Context) -> ControllerCanvasView {
        let view = ControllerCanvasView()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: ControllerCanvasView, context: Context) { configure(uiView) }

    private func configure(_ view: ControllerCanvasView) {
        view.configure(state: state, enabled: enabled, layout: layout,
                       orientation: orientation, editing: editing,
                       allowExtendedControls: allowExtendedControls,
                       latchedControls: latchedControls, retainedSticks: retainedSticks,
                       onLayoutChange: onLayoutChange, onInput: onInput, onConfigure: onConfigure)
    }

    static func dismantleUIView(_ uiView: ControllerCanvasView, coordinator: ()) { uiView.stopInput() }
}

final class ControllerCanvasView: UIView, UIGestureRecognizerDelegate {
    private enum Capture {
        case stick(ControllerControlID)
        case button(ControllerControlID?)
    }

    private struct Item {
        let id: ControllerControlID
        let center: CGPoint
        let radius: CGFloat
        var frame: CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
        func contains(_ point: CGPoint) -> Bool {
            hypot(point.x - center.x, point.y - center.y) <= radius
        }
    }

    private struct LayoutDrag {
        let touchID: ObjectIdentifier
        let controlID: ControllerControlID
        let offset: CGPoint
    }

    private static let background = UIColor(red: 0.035, green: 0.065, blue: 0.12, alpha: 1)
    private static let well = UIColor(red: 0.075, green: 0.13, blue: 0.20, alpha: 1)
    private static let cyan = UIColor(red: 0.28, green: 0.84, blue: 0.94, alpha: 1)
    private static let green = UIColor(red: 0.55, green: 0.93, blue: 0.61, alpha: 1)
    private static let muted = UIColor(red: 0.60, green: 0.69, blue: 0.78, alpha: 1)
    private static let selectionColor = UIColor(red: 1, green: 0.77, blue: 0.32, alpha: 1)

    private var controllerLayout = ControllerLayout.default
    private var orientation: ControllerOrientation = .portrait
    private var items: [Item] = []
    private var captures: [ObjectIdentifier: Capture] = [:]
    private var contactIDs: [ObjectIdentifier: Int] = [:]
    private var nextContactID = 0
    private var engineInputMayBeActive = false
    private var drag: LayoutDrag?
    private var selectedID: ControllerControlID?
    private var displayedState = GamepadState.neutral
    private var latchedControls: Set<ControllerControlID> = []
    private var retainedSticks: Set<ControllerControlID> = []
    private var inputEnabled = false
    private var editing = false
    private var allowExtendedControls = true
    private var onInput: ((ControllerInputEvent) -> Void)?
    private var onConfigure: ((ControllerControlID) -> Void)?
    private var onLayoutChange: ((ControllerLayout) -> Void)?
    private var previousSize = CGSize.zero
    private var pendingCancellations: [() -> Void] = []
    private var accessibilityControls: [ControllerControlID: CanvasAccessibilityControl] = [:]
    private lazy var configurePress: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(configureLongPressed(_:)))
        recognizer.minimumPressDuration = 0.5
        recognizer.allowableMovement = 8
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityIdentifier = "controller.touchCanvas"
        addGestureRecognizer(configurePress)
        configurePress.isEnabled = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("ControllerCanvasView is created programmatically") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configure(state: GamepadState, enabled: Bool, layout: ControllerLayout,
                   orientation: ControllerOrientation, editing: Bool,
                   allowExtendedControls: Bool,
                   latchedControls: Set<ControllerControlID>, retainedSticks: Set<ControllerControlID>,
                   onLayoutChange: @escaping (ControllerLayout) -> Void,
                   onInput: @escaping (ControllerInputEvent) -> Void,
                   onConfigure: ((ControllerControlID) -> Void)?) {
        self.onInput = onInput
        self.onConfigure = onConfigure
        self.onLayoutChange = onLayoutChange
        let modeChanged = self.editing != editing || self.orientation != orientation ||
            self.allowExtendedControls != allowExtendedControls || (inputEnabled && !enabled)
        // A drag writes locally before publishing. Its SwiftUI echo is equal and
        // must not cancel the finger that is still dragging.
        let externalLayoutChanged = controllerLayout != layout
        if modeChanged || externalLayoutChanged {
            cancelInput(deferred: true)
            if self.orientation != orientation || externalLayoutChanged { selectedID = nil }
        }
        controllerLayout = layout
        self.orientation = orientation
        self.editing = editing
        self.allowExtendedControls = allowExtendedControls
        self.latchedControls = enabled && !editing ? latchedControls : []
        self.retainedSticks = enabled && !editing ? retainedSticks : []
        inputEnabled = enabled
        displayedState = enabled && !editing ? state : .neutral
        isUserInteractionEnabled = enabled || editing
        configurePress.isEnabled = editing && onConfigure != nil
        rebuildItems()
        updateAccessibility()
        setNeedsDisplay()
    }

    func stopInput() { cancelInput(deferred: false) }

    private func cancelInput(deferred: Bool) {
        if !deferred { flushPendingCancellations() }
        let hadInput = engineInputMayBeActive || !captures.isEmpty || !displayedState.isNeutral ||
            !latchedControls.isEmpty || !retainedSticks.isEmpty
        engineInputMayBeActive = false
        captures.removeAll()
        contactIDs.removeAll()
        drag = nil
        displayedState = .neutral
        latchedControls.removeAll()
        retainedSticks.removeAll()
        if hadInput {
            if deferred {
                // Keep the callback's parent epoch. A new contact must flush
                // this cancellation before beginning, not invalidate it and
                // strand the engine's old contact/retained ownership.
                let callback = onInput
                pendingCancellations.append { callback?(.cancelAll) }
                DispatchQueue.main.async { [weak self] in
                    self?.flushPendingCancellations()
                }
            } else {
                onInput?(.cancelAll)
            }
        }
        setNeedsDisplay()
    }

    private func flushPendingCancellations() {
        let callbacks = pendingCancellations
        pendingCancellations.removeAll()
        callbacks.forEach { $0() }
    }

    @objc private func applicationWillResignActive() { stopInput() }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { cancelInput(deferred: true) }
        super.willMove(toWindow: newWindow)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size {
            cancelInput(deferred: true)
            previousSize = bounds.size
        }
        rebuildItems()
        updateAccessibility()
        setNeedsDisplay()
    }

    private var contentRect: CGRect {
        bounds.inset(by: UIEdgeInsets(top: 32, left: 10, bottom: 20, right: 10))
    }

    private var placements: [ControllerPlacement] {
        orientation == .portrait ? controllerLayout.portrait : controllerLayout.landscape
    }

    private func rebuildItems() {
        let area = contentRect
        guard area.width > 0, area.height > 0 else { items = []; return }
        items = placements.map { placement in
            let radius = CGFloat(placement.id.minimumDiameter) / 2
            let desired = CGPoint(x: area.minX + CGFloat(placement.position.x) * area.width,
                                  y: area.minY + CGFloat(placement.position.y) * area.height)
            return Item(id: placement.id, center: clampedCenter(desired, radius: radius), radius: radius)
        }
    }

    private func clampedCenter(_ point: CGPoint, radius: CGFloat) -> CGPoint {
        let area = contentRect
        func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat, fallback: CGFloat) -> CGFloat {
            low <= high ? min(max(value, low), high) : fallback
        }
        return CGPoint(
            x: clamp(point.x, low: area.minX + radius, high: area.maxX - radius, fallback: area.midX),
            y: clamp(point.y, low: area.minY + radius, high: area.maxY - radius, fallback: area.midY))
    }

    private func item(for id: ControllerControlID) -> Item? { items.first { $0.id == id } }

    private func hitItem(at point: CGPoint) -> Item? {
        // Drawing and hit testing share persisted z-order; move appends its item.
        items.reversed().first { $0.contains(point) }
    }

    private func isExtended(_ id: ControllerControlID) -> Bool {
        [.leftTrigger, .rightTrigger, .guide, .share].contains(id)
    }

    private func isPlayable(_ id: ControllerControlID) -> Bool {
        inputEnabled && !editing && (allowExtendedControls || !isExtended(id))
    }

    private func allocateContact(for touchID: ObjectIdentifier) -> Int {
        nextContactID += 1
        contactIDs[touchID] = nextContactID
        engineInputMayBeActive = true
        return nextContactID
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard editing || inputEnabled else { return }
        flushPendingCancellations()
        if editing {
            guard drag == nil, let touch = touches.first else { return }
            let point = touch.location(in: self)
            guard let target = hitItem(at: point) else {
                selectedID = nil
                updateAccessibility()
                setNeedsDisplay()
                return
            }
            selectedID = target.id
            drag = LayoutDrag(touchID: ObjectIdentifier(touch), controlID: target.id,
                              offset: CGPoint(x: point.x - target.center.x, y: point.y - target.center.y))
            // Promote without jumping from the grabbed edge to the finger.
            moveControl(target.id, to: target.center)
            return
        }
        for touch in touches {
            guard let target = hitItem(at: touch.location(in: self)), isPlayable(target.id) else { continue }
            let touchID = ObjectIdentifier(touch)
            if target.id.isStick {
                let occupied = captures.values.contains {
                    if case .stick(let id) = $0 { return id == target.id }
                    return false
                }
                if !occupied {
                    captures[touchID] = .stick(target.id)
                    let contact = allocateContact(for: touchID)
                    onInput?(.begin(contact: contact, control: target.id,
                                    position: stickPosition(at: touch.location(in: self), in: target)))
                }
            } else {
                captures[touchID] = .button(target.id)
                let contact = allocateContact(for: touchID)
                onInput?(.begin(contact: contact, control: target.id, position: .zero))
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if editing { moveDrag(using: touches); return }
        guard inputEnabled else { return }
        for touch in touches {
            let touchID = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            guard let capture = captures[touchID], let contact = contactIDs[touchID] else { continue }
            switch capture {
            case .stick(let id):
                if let target = item(for: id) {
                    onInput?(.move(contact: contact, position: stickPosition(at: point, in: target)))
                }
            case .button(let previous):
                let target = hitItem(at: point)
                let id = target.flatMap { !$0.id.isStick && isPlayable($0.id) ? $0.id : nil }
                if id != previous {
                    captures[touchID] = .button(id)
                    onInput?(.transfer(contact: contact, to: id))
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if editing {
            moveDrag(using: touches)
            if let drag, touches.contains(where: { ObjectIdentifier($0) == drag.touchID }) { self.drag = nil }
            return
        }
        for touch in touches {
            let touchID = ObjectIdentifier(touch)
            captures.removeValue(forKey: touchID)
            if let contact = contactIDs.removeValue(forKey: touchID) {
                onInput?(.end(contact: contact))
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { stopInput() }

    private func moveDrag(using touches: Set<UITouch>) {
        guard let drag, let touch = touches.first(where: { ObjectIdentifier($0) == drag.touchID }) else { return }
        let point = touch.location(in: self)
        moveControl(drag.controlID, to: CGPoint(x: point.x - drag.offset.x, y: point.y - drag.offset.y))
    }

    private func moveControl(_ id: ControllerControlID, to desired: CGPoint) {
        guard editing, let target = item(for: id), contentRect.width > 0, contentRect.height > 0 else { return }
        let center = clampedCenter(desired, radius: target.radius)
        let normalized = NormalizedControlPosition(
            x: Double((center.x - contentRect.minX) / contentRect.width),
            y: Double((center.y - contentRect.minY) / contentRect.height))
        var updated = controllerLayout
        do { try updated.move(id, to: normalized, orientation: orientation) }
        catch { return }
        selectedID = id
        controllerLayout = updated
        rebuildItems()
        updateAccessibility()
        setNeedsDisplay()
        onLayoutChange?(updated)
    }

    private func stickPosition(at point: CGPoint, in item: Item) -> StickPosition {
        let x = min(1, max(-1, Double((point.x - item.center.x) / item.radius)))
        let y = min(1, max(-1, Double((item.center.y - point.y) / item.radius)))
        // Thresholds measure physical axis distance. Do not rescale the range
        // outside the deadzone or normalize diagonal input to a unit circle.
        guard hypot(x, y) > 0.10 else { return .zero }
        return StickPosition(x: x, y: y)
    }

    private func activate(_ id: ControllerControlID) -> Bool {
        flushPendingCancellations()
        if editing {
            guard let target = item(for: id) else { return false }
            moveControl(id, to: target.center)
            return true
        }
        guard isPlayable(id), !id.isStick, window != nil else { return false }
        // The engine owns both configured toggle behavior and pulse deadlines.
        engineInputMayBeActive = true
        onInput?(.accessibilityActivate(id))
        return true
    }

    private func accessibleMove(_ id: ControllerControlID, dx: CGFloat, dy: CGFloat) -> Bool {
        guard editing, let target = item(for: id) else { return false }
        moveControl(id, to: CGPoint(x: target.center.x + dx, y: target.center.y + dy))
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === configurePress, editing, onConfigure != nil else { return false }
        return hitItem(at: gestureRecognizer.location(in: self)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        editing && onConfigure != nil && hitItem(at: touch.location(in: self)) != nil
    }

    @objc private func configureLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, editing,
              let id = drag?.controlID ?? hitItem(at: recognizer.location(in: self))?.id else { return }
        _ = configureControl(id)
    }

    private func configureControl(_ id: ControllerControlID) -> Bool {
        guard editing, let onConfigure else { return false }
        cancelInput(deferred: false)
        onInput?(.cancelAll)
        selectedID = id
        updateAccessibility()
        setNeedsDisplay()
        onConfigure(id)
        return true
    }

    private func updateAccessibility() {
        var ordered: [UIAccessibilityElement] = []
        for item in items {
            let id = item.id
            let element: CanvasAccessibilityControl
            if let existing = accessibilityControls[id] {
                element = existing
            } else {
                element = CanvasAccessibilityControl(accessibilityContainer: self)
                element.activate = { [weak self] in self?.activate(id) ?? false }
                accessibilityControls[id] = element
            }
            element.accessibilityIdentifier = "controller.\(id.rawValue)"
            element.accessibilityLabel = accessibilityLabel(id)
            element.accessibilityFrameInContainerSpace = item.frame
            element.accessibilityCustomActions = nil
            if editing {
                element.accessibilityTraits = selectedID == id ? [.button, .selected] : [.button]
                element.accessibilityHint = "Drag to move or hold for control settings. Double-tap selects; Actions also offer movement and settings. No game input is sent."
                let position = controllerLayout.placement(for: id, orientation: orientation).position
                element.accessibilityValue = "\(Int(position.x * 100)) percent from left, \(Int(position.y * 100)) percent from top"
                element.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: "Move left") { [weak self] _ in self?.accessibleMove(id, dx: -12, dy: 0) ?? false },
                    UIAccessibilityCustomAction(name: "Move right") { [weak self] _ in self?.accessibleMove(id, dx: 12, dy: 0) ?? false },
                    UIAccessibilityCustomAction(name: "Move up") { [weak self] _ in self?.accessibleMove(id, dx: 0, dy: -12) ?? false },
                    UIAccessibilityCustomAction(name: "Move down") { [weak self] _ in self?.accessibleMove(id, dx: 0, dy: 12) ?? false }
                ]
                if onConfigure != nil {
                    element.accessibilityCustomActions?.insert(
                        UIAccessibilityCustomAction(name: "Control settings") { [weak self] _ in
                            self?.configureControl(id) ?? false
                        }, at: 0)
                }
            } else {
                element.accessibilityValue = latchedControls.contains(id) ? "Held" :
                    retainedSticks.contains(id) ? "Retained position" : isPressed(id) ? "Pressed" : nil
                if !isPlayable(id) {
                    element.accessibilityTraits = [.button, .notEnabled]
                    element.accessibilityHint = isExtended(id) && !allowExtendedControls
                        ? "Practice only. Its Xbox bridge mapping has not been verified." : "Controls are paused."
                } else if id.isStick {
                    element.accessibilityTraits = [.allowsDirectInteraction]
                    element.accessibilityHint = "Direct touch: drag from the center. Auto-center follows your settings. Release all clears retained input."
                } else {
                    element.accessibilityTraits = latchedControls.contains(id) ? [.button, .selected] : [.button]
                    element.accessibilityHint = "Double-tap activates the configured action. Hold Toggle buttons switch between held and released. Other buttons make a short press."
                }
            }
            ordered.append(element)
        }
        accessibilityElements = ordered
    }

    private func label(_ id: ControllerControlID) -> String {
        switch id {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .leftBumper: return "LB"
        case .rightBumper: return "RB"
        case .leftTrigger: return "LT"
        case .rightTrigger: return "RT"
        case .leftStickClick: return "LS"
        case .rightStickClick: return "RS"
        case .view: return "View"
        case .menu: return "Menu"
        case .guide: return "Xbox"
        case .share: return "Share"
        case .dpadUp: return "↑"
        case .dpadRight: return "→"
        case .dpadDown: return "↓"
        case .dpadLeft: return "←"
        case .leftStick: return "LEFT STICK"
        case .rightStick: return "RIGHT STICK"
        }
    }

    private func accessibilityLabel(_ id: ControllerControlID) -> String {
        switch id {
        case .leftBumper: return "Left bumper"
        case .rightBumper: return "Right bumper"
        case .leftTrigger: return "Left trigger, digital press"
        case .rightTrigger: return "Right trigger, digital press"
        case .leftStickClick: return "Left stick click"
        case .rightStickClick: return "Right stick click"
        case .guide: return "Xbox button"
        case .dpadUp: return "D-pad up"
        case .dpadRight: return "D-pad right"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .leftStick: return "Left analog stick"
        case .rightStick: return "Right analog stick"
        default: return "\(label(id)) button"
        }
    }

    private func isPressed(_ id: ControllerControlID) -> Bool {
        if let button = id.padButton { return displayedState.buttons.contains(button) }
        switch id {
        case .dpadUp: return [.up, .upLeft, .upRight].contains(displayedState.dpad)
        case .dpadRight: return [.right, .upRight, .downRight].contains(displayedState.dpad)
        case .dpadDown: return [.down, .downLeft, .downRight].contains(displayedState.dpad)
        case .dpadLeft: return [.left, .upLeft, .downLeft].contains(displayedState.dpad)
        default: return false
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let panel = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 20)
        Self.background.setFill()
        panel.fill()
        (editing ? Self.selectionColor : Self.cyan).withAlphaComponent(0.3).setStroke()
        panel.lineWidth = 1
        panel.stroke()
        let heading = editing ? selectedID.map { "MOVE \(label($0))" } ?? "EDIT · DRAG ANY CONTROL" : "TOUCH CONTROLLER"
        drawText(heading, at: CGPoint(x: bounds.midX, y: 10), size: 10,
                 color: editing ? Self.selectionColor : Self.muted, weight: .semibold)
        for item in items {
            context.saveGState()
            if !editing && !isPlayable(item.id) { context.setAlpha(0.36) }
            if item.id.isStick { drawStick(item) } else { drawButton(item) }
            context.restoreGState()
            if editing && selectedID == item.id {
                let outline = UIBezierPath(ovalIn: item.frame.insetBy(dx: -3, dy: -3))
                Self.selectionColor.setStroke()
                outline.lineWidth = 2
                outline.setLineDash([4, 3], count: 2, phase: 0)
                outline.stroke()
            }
        }
        let footer = editing ? "Drag to move · hold for settings · tap Save layout" : inputEnabled ? "Slide between buttons · Release all clears holds" : "Controls paused"
        drawText(footer, at: CGPoint(x: bounds.midX, y: bounds.maxY - 15), size: 9, color: Self.muted)
    }

    private func drawButton(_ item: Item) {
        let active = !editing && isPlayable(item.id) && isPressed(item.id)
        let practiceOnly = !allowExtendedControls && isExtended(item.id)
        let latched = !editing && latchedControls.contains(item.id)
        drawCircle(item, fill: active ? Self.green : Self.well,
                   stroke: latched ? Self.selectionColor : active ? .white : Self.green.withAlphaComponent(0.7))
        if latched {
            let outline = UIBezierPath(ovalIn: item.frame.insetBy(dx: -2, dy: -2))
            Self.selectionColor.setStroke()
            outline.lineWidth = 2
            outline.stroke()
        }
        let text = label(item.id)
        let size: CGFloat = text.count > 2 ? 10 : 16
        drawText(text, at: CGPoint(x: item.center.x, y: item.center.y - (practiceOnly || latched ? 4 : 0)),
                 size: size, color: active ? Self.background : .white,
                 verticallyCentered: true, weight: .bold)
        if practiceOnly {
            drawText("PRACTICE", at: CGPoint(x: item.center.x, y: item.center.y + 7),
                     size: 6.5, color: Self.muted, weight: .semibold)
        } else if latched {
            drawText("HOLD", at: CGPoint(x: item.center.x, y: item.center.y + 7),
                     size: 7, color: Self.background, weight: .bold)
        }
    }

    private func drawStick(_ item: Item) {
        let retained = !editing && retainedSticks.contains(item.id)
        drawCircle(item, fill: Self.well, stroke: retained ? Self.selectionColor : Self.cyan.withAlphaComponent(0.65))
        let position = item.id == .leftStick ? displayedState.leftStick : displayedState.rightStick
        // Keep the drawing inside its circular well while preserving the
        // independent axes sent to the engine, including square-range corners.
        let visualScale = max(1, hypot(position.x, position.y))
        let knob = Item(id: item.id,
                        center: CGPoint(x: item.center.x + CGFloat(position.x / visualScale) * item.radius * 0.62,
                                        y: item.center.y - CGFloat(position.y / visualScale) * item.radius * 0.62),
                        radius: item.radius * 0.30)
        let active = !editing && abs(position.x) + abs(position.y) > 0
        drawCircle(knob, fill: retained ? Self.selectionColor : active ? Self.cyan : Self.cyan.withAlphaComponent(0.30),
                   stroke: retained ? Self.selectionColor : Self.cyan)
        drawText(item.id == .leftStick ? "L" : "R", at: knob.center, size: 12,
                 color: active ? Self.background : .white, verticallyCentered: true, weight: .bold)
        drawText(label(item.id), at: CGPoint(x: item.center.x, y: item.frame.maxY - 15),
                 size: 8, color: Self.muted, weight: .semibold)
        if retained {
            drawText("HOLD", at: CGPoint(x: item.center.x, y: item.frame.minY + 8),
                     size: 8, color: Self.selectionColor, weight: .bold)
        }
    }

    private func drawCircle(_ item: Item, fill: UIColor, stroke: UIColor) {
        let path = UIBezierPath(ovalIn: item.frame)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawText(_ text: String, at center: CGPoint, size: CGFloat, color: UIColor,
                          verticallyCentered: Bool = false, weight: UIFont.Weight = .regular) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: center.x - measured.width / 2,
                                           y: center.y - (verticallyCentered ? measured.height / 2 : 0)),
                               withAttributes: attributes)
    }
}

private final class CanvasAccessibilityControl: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}

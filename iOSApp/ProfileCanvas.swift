import ControllerCore
import SwiftUI
import UIKit

/// UIKit owns live touches; saved geometry is independent of game input.
struct ProfileCanvas: UIViewRepresentable {
    var state: GamepadState
    var enabled: Bool
    var profile: ControllerProfile
    var pageID: UUID
    var orientation: ControllerOrientation
    var editing: Bool
    var allowExtendedControls: Bool
    var allowDesktopControls: Bool = false
    var allowTriggerControls: Bool = false
    var activeControls: Set<UUID>
    var latchedControls: Set<UUID>
    var retainedSticks: Set<UUID>
    var stickPositions: [UUID: StickPosition]
    var buttonAimStates: [UUID: ButtonAimVisualState]
    var buttonDirectionalSelections: [UUID: ButtonDirectionalSelection]
    var touchAimStates: [UUID: TouchAimState]
    var touchAimScores: [UUID: Double]
    var touchAimIssues: [UUID: String]
    var floatingRingStates: [UUID: FloatingRingState]
    var dismissedFloatingButtonSessions: [UUID: UUID]
    var activeTouchpads: Set<UUID>
    var lockedTouchpads: Set<UUID>
    var pendingTouchpadLocks: Set<UUID>
    var scrollModeEnabled: Bool
    var showCameraFollow: Bool = false
    var cameraFollowSnapshot: CameraFollowPracticeSnapshot? = nil
    var autoCenterOverride: Bool? = nil
    var allSticksAutoCenterEnabled = false
    var autoCenterMixed = false
    var onProfileChange: (ControllerProfile) -> Void
    var onInput: (ProfileInputEvent) -> Bool
    var onConfigure: ((UUID) -> Void)? = nil
    var onMeasure: ((FloatingCanvasSnapshot, ControllerProfile, UUID, ControllerOrientation) -> Void)? = nil
    var onIssue: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> ProfileCanvasView {
        let view = ProfileCanvasView()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: ProfileCanvasView, context: Context) { configure(uiView) }

    private func configure(_ view: ProfileCanvasView) {
        view.configure(state: state, enabled: enabled, profile: profile, pageID: pageID,
                       orientation: orientation, editing: editing,
                       allowExtendedControls: allowExtendedControls,
                       allowDesktopControls: allowDesktopControls,
                       allowTriggerControls: allowTriggerControls,
                       activeControls: activeControls,
                       latchedControls: latchedControls, retainedSticks: retainedSticks,
                       stickPositions: stickPositions,
                       buttonAimStates: buttonAimStates, buttonDirectionalSelections: buttonDirectionalSelections,
                       touchAimStates: touchAimStates, touchAimScores: touchAimScores, touchAimIssues: touchAimIssues,
                       floatingRingStates: floatingRingStates,
                       dismissedFloatingButtonSessions: dismissedFloatingButtonSessions,
                       activeTouchpads: activeTouchpads, lockedTouchpads: lockedTouchpads,
                       pendingTouchpadLocks: pendingTouchpadLocks, scrollModeEnabled: scrollModeEnabled,
                       showCameraFollow: showCameraFollow, cameraFollowSnapshot: cameraFollowSnapshot,
                       autoCenterOverride: autoCenterOverride,
                       allSticksAutoCenterEnabled: allSticksAutoCenterEnabled,
                       autoCenterMixed: autoCenterMixed,
                       onProfileChange: onProfileChange, onInput: onInput, onConfigure: onConfigure,
                       onMeasure: onMeasure, onIssue: onIssue)
    }

    static func dismantleUIView(_ uiView: ProfileCanvasView, coordinator: ()) { uiView.stopInput() }
}

final class ProfileCanvasView: UIView, UIGestureRecognizerDelegate {
    private enum Capture: Equatable {
        case stick(UUID)
        case touchpad(UUID)
        case touchAim(UUID)
        case button(UUID?)
    }

    private struct Item {
        let control: ProfileControl
        let center: CGPoint
        let radius: CGFloat
        let padSize: CGSize?
        init(control: ProfileControl, center: CGPoint, radius: CGFloat, padSize: CGSize? = nil) {
            self.control = control; self.center = center; self.radius = radius; self.padSize = padSize
        }
        var id: UUID { control.id }
        var isStick: Bool { control.kind.isStick }
        var isTouchpad: Bool { control.isTouchpad }
        var isTouchAim: Bool { control.isTouchAim }
        var frame: CGRect {
            let size = padSize ?? CGSize(width: radius * 2, height: radius * 2)
            return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        }
        func outline(inset: CGFloat = 0) -> UIBezierPath {
            let rect = frame.insetBy(dx: inset, dy: inset)
            return isTouchpad || isTouchAim || (!isStick && (control.controlWidth != nil || control.controlHeight != nil || (!control.orientationDimensions.isEmpty && abs(rect.width - rect.height) > 0.01)))
                ? UIBezierPath(roundedRect: rect, cornerRadius: min(14, min(rect.width, rect.height) * 0.18))
                : UIBezierPath(ovalIn: rect)
        }
        func contains(_ point: CGPoint) -> Bool {
            outline().contains(point)
        }
    }

    private struct LayoutDrag {
        let touchID: ObjectIdentifier
        let controlID: UUID
        let offset: CGPoint
    }

    private static let background = ControllerAppearancePalette.canvasBackground
    private static let well = ControllerAppearancePalette.well
    private static let cyan = ControllerAppearancePalette.cyan
    private static let green = ControllerAppearancePalette.green
    private static let muted = ControllerAppearancePalette.muted
    private static let selectionColor = ControllerAppearancePalette.selection

    private struct Capabilities {
        let targets: Set<ControllerControlID>
        let desktop: Bool
        let anyOutput: Bool
    }
    private var capabilities: [UUID: Capabilities] = [:]
    private var needsPointerHeader = false
    private var needsDesktopHeader = false
    private var needsCameraHeader = false
    private var cameraCommands: [UUID: CameraFollowCommand] = [:]
    private var cameraFollowSnapshot: CameraFollowPracticeSnapshot?
    private var autoCenterCommands: [UUID: AutoCenterCommand] = [:]
    private var autoCenterOverride: Bool?
    private var allSticksAutoCenterEnabled = false
    private var autoCenterMixed = false
    private var controllerProfile: ControllerProfile?
    private var pageID: UUID?
    private var orientation: ControllerOrientation = .portrait
    private var items: [Item] = []
    private var captures: [ObjectIdentifier: Capture] = [:]
    private var contactIDs: [ObjectIdentifier: Int] = [:]
    private var touchpadPoints: [ObjectIdentifier: CGPoint] = [:]
    private var touchAimStarts: [ObjectIdentifier: TimeInterval] = [:]
    private var swipeRouter: ProfileSwipeRouter?
    private var routingGeneration = 0
    private var nextContactID = 0
    private var engineInputMayBeActive = false
    private var drag: LayoutDrag?
    private var selectedID: UUID?
    private var displayedState = GamepadState.neutral
    private var activeControls: Set<UUID> = []
    private var latchedControls: Set<UUID> = []
    private var retainedSticks: Set<UUID> = []
    private var stickPositions: [UUID: StickPosition] = [:]
    private var buttonAimStates: [UUID: ButtonAimVisualState] = [:]
    private var buttonDirectionalSelections: [UUID: ButtonDirectionalSelection] = [:]
    private var touchAimStates: [UUID: TouchAimState] = [:]
    private var touchAimScores: [UUID: Double] = [:]
    private var touchAimIssues: [UUID: String] = [:]
    private var floatingRingStates: [UUID: FloatingRingState] = [:]
    private var dismissedFloatingButtonSessions: [UUID: UUID] = [:]
    private let floatingOverlay = FloatingCanvasOverlay()
    private var activeTouchpads: Set<UUID> = []
    private var lockedTouchpads: Set<UUID> = []
    private var pendingTouchpadLocks: Set<UUID> = []
    private var scrollModeEnabled = false
    private var inputEnabled = false
    private var editing = false
    private var allowExtendedControls = true
    private var allowDesktopControls = false
    private var allowTriggerControls = false
    private var onInput: ((ProfileInputEvent) -> Bool)?
    private var onConfigure: ((UUID) -> Void)?
    private var onProfileChange: ((ControllerProfile) -> Void)?
    private var onMeasure: ((FloatingCanvasSnapshot, ControllerProfile, UUID, ControllerOrientation) -> Void)?
    private var onIssue: ((String) -> Void)?
    private var lastMeasurement: FloatingCanvasSnapshot?
    private var lastMeasuredProfile: ControllerProfile?
    private var lastMeasuredPage: UUID?
    private var lastMeasuredOrientation: ControllerOrientation?
    private var previousSize = CGSize.zero
    private var pendingCancellations: [() -> Void] = []
    private var accessibilityControls: [UUID: ProfileCanvasAccessibilityControl] = [:]
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
        accessibilityIdentifier = "profile.touchCanvas"
        addGestureRecognizer(configurePress)
        addSubview(floatingOverlay)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProfileCanvasView, _: UITraitCollection) in view.setNeedsDisplay() }
        configurePress.isEnabled = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("ProfileCanvasView is created programmatically") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configure(state: GamepadState, enabled: Bool, profile: ControllerProfile, pageID: UUID,
                   orientation: ControllerOrientation, editing: Bool,
                   allowExtendedControls: Bool,
                   allowDesktopControls: Bool = false,
                   allowTriggerControls: Bool = false,
                   activeControls: Set<UUID>,
                   latchedControls: Set<UUID>, retainedSticks: Set<UUID>,
                   stickPositions: [UUID: StickPosition],
                   buttonAimStates: [UUID: ButtonAimVisualState], buttonDirectionalSelections: [UUID: ButtonDirectionalSelection],
                   touchAimStates: [UUID: TouchAimState], touchAimScores: [UUID: Double], touchAimIssues: [UUID: String],
                   floatingRingStates: [UUID: FloatingRingState],
                   dismissedFloatingButtonSessions: [UUID: UUID],
                   activeTouchpads: Set<UUID>, lockedTouchpads: Set<UUID>,
                   pendingTouchpadLocks: Set<UUID>, scrollModeEnabled: Bool,
                   showCameraFollow: Bool, cameraFollowSnapshot: CameraFollowPracticeSnapshot?,
                   autoCenterOverride: Bool? = nil, allSticksAutoCenterEnabled: Bool = false,
                   autoCenterMixed: Bool = false,
                   onProfileChange: @escaping (ControllerProfile) -> Void,
                   onInput: @escaping (ProfileInputEvent) -> Bool,
                   onConfigure: ((UUID) -> Void)?,
                   onMeasure: ((FloatingCanvasSnapshot, ControllerProfile, UUID, ControllerOrientation) -> Void)?,
                   onIssue: ((String) -> Void)?) {
        self.onInput = onInput
        self.onConfigure = onConfigure
        self.onMeasure = onMeasure
        self.onIssue = onIssue
        self.onProfileChange = onProfileChange
        let modeChanged = self.editing != editing || self.orientation != orientation || needsCameraHeader != showCameraFollow ||
            self.allowExtendedControls != allowExtendedControls || self.allowDesktopControls != allowDesktopControls || self.allowTriggerControls != allowTriggerControls || (inputEnabled && !enabled)
        // A drag writes locally before publishing. Its SwiftUI echo is equal and
        // must not cancel the finger that is still dragging.
        let externalProfileChanged = controllerProfile != profile || self.pageID != pageID
        if modeChanged || externalProfileChanged {
            cancelInput(deferred: true)
            if self.orientation != orientation || externalProfileChanged { selectedID = nil }
        }
        if externalProfileChanged {
            swipeRouter = try? ProfileSwipeRouter(profile: profile)
            cameraCommands = Dictionary(uniqueKeysWithValues: profile.controls(on: pageID).compactMap { control in
                guard let command = try? control.payloadProgram().cameraFollowCommand else { return nil }
                return (control.id, command)
            })
            autoCenterCommands = Dictionary(uniqueKeysWithValues: profile.controls(on: pageID).compactMap { control in
                guard let command = try? control.payloadProgram().autoCenterCommand else { return nil }
                return (control.id, command)
            })
            let rings = profile.page(for: pageID)?.floatingRingZones.filter(\.enabled) ?? []
            needsPointerHeader = profile.controls(on: pageID).contains {
                $0.isTouchpad || ($0.isTouchAim && $0.touchAim.aim.output.isMouse) || $0.isScrollModeToggle || ($0.buttonAim.enabled && ($0.buttonAim.tuning.output.isMouse ||
                    ($0.buttonAim.alternate.enabled && $0.buttonAim.alternate.tuning.output.isMouse)))
            } || rings.contains { $0.config.aim.enabled && $0.config.aim.tuning.output.isMouse }
            needsDesktopHeader = profile.controls(on: pageID).contains { $0.hasKeyboardOrMouseOutputs } || rings.contains { $0.config.hasDesktopOutputs }
            capabilities = Dictionary(uniqueKeysWithValues: profile.controls(on: pageID).map { control in
                (control.id, Capabilities(targets: control.outputTargets,
                                          desktop: control.hasKeyboardOrMouseOutputs,
                                          anyOutput: control.hasAnyOutput))
            })
        }
        controllerProfile = profile
        self.pageID = pageID
        self.orientation = orientation
        self.editing = editing
        self.allowExtendedControls = allowExtendedControls
        self.allowDesktopControls = allowDesktopControls
        self.allowTriggerControls = allowTriggerControls
        self.activeControls = enabled && !editing ? activeControls : []
        self.latchedControls = enabled && !editing ? latchedControls : []
        self.retainedSticks = enabled && !editing ? retainedSticks : []
        self.stickPositions = enabled && !editing ? stickPositions : [:]
        self.touchAimStates = enabled && !editing ? touchAimStates : [:]
        self.touchAimScores = enabled && !editing ? touchAimScores : [:]
        self.touchAimIssues = enabled && !editing ? touchAimIssues : [:]
        self.floatingRingStates = enabled && !editing ? floatingRingStates : [:]
        self.dismissedFloatingButtonSessions = enabled && !editing ? dismissedFloatingButtonSessions : [:]
        self.buttonAimStates = enabled && !editing ? buttonAimStates : [:]
        self.buttonDirectionalSelections = enabled && !editing ? buttonDirectionalSelections : [:]
        self.activeTouchpads = enabled && !editing ? activeTouchpads : []
        self.lockedTouchpads = enabled && !editing ? lockedTouchpads : []
        self.pendingTouchpadLocks = enabled && !editing ? pendingTouchpadLocks : []
        self.scrollModeEnabled = enabled && !editing && scrollModeEnabled
        needsCameraHeader = showCameraFollow
        self.cameraFollowSnapshot = enabled && !editing && (allowExtendedControls || allowDesktopControls) ? cameraFollowSnapshot : nil
        self.autoCenterOverride = autoCenterOverride
        self.allSticksAutoCenterEnabled = allSticksAutoCenterEnabled
        self.autoCenterMixed = autoCenterMixed
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
            !activeControls.isEmpty || !latchedControls.isEmpty || !retainedSticks.isEmpty ||
            !activeTouchpads.isEmpty || !lockedTouchpads.isEmpty || !pendingTouchpadLocks.isEmpty || !floatingRingStates.isEmpty
        // Parent cancellation owns the deferred engine event; overlay only drops UIKit sessions here.
        floatingOverlay.stopInput(sendCancellations: false)
        engineInputMayBeActive = false
        routingGeneration &+= 1
        swipeRouter?.reset()
        captures.removeAll()
        contactIDs.removeAll()
        touchpadPoints.removeAll(); touchAimStarts.removeAll()
        drag = nil
        displayedState = .neutral
        activeControls.removeAll()
        latchedControls.removeAll()
        retainedSticks.removeAll()
        stickPositions.removeAll()
        buttonAimStates.removeAll(); buttonDirectionalSelections.removeAll()
        touchAimStates.removeAll(); touchAimScores.removeAll(); touchAimIssues.removeAll()
        floatingRingStates.removeAll()
        dismissedFloatingButtonSessions.removeAll()
        activeTouchpads.removeAll()
        lockedTouchpads.removeAll()
        pendingTouchpadLocks.removeAll()
        scrollModeEnabled = false
        cameraFollowSnapshot = nil
        if hadInput {
            if deferred {
                // Keep the callback's parent epoch. A new contact must flush
                // this cancellation before beginning, not invalidate it and
                // strand the engine's old contact/retained ownership.
                let callback = onInput
                pendingCancellations.append { _ = callback?(.cancelAll) }
                DispatchQueue.main.async { [weak self] in
                    self?.flushPendingCancellations()
                }
            } else {
                _ = onInput?(.cancelAll)
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
        // Toolbar/status chrome overlays the canvas; it never limits placement.
        // Whole controls still clamp inside these bounds so edge buttons stay reachable.
        bounds
    }

    private var placements: [ProfilePlacement] {
        controllerProfile.flatMap { profile in pageID.map { profile.placements(for: orientation, on: $0) } } ?? []
    }

    private func rebuildItems() {
        let area = contentRect
        guard area.width > 0, area.height > 0 else { items = []; return }
        items = placements.compactMap { placement in
            guard let control = controllerProfile?.control(for: placement.id) else { return nil }
            let desired = CGPoint(x: area.minX + CGFloat(placement.position.x) * area.width,
                                  y: area.minY + CGFloat(placement.position.y) * area.height)
            if control.isTouchpad {
                guard area.width >= 44, area.height >= 44 else { return nil }
                let dimensions = control.dimensions(for: orientation)
                let size = CGSize(width: min(area.width, max(44, CGFloat(dimensions.width))),
                                  height: min(area.height, max(44, CGFloat(dimensions.height))))
                return Item(control: control, center: clampedCenter(desired, halfSize: CGSize(
                    width: size.width / 2, height: size.height / 2)),
                            radius: min(size.width, size.height) / 2, padSize: size)
            }
            let availableDiameter = min(area.width, area.height)
            guard availableDiameter >= CGFloat(control.minimumDiameter) else { return nil }
            let dimensions = control.dimensions(for: orientation)
            let size = CGSize(width: min(area.width, CGFloat(dimensions.width)),
                              height: min(area.height, CGFloat(dimensions.height)))
            let radius = min(size.width, size.height) / 2
            return Item(control: control, center: clampedCenter(desired, halfSize: CGSize(width: size.width / 2, height: size.height / 2)),
                        radius: radius, padSize: size)
        }
        // Measure canonical controls before hiding converted members. Their saved positions remain recoverable.
        let snapshot = measuredSnapshot(area: area)
        publishMeasurement(snapshot)
        if !editing, let profile = controllerProfile, let pageID {
            let hidden = profile.page(for: pageID)?.floatingMemberIDs ?? []
            items.removeAll { hidden.contains($0.id) }
        }
        if let profile = controllerProfile, let pageID {
            floatingOverlay.frame = area
            floatingOverlay.configure(profile: profile, pageID: pageID, orientation: orientation, editing: editing,
                enabled: inputEnabled, allowExtendedControls: allowExtendedControls, allowDesktopControls: allowDesktopControls, allowTriggerControls: allowTriggerControls, snapshot: snapshot,
                activeControls: activeControls, latchedControls: latchedControls, ringStates: floatingRingStates,
                dismissedButtonSessions: dismissedFloatingButtonSessions,
                ordinaryControlHitTest: { [weak self] point in
                    self?.items.contains { $0.contains(CGPoint(x: point.x + area.minX, y: point.y + area.minY)) } ?? false
                }, onInput: { [weak self] event in
                    guard let self else { return false }
                    self.flushPendingCancellations()
                    self.engineInputMayBeActive = true
                    return self.onInput?(event) ?? false
                }, onIssue: { [weak self] text in self?.onIssue?(text) })
        }
    }

    private func measuredSnapshot(area: CGRect) -> FloatingCanvasSnapshot {
        let frames = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, FloatingRect(x: Double(item.frame.minX - area.minX), y: Double(item.frame.minY - area.minY),
                                   width: Double(item.frame.width), height: Double(item.frame.height)))
        })
        return FloatingCanvasSnapshot(width: Double(area.width), height: Double(area.height), frames: frames)
    }

    private func publishMeasurement(_ snapshot: FloatingCanvasSnapshot) {
        guard let profile = controllerProfile, let pageID, let onMeasure else { return }
        guard lastMeasurement != snapshot || lastMeasuredProfile != profile || lastMeasuredPage != pageID || lastMeasuredOrientation != orientation else { return }
        lastMeasurement = snapshot; lastMeasuredProfile = profile; lastMeasuredPage = pageID; lastMeasuredOrientation = orientation
        let measuredOrientation = orientation
        DispatchQueue.main.async { onMeasure(snapshot, profile, pageID, measuredOrientation) }
    }

    private func clampedCenter(_ point: CGPoint, radius: CGFloat) -> CGPoint {
        clampedCenter(point, halfSize: CGSize(width: radius, height: radius))
    }

    private func clampedCenter(_ point: CGPoint, halfSize: CGSize) -> CGPoint {
        let area = contentRect
        func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat, fallback: CGFloat) -> CGFloat {
            low <= high ? min(max(value, low), high) : fallback
        }
        return CGPoint(
            x: clamp(point.x, low: area.minX + halfSize.width, high: area.maxX - halfSize.width, fallback: area.midX),
            y: clamp(point.y, low: area.minY + halfSize.height, high: area.maxY - halfSize.height, fallback: area.midY))
    }

    private func item(for id: UUID) -> Item? { items.first { $0.id == id } }

    private func hitItem(at point: CGPoint) -> Item? {
        // Drawing and hit testing share persisted z-order; move appends its item.
        items.reversed().first { $0.contains(point) }
    }

    private var practiceOnlyActions: Set<ControllerControlID> {
        allowTriggerControls ? [.guide, .share] : [.leftTrigger, .rightTrigger, .guide, .share]
    }

    private func isFullyPracticeOnly(_ id: UUID) -> Bool {
        if let control = controllerProfile?.control(for: id), control.isReleaseAllAction || control.isFloatingAction || control.isAutoCenterAction { return false }
        if controllerProfile?.control(for: id)?.isCameraFollowAction == true { return !allowDesktopControls }
        if controllerProfile?.control(for: id)?.isTouchpad == true { return !allowDesktopControls }
        guard let control = controllerProfile?.control(for: id), control.kind != .recenter, control.kind != .pageButton,
              let capability = capabilities[id], capability.anyOutput else { return false }
        if control.kind.isStick && !control.isDirectional { return false }
        if capability.desktop && allowDesktopControls { return false }
        return capability.targets.subtracting(practiceOnlyActions).isEmpty
    }

    private func hasPracticeOnlyActions(_ id: UUID) -> Bool {
        if controllerProfile?.control(for: id)?.isCameraFollowAction == true { return !allowDesktopControls }
        guard let capability = capabilities[id] else { return false }
        return (capability.desktop && !allowDesktopControls) || !capability.targets.isDisjoint(with: practiceOnlyActions)
    }

    private func isPlayable(_ id: UUID) -> Bool {
        inputEnabled && !editing && (allowExtendedControls || !isFullyPracticeOnly(id))
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
            if target.isTouchAim {
                let occupied = captures.values.contains { if case .touchAim(let id) = $0 { return id == target.id }; return false }
                guard !occupied else { continue }
                captures[touchID] = .touchAim(target.id); touchAimStarts[touchID] = touch.timestamp
                let contact = allocateContact(for: touchID)
                let sample = TouchAimSample(pointer: buttonSample(at: touch.location(in: self), in: target),
                                            metrics: TouchMetricCapture.metrics(touch, in: self), elapsed: 0)
                guard onInput?(.beginTouchAim(contact: contact, control: target.id, sample: sample)) == true else {
                    cancelCapturedTouch(touchID); continue
                }
                // Sensor surfaces own a direct contact and never join swipe routing.
                continue
            } else if target.isTouchpad {
                let occupied = captures.values.contains {
                    if case .touchpad(let id) = $0 { return id == target.id }
                    return false
                }
                guard !occupied else { continue }
                captures[touchID] = .touchpad(target.id)
                touchpadPoints[touchID] = touch.location(in: self)
                let contact = allocateContact(for: touchID)
                guard onInput?(.beginTouchpad(contact: contact, control: target.id)) == true else {
                    cancelCapturedTouch(touchID); continue
                }
            } else if target.isStick {
                // Duplicate analog instances share a channel. An ignored second
                // finger must not become a router owner that blocks later swipes.
                let occupied = self.occupied(target, excluding: touchID)
                if !occupied {
                    captures[touchID] = .stick(target.id)
                    let contact = allocateContact(for: touchID)
                    guard onInput?(.beginStick(contact: contact, control: target.id,
                                    travel: stickTravel(at: touch.location(in: self), in: target))) == true else {
                        cancelCapturedTouch(touchID); continue
                    }
                }
            } else {
                captures[touchID] = .button(target.id)
                let contact = allocateContact(for: touchID)
                let accepted = target.control.isAdvancedButton
                    ? onInput?(.beginButton(contact: contact, control: target.id, sample: buttonSample(at: touch.location(in: self), in: target)))
                    : onInput?(.begin(contact: contact, control: target.id, position: .zero))
                guard accepted == true else { cancelCapturedTouch(touchID); continue }
            }
            if let contact = contactIDs[touchID] {
                do { try swipeRouter?.begin(contact: contact, control: target.id,
                                            at: ProcessInfo.processInfo.systemUptime) }
                catch { cancelCapturedTouch(touchID) }
            }
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if editing { moveDrag(using: touches); return }
        guard inputEnabled else { return }
        for touch in touches {
            let touchID = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            guard let capture = captures[touchID], let contact = contactIDs[touchID] else { continue }
            if case .touchAim = capture {
                moveCapturedTouch(touch, event: event, capture: capture, touchID: touchID, contact: contact)
                continue
            }
            let hits = items.reversed().filter { $0.contains(point) }
            let unavailable = Set(items.filter { !isPlayable($0.id) ||
                occupied($0, excluding: touchID) }.map(\.id))
            let time = ProcessInfo.processInfo.systemUptime
            do {
                let decision = try swipeRouter?.decision(contact: contact,
                    hitControls: hits.map(\.id), unavailableControls: unavailable, at: time) ?? .moveCurrent
                switch decision {
                case .moveCurrent:
                    moveCapturedTouch(touch, event: event, capture: capture,
                                      touchID: touchID, contact: contact)
                case .hold:
                    break
                case .transfer(let destination):
                    let generation = routingGeneration
                    if controllerProfile?.swipeMode == .buttons {
                        guard onInput?(.transfer(contact: contact, to: destination)) == true,
                              routingGeneration == generation, contactIDs[touchID] == contact else { continue }
                        captures[touchID] = .button(destination)
                    } else if let destination, let target = item(for: destination) {
                        let departing: StickTravel?
                        if case .stick(let id) = capture, let old = item(for: id) {
                            departing = stickTravel(at: point, in: old)
                        } else { departing = nil }
                        var finalDeltas: [PointerDelta] = []
                        if case .touchpad = capture {
                            guard let deltas = touchpadDeltas(for: touch, event: event, touchID: touchID) else {
                                cancelCapturedTouch(touchID); continue
                            }
                            finalDeltas = deltas
                        }
                        let accepted = onInput?(.handoffTravel(contact: contact, to: destination,
                            departingTravel: departing,
                            arrivingTravel: target.isStick ? stickTravel(at: point, in: target) : .zero,
                            finalPadDeltas: finalDeltas)) == true
                        guard routingGeneration == generation, contactIDs[touchID] == contact else { continue }
                        guard accepted else {
                            // A rejected handoff leaves this pad's existing contact active.
                            // Its observed path still must cancel any accidental click-lock.
                            if !finalDeltas.isEmpty { _ = onInput?(.moveTouchpadBatch(contact: contact, deltas: finalDeltas)) }
                            continue
                        }
                        if target.isTouchpad {
                            captures[touchID] = .touchpad(destination)
                            touchpadPoints[touchID] = point // Relative movement starts here; no entry jump.
                        } else {
                            touchpadPoints.removeValue(forKey: touchID)
                            captures[touchID] = target.isStick ? .stick(destination) : .button(destination)
                        }
                    } else { continue }
                    try swipeRouter?.accept(contact: contact, target: destination, at: time)
                }
            } catch { cancelCapturedTouch(touchID) }
        }
        setNeedsDisplay()
    }

    private func occupied(_ target: Item, excluding touchID: ObjectIdentifier) -> Bool {
        captures.contains { token, capture in
            guard token != touchID else { return false }
            if target.isTouchpad, case .touchpad(let id) = capture { return id == target.id }
            if target.isStick, case .stick(let id) = capture,
               let other = controllerProfile?.control(for: id) {
                if target.control.isDirectional { return id == target.id }
                return !other.isDirectional && other.logicalStick == target.control.logicalStick
            }
            return false
        }
    }

    private func moveCapturedTouch(_ touch: UITouch, event: UIEvent?, capture: Capture,
                                   touchID: ObjectIdentifier, contact: Int) {
        switch capture {
        case .touchAim(let id):
            guard let target = item(for: id), let start = touchAimStarts[touchID] else { cancelCapturedTouch(touchID); return }
            let touches = (event?.coalescedTouches(for: touch) ?? []) + [touch]
            let samples = touches.map { sample in
                TouchAimSample(pointer: buttonSample(at: sample.location(in: self), in: target),
                               metrics: TouchMetricCapture.metrics(sample, in: self), elapsed: sample.timestamp - start)
            }
            guard samples.count <= 256, samples.allSatisfy(\.isValid) else { cancelCapturedTouch(touchID); return }
            if onInput?(.moveTouchAimBatch(contact: contact, samples: samples)) != true { cancelCapturedTouch(touchID) }
        case .touchpad:
            // Pass the complete coalesced path before advancing click-lock timers.
            guard let deltas = touchpadDeltas(for: touch, event: event, touchID: touchID) else {
                cancelCapturedTouch(touchID); return
            }
            if !deltas.isEmpty { _ = onInput?(.moveTouchpadBatch(contact: contact, deltas: deltas)) }
        case .stick(let id):
            if let target = item(for: id) {
                _ = onInput?(.moveStick(contact: contact, travel: stickTravel(at: touch.location(in: self), in: target)))
            }
        case .button(let id):
            if let id, let target = item(for: id), target.control.isAdvancedButton {
                guard let samples = buttonSamples(for: touch, event: event, in: target) else { cancelCapturedTouch(touchID); return }
                _ = onInput?(.moveButtonBatch(contact: contact, samples: samples))
            }
        }
    }

    private func buttonSample(at point: CGPoint, in item: Item) -> ButtonPointerSample {
        .init(x: Double(point.x - item.frame.minX), y: Double(point.y - item.frame.minY),
              width: Double(item.frame.width), height: Double(item.frame.height))
    }
    private func buttonSamples(for touch: UITouch, event: UIEvent?, in item: Item) -> [ButtonPointerSample]? {
        let samples = ((event?.coalescedTouches(for: touch) ?? []) + [touch]).map {
            buttonSample(at: $0.location(in: self), in: item)
        }
        guard samples.count <= 256, samples.allSatisfy(\.isValid) else { return nil }
        return samples
    }

    private func touchpadDeltas(for touch: UITouch, event: UIEvent?, touchID: ObjectIdentifier) -> [PointerDelta]? {
        guard var previous = touchpadPoints[touchID] else { return nil }
        var deltas: [PointerDelta] = []
        let samples = (event?.coalescedTouches(for: touch) ?? []) + [touch]
        for sample in samples {
            let point = sample.location(in: self)
            let delta = PointerDelta(dx: Double(point.x - previous.x), dy: Double(point.y - previous.y))
            guard delta.isValidInput else { return nil }
            previous = point
            if delta.dx != 0 || delta.dy != 0 {
                // Match the core's atomic-path limit. Cancel an exceptional
                // oversized path rather than truncate its click-slop evidence.
                guard deltas.count < 256 else { return nil }
                deltas.append(delta)
            }
        }
        touchpadPoints[touchID] = previous
        return deltas
    }

    private func cancelCapturedTouch(_ touchID: ObjectIdentifier) {
        captures.removeValue(forKey: touchID)
        touchpadPoints.removeValue(forKey: touchID)
        touchAimStarts.removeValue(forKey: touchID)
        if let contact = contactIDs.removeValue(forKey: touchID) {
            swipeRouter?.end(contact: contact)
            _ = onInput?(.cancel(contact: contact))
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
            if case .touchAim? = captures[touchID] {
                guard inputEnabled else { cancelCapturedTouch(touchID); continue }
                captures.removeValue(forKey: touchID); touchAimStarts.removeValue(forKey: touchID)
                if let contact = contactIDs.removeValue(forKey: touchID) { _ = onInput?(.end(contact: contact)) }
                continue
            }
            if case .button(let id)? = captures[touchID], let id, let target = item(for: id),
               target.control.isAdvancedButton, let contact = contactIDs[touchID] {
                guard inputEnabled, let samples = buttonSamples(for: touch, event: event, in: target) else {
                    cancelCapturedTouch(touchID); continue
                }
                captures.removeValue(forKey: touchID); contactIDs.removeValue(forKey: touchID)
                swipeRouter?.end(contact: contact)
                _ = onInput?(.endButton(contact: contact, finalSamples: samples))
                continue
            }
            if case .touchpad? = captures[touchID], let contact = contactIDs[touchID] {
                guard inputEnabled,
                      let deltas = touchpadDeltas(for: touch, event: event, touchID: touchID) else {
                    cancelCapturedTouch(touchID)
                    continue
                }
                captures.removeValue(forKey: touchID)
                contactIDs.removeValue(forKey: touchID)
                swipeRouter?.end(contact: contact)
                touchpadPoints.removeValue(forKey: touchID)
                // Final path/slop and lift are atomic, so a late timer cannot
                // engage a previously unexecuted lock just before the lift.
                _ = onInput?(.endTouchpad(contact: contact, finalDeltas: deltas))
                continue
            }
            if controllerProfile?.swipeMode == .controls,
               case .stick(let id)? = captures[touchID], let target = item(for: id),
               let contact = contactIDs[touchID] {
                _ = onInput?(.moveStick(contact: contact, travel: stickTravel(at: touch.location(in: self), in: target)))
            }
            captures.removeValue(forKey: touchID)
            touchpadPoints.removeValue(forKey: touchID)
            if let contact = contactIDs.removeValue(forKey: touchID) {
                swipeRouter?.end(contact: contact)
                _ = onInput?(.end(contact: contact))
            }
        }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if editing {
            if let drag, touches.contains(where: { ObjectIdentifier($0) == drag.touchID }) { self.drag = nil }
            return
        }
        for touch in touches {
            cancelCapturedTouch(ObjectIdentifier(touch))
        }
        // Lifecycle/geometry changes still use stopInput and global cancelAll.
        setNeedsDisplay()
    }

    private func moveDrag(using touches: Set<UITouch>) {
        guard let drag, let touch = touches.first(where: { ObjectIdentifier($0) == drag.touchID }) else { return }
        let point = touch.location(in: self)
        moveControl(drag.controlID, to: CGPoint(x: point.x - drag.offset.x, y: point.y - drag.offset.y))
    }

    private func moveControl(_ id: UUID, to desired: CGPoint) {
        guard editing, let target = item(for: id), contentRect.width > 0, contentRect.height > 0 else { return }
        let center = clampedCenter(desired, halfSize: CGSize(width: target.frame.width / 2,
                                                           height: target.frame.height / 2))
        let normalized = NormalizedControlPosition(
            x: Double((center.x - contentRect.minX) / contentRect.width),
            y: Double((center.y - contentRect.minY) / contentRect.height))
        guard var updated = controllerProfile else { return }
        do { try updated.move(id, to: normalized, orientation: orientation) }
        catch { return }
        selectedID = id
        controllerProfile = updated
        rebuildItems()
        updateAccessibility()
        setNeedsDisplay()
        onProfileChange?(updated)
    }

    private func stickTravel(at point: CGPoint, in item: Item) -> StickTravel {
        let x = Double((point.x - item.center.x) / (item.frame.width / 2))
        let y = Double((item.center.y - point.y) / (item.frame.height / 2))
        // Preserve travel beyond the rim for Extended Boost. The engine clamps
        // the visible knob and analog output separately, after validation.
        guard hypot(x, y) > 0.10 else { return .zero }
        return StickTravel(x: x, y: y)
    }

    private func activate(_ id: UUID) -> Bool {
        flushPendingCancellations()
        if editing {
            guard let target = item(for: id) else { return false }
            moveControl(id, to: target.center)
            return true
        }
        guard isPlayable(id), let target = item(for: id), !target.isStick, !target.isTouchpad, !target.isTouchAim,
              window != nil else { return false }
        // The engine owns both configured toggle behavior and pulse deadlines.
        engineInputMayBeActive = true
        _ = onInput?(.accessibilityActivate(id))
        return true
    }

    private func accessibleMove(_ id: UUID, dx: CGFloat, dy: CGFloat) -> Bool {
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

    private func configureControl(_ id: UUID) -> Bool {
        guard editing, let onConfigure else { return false }
        cancelInput(deferred: false)
        _ = onInput?(.cancelAll)
        selectedID = id
        updateAccessibility()
        setNeedsDisplay()
        onConfigure(id)
        return true
    }

    private func updateAccessibility() {
        let validIDs = Set(items.map(\.id))
        accessibilityControls = accessibilityControls.filter { validIDs.contains($0.key) }
        let floatingVisible = !editing && hasFloatingZones
        isAccessibilityElement = items.isEmpty && !floatingVisible
        if items.isEmpty && !floatingVisible {
            accessibilityLabel = placements.isEmpty ? "Empty page" : "Controller needs more space"
            accessibilityHint = "Use Edit and Add control to arrange this profile."
            accessibilityTraits = [.staticText]
            accessibilityElements = nil
            return
        }
        accessibilityLabel = nil
        accessibilityHint = nil
        var ordered: [UIAccessibilityElement] = []
        for item in items {
            let id = item.id
            let element: ProfileCanvasAccessibilityControl
            if let existing = accessibilityControls[id] {
                element = existing
            } else {
                element = ProfileCanvasAccessibilityControl(accessibilityContainer: self)
                element.activate = { [weak self] in self?.activate(id) ?? false }
                accessibilityControls[id] = element
            }
            element.accessibilityIdentifier = "profile.control.\(id.uuidString)"
            element.accessibilityLabel = accessibilityLabel(id)
            element.accessibilityFrameInContainerSpace = item.frame
            element.accessibilityCustomActions = nil
            if editing {
                element.accessibilityTraits = selectedID == id ? [.button, .selected] : [.button]
                element.accessibilityHint = "Drag to move or hold for control settings. Double-tap selects; Actions also offer movement and settings. No game input is sent."
                if let position = placements.first(where: { $0.id == id })?.position {
                    let size = "displayed \(Int(item.frame.width)) points wide by \(Int(item.frame.height)) points high"
                    element.accessibilityValue = "\(Int(position.x * 100)) percent from left, \(Int(position.y * 100)) percent from top, \(size)"
                }
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
                element.accessibilityValue = latchedControls.contains(id) ? (item.control.autoTapEnabled ? "Repeating" : "Held") :
                    retainedSticks.contains(id) ? "Retained position" : isPressed(id) ? "Pressed" : nil
                if !isPlayable(id) {
                    element.accessibilityTraits = [.button, .notEnabled]
                    element.accessibilityHint = isFullyPracticeOnly(id) && !allowExtendedControls
                        ? "These actions are unavailable on the selected connection. You can preview them in Practice." : "Controls are paused."
                } else if autoCenterCommands[id] != nil {
                    element.accessibilityTraits = allSticksAutoCenterEnabled ? [.button, .selected] : [.button]
                    element.accessibilityValue = autoCenterMixed ? "Auto-center mixed" : allSticksAutoCenterEnabled ? "Auto-center on" : "Auto-center off"
                    switch autoCenterCommands[id] {
                    case .enable: element.accessibilityHint = "Double-tap turns auto-center on for all sticks and stick-output aiming pads in this profile."
                    case .disable: element.accessibilityHint = "Double-tap turns auto-center off for all sticks and stick-output aiming pads in this profile."
                    default: element.accessibilityHint = "Double-tap switches auto-center for all sticks and stick-output aiming pads in this profile. Mixed settings switch to on first."
                    }
                } else if cameraCommands[id] != nil {
                    element.accessibilityTraits = cameraFollowSnapshot?.requestedEnabled == true ? [.button, .selected] : [.button]
                    element.accessibilityValue = CameraFollowPresentation.status(cameraFollowSnapshot)
                    switch cameraCommands[id] {
                    case .enable: element.accessibilityHint = "Double-tap turns Camera Follow on. It moves the right stick in computer receiver mode; Practice previews the output."
                    case .disable: element.accessibilityHint = "Double-tap turns Camera Follow off."
                    default: element.accessibilityHint = "Double-tap switches Camera Follow on or off. It moves the right stick in computer receiver mode; Practice previews the output. Release all turns it off."
                    }
                } else if item.isTouchpad {
                    element.accessibilityTraits = [.allowsDirectInteraction]
                    var values = [scrollModeEnabled ? "Scroll mode" : "Pointer mode"]
                    if lockedTouchpads.contains(id) { values.append("Left mouse button locked") }
                    else if pendingTouchpadLocks.contains(id) { values.append("Left lock pending") }
                    if activeTouchpads.contains(id) { values.append("Touch active") }
                    element.accessibilityValue = values.joined(separator: ", ")
                    element.accessibilityHint = "Direct touch: slide one finger to move the pointer or scroll. Practice previews the output; computer receiver mode sends it to the receiver. Click behavior follows this pad's settings. Release all clears locks and pending clicks. Double-tap activation does not create a click."
                } else if item.isStick {
                    element.accessibilityTraits = [.allowsDirectInteraction]
                    element.accessibilityHint = "Direct touch: drag from the center. Auto-center follows your saved settings unless changed by an in-game button. Release all clears retained input."
                    if let autoCenterOverride {
                        let policy = autoCenterOverride ? "Auto-center on" : "Auto-center off"
                        element.accessibilityValue = [element.accessibilityValue, policy].compactMap { $0 }.joined(separator: ", ")
                    }
                    if item.control.isDirectional {
                        element.accessibilityHint? += " Directional mode uses the configured actions and sends no analog stick movement."
                    }
                    if !allowExtendedControls && hasPracticeOnlyActions(id) {
                        element.accessibilityHint? += " Some actions are unavailable on the selected connection and are not sent."
                    }
                } else if item.isTouchAim {
                    element.accessibilityTraits = [.allowsDirectInteraction]
                    var values = [touchAimStates[id]?.rawValue.capitalized ?? "Idle"]
                    if item.control.touchAim.requiresLocalSetup { values.append("Local touch setup needed; sensor actions are paused") }
                    if let score = touchAimScores[id] { values.append("Score " + score.formatted(.number.precision(.fractionLength(2)))) }
                    if let issue = touchAimIssues[id] { values.append(issue) }
                    element.accessibilityValue = values.joined(separator: ", ")
                    element.accessibilityHint = "Direct finger touch only. Move to aim; contact measurements choose actions. Lift to center and release. Accessibility taps do not simulate sensor input."
                } else if item.control.isAdvancedButton {
                    element.accessibilityTraits = [.button, .allowsDirectInteraction]
                    var values = [String]()
                    if let state = buttonAimStates[id] { values.append(aimStateLabel(state)) }
                    if let selected = buttonDirectionalSelections[id], let direction = selected.direction, selected.stage > 0 {
                        values.append("\(direction.rawValue.capitalized) stage \(selected.stage)")
                    }
                    if latchedControls.contains(id) { values.append("Held") }
                    if retainedSticks.contains(id) { values.append("Aim position retained") }
                    element.accessibilityValue = values.joined(separator: ", ")
                    element.accessibilityHint = "Direct touch: start on this button, then drag to aim or select directional actions. Lift deliberately for release actions. This button does not slide into another control. Release all clears held actions and alternate phases."
                } else if item.control.kind == .pageButton {
                    element.accessibilityTraits = [.button]
                    element.accessibilityHint = "Double-tap to change page. Changing pages releases held controls. Sliding onto this button does not activate it."
                } else if item.control.kind == .recenter {
                    element.accessibilityTraits = [.button]
                    element.accessibilityHint = "Double-tap to center all sticks and release their actions. Other held buttons stay held."
                } else {
                    element.accessibilityTraits = latchedControls.contains(id) ? [.button, .selected] : [.button]
                    element.accessibilityHint = "Double-tap activates the configured action. Hold Toggle buttons switch between held and released. Other buttons make a short press."
                    if item.control.autoTapEnabled {
                        element.accessibilityHint = "Double-tap to start repeating. Double-tap again to stop. Release all also stops repeating."
                    }
                    if capabilities[id]?.anyOutput == false {
                        element.accessibilityHint = "No actions assigned. Edit this control to choose its actions."
                    } else if !allowExtendedControls && hasPracticeOnlyActions(id) {
                        element.accessibilityHint? += " Some of this button's actions are unavailable on the selected connection and are not sent."
                    }
                }
            }
            ordered.append(element)
        }
        var elements: [Any] = ordered
        if floatingVisible { elements.append(floatingOverlay) }
        accessibilityElements = elements
    }

    private var hasFloatingZones: Bool {
        guard let pageID, let page = controllerProfile?.page(for: pageID) else { return false }
        return !page.floatingButtonZones.isEmpty || !page.floatingRingZones.isEmpty
    }

    private func label(_ id: UUID) -> String {
        guard let control = controllerProfile?.control(for: id) else { return "Control" }
        if control.actions.count == 1, let action = control.actions.first,
           control.name == action.displayName { return action.shortLabel }
        if let stick = control.logicalStick, control.name == stick.displayName { return stick.shortLabel }
        return control.name
    }

    private func accessibilityLabel(_ id: UUID) -> String {
        guard let control = controllerProfile?.control(for: id) else { return "Control" }
        switch control.kind {
        case .leftStick: return "\(control.name), \(control.isDirectional ? "directional stick" : "left analog stick")"
        case .rightStick: return "\(control.name), \(control.isDirectional ? "directional stick" : "right analog stick")"
        case .touchpad: return "\(control.name), touchpad"
        case .touchAim: return "\(control.name), TouchAim"
        case .recenter: return "\(control.name), recenter sticks button"
        case .pageButton: return "\(control.name), page button"
        case .button: return "\(control.name), button"
        }
    }

    private func isPressed(_ id: UUID) -> Bool {
        if autoCenterCommands[id] != nil { return allSticksAutoCenterEnabled }
        if cameraCommands[id] != nil { return cameraFollowSnapshot?.requestedEnabled == true }
        if activeControls.contains(id) { return true }
        guard let control = controllerProfile?.control(for: id), control.kind == .button,
              let capability = capabilities[id], !capability.desktop, !capability.targets.isEmpty else { return false }
        // A mapped action can be owned by another button or a Stick+ stage.
        // Reflect that output without borrowing the other instance's HOLD badge.
        return capability.targets.allSatisfy { action in
            if let button = action.padButton { return displayedState.buttons.contains(button) }
            switch action {
            case .dpadUp: return [.up, .upLeft, .upRight].contains(displayedState.dpad)
            case .dpadRight: return [.right, .upRight, .downRight].contains(displayedState.dpad)
            case .dpadDown: return [.down, .downLeft, .downRight].contains(displayedState.dpad)
            case .dpadLeft: return [.left, .upLeft, .downLeft].contains(displayedState.dpad)
            default: return false
            }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        Self.background.setFill()
        context.fill(bounds)
        if editing { floatingOverlay.drawEditGuides() }
        for item in items {
            context.saveGState()
            if !editing && !isPlayable(item.id) { context.setAlpha(0.36) }
            if item.isTouchAim { drawTouchAim(item) }
            else if item.isTouchpad { drawTouchpad(item) }
            else if item.isStick { drawStick(item) }
            else { drawButton(item) }
            context.restoreGState()
            if editing && selectedID == item.id {
                let outline = item.outline(inset: -3)
                Self.selectionColor.setStroke()
                outline.lineWidth = 2
                outline.setLineDash([4, 3], count: 2, phase: 0)
                outline.stroke()
            }
        }
        if items.isEmpty && !hasFloatingZones {
            let text = placements.isEmpty
                ? "No controls on this page.\nTap Edit, then Add control."
                : "Rotate or enlarge the controller area\nto show these controls."
            drawLabel(text, in: contentRect.insetBy(dx: 15, dy: 15), size: 16, color: Self.muted)
        }
    }

    private func drawTouchAim(_ item: Item) {
        let active = !editing && activeControls.contains(item.id)
        let outline = item.outline()
        (active ? Self.cyan.withAlphaComponent(0.2) : Self.well).setFill(); outline.fill()
        Self.cyan.setStroke(); outline.lineWidth = 2; outline.stroke()
        let inset = item.frame.insetBy(dx: 8, dy: 8)
        drawLabel(label(item.id), in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: min(32, inset.height / 3)),
                  size: min(16, item.frame.height / 8), color: .label, weight: .bold)
        if !editing {
            let status = item.control.touchAim.requiresLocalSetup ? "LOCAL SETUP NEEDED" :
                (touchAimIssues[item.id] != nil ? "SENSOR UNAVAILABLE" : (touchAimStates[item.id]?.rawValue.uppercased() ?? "TOUCH TO AIM"))
            drawLabel(status, in: CGRect(x: inset.minX, y: item.center.y - 9, width: inset.width, height: 25),
                      size: min(12, item.frame.height / 10), color: Self.cyan)
            if let score = touchAimScores[item.id] {
                drawText("Score " + score.formatted(.number.precision(.fractionLength(2))),
                         at: CGPoint(x: item.center.x, y: inset.maxY - 10), size: 11, color: Self.muted)
            }
        }
    }

    private func drawButton(_ item: Item) {
        let active = !editing && isPlayable(item.id) && isPressed(item.id)
        let practiceOnly = !allowExtendedControls && isFullyPracticeOnly(item.id)
        let partial = !allowExtendedControls && !practiceOnly && hasPracticeOnlyActions(item.id)
        let latched = !editing && latchedControls.contains(item.id)
        let accent = item.control.kind == .recenter || item.control.kind == .pageButton ? Self.selectionColor : Self.green
        drawCircle(item, fill: active ? accent : Self.well,
                   stroke: latched ? Self.selectionColor : active ? .label : accent.withAlphaComponent(0.7))
        if latched {
            let outline = item.outline(inset: -2)
            Self.selectionColor.setStroke()
            outline.lineWidth = 2
            outline.stroke()
        }
        let text = label(item.id)
        let noAction = item.control.kind == .button && !item.control.isLocalAction && capabilities[item.id]?.anyOutput == false
        let advancedBadge: String? = !editing ? buttonAimStates[item.id].map(aimStateLabel) ?? buttonDirectionalSelections[item.id].flatMap { selection in
            guard let direction = selection.direction, selection.stage > 0 else { return nil }
            return "\(direction.rawValue.uppercased()) \(selection.stage)"
        } : nil
        let cameraBadge = !editing && (allowExtendedControls || allowDesktopControls) && cameraCommands[item.id] != nil
            ? CameraFollowPresentation.badge(cameraFollowSnapshot) : nil
        let centerBadge = !editing && autoCenterCommands[item.id] != nil
            ? (autoCenterMixed ? "MIXED" : allSticksAutoCenterEnabled ? "ON" : "OFF") : nil
        let badge = centerBadge ?? cameraBadge ?? advancedBadge ?? (latched ? (item.control.autoTapEnabled ? "REPEAT" : "HOLD") : practiceOnly ? "PRACTICE" : partial ? "PARTIAL" : noAction ? "NO ACTION" : nil)
        let size: CGFloat = text.count <= 2 ? min(22, item.radius * 0.72) : min(14, max(10, item.radius * 0.24))
        let labelHeight = badge == nil ? min(40, item.radius * 1.2) : min(28, item.radius * 0.8)
        let labelRect = CGRect(x: item.frame.minX + item.frame.width * 0.07,
                               y: item.center.y - labelHeight / 2 - (badge == nil ? 0 : 5),
                               width: item.frame.width * 0.86, height: labelHeight)
        drawLabel(text, in: labelRect, size: size, color: active ? Self.background : .label, weight: .bold)
        if let badge {
            drawText(badge, at: CGPoint(x: item.center.x, y: item.center.y + 8),
                     size: latched ? 7 : 6.5, color: active ? Self.background : Self.muted, weight: .semibold)
        }
    }

    private func aimStateLabel(_ state: ButtonAimVisualState) -> String {
        switch state {
        case .idle: return "READY"
        case .aiming: return "AIM"
        case .armed: return "ARMED"
        case .latchReady: return "LATCH READY"
        case .waitingToFire: return "WAIT"
        case .alternateArmed: return "ALT READY"
        case .alternateAiming: return "ALT AIM"
        case .alternateWaitingToFire: return "ALT WAIT"
        case .alternateRecovery: return "ALT RECOVERY"
        case .alternateResetReady: return "RESET READY"
        }
    }

    private func drawTouchpad(_ item: Item) {
        let playable = isPlayable(item.id)
        let active = !editing && playable && activeTouchpads.contains(item.id)
        let locked = !editing && playable && lockedTouchpads.contains(item.id)
        let pending = !editing && playable && pendingTouchpadLocks.contains(item.id)
        let accent = locked || pending ? Self.selectionColor : Self.cyan
        let outline = item.outline()
        (active ? Self.cyan.withAlphaComponent(0.12) : Self.well).setFill()
        outline.fill()
        accent.withAlphaComponent(active || locked || pending ? 1 : 0.65).setStroke()
        outline.lineWidth = locked ? 2.5 : 1.5
        if pending { outline.setLineDash([5, 3], count: 2, phase: 0) }
        outline.stroke()

        let mode = scrollModeEnabled ? "SCROLL" : "POINTER"
        let badge = !(allowExtendedControls || allowDesktopControls) ? "PRACTICE ONLY" : locked ? "LEFT LOCKED" :
            pending ? "LOCK PENDING" : active ? "TOUCHING" : nil
        let compact = item.frame.height < 88 || item.frame.width < 110
        let nameHeight: CGFloat = compact ? 14 : 32
        let nameRect = CGRect(x: item.frame.minX + 6, y: item.center.y - nameHeight / 2 - 6,
                              width: item.frame.width - 12, height: nameHeight)
        drawLabel(label(item.id), in: nameRect, size: compact ? 10 : 15, color: .label, weight: .semibold)
        let caption = compact ? badge ?? mode : mode
        let captionRect = CGRect(x: item.frame.minX + 5,
                                 y: compact ? item.center.y + 4 : item.frame.maxY - 21,
                                 width: item.frame.width - 10, height: 13)
        drawLabel(caption, in: captionRect, size: compact ? 7 : 9, color: accent, weight: .bold)
        if !compact, let badge {
            drawLabel(badge, in: CGRect(x: item.frame.minX + 8, y: item.frame.minY + 8,
                                        width: item.frame.width - 16, height: 14),
                      size: 9, color: accent, weight: .bold)
        }
        if !editing && playable,
           let captured = captures.first(where: {
               if case .touchpad(let id) = $0.value { return id == item.id }
               return false
           }), let point = touchpadPoints[captured.key] {
            // The contact remains captured outside the pad; only its marker is clamped.
            let x = min(item.frame.maxX - 8, max(item.frame.minX + 8, point.x))
            let y = min(item.frame.maxY - 8, max(item.frame.minY + 8, point.y))
            accent.setFill()
            UIBezierPath(ovalIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
        }
    }

    private func drawStick(_ item: Item) {
        let retained = !editing && retainedSticks.contains(item.id)
        drawCircle(item, fill: Self.well, stroke: retained ? Self.selectionColor : Self.cyan.withAlphaComponent(0.65))
        let position = editing ? .zero : stickPositions[item.id] ?? .zero
        // Keep the drawing inside its circular well while preserving the
        // independent axes sent to the engine, including square-range corners.
        let visualScale = max(1, hypot(position.x, position.y))
        let knob = Item(control: item.control,
                        center: CGPoint(x: item.center.x + CGFloat(position.x / visualScale) * (item.frame.width / 2) * 0.62,
                                        y: item.center.y - CGFloat(position.y / visualScale) * (item.frame.height / 2) * 0.62),
                        radius: item.radius * 0.30)
        let active = !editing && abs(position.x) + abs(position.y) > 0
        drawCircle(knob, fill: retained ? Self.selectionColor : active ? Self.cyan : Self.cyan.withAlphaComponent(0.30),
                   stroke: retained ? Self.selectionColor : Self.cyan)
        drawText(item.control.isDirectional ? "D" : item.control.logicalStick == .leftStick ? "L" : "R", at: knob.center, size: 12,
                 color: active ? Self.background : .label, verticallyCentered: true, weight: .bold)
        drawLabel(label(item.id), in: CGRect(x: item.center.x - item.radius * 0.8, y: item.frame.maxY - 18,
                                            width: item.radius * 1.6, height: 12),
                  size: 8, color: Self.muted, weight: .semibold)
        let badge = retained ? "HOLD" : !allowExtendedControls && isFullyPracticeOnly(item.id) ? "PRACTICE" :
            !allowExtendedControls && hasPracticeOnlyActions(item.id) ? "PARTIAL" :
            !editing && autoCenterOverride != nil ? (autoCenterOverride == true ? "CENTER ON" : "CENTER OFF") : item.control.isDirectional ? "DIRECTIONAL" : nil
        if let badge {
            drawText(badge, at: CGPoint(x: item.center.x, y: item.frame.minY + 8),
                     size: 8, color: retained ? Self.selectionColor : Self.muted, weight: .bold)
        }
    }

    private func drawCircle(_ item: Item, fill: UIColor, stroke: UIColor) {
        let path = item.outline()
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

    private func drawLabel(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor,
                           weight: UIFont.Weight = .regular) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph
        ]
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        let measured = (text as NSString).boundingRect(with: rect.size, options: options, attributes: attributes, context: nil)
        let height = min(rect.height, ceil(measured.height))
        let centered = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        (text as NSString).draw(with: centered, options: options, attributes: attributes, context: nil)
    }
}

private final class ProfileCanvasAccessibilityControl: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}

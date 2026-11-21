import ControllerCore
import UIKit

/// Transparent Play overlay. The parent supplies actual canvas measurements and the hit test
/// for ordinary visible controls, which keep their source-defined priority over floating UI.
final class FloatingCanvasOverlay: UIView {
    private enum Target { case button(UUID), ring(UUID), ringActions(UUID), finishButton(UUID), finishRing(UUID), summonButton(UUID), summonRing(UUID) }
    private enum Capture { case button(zone: UUID, session: UUID, contact: Int), ring(zone: UUID, session: UUID, contact: Int, began: TimeInterval) }
    private var profile: ControllerProfile?
    private var pageID: UUID?
    private var orientation: ControllerOrientation = .portrait
    private var snapshot = FloatingCanvasSnapshot(width: 1, height: 1, frames: [:])
    private var editing = false
    private var enabled = false
    private var allowExtendedControls = true
    private var allowDesktopControls = false
    private var allowTriggerControls = false
    private var active: Set<UUID> = []
    private var latched: Set<UUID> = []
    private var ringStates: [UUID: FloatingRingState] = [:]
    private var dismissedButtonSessions: [UUID: UUID] = [:]
    private var buttons: [UUID: FloatingButtonSession] = [:]
    private var order: [UUID] = []
    private var captures: [ObjectIdentifier: Capture] = [:]
    private var nextContact = -1_000_000
    private var generation: UInt64 = 0
    private let aimFeedback = UIImpactFeedbackGenerator(style: .light)
    private weak var actionsSheet: UIAlertController?
    private var ordinaryHit: (CGPoint) -> Bool = { _ in false }
    private var onInput: (ProfileInputEvent) -> Bool = { _ in false }
    private var onIssue: (String) -> Void = { _ in }
    private var page: ProfilePage? { pageID.flatMap { profile?.page(for: $0) } }

    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = false; backgroundColor = .clear
        isMultipleTouchEnabled = true; isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: FloatingCanvasOverlay, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(profile: ControllerProfile, pageID: UUID, orientation: ControllerOrientation,
                   editing: Bool, enabled: Bool, allowExtendedControls: Bool, allowDesktopControls: Bool = false, allowTriggerControls: Bool = false,
                   snapshot: FloatingCanvasSnapshot, activeControls: Set<UUID>, latchedControls: Set<UUID>,
                   ringStates: [UUID: FloatingRingState], dismissedButtonSessions: [UUID: UUID],
                   ordinaryControlHitTest: @escaping (CGPoint) -> Bool,
                   onInput: @escaping (ProfileInputEvent) -> Bool, onIssue: @escaping (String) -> Void) {
        let contextChanged = self.profile != profile || self.pageID != pageID || self.orientation != orientation ||
            self.editing != editing || self.enabled != enabled || self.allowExtendedControls != allowExtendedControls || self.allowDesktopControls != allowDesktopControls || self.allowTriggerControls != allowTriggerControls ||
            self.snapshot.width != snapshot.width || self.snapshot.height != snapshot.height
        if contextChanged { stopInput() }
        self.profile = profile; self.pageID = pageID; self.orientation = orientation; self.editing = editing
        self.enabled = enabled; self.allowExtendedControls = allowExtendedControls; self.allowDesktopControls = allowDesktopControls; self.snapshot = snapshot
        self.allowTriggerControls = allowTriggerControls
        if enabled && !editing && !contextChanged {
            for (id, state) in ringStates where state.aiming && state.geometry.config.aim.tuning.hapticsEnabled {
                if self.ringStates[id]?.aiming != true || self.ringStates[id]?.contact != state.contact {
                    aimFeedback.impactOccurred()
                }
            }
        }
        self.active = activeControls; self.latched = latchedControls; self.ringStates = ringStates
        self.dismissedButtonSessions = dismissedButtonSessions
        for (zone, sessionID) in dismissedButtonSessions where buttons[zone]?.sessionID == sessionID {
            buttons[zone] = nil
            captures = captures.filter { if case let .button(id, capturedSession, _) = $0.value { id != zone || capturedSession != sessionID } else { true } }
        }
        ordinaryHit = ordinaryControlHitTest; self.onInput = onInput; self.onIssue = onIssue
        for (id, state) in ringStates where state.visible && !order.contains(id) { order.append(id) }
        order.removeAll { buttons[$0] == nil && ringStates[$0]?.visible != true }
        isUserInteractionEnabled = enabled && !editing
        rebuildAccessibility(); setNeedsDisplay()
    }
    func stopInput(sendCancellations: Bool = true) {
        generation &+= 1
        actionsSheet?.dismiss(animated: false); actionsSheet = nil
        if sendCancellations {
            for (id, var session) in buttons {
                let sessionID = session.sessionID
                _ = session.finish(sessionID: sessionID) { [weak self] command in self?.dispatch(command, zoneID: id, sessionID: sessionID) ?? false }
            }
            for (id, state) in ringStates where state.visible { _ = onInput(.floatingRingAction(zoneID: id, sessionID: state.sessionID, action: .finish)) }
        }
        buttons = [:]; captures = [:]; order = []; ringStates = [:]; dismissedButtonSessions = [:]
        accessibilityElements = []; setNeedsDisplay()
    }
    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { stopInput() }; super.willMove(toWindow: newWindow)
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        enabled && !editing && target(at: point) != nil
    }
    private func isPlayable(_ control: ProfileControl) -> Bool {
        if control.isCameraFollowAction || control.isScrollModeToggle { return allowExtendedControls || allowDesktopControls }
        if allowExtendedControls || control.isLocalAction || !control.hasAnyOutput || (allowDesktopControls && control.hasKeyboardOrMouseOutputs) { return true }
        return !control.outputTargets.subtracting(practiceOnlyActions).isEmpty
    }
    private func isPlayable(_ zone: FloatingRingZone) -> Bool {
        allowExtendedControls || !zone.config.hasAnyOutput || (allowDesktopControls && zone.config.hasDesktopOutputs) || !zone.config.outputTargets.subtracting(practiceOnlyActions).isEmpty
    }
    private var practiceOnlyActions: Set<ControllerControlID> {
        allowTriggerControls ? [.guide, .share] : [.leftTrigger, .rightTrigger, .guide, .share]
    }
    private func target(at point: CGPoint) -> Target? {
        guard bounds.contains(point), !ordinaryHit(point), let page else { return nil }
        let p = point.floatingPoint
        // Actual surfaced targets win; invisible direct-boost bands are checked separately.
        for id in order.reversed() {
            if let session = buttons[id], !session.isFinished {
                if session.placement.finish.contains(p) { return .finishButton(id) }
                if session.placement.members.reversed().contains(where: { memberContains($0, point: point) }) { return .button(id) }
            }
            if let state = ringStates[id], state.visible, state.placement.bounds.contains(p) {
                if state.placement.finish.contains(p) { return state.placement.bounds.width < 100 ? .ringActions(id) : .finishRing(id) }
                if ringActionsFrame(state).contains(point) { return .ringActions(id) }
                let local = state.placement.local(p, applyGrabOffset: false)
                if state.geometry.role(at: local) != nil { return .ring(id) }
            }
        }
        for id in order.reversed() {
            if let state = ringStates[id], state.visible {
                let local = state.placement.local(p, applyGrabOffset: false)
                if state.geometry.directHit(.one, at: local) || state.geometry.directHit(.two, at: local) { return .ring(id) }
            }
        }
        for zone in page.floatingRingZones.reversed() where zone.enabled && ringStates[zone.id]?.visible != true && isPlayable(zone) {
            if activation(zone.geometry(for: orientation))?.contains(p) == true { return .summonRing(zone.id) }
        }
        for zone in page.floatingButtonZones.reversed() where zone.enabled && buttons[zone.id] == nil {
            guard zone.memberIDs.contains(where: { profile?.control(for: $0).map(isPlayable) == true }) else { continue }
            if activation(zone.geometry(for: orientation))?.contains(p) == true { return .summonButton(zone.id) }
        }
        return nil
    }
    private func activation(_ geometry: FloatingZoneGeometry?) -> FloatingRect? {
        try? geometry?.resolved(canvasWidth: snapshot.width, canvasHeight: snapshot.height)
    }
    private func memberContains(_ member: FloatingMemberGeometry, point: CGPoint) -> Bool {
        guard let control = profile?.control(for: member.id), isPlayable(control) else { return false }
        return memberPath(member, control: control).contains(point)
    }
    private func memberPath(_ member: FloatingMemberGeometry, control: ProfileControl) -> UIBezierPath {
        control.controlWidth != nil || control.controlHeight != nil || (!control.orientationDimensions.isEmpty && abs(member.frame.width - member.frame.height) > 0.01)
            ? UIBezierPath(roundedRect: member.frame.uiRect, cornerRadius: min(14, member.frame.uiRect.height * 0.18))
            : UIBezierPath(ovalIn: member.frame.uiRect)
    }
    private func allocateContact() -> Int { nextContact -= 1; return nextContact }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard enabled, !editing, let target = target(at: touch.location(in: self)) else { continue }
            let token = ObjectIdentifier(touch), point = touch.location(in: self).floatingPoint, contact = allocateContact(), version = generation
            do {
                switch target {
                case let .finishButton(zone): finishButton(zone)
                case let .finishRing(zone): finishRing(zone)
                case let .ringActions(zone): showRingActions(zone)
                case let .summonButton(zoneID):
                    guard let profile, let zone = page?.floatingButtonZones.first(where: { $0.id == zoneID }) else { continue }
                    var session = try FloatingButtonSession(zone: zone, orientation: orientation, canonicalGeometry: snapshot.frames,
                                                            touch: point, usable: snapshot.usable, routing: zone.routing(in: profile))
                    let sessionID = session.sessionID
                    guard onInput(.registerFloatingButtonSession(zoneID: zoneID, sessionID: sessionID)), version == generation else { continue }
                    let accepted = session.beginActivation(contact: contact, sessionID: sessionID) { [weak self] command in self?.dispatch(command, zoneID: zoneID, sessionID: sessionID) ?? false }
                    guard version == generation, dismissedButtonSessions[zoneID] != sessionID else { continue }
                    buttons[zoneID] = session; promote(zoneID)
                    if accepted { captures[token] = .button(zone: zoneID, session: session.sessionID, contact: contact) }
                case let .button(zoneID):
                    guard var session = buttons[zoneID] else { continue }
                    let sessionID = session.sessionID
                    let accepted = session.begin(contact: contact, at: point, sessionID: sessionID) { [weak self] command in self?.dispatch(command, zoneID: zoneID, sessionID: sessionID) ?? false }
                    guard version == generation, dismissedButtonSessions[zoneID] != sessionID else { continue }; buttons[zoneID] = session
                    if accepted { captures[token] = .button(zone: zoneID, session: session.sessionID, contact: contact); promote(zoneID) }
                case let .summonRing(zoneID), let .ring(zoneID):
                    let session = ringStates[zoneID]?.visible == true ? ringStates[zoneID]!.sessionID : UUID()
                    if onInput(.beginFloatingRing(contact: contact, zoneID: zoneID, sessionID: session, point: point, usable: snapshot.usable)), version == generation {
                        captures[token] = .ring(zone: zoneID, session: session, contact: contact, began: touch.timestamp); promote(zoneID)
                    }
                }
            } catch { onIssue(error.localizedDescription) }
        }
        rebuildAccessibility(); setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { deliver(touches, event: event, ending: false) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { deliver(touches, event: event, ending: true) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { cancel(ObjectIdentifier(touch)) }; setNeedsDisplay()
    }
    private func deliver(_ touches: Set<UITouch>, event: UIEvent?, ending: Bool) {
        for touch in touches {
            let token = ObjectIdentifier(touch)
            guard let capture = captures[token] else { continue }
            let path = (event?.coalescedTouches(for: touch) ?? []) + [touch]
            guard path.count <= 256, path.allSatisfy({ $0.location(in: self).floatingPoint.isValid }) else { cancel(token); continue }
            let version = generation
            do {
                switch capture {
                case let .button(zoneID, sessionID, contact):
                    guard var session = buttons[zoneID], session.sessionID == sessionID else { captures[token] = nil; continue }
                    let points = path.map { $0.location(in: self).floatingPoint }
                    if ending {
                        _ = try session.end(contact: contact, through: points, sessionID: sessionID) { [weak self] command in self?.dispatch(command, zoneID: zoneID, sessionID: sessionID) ?? false }
                    } else {
                        _ = try session.move(contact: contact, through: points, sessionID: sessionID) { [weak self] command in self?.dispatch(command, zoneID: zoneID, sessionID: sessionID) ?? false }
                    }
                    if version == generation { buttons[zoneID] = session.isFinished || dismissedButtonSessions[zoneID] == sessionID ? nil : session }
                    if session.isFinished { captures[token] = nil; order.removeAll { $0 == zoneID } }
                case let .ring(_, sessionID, contact, began):
                    let samples = path.map { FloatingRingSample(point: $0.location(in: self).floatingPoint, elapsed: $0.timestamp - began) }
                    guard samples.allSatisfy(\.isValid), zip(samples, samples.dropFirst()).allSatisfy({ $0.0.elapsed <= $0.1.elapsed }) else { cancel(token); continue }
                    let event: ProfileInputEvent = ending ? .endFloatingRing(contact: contact, sessionID: sessionID, samples: samples)
                        : .moveFloatingRing(contact: contact, sessionID: sessionID, samples: samples)
                    if !onInput(event) { cancel(token) }
                }
            } catch { cancel(token); onIssue(error.localizedDescription) }
            if ending { captures[token] = nil }
        }
        rebuildAccessibility(); setNeedsDisplay()
    }
    private func cancel(_ token: ObjectIdentifier) {
        guard let capture = captures.removeValue(forKey: token) else { return }
        switch capture {
        case let .button(zoneID, sessionID, contact):
            guard var session = buttons[zoneID] else { return }
            _ = session.cancel(contact: contact, sessionID: sessionID) { [weak self] command in self?.dispatch(command, zoneID: zoneID, sessionID: sessionID) ?? false }
            if dismissedButtonSessions[zoneID] != sessionID { buttons[zoneID] = session }
        case let .ring(_, sessionID, contact, _): _ = onInput(.cancelFloatingRing(contact: contact, sessionID: sessionID))
        }
    }
    private func dispatch(_ command: FloatingButtonCommand, zoneID: UUID, sessionID: UUID) -> Bool {
        guard dismissedButtonSessions[zoneID] != sessionID else { return false }
        switch command {
        case let .begin(member, contact, sample):
            guard let control = profile?.control(for: member), isPlayable(control) else { return false }
            return onInput(control.isAdvancedButton ? .beginButton(contact: contact, control: member, sample: sample) : .begin(contact: contact, control: member, position: .zero))
        case let .move(member, contact, samples):
            return onInput(profile?.control(for: member)?.isAdvancedButton == true ? .moveButtonBatch(contact: contact, samples: samples) : .move(contact: contact, position: .zero))
        case let .handoff(contact, _, target, _, _):
            guard let control = profile?.control(for: target), isPlayable(control) else { return false }
            return onInput(.handoffFloatingButton(contact: contact, zoneID: zoneID, to: target))
        case let .end(member, contact, samples):
            return onInput(profile?.control(for: member)?.isAdvancedButton == true ? .endButton(contact: contact, finalSamples: samples) : .end(contact: contact))
        case let .cancel(_, contact): return onInput(.cancel(contact: contact))
        case .finishScope: return onInput(.finishFloatingButtonSession(zoneID: zoneID, sessionID: sessionID))
        }
    }
    private func promote(_ id: UUID) { order.removeAll { $0 == id }; order.append(id) }
    private func finishButton(_ id: UUID, expectedSession: UUID? = nil) {
        guard var session = buttons[id], expectedSession == nil || expectedSession == session.sessionID else { return }
        let sessionID = session.sessionID
        _ = session.finish(sessionID: sessionID) { [weak self] command in self?.dispatch(command, zoneID: id, sessionID: sessionID) ?? false }
        buttons[id] = nil; order.removeAll { $0 == id }
        captures = captures.filter { if case let .button(zone, _, _) = $0.value { zone != id } else { true } }
    }
    private func finishRing(_ id: UUID, expectedSession: UUID? = nil) {
        guard let state = ringStates[id], expectedSession == nil || expectedSession == state.sessionID else { return }
        _ = onInput(.floatingRingAction(zoneID: id, sessionID: state.sessionID, action: .finish))
        captures = captures.filter { if case let .ring(zone, _, _, _) = $0.value { zone != id } else { true } }
    }
    private func ringActionsFrame(_ state: FloatingRingState) -> CGRect {
        if state.placement.bounds.width < 100 { return state.placement.finish.uiRect }
        return .init(x: state.placement.bounds.x, y: state.placement.bounds.y,
                     width: min(96, state.placement.bounds.width - 52), height: 48)
    }
    private func showRingActions(_ id: UUID) {
        guard actionsSheet == nil, let state = ringStates[id], state.visible else { return }
        var responder: UIResponder? = self
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let presenter = responder as? UIViewController, presenter.presentedViewController == nil else { return }
        let session = state.sessionID, version = generation
        let sheet = UIAlertController(title: page?.floatingRingZones.first(where: { $0.id == id })?.name ?? "Ring actions",
                                      message: (["These actions affect only this ring."] + state.boostBankStatus + [state.issue].compactMap { $0 }).joined(separator: "\n"), preferredStyle: .actionSheet)
        for (title, action) in [("Stop firing", FloatingLocalAction.stopFire), ("Release ADS", .releaseADS),
                                ("End camera suppression", .endSuppression), ("Finish ring", .finish)] {
            sheet.addAction(UIAlertAction(title: title, style: action == .finish ? .destructive : .default) { [weak self] _ in
                guard let self, self.generation == version, self.ringStates[id]?.sessionID == session else { return }
                if action == .finish { self.finishRing(id) }
                else { _ = self.onInput(.floatingRingAction(zoneID: id, sessionID: session, action: action)) }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = self
        sheet.popoverPresentationController?.sourceRect = ringActionsFrame(state)
        actionsSheet = sheet; presenter.present(sheet, animated: true)
    }

    /// Draw in the parent canvas so ordinary controls stay above the sample thresholds.
    func drawEditGuides() {
        guard editing, let page else { return }
        for zone in page.floatingRingZones {
            guard let frame = activation(zone.geometry(for: orientation)),
                  let geometry = try? FloatingRingGeometry(config: zone.config),
                  let sample = geometry.place(at: frame.center, usable: snapshot.usable) else { continue }
            let center = CGPoint(x: sample.origin.x + geometry.center.x, y: sample.origin.y + geometry.center.y)
            let config = zone.config
            let separate = config.boostBanks != nil || config.compactAimBoosts || config.adjacentMovementBoosts
            for role in (separate ? RingBoostBank.allCases : [.movement]) {
                let participates = role == .aim ? config.aim.participateInBoosts : config.movement.participateInBoosts
                for stage in RingBoostStage.allCases {
                    let radius = geometry.boostDistance(stage, bank: role)
                    let enabled = zone.enabled && participates && config.boost(stage, bank: role).enabled
                    let color = (stage == .one ? UIColor.systemOrange : .systemPurple).withAlphaComponent(enabled ? 0.76 : 0.38)
                    let path = UIBezierPath(ovalIn: CGRect(x: center.x-radius, y: center.y-radius, width: 2*radius, height: 2*radius))
                    if role == .aim { path.setLineDash([2, 4], count: 2, phase: 0) }
                    else if !enabled { path.setLineDash([7, 5], count: 2, phase: 0) }
                    color.setStroke(); path.lineWidth = 1.25; path.stroke()
                    let name = (separate ? (role == .aim ? "Aim " : "Move ") : "") + (stage == .one ? "B1" : "B2")
                    let y = role == .aim ? center.y + radius - 14 : center.y - radius
                    label(enabled ? name : name + " off", in: CGRect(x: center.x-38, y: y, width: 76, height: 14), color: color, size: 10)
                }
            }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let page else { return }
        for zone in page.floatingButtonZones where editing || buttons[zone.id] == nil {
            if let frame = activation(zone.geometry(for: orientation)) { drawZone(frame, name: zone.name, enabled: zone.enabled) }
        }
        for zone in page.floatingRingZones where editing || ringStates[zone.id]?.visible != true {
            if let frame = activation(zone.geometry(for: orientation)) { drawZone(frame, name: zone.name, enabled: zone.enabled) }
        }
        guard !editing else { return }
        for id in order {
            if let session = buttons[id], !session.isFinished { drawButtonSession(session) }
            if let state = ringStates[id], state.visible { drawRing(state) }
        }
    }
    private func drawZone(_ frame: FloatingRect, name: String, enabled: Bool) {
        let rectangle = frame.uiRect, color = enabled ? UIColor.systemCyan : .systemGray
        color.withAlphaComponent(editing ? 0.10 : 0.035).setFill()
        let path = UIBezierPath(roundedRect: rectangle, cornerRadius: 12); path.fill()
        color.withAlphaComponent(editing ? 0.8 : 0.35).setStroke(); path.lineWidth = 1.5
        path.setLineDash([5,4], count: 2, phase: 0); path.stroke()
        label(enabled ? name : "\(name) · Disabled", in: rectangle.insetBy(dx: 8, dy: 8), color: color.withAlphaComponent(0.85), size: 12)
    }
    private func drawButtonSession(_ session: FloatingButtonSession) {
        UIColor.secondarySystemBackground.withAlphaComponent(0.94).setFill(); UIBezierPath(roundedRect: session.placement.bounds.uiRect, cornerRadius: 14).fill()
        drawFinish(session.placement.finish.uiRect)
        for member in session.placement.members {
            guard let control = profile?.control(for: member.id) else { continue }
            let pressed = active.contains(member.id) || latched.contains(member.id), path = memberPath(member, control: control)
            (pressed ? UIColor.systemGreen.withAlphaComponent(0.35) : UIColor.systemCyan.withAlphaComponent(0.10)).setFill(); path.fill()
            (isPlayable(control) ? UIColor.systemCyan : UIColor.systemGray).setStroke(); path.lineWidth = pressed ? 3 : 1.5; path.stroke()
            label(control.name, in: member.frame.uiRect.insetBy(dx: 5, dy: 5), color: .label, size: 14)
            if latched.contains(member.id) { label("Held", in: .init(x:member.frame.uiRect.minX,y:member.frame.uiRect.maxY-19,width:member.frame.uiRect.width,height:15), color:.systemGreen,size:10) }
        }
    }
    private func drawRing(_ state: FloatingRingState) {
        let g = state.geometry, config = g.config
        let center = CGPoint(x: state.placement.origin.x + g.center.x, y: state.placement.origin.y + g.center.y)
        func circle(_ radius: Double, color: UIColor, fill: Bool = false) {
            let path = UIBezierPath(ovalIn:.init(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
            if fill { color.withAlphaComponent(0.13).setFill(); path.fill() }
            color.setStroke(); path.lineWidth = 1.5
            path.stroke()
        }
        let compact = config.compactAimBoosts && config.aim.participateInBoosts && state.contact != nil && state.role == .aim
        let visibleRadius = compact ? config.innerRadius : g.visibleRadius
        UIColor.secondarySystemBackground.withAlphaComponent(0.94).setFill()
        UIBezierPath(ovalIn: .init(x: center.x-visibleRadius, y: center.y-visibleRadius,
                                  width: visibleRadius*2, height: visibleRadius*2)).fill()
        if config.movement.enabled && !compact { circle(config.movementRadius,color:.systemCyan,fill:true) }
        if config.aim.enabled { circle(config.innerRadius,color:.systemBlue,fill:true) }
        for knob in config.knobs where config.aim.enabled && knob.enabled {
            guard let frame = state.knobFrames[knob.id] else { continue }
            let path = UIBezierPath(ovalIn:frame.uiRect)
            (state.aiming ? UIColor.systemBlue.withAlphaComponent(0.25) : UIColor.tertiarySystemFill).setFill(); path.fill()
            UIColor.label.withAlphaComponent(0.8).setStroke(); path.lineWidth = 1; path.stroke()
            label(knob.name.isEmpty ? "Aim" : knob.name,in:frame.uiRect.insetBy(dx:3,dy:3),color:.label,size:11)
        }
        if config.movement.enabled && !compact {
            let point = CGPoint(x:center.x+state.movement.x*config.movementRadius,y:center.y-state.movement.y*config.movementRadius)
            UIColor.systemCyan.setFill(); UIBezierPath(ovalIn:.init(x:point.x-8,y:point.y-8,width:16,height:16)).fill()
        }
        drawFinish(state.placement.finish.uiRect)
        let actions = ringActionsFrame(state)
        UIColor.tertiarySystemBackground.setFill(); UIBezierPath(roundedRect: actions, cornerRadius: 10).fill()
        UIColor.separator.setStroke(); let actionsOutline = UIBezierPath(roundedRect: actions, cornerRadius: 10); actionsOutline.lineWidth = 1.5; actionsOutline.stroke()
        label("Actions", in: actions.insetBy(dx: 3, dy: 3), color: .label, size: 12)
        let status = [state.ads ? "ADS" : nil,state.firing ? "Fire" : nil,state.armed ? "Armed" : nil,state.pending ? "Waiting" : nil,state.retained ? "Held" : nil,state.fine ? "Fine" : nil].compactMap { $0 }
        let statusText = (status + state.boostBankStatus).joined(separator:" · ")
        if !statusText.isEmpty { label(statusText,in:.init(x:state.placement.bounds.x,y:state.placement.bounds.y+state.placement.bounds.height-20,width:state.placement.bounds.width,height:20),color:.label,size:10) }
    }
    private func drawFinish(_ rectangle: CGRect) {
        UIColor.systemRed.withAlphaComponent(0.18).setFill(); UIBezierPath(roundedRect:rectangle,cornerRadius:10).fill()
        UIColor.systemRed.setStroke(); let outline = UIBezierPath(roundedRect:rectangle,cornerRadius:10); outline.lineWidth = 1.5; outline.stroke()
        label("Finish",in:rectangle.insetBy(dx:4,dy:4),color:.label,size:13)
    }
    private func label(_ text: String, in rect: CGRect, color: UIColor, size: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key:Any] = [.font:UIFont.systemFont(ofSize:size,weight:.semibold),.foregroundColor:color,.paragraphStyle:style]
        let measured = (text as NSString).boundingRect(with:rect.size,options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attributes,context:nil)
        let aligned = CGRect(x:rect.minX,y:rect.midY-min(rect.height,measured.height)/2,width:rect.width,height:min(rect.height,measured.height))
        (text as NSString).draw(with:aligned,options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attributes,context:nil)
    }
    private func rebuildAccessibility() {
        guard enabled, !editing, let page else { accessibilityElements = []; return }
        var elements: [UIAccessibilityElement] = []
        func add(_ name: String, frame: CGRect, action: @escaping () -> Bool) {
            let item = FloatingAccessibilityElement(accessibilityContainer:self)
            item.accessibilityLabel = name; item.accessibilityTraits = .button
            item.accessibilityFrameInContainerSpace = frame; item.perform = action; elements.append(item)
        }
        for zone in page.floatingButtonZones where zone.enabled {
            guard zone.memberIDs.contains(where: { profile?.control(for: $0).map(isPlayable) == true }) else { continue }
            if let session = buttons[zone.id] {
                add("Finish \(zone.name)",frame:session.placement.finish.uiRect) { [weak self] in self?.finishButton(zone.id, expectedSession: session.sessionID); self?.setNeedsDisplay(); self?.rebuildAccessibility(); return true }
                for member in session.placement.members {
                    guard let control = profile?.control(for:member.id), isPlayable(control) else { continue }
                    add(control.name,frame:member.frame.uiRect) { [weak self] in
                        guard let self, self.enabled, !self.editing, self.buttons[zone.id]?.sessionID == session.sessionID,
                              self.dismissedButtonSessions[zone.id] != session.sessionID else { return false }
                        return self.onInput(.accessibilityActivate(member.id))
                    }
                }
            } else if let rectangle = activation(zone.geometry(for:orientation)) {
                add("Activate floating \(zone.name)",frame:rectangle.uiRect) { [weak self] in self?.accessibilitySummonButton(zone,at:rectangle.center) ?? false }
            }
        }
        for zone in page.floatingRingZones where zone.enabled && isPlayable(zone) {
            if let state = ringStates[zone.id], state.visible {
                add("Actions for \(zone.name)", frame: ringActionsFrame(state)) { [weak self] in self?.showRingActions(zone.id); return true }
                add("Finish \(zone.name)",frame:state.placement.finish.uiRect) { [weak self] in self?.finishRing(zone.id, expectedSession: state.sessionID); return true }
                for (title,action) in [("Stop firing",FloatingLocalAction.stopFire),("Release ADS",.releaseADS),("End camera suppression",.endSuppression)] {
                    let item = UIAccessibilityCustomAction(name:title) { [weak self] _ in self?.onInput(.floatingRingAction(zoneID:zone.id,sessionID:state.sessionID,action:action)) ?? false }
                    elements.last?.accessibilityCustomActions = (elements.last?.accessibilityCustomActions ?? []) + [item]
                }
            } else if let rectangle = activation(zone.geometry(for:orientation)) {
                add("Activate floating \(zone.name)",frame:rectangle.uiRect) { [weak self] in
                    guard let self else { return false }; let contact = self.allocateContact(), session = UUID()
                    guard self.onInput(.beginFloatingRing(contact:contact,zoneID:zone.id,sessionID:session,point:rectangle.center,usable:self.snapshot.usable)) else { return false }
                    _ = self.onInput(.endFloatingRing(contact:contact,sessionID:session,samples:[])); self.promote(zone.id); return true
                }
            }
        }
        accessibilityElements = elements
    }
    private func accessibilitySummonButton(_ zone: FloatingButtonZone, at point: FloatingPoint) -> Bool {
        guard let profile, enabled, !editing, page?.floatingButtonZones.contains(zone) == true, buttons[zone.id] == nil else { return false }
        let version = generation
        do {
            var session = try FloatingButtonSession(zone:zone,orientation:orientation,canonicalGeometry:snapshot.frames,touch:point,usable:snapshot.usable,routing:zone.routing(in:profile))
            let contact = allocateContact(), sessionID = session.sessionID
            guard onInput(.registerFloatingButtonSession(zoneID: zone.id, sessionID: sessionID)), version == generation else { return false }
            _ = session.beginActivation(contact:contact,sessionID:session.sessionID) { _ in true }
            _ = try session.end(contact:contact,through:[],sessionID:session.sessionID) { _ in true }
            buttons[zone.id] = session; promote(zone.id)
            if let start = zone.startMemberID { _ = onInput(.accessibilityActivate(start)) }
            rebuildAccessibility(); setNeedsDisplay(); return true
        } catch { onIssue(error.localizedDescription); return false }
    }
}

private final class FloatingAccessibilityElement: UIAccessibilityElement {
    var perform: (() -> Bool)?
    override func accessibilityActivate() -> Bool { perform?() ?? false }
}
private extension CGPoint { var floatingPoint: FloatingPoint { .init(x:Double(x),y:Double(y)) } }
private extension FloatingRect { var uiRect: CGRect { .init(x:x,y:y,width:width,height:height) } }

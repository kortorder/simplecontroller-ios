import SwiftUI
import UIKit
import ControllerCore

/// UIKit contact measurements, not an estimate of pressure. Zero radius and
/// unsupported force stay unavailable instead of becoming a synthetic signal.
enum TouchMetricCapture {
    static func metrics(_ touch: UITouch, in view: UIView) -> TouchMetrics {
        let radius = Double(touch.majorRadius)
        let tolerance = Double(touch.majorRadiusTolerance)
        var force: Double?
        if view.traitCollection.forceTouchCapability == .available {
            let maximum = Double(touch.maximumPossibleForce)
            let value = Double(touch.force)
            if maximum.isFinite, maximum > 0, value.isFinite, value >= 0, value <= maximum {
                force = value / maximum
            }
        }
        return TouchMetrics(majorRadius: radius.isFinite && radius > 0 && radius <= 1200 ? radius : nil,
                            radiusTolerance: tolerance.isFinite && tolerance >= 0 && tolerance <= 1200 ? tolerance : nil,
                            normalizedForce: force)
    }
}

/// Has no reference to the controller, transport, payload engine or persistence.
struct TouchMetricPad: UIViewRepresentable {
    var enabled: Bool
    var resetID: UUID
    var onSample: (TouchAimCalibrationSample) -> Void
    var onEnd: (Bool, Double) -> Void

    func makeUIView(context: Context) -> TouchMetricPadView { TouchMetricPadView() }
    func updateUIView(_ view: TouchMetricPadView, context: Context) {
        view.onSample = onSample; view.onEnd = onEnd
        view.configure(enabled: enabled, resetID: resetID)
    }
    static func dismantleUIView(_ view: TouchMetricPadView, coordinator: ()) { view.stop() }
}

final class TouchMetricPadView: UIView {
    var onSample: ((TouchAimCalibrationSample) -> Void)?
    var onEnd: ((Bool, Double) -> Void)?
    private var activeTouch: UITouch?
    private var startedAt: TimeInterval = 0
    private var lastSampleAt: TimeInterval = 0
    private var lastPoint: CGPoint = .zero
    private var movingUntil: TimeInterval = 0
    private var motionWindow = TouchAimMotionWindow()
    private var lastMotionTimestamp: TimeInterval = 0
    private var count = 0
    private var link: CADisplayLink?
    private var resetID: UUID?
    private var enabled = false
    private lazy var measurementPan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(measurementPanChanged))
        recognizer.minimumNumberOfTouches = 1; recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false; recognizer.delaysTouchesBegan = false
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        addGestureRecognizer(measurementPan)
        backgroundColor = UIColor.secondarySystemBackground
        layer.borderWidth = 2; layer.borderColor = UIColor.systemTeal.cgColor
        layer.cornerRadius = 16
        isAccessibilityElement = true
        accessibilityLabel = "No-output touch measurement pad"
        accessibilityHint = "Touch with one finger. Hold still, then move in small circles and lift. This pad sends no controller actions."
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
                                              name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view") }
    deinit { link?.invalidate(); NotificationCenter.default.removeObserver(self) }
    func configure(enabled: Bool, resetID: UUID) {
        if self.resetID != resetID || !enabled { stop() }
        self.resetID = resetID; self.enabled = enabled
        alpha = enabled ? 1 : 0.5
    }
    func stop() {
        link?.invalidate(); link = nil; activeTouch = nil; count = 0
        motionWindow.reset(); lastMotionTimestamp = 0; movingUntil = 0
        setNeedsDisplay()
    }
    @objc private func interrupted() { finish(completed: false) }
    @objc private func measurementPanChanged(_ recognizer: UIPanGestureRecognizer) { }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop(); return }
        // Moving on the measurement surface must stay a sensor gesture, not scroll
        // the surrounding instructions. Raw UIKit touch callbacks remain enabled.
        var ancestor = superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView { scroll.panGestureRecognizer.require(toFail: measurementPan) }
            ancestor = current.superview
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch; startedAt = CACurrentMediaTime(); lastSampleAt = startedAt - 1
        movingUntil = 0; lastPoint = touch.location(in: self); count = 0
        motionWindow.reset(); lastMotionTimestamp = touch.timestamp
        guard (try? motionWindow.observe(x: Double(lastPoint.x), y: Double(lastPoint.y), at: touch.timestamp)) != nil else {
            finish(completed: false); return
        }
        sample(now: startedAt)
        let displayLink = CADisplayLink(target: self, selector: #selector(frameTick))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        displayLink.add(to: .main, forMode: .common); link = displayLink
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        // Use each point's own event time. Small coalesced segments must combine
        // into genuine displacement; bounded jitter must not accumulate forever.
        let observedAt = CACurrentMediaTime()
        for observation in event?.coalescedTouches(for: touch) ?? [touch] {
            // UIKit may repeat a previously delivered point in a coalesced batch.
            guard observation.timestamp >= lastMotionTimestamp else { continue }
            let point = observation.location(in: self)
            do {
                if try motionWindow.observe(x: Double(point.x), y: Double(point.y), at: observation.timestamp) {
                    movingUntil = observedAt + TouchAimMotionWindow.observationWindow
                }
            } catch {
                finish(completed: false); return
            }
            lastMotionTimestamp = observation.timestamp; lastPoint = point
        }
        setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        // Lift measurements can collapse. Do not classify that terminal sample.
        finish(completed: true)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        finish(completed: false)
    }
    @objc private func frameTick(_ sender: CADisplayLink) { sample(now: CACurrentMediaTime()) }
    private func sample(now: TimeInterval) {
        guard let touch = activeTouch, now - lastSampleAt >= 0.025 else { return }
        guard count < 256, now - startedAt <= 30 else { finish(completed: false); return }
        lastSampleAt = now; count += 1
        onSample?(.init(metrics: TouchMetricCapture.metrics(touch, in: self),
                        elapsed: max(0, now - startedAt), moving: now < movingUntil))
        setNeedsDisplay()
    }
    private func finish(completed: Bool) {
        guard activeTouch != nil else { return }
        let duration = max(0, CACurrentMediaTime() - startedAt)
        stop(); onEnd?(completed, duration)
    }
    override func draw(_ rect: CGRect) {
        guard activeTouch != nil else { return }
        UIColor.systemTeal.withAlphaComponent(0.3).setFill()
        UIBezierPath(ovalIn: CGRect(x: lastPoint.x - 18, y: lastPoint.y - 18, width: 36, height: 36)).fill()
    }
}

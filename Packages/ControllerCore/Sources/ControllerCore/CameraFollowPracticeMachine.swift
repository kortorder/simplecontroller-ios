import Foundation

public struct CameraFollowError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Source-audited receiver defaults. This value has no transport or persistence.
public struct CameraFollowTuning: Equatable, Sendable {
    public var movementDeadzone: Double
    public var manualRightDeadzone: Double
    public var activationDelayMilliseconds: Int
    public var manualOverrideMilliseconds: Int
    public var gain: Double
    public var maximumOutput: Double
    public var rampInMilliseconds: Int
    public var rampOutMilliseconds: Int
    public var invertDirection: Bool
    public var allowSidewaysSteering: Bool
    public init(movementDeadzone: Double = 0.20, manualRightDeadzone: Double = 0.15,
                activationDelayMilliseconds: Int = 200, manualOverrideMilliseconds: Int = 750,
                gain: Double = 0.55, maximumOutput: Double = 0.45,
                rampInMilliseconds: Int = 180, rampOutMilliseconds: Int = 120,
                invertDirection: Bool = false, allowSidewaysSteering: Bool = true) {
        self.movementDeadzone = movementDeadzone; self.manualRightDeadzone = manualRightDeadzone
        self.activationDelayMilliseconds = activationDelayMilliseconds; self.manualOverrideMilliseconds = manualOverrideMilliseconds
        self.gain = gain; self.maximumOutput = maximumOutput
        self.rampInMilliseconds = rampInMilliseconds; self.rampOutMilliseconds = rampOutMilliseconds
        self.invertDirection = invertDirection; self.allowSidewaysSteering = allowSidewaysSteering
    }
    public static let `default` = Self()
    public func validate() throws {
        guard movementDeadzone.isFinite, (0...1).contains(movementDeadzone),
              manualRightDeadzone.isFinite, (0...1).contains(manualRightDeadzone),
              gain.isFinite, (0...5).contains(gain), maximumOutput.isFinite, (0...1).contains(maximumOutput),
              [activationDelayMilliseconds, manualOverrideMilliseconds, rampInMilliseconds, rampOutMilliseconds]
                .allSatisfy({ (0...60_000).contains($0) }) else {
            throw CameraFollowError("Camera Follow timing, gain or deadzone is invalid.")
        }
    }
}

/// Feed already-arbitrated input owners. A live right-stick capture suppresses
/// assistance even at its neutral position; mouse suppression is also owner-derived.
public struct CameraFollowInputs: Equatable, Sendable {
    public var leftStick: StickPosition
    public var leftAllowsFollow: Bool
    public var manualRightStick: StickPosition
    public var macroRightStick: StickPosition
    public var manualRightContactActive: Bool
    public var mouseSuppressed: Bool
    public init(leftStick: StickPosition = .zero, leftAllowsFollow: Bool = true,
                manualRightStick: StickPosition = .zero, macroRightStick: StickPosition = .zero,
                manualRightContactActive: Bool = false, mouseSuppressed: Bool = false) {
        self.leftStick = leftStick; self.leftAllowsFollow = leftAllowsFollow
        self.manualRightStick = manualRightStick; self.macroRightStick = macroRightStick
        self.manualRightContactActive = manualRightContactActive; self.mouseSuppressed = mouseSuppressed
    }
    public static let neutral = Self()
    public func validate() throws {
        guard [leftStick, manualRightStick, macroRightStick].allSatisfy({
            $0.x.isFinite && $0.y.isFinite && (-1...1).contains($0.x) && (-1...1).contains($0.y)
        }) else { throw CameraFollowError("Camera Follow inputs must be finite normalized stick positions.") }
    }
}

public enum CameraFollowOutputSource: String, Equatable, Sendable {
    case macro, manual, manualOverride, cameraFollow, neutral, suppressed
}
public struct CameraFollowPracticeSnapshot: Equatable, Sendable {
    public let requestedEnabled: Bool
    public let effectiveEnabled: Bool
    public let strengthPercent: Double
    public let manualRightContactActive: Bool
    public let mouseSuppressed: Bool
    public var suppressed: Bool { manualRightContactActive || mouseSuppressed }
    public let generatedRightStick: StickPosition
    public let rightStick: StickPosition
    public let source: CameraFollowOutputSource
    public let nextDeadline: TimeInterval?
}

/// Deterministic local reproduction of the original receiver's camera assistance.
/// No leases, UIKit, networking or gamepad transport are accessed. Integration must
/// keep generated assistance out of bridge output until separately supported.
public struct CameraFollowPracticeMachine: Sendable {
    public let tuning: CameraFollowTuning
    public private(set) var inputs: CameraFollowInputs = .neutral
    public private(set) var requestedEnabled = false
    public private(set) var strengthPercent = 100.0
    private var effectiveEnabled = false
    private var movementStartedAt: Double?
    private var manualOverrideUntil = 0.0
    private var generatedX = 0.0
    private var lastTarget = 0.0
    private var lastStepAt: Double
    private var lastTime: Double
    private var selectedRightStick: StickPosition = .zero
    private var selectedSource: CameraFollowOutputSource = .manual

    public init(tuning: CameraFollowTuning = .default, at time: TimeInterval = 0) throws {
        try tuning.validate(); try Self.validateTime(time)
        self.tuning = tuning; lastTime = time; lastStepAt = time
    }
    public var snapshot: CameraFollowPracticeSnapshot {
        .init(requestedEnabled: requestedEnabled, effectiveEnabled: effectiveEnabled, strengthPercent: strengthPercent,
              manualRightContactActive: inputs.manualRightContactActive, mouseSuppressed: inputs.mouseSuppressed,
              generatedRightStick: .init(x: generatedX), rightStick: selectedRightStick,
              source: selectedSource, nextDeadline: nextDeadline)
    }
    public var nextDeadline: TimeInterval? {
        var deadlines: [Double] = []
        if !macroActive && !manualActive && manualOverrideUntil > lastTime { deadlines.append(manualOverrideUntil) }
        if effectiveEnabled && !macroActive && !manualActive && leftIsMoving,
           let start = movementStartedAt {
            let activation = start + Double(tuning.activationDelayMilliseconds) / 1000
            if activation > lastTime { deadlines.append(max(activation, manualOverrideUntil)) }
        }
        if abs(cameraTarget(at: lastTime) - generatedX) > 1e-12 { deadlines.append(lastTime + 0.01) }
        return deadlines.filter { $0 > lastTime && $0.isFinite }.min()
    }
    public mutating func setEnabled(_ enabled: Bool, at time: TimeInterval) throws {
        try acceptTime(time); requestedEnabled = enabled
        synchronizeEffectiveState(at: time); step(at: time)
    }
    public mutating func toggle(at time: TimeInterval) throws { try setEnabled(!requestedEnabled, at: time) }
    public mutating func setStrengthPercent(_ percent: Double, at time: TimeInterval) throws {
        guard percent.isFinite, (0...200).contains(percent) else { throw CameraFollowError("Camera Follow strength must be 0–200 percent.") }
        try acceptTime(time)
        if strengthPercent != percent {
            let old = strengthPercent; strengthPercent = percent
            generatedX = clamp(old > 0 ? generatedX / old * percent : 0, to: maximumOutput)
            let target = cameraTarget(at: time)
            if abs(generatedX) > abs(target) { generatedX = target }
            lastTarget = old > 0 ? lastTarget / old * percent : 0
            lastStepAt = time
        }
        step(at: time)
    }
    public mutating func updateInputs(_ value: CameraFollowInputs, at time: TimeInterval) throws {
        try value.validate(); try acceptTime(time)
        let wasMoving = leftIsMoving, wasManual = manualActive
        inputs = value
        if !value.leftAllowsFollow {
            movementStartedAt = nil; generatedX = 0; lastTarget = 0; lastStepAt = time
        } else if leftIsMoving && !wasMoving { movementStartedAt = time }
        else if !leftIsMoving { movementStartedAt = nil }
        if wasManual && !manualActive { manualOverrideUntil = time + Double(tuning.manualOverrideMilliseconds) / 1000 }
        synchronizeEffectiveState(at: time); step(at: time)
    }
    public mutating func tick(at time: TimeInterval) throws { try acceptTime(time); step(at: time) }

    /// Cancels the assistance generated by movement without disturbing a manual right
    /// stick, mouse suppression, or the user's enabled/strength preferences.
    mutating func clearLeftInput(at time: TimeInterval) throws {
        try acceptTime(time); inputs.leftStick = .zero; movementStartedAt = nil
        generatedX = 0; lastTarget = 0; lastStepAt = time
        synchronizeEffectiveState(at: time); step(at: time)
    }
    /// Source clear_inputs behavior: keeps the requested toggle and strength but
    /// removes every input, timeout and ramp. New movement must activate afresh.
    public mutating func clearInputs(at time: TimeInterval) throws {
        try acceptTime(time); inputs = .neutral; movementStartedAt = nil; manualOverrideUntil = 0
        generatedX = 0; lastTarget = 0; lastStepAt = time
        effectiveEnabled = requestedEnabled; step(at: time)
    }
    /// Native lifecycle safety boundary. Preserve preference strength, but require
    /// a fresh explicit enable after Release all/profile/background cancellation.
    public mutating func reset(at time: TimeInterval) throws {
        try acceptTime(time); requestedEnabled = false; try clearInputs(at: time)
    }
    private var maximumOutput: Double { min(1, tuning.maximumOutput * strengthPercent / 100) }
    private var leftIsMoving: Bool { inputs.leftAllowsFollow && hypot(inputs.leftStick.x, inputs.leftStick.y) > tuning.movementDeadzone }
    private var manualActive: Bool { hypot(inputs.manualRightStick.x, inputs.manualRightStick.y) > tuning.manualRightDeadzone }
    private var macroActive: Bool { hypot(inputs.macroRightStick.x, inputs.macroRightStick.y) > 0.0001 }
    private mutating func synchronizeEffectiveState(at time: Double) {
        let enabled = requestedEnabled && !inputs.manualRightContactActive && !inputs.mouseSuppressed
        guard enabled != effectiveEnabled else { return }
        effectiveEnabled = enabled; generatedX = 0; lastTarget = 0; lastStepAt = time
        movementStartedAt = enabled && leftIsMoving ? time : nil
    }
    private func cameraTarget(at time: Double) -> Double {
        guard effectiveEnabled, !macroActive, !manualActive, time >= manualOverrideUntil, leftIsMoving,
              let start = movementStartedAt, time >= start + Double(tuning.activationDelayMilliseconds) / 1000,
              tuning.allowSidewaysSteering || abs(inputs.leftStick.y) > tuning.movementDeadzone else { return 0 }
        let direction = tuning.invertDirection ? -1.0 : 1.0
        return clamp(inputs.leftStick.x * tuning.gain * strengthPercent / 100 * direction, to: maximumOutput)
    }
    private mutating func step(at time: Double) {
        var elapsed = max(0, time - lastStepAt); lastStepAt = time
        let target = cameraTarget(at: time)
        // The activation wait must never become accumulated ramp time.
        if abs(target) > 0.0001 && abs(lastTarget) <= 0.0001 { elapsed = 0 }
        let ramp = abs(target) > abs(generatedX) ? tuning.rampInMilliseconds : tuning.rampOutMilliseconds
        if ramp <= 0 { generatedX = target }
        else {
            // Two complete ranges suffice for even a full direction reversal;
            // bounding elapsed avoids overflow after a very late scheduler call.
            let delta = maximumOutput * min(elapsed, 2 * Double(ramp) / 1000) * 1000 / Double(ramp)
            generatedX = generatedX < target ? min(generatedX + delta, target) : max(generatedX - delta, target)
        }
        generatedX = clamp(generatedX, to: maximumOutput); lastTarget = target
        if macroActive { selectedRightStick = inputs.macroRightStick; selectedSource = .macro }
        else if manualActive { selectedRightStick = inputs.manualRightStick; selectedSource = .manual }
        else if time < manualOverrideUntil { selectedRightStick = inputs.manualRightStick; selectedSource = .manualOverride }
        else if effectiveEnabled && abs(generatedX) > 0.0001 { selectedRightStick = .init(x: generatedX); selectedSource = .cameraFollow }
        else if !effectiveEnabled {
            selectedRightStick = inputs.manualRightStick
            selectedSource = requestedEnabled ? .suppressed : .manual
        } else { selectedRightStick = .zero; selectedSource = .neutral }
    }
    private func clamp(_ value: Double, to maximum: Double) -> Double { max(-maximum, min(maximum, value)) }
    private mutating func acceptTime(_ time: Double) throws {
        try Self.validateTime(time)
        guard time >= lastTime else { throw CameraFollowError("Camera Follow time cannot move backwards.") }
        lastTime = time
    }
    private static func validateTime(_ time: Double) throws {
        guard time.isFinite, time >= 0 else { throw CameraFollowError("Camera Follow time must be finite and nonnegative.") }
    }
}

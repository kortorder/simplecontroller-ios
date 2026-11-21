import Foundation

public enum ButtonAimOutput: String, Codable, CaseIterable, Sendable { case mouse, gameMouse, leftStick, rightStick, dpad
    public var logicalStick: ControllerControlID? { self == .leftStick ? .leftStick : self == .rightStick ? .rightStick : nil }
    public var isMouse: Bool { self == .mouse || self == .gameMouse }
}
public enum ButtonAimPayloadTiming: String, Codable, CaseIterable, Sendable { case immediate, sendOnRelease }
public enum ButtonAimMouseResponse: String, Codable, CaseIterable, Sendable { case linearRelative, smoothedNonlinear }
public enum ButtonAimOrigin: String, Codable, CaseIterable, Sendable { case initialTouch, controlCenter }
public enum ButtonAimDpadMode: String, Codable, CaseIterable, Sendable { case fourWay, eightWay }
public enum ButtonAlternatePhase: String, Codable, Sendable { case base, alternateArmed, alternateRecovery }
public enum ButtonAimVisualState: String, Sendable { case idle, aiming, armed, latchReady, waitingToFire, alternateArmed, alternateAiming, alternateWaitingToFire, alternateRecovery, alternateResetReady }

/// Local UIKit points; +X right, +Y down. Coordinates may leave the rectangle.
public struct ButtonPointerSample: Equatable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
    public var isValid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && abs(x) <= 65_536 && abs(y) <= 65_536 && (1...1200).contains(width) && (1...1200).contains(height) }
    public var isInside: Bool { x >= 0 && y >= 0 && x < width && y < height }
}
public struct ButtonDirectionalSelection: Equatable, Sendable {
    public var direction: StickDirection?; public var stage: Int
    public init(direction: StickDirection? = nil, stage: Int = 0) { self.direction=direction; self.stage=stage }
}
public struct ButtonFeedback: Equatable, Sendable {
    public enum Kind: String, Sendable { case engaged, latchReady, alternateArmed, resetReady, cancelled }
    public var control: UUID; public var kind: Kind
    public init(control: UUID, kind: Kind) { self.control=control; self.kind=kind }
}

/// Advanced gesture leases accept releasable outputs, including owned trigger pulses.
/// WAIT, force-UP and local edge commands remain available on ordinary buttons.
func advancedButtonProgram(_ source: String) throws -> ControllerPayloadProgram {
    let program = try ControllerPayloadProgram.parse(source)
    for step in program.steps {
        switch step {
        case .digital, .keyDown, .mouseDown, .triggerPressure, .triggerPulse, .fixedStick: break
        case .wait, .mouseUp, .scrollModeToggle, .releaseAll, .cameraFollow, .autoCenter:
            throw ControllerPayloadError("Advanced button payloads need releasable outputs; WAIT, mouse UP and local actions are not supported here.")
        }
    }
    return program
}

func validateAimCommandTiming(_ program: ControllerPayloadProgram, default timing: ButtonAimPayloadTiming) throws {
    if timing == .sendOnRelease && program.modifiers.contains(where: { $0.repeatMilliseconds != nil && $0.timing != .immediate }) {
        throw ControllerPayloadError("Button Aim set to Send on release needs (I) on a repeating command so it can repeat while held.")
    }
}

public struct ButtonDirectionStages: Codable, Equatable, Sendable {
    public var firstDistance: Double
    public var secondDistance: Double
    public var firstPayload: String
    public var secondPayload: String
    public init(firstDistance: Double = 48, secondDistance: Double = 96, firstPayload: String = "", secondPayload: String = "") {
        self.firstDistance = firstDistance
        self.secondDistance = secondDistance
        self.firstPayload = firstPayload
        self.secondPayload = secondPayload
    }
    public func validate() throws {
        guard firstDistance.isFinite, secondDistance.isFinite, (1...1200).contains(firstDistance), (2...1200).contains(secondDistance), secondDistance >= firstDistance + 1 else { throw ControllerPayloadError("Directional distances must be 1–1200 points, with Second at least 1 point beyond First.") }
        _ = try advancedButtonProgram(firstPayload); _ = try advancedButtonProgram(secondPayload)
    }
    private enum CodingKeys: String, CodingKey { case firstDistance, secondDistance, firstPayload, secondPayload }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["firstDistance", "secondDistance", "firstPayload", "secondPayload"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstDistance = try c.decode(Double.self, forKey: .firstDistance)
        secondDistance = try c.decode(Double.self, forKey: .secondDistance)
        firstPayload = try c.decode(String.self, forKey: .firstPayload)
        secondPayload = try c.decode(String.self, forKey: .secondPayload)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(firstDistance, forKey: .firstDistance)
        try c.encode(secondDistance, forKey: .secondDistance)
        try c.encode(firstPayload, forKey: .firstPayload)
        try c.encode(secondPayload, forKey: .secondPayload)
    }
}

public struct ButtonAimTuning: Codable, Equatable, Sendable {
    public var output: ButtonAimOutput
    public var sensitivity: Double
    public var invertY: Bool
    public var stickResponse: StickResponseMode
    public var mouseResponse: ButtonAimMouseResponse
    public var origin: ButtonAimOrigin
    public var fullDisplacement: Double
    public var deadzone: Double
    public var autoCenter: Bool
    public var dpadMode: ButtonAimDpadMode
    public var dpadOrigin: ButtonAimOrigin
    public var dpadActivationDistance: Double
    public var hapticsEnabled: Bool
    public init(output: ButtonAimOutput = .mouse, sensitivity: Double = 1, invertY: Bool = false, stickResponse: StickResponseMode = .linear, mouseResponse: ButtonAimMouseResponse = .smoothedNonlinear, origin: ButtonAimOrigin = .initialTouch, fullDisplacement: Double = 220, deadzone: Double = 8, autoCenter: Bool = true, dpadMode: ButtonAimDpadMode = .eightWay, dpadOrigin: ButtonAimOrigin = .controlCenter, dpadActivationDistance: Double = 8, hapticsEnabled: Bool = true) {
        self.output = output
        self.sensitivity = sensitivity
        self.invertY = invertY
        self.stickResponse = stickResponse
        self.mouseResponse = mouseResponse
        self.origin = origin
        self.fullDisplacement = fullDisplacement
        self.deadzone = deadzone
        self.autoCenter = autoCenter
        self.dpadMode = dpadMode
        self.dpadOrigin = dpadOrigin
        self.dpadActivationDistance = dpadActivationDistance
        self.hapticsEnabled = hapticsEnabled
    }
    public func validate() throws {
        guard sensitivity.isFinite, (0...5).contains(sensitivity), fullDisplacement.isFinite, (1...1200).contains(fullDisplacement), deadzone.isFinite, deadzone >= 0, deadzone < fullDisplacement, dpadActivationDistance.isFinite, (0...1200).contains(dpadActivationDistance) else { throw ControllerPayloadError("Aim sensitivity must be 0–5; displacement 1–1200 points; deadzone must be smaller than displacement.") }
    }
    private enum CodingKeys: String, CodingKey { case output, sensitivity, invertY, stickResponse, mouseResponse, origin, fullDisplacement, deadzone, autoCenter, dpadMode, dpadOrigin, dpadActivationDistance, hapticsEnabled }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["output", "sensitivity", "invertY", "stickResponse", "mouseResponse", "origin", "fullDisplacement", "deadzone", "autoCenter", "dpadMode", "dpadOrigin", "dpadActivationDistance", "hapticsEnabled"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        output = try c.decode(ButtonAimOutput.self, forKey: .output)
        sensitivity = try c.decode(Double.self, forKey: .sensitivity)
        invertY = try c.decode(Bool.self, forKey: .invertY)
        stickResponse = try c.decode(StickResponseMode.self, forKey: .stickResponse)
        mouseResponse = try c.decode(ButtonAimMouseResponse.self, forKey: .mouseResponse)
        origin = try c.decode(ButtonAimOrigin.self, forKey: .origin)
        fullDisplacement = try c.decode(Double.self, forKey: .fullDisplacement)
        deadzone = try c.decode(Double.self, forKey: .deadzone)
        autoCenter = try c.decode(Bool.self, forKey: .autoCenter)
        dpadMode = try c.decode(ButtonAimDpadMode.self, forKey: .dpadMode)
        dpadOrigin = try c.decode(ButtonAimOrigin.self, forKey: .dpadOrigin)
        dpadActivationDistance = try c.decode(Double.self, forKey: .dpadActivationDistance)
        hapticsEnabled = try c.decode(Bool.self, forKey: .hapticsEnabled)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(output, forKey: .output)
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(invertY, forKey: .invertY)
        try c.encode(stickResponse, forKey: .stickResponse)
        try c.encode(mouseResponse, forKey: .mouseResponse)
        try c.encode(origin, forKey: .origin)
        try c.encode(fullDisplacement, forKey: .fullDisplacement)
        try c.encode(deadzone, forKey: .deadzone)
        try c.encode(autoCenter, forKey: .autoCenter)
        try c.encode(dpadMode, forKey: .dpadMode)
        try c.encode(dpadOrigin, forKey: .dpadOrigin)
        try c.encode(dpadActivationDistance, forKey: .dpadActivationDistance)
        try c.encode(hapticsEnabled, forKey: .hapticsEnabled)
    }
}

public struct ButtonAimAlternateSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var payload: String
    public var payloadTiming: ButtonAimPayloadTiming
    public var resetHoldMilliseconds: Int
    public var baseUnlatchDelayMilliseconds: Int
    public var displayName: String
    public var tuning: ButtonAimTuning
    public init(enabled: Bool = false, payload: String = "", payloadTiming: ButtonAimPayloadTiming = .immediate, resetHoldMilliseconds: Int = 2000, baseUnlatchDelayMilliseconds: Int = 0, displayName: String = "", tuning: ButtonAimTuning = .init()) {
        self.enabled = enabled
        self.payload = payload
        self.payloadTiming = payloadTiming
        self.resetHoldMilliseconds = resetHoldMilliseconds
        self.baseUnlatchDelayMilliseconds = baseUnlatchDelayMilliseconds
        self.displayName = displayName
        self.tuning = tuning
    }
    public func validate() throws {
        guard (0...60_000).contains(resetHoldMilliseconds), (0...60_000).contains(baseUnlatchDelayMilliseconds), displayName.count <= 64 else { throw ControllerPayloadError("Alternate timing must be 0–60000 ms and its name at most 64 characters.") }
        try tuning.validate(); let program = try advancedButtonProgram(payload)
        if enabled && !program.hasAnyOutput { throw ControllerPayloadError("Alternate needs a payload.") }
    }
    private enum CodingKeys: String, CodingKey { case enabled, payload, payloadTiming, resetHoldMilliseconds, baseUnlatchDelayMilliseconds, displayName, tuning }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "payload", "payloadTiming", "resetHoldMilliseconds", "baseUnlatchDelayMilliseconds", "displayName", "tuning"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        payload = try c.decode(String.self, forKey: .payload)
        payloadTiming = try c.decode(ButtonAimPayloadTiming.self, forKey: .payloadTiming)
        resetHoldMilliseconds = try c.decode(Int.self, forKey: .resetHoldMilliseconds)
        baseUnlatchDelayMilliseconds = try c.decode(Int.self, forKey: .baseUnlatchDelayMilliseconds)
        displayName = try c.decode(String.self, forKey: .displayName)
        tuning = try c.decode(ButtonAimTuning.self, forKey: .tuning)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(payload, forKey: .payload)
        try c.encode(payloadTiming, forKey: .payloadTiming)
        try c.encode(resetHoldMilliseconds, forKey: .resetHoldMilliseconds)
        try c.encode(baseUnlatchDelayMilliseconds, forKey: .baseUnlatchDelayMilliseconds)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(tuning, forKey: .tuning)
    }
}

public struct ButtonAimSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var payloadTiming: ButtonAimPayloadTiming
    public var releaseDelayMilliseconds: Int
    public var cancelOnBoundaryExit: Bool
    public var rearmOnBoundaryReturn: Bool
    public var tuning: ButtonAimTuning
    public var alternate: ButtonAimAlternateSettings
    public init(enabled: Bool = false, payloadTiming: ButtonAimPayloadTiming = .immediate, releaseDelayMilliseconds: Int = 0, cancelOnBoundaryExit: Bool = false, rearmOnBoundaryReturn: Bool = false, tuning: ButtonAimTuning = .init(), alternate: ButtonAimAlternateSettings = .init()) {
        self.enabled = enabled
        self.payloadTiming = payloadTiming
        self.releaseDelayMilliseconds = releaseDelayMilliseconds
        self.cancelOnBoundaryExit = cancelOnBoundaryExit
        self.rearmOnBoundaryReturn = rearmOnBoundaryReturn
        self.tuning = tuning
        self.alternate = alternate
    }
    public func validate() throws {
        guard (0...60_000).contains(releaseDelayMilliseconds) else { throw ControllerPayloadError("Release delay must be 0–60000 ms.") }
        try tuning.validate(); try alternate.validate()
    }
    private enum CodingKeys: String, CodingKey { case enabled, payloadTiming, releaseDelayMilliseconds, cancelOnBoundaryExit, rearmOnBoundaryReturn, tuning, alternate }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "payloadTiming", "releaseDelayMilliseconds", "cancelOnBoundaryExit", "rearmOnBoundaryReturn", "tuning", "alternate"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        payloadTiming = try c.decode(ButtonAimPayloadTiming.self, forKey: .payloadTiming)
        releaseDelayMilliseconds = try c.decode(Int.self, forKey: .releaseDelayMilliseconds)
        cancelOnBoundaryExit = try c.decode(Bool.self, forKey: .cancelOnBoundaryExit)
        rearmOnBoundaryReturn = try c.decode(Bool.self, forKey: .rearmOnBoundaryReturn)
        tuning = try c.decode(ButtonAimTuning.self, forKey: .tuning)
        alternate = try c.decode(ButtonAimAlternateSettings.self, forKey: .alternate)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(payloadTiming, forKey: .payloadTiming)
        try c.encode(releaseDelayMilliseconds, forKey: .releaseDelayMilliseconds)
        try c.encode(cancelOnBoundaryExit, forKey: .cancelOnBoundaryExit)
        try c.encode(rearmOnBoundaryReturn, forKey: .rearmOnBoundaryReturn)
        try c.encode(tuning, forKey: .tuning)
        try c.encode(alternate, forKey: .alternate)
    }
}

public struct ButtonDirectionalSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var directions: [StickDirection: ButtonDirectionStages]
    public init(enabled: Bool = false, directions: [StickDirection: ButtonDirectionStages] = Dictionary(uniqueKeysWithValues: StickDirection.allCases.map { ($0, .init()) })) { self.enabled=enabled; self.directions=directions }
    public func validate() throws {
        guard Set(directions.keys) == Set(StickDirection.allCases) else { throw ControllerPayloadError("All four button directions must be present.") }
        for value in directions.values { try value.validate() }
    }
    public func selection(dx: Double, dy: Double, previous: ButtonDirectionalSelection = .init()) throws -> ButtonDirectionalSelection {
        try validate(); guard dx.isFinite, dy.isFinite, abs(dx) <= 131_072, abs(dy) <= 131_072 else { throw ControllerInputError.invalidPosition }
        let horizontal = abs(dx), vertical = abs(dy)
        var direction: StickDirection = horizontal >= vertical ? (dx >= 0 ? .right : .left) : (dy >= 0 ? .down : .up)
        if previous.stage > 0, let old = previous.direction, direction != old {
            let oldHorizontal = old == .left || old == .right
            let newHorizontal = direction == .left || direction == .right
            // Source's axis hysteresis also blocked a direct sign reversal indefinitely.
            // Keep 12-point hysteresis only between axes; opposite directions switch safely.
            if oldHorizontal != newHorizontal && (newHorizontal ? horizontal : vertical) < (oldHorizontal ? horizontal : vertical) + 12 { direction = old }
        }
        let stages = directions[direction]!
        let distance = direction == .left || direction == .right ? horizontal : vertical
        let same = previous.direction == direction
        let second = stages.secondDistance - (same && previous.stage >= 2 ? min(4, (stages.secondDistance-stages.firstDistance)/2) : 0)
        let first = stages.firstDistance - (same && previous.stage >= 1 ? min(4, stages.firstDistance/2) : 0)
        let stage = distance >= second ? 2 : distance >= first ? 1 : 0
        return stage == 0 ? .init() : .init(direction: direction, stage: stage)
    }
    private enum CodingKeys: String, CodingKey { case enabled, directions }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "directions"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        let values = try c.decode([String: ButtonDirectionStages].self, forKey: .directions)
        guard Set(values.keys) == Set(StickDirection.allCases.map(\.rawValue)) else { throw ControllerProfileError.invalidFormat }
        directions = Dictionary(uniqueKeysWithValues: values.map { (StickDirection(rawValue: $0.key)!, $0.value) }); try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(Dictionary(uniqueKeysWithValues: directions.map { ($0.key.rawValue, $0.value) }), forKey: .directions)
    }
}

import Foundation

// Adapted from the Android floating controls, including role-specific boost geometry.
// Dimensions are iOS points; saved x/y geometry is +Y down. Runtime output uses +Y up.
// Templates contain no captured contacts, timers, live claims or placement.
public enum FloatingStartRole: String, Codable, CaseIterable, Sendable { case movement, aim, boostOne, boostTwo }
public enum RingBoostStage: String, Codable, CaseIterable, Sendable { case one, two }
public enum RingAction: String, Codable, CaseIterable, Sendable { case tap, hold, `repeat` }
public enum RingFireMode: String, Codable, CaseIterable, Sendable { case none, hold, tap, releaseShot, `repeat` }
public enum FloatingLocalAction: String, Codable, CaseIterable, Sendable { case finish, stopFire, releaseADS, endSuppression }

func ringProgram(_ source: String) throws -> ControllerPayloadProgram {
    guard source.count <= 1_000 else { throw FloatingControlError("A ring payload must be at most 1000 characters.") }
    let value = try ControllerPayloadProgram.parse(source)
    guard !value.steps.contains(where: { step in
        switch step { case .releaseAll: true; default: false }
    }) else { throw FloatingControlError("Ring actions do not support Release all; use the scoped Finish control.") }
    try value.validateSustained()
    return value
}
enum RingOutputKey: Hashable, Sendable {
    case digital(ControllerControlID), key(KeyboardKey), mouse(PracticeMouseButton), trigger(TriggerChannel), fixedStick(FixedStickChannel)
}
func ringKeys(_ source: String) -> Set<RingOutputKey> {
    guard let value = try? ringProgram(source) else { return [] }
    return Set(value.steps.compactMap { step in
        switch step {
        case let .digital(id):
            if id == .leftTrigger { return .trigger(.left) }
            if id == .rightTrigger { return .trigger(.right) }
            return .digital(id)
        case let .keyDown(key): return .key(key)
        case let .mouseDown(button): return .mouse(button)
        case let .triggerPressure(channel, _), let .triggerPulse(channel, _, _): return .trigger(channel)
        case let .fixedStick(macro): return .fixedStick(macro.channel)
        default: return nil
        }
    })
}

public struct RingDirectionalPayloads: Codable, Equatable, Sendable {
    public var up: String
    public var right: String
    public var down: String
    public var left: String
    public init(up: String = "", right: String = "", down: String = "", left: String = "") {
        self.up = up
        self.right = right
        self.down = down
        self.left = left
    }
    public func validate() throws {
        for value in values { _ = try ringProgram(value) }
    }
    public var values: [String] { [up, right, down, left] }
    public func value(for direction: StickDirection) -> String {
        switch direction { case .up: up; case .right: right; case .down: down; case .left: left }
    }
    private enum CodingKeys: String, CodingKey { case up, right, down, left }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["up", "right", "down", "left"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        up = try c.decode(String.self, forKey: .up)
        right = try c.decode(String.self, forKey: .right)
        down = try c.decode(String.self, forKey: .down)
        left = try c.decode(String.self, forKey: .left)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(up, forKey: .up)
        try c.encode(right, forKey: .right)
        try c.encode(down, forKey: .down)
        try c.encode(left, forKey: .left)
    }
}

public struct RingMovementSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var output: ButtonAimOutput
    public var sensitivity: Double
    public var response: StickResponseMode
    public var autoCenter: Bool
    public var excludeFromCameraFollow: Bool
    public var initialX: Double
    public var initialY: Double
    public var participateInBoosts: Bool
    public init(enabled: Bool = true, output: ButtonAimOutput = .leftStick, sensitivity: Double = 1, response: StickResponseMode = .linear, autoCenter: Bool = true, excludeFromCameraFollow: Bool = false, initialX: Double = 0, initialY: Double = 0, participateInBoosts: Bool = true) {
        self.enabled = enabled
        self.output = output
        self.sensitivity = sensitivity
        self.response = response
        self.autoCenter = autoCenter
        self.excludeFromCameraFollow = excludeFromCameraFollow
        self.initialX = initialX
        self.initialY = initialY
        self.participateInBoosts = participateInBoosts
    }
    public func validate() throws {
        guard output == .leftStick || output == .rightStick, sensitivity.isFinite, (0...5).contains(sensitivity),
              initialX.isFinite, initialY.isFinite, hypot(initialX, initialY) <= 1 + 1e-10 else {
            throw FloatingControlError("Ring movement needs a stick output, sensitivity 0–5 and a normalized starting vector.")
        }
    }
    /// Saved geometry uses view coordinates: positive Y points down.
    public var initialPosition: StickPosition { .init(x: initialX, y: -initialY) }
    private enum CodingKeys: String, CodingKey { case enabled, output, sensitivity, response, autoCenter, excludeFromCameraFollow, initialX, initialY, participateInBoosts }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "output", "sensitivity", "response", "autoCenter", "excludeFromCameraFollow", "initialX", "initialY", "participateInBoosts"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        output = try c.decode(ButtonAimOutput.self, forKey: .output)
        sensitivity = try c.decode(Double.self, forKey: .sensitivity)
        response = try c.decode(StickResponseMode.self, forKey: .response)
        autoCenter = try c.decode(Bool.self, forKey: .autoCenter)
        excludeFromCameraFollow = try c.decode(Bool.self, forKey: .excludeFromCameraFollow)
        initialX = try c.decode(Double.self, forKey: .initialX)
        initialY = try c.decode(Double.self, forKey: .initialY)
        participateInBoosts = try c.decode(Bool.self, forKey: .participateInBoosts)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(output, forKey: .output)
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(response, forKey: .response)
        try c.encode(autoCenter, forKey: .autoCenter)
        try c.encode(excludeFromCameraFollow, forKey: .excludeFromCameraFollow)
        try c.encode(initialX, forKey: .initialX)
        try c.encode(initialY, forKey: .initialY)
        try c.encode(participateInBoosts, forKey: .participateInBoosts)
    }
}

public struct RingFineAimSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var sensitivity: Double
    public var qualifyingStages: Set<RingBoostStage>
    public var persistWhileAdsLatched: Bool
    public init(enabled: Bool = false, sensitivity: Double = 0.4, qualifyingStages: Set<RingBoostStage> = [.one], persistWhileAdsLatched: Bool = true) {
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.qualifyingStages = qualifyingStages
        self.persistWhileAdsLatched = persistWhileAdsLatched
    }
    public func validate() throws {
        guard sensitivity.isFinite, (0...5).contains(sensitivity), !qualifyingStages.isEmpty else {
            throw FloatingControlError("Fine aim needs sensitivity 0–5 and a qualifying boost.")
        }
    }

    private enum CodingKeys: String, CodingKey { case enabled, sensitivity, qualifyingStages, persistWhileAdsLatched }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "sensitivity", "qualifyingStages", "persistWhileAdsLatched"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        sensitivity = try c.decode(Double.self, forKey: .sensitivity)
        let qualifyingStagesValues = try c.decode([RingBoostStage].self, forKey: .qualifyingStages)
        qualifyingStages = Set(qualifyingStagesValues)
        guard qualifyingStages.count == qualifyingStagesValues.count else { throw FloatingControlError("Duplicate qualifying stages.") }
        persistWhileAdsLatched = try c.decode(Bool.self, forKey: .persistWhileAdsLatched)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(qualifyingStages.sorted { $0.rawValue < $1.rawValue }, forKey: .qualifyingStages)
        try c.encode(persistWhileAdsLatched, forKey: .persistWhileAdsLatched)
    }
}

public struct RingAimSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var tuning: ButtonAimTuning
    public var continueOutside: Bool
    public var participateInBoosts: Bool
    public var suppressCameraFollow: Bool
    public var fine: RingFineAimSettings
    public init(enabled: Bool = true, tuning: ButtonAimTuning = .init(mouseResponse: .linearRelative), continueOutside: Bool = true, participateInBoosts: Bool = false, suppressCameraFollow: Bool = false, fine: RingFineAimSettings = .init()) {
        self.enabled = enabled
        self.tuning = tuning
        self.continueOutside = continueOutside
        self.participateInBoosts = participateInBoosts
        self.suppressCameraFollow = suppressCameraFollow
        self.fine = fine
    }
    public func validate() throws {
        guard tuning.output == .mouse || tuning.output == .gameMouse || tuning.output == .rightStick else {
            throw FloatingControlError("Ring aim supports Mouse, Game Mouse or Right Stick.")
        }
        try tuning.validate(); try fine.validate()
    }

    private enum CodingKeys: String, CodingKey { case enabled, tuning, continueOutside, participateInBoosts, suppressCameraFollow, fine }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "tuning", "continueOutside", "participateInBoosts", "suppressCameraFollow", "fine"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        tuning = try c.decode(ButtonAimTuning.self, forKey: .tuning)
        continueOutside = try c.decode(Bool.self, forKey: .continueOutside)
        participateInBoosts = try c.decode(Bool.self, forKey: .participateInBoosts)
        suppressCameraFollow = try c.decode(Bool.self, forKey: .suppressCameraFollow)
        fine = try c.decode(RingFineAimSettings.self, forKey: .fine)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(tuning, forKey: .tuning)
        try c.encode(continueOutside, forKey: .continueOutside)
        try c.encode(participateInBoosts, forKey: .participateInBoosts)
        try c.encode(suppressCameraFollow, forKey: .suppressCameraFollow)
        try c.encode(fine, forKey: .fine)
    }
}

public struct RingReturnFireSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var qualifyingStages: Set<RingBoostStage>
    public var delayMilliseconds: Int
    public var cancelOnExit: Bool
    public var startOnBoostEntry: Bool = false
    public init(enabled: Bool = false, qualifyingStages: Set<RingBoostStage> = [.one], delayMilliseconds: Int = 0, cancelOnExit: Bool = true) {
        self.enabled = enabled
        self.qualifyingStages = qualifyingStages
        self.delayMilliseconds = delayMilliseconds
        self.cancelOnExit = cancelOnExit
    }
    public func validate() throws {
        guard (0...60_000).contains(delayMilliseconds), !qualifyingStages.isEmpty else {
            throw FloatingControlError("Return fire needs a delay of 0–60000 ms and a qualifying boost.")
        }
    }

    private enum CodingKeys: String, CodingKey { case enabled, qualifyingStages, delayMilliseconds, cancelOnExit, startOnBoostEntry }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "qualifyingStages", "delayMilliseconds", "cancelOnExit"], optional: ["startOnBoostEntry"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startOnBoostEntry = try c.decodeIfPresent(Bool.self, forKey: .startOnBoostEntry) ?? false
        enabled = try c.decode(Bool.self, forKey: .enabled)
        let qualifyingStagesValues = try c.decode([RingBoostStage].self, forKey: .qualifyingStages)
        qualifyingStages = Set(qualifyingStagesValues)
        guard qualifyingStages.count == qualifyingStagesValues.count else { throw FloatingControlError("Duplicate qualifying stages.") }
        delayMilliseconds = try c.decode(Int.self, forKey: .delayMilliseconds)
        cancelOnExit = try c.decode(Bool.self, forKey: .cancelOnExit)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        if startOnBoostEntry { try c.encode(true, forKey: .startOnBoostEntry) }
        try c.encode(enabled, forKey: .enabled)
        try c.encode(qualifyingStages.sorted { $0.rawValue < $1.rawValue }, forKey: .qualifyingStages)
        try c.encode(delayMilliseconds, forKey: .delayMilliseconds)
        try c.encode(cancelOnExit, forKey: .cancelOnExit)
    }
}

public struct RingFireSettings: Codable, Equatable, Sendable {
    public var mode: RingFireMode
    public var adsPayload: String
    public var firePayload: String
    public var pulsePressMilliseconds: Int
    public var pulseGapMilliseconds: Int
    public var retainADSOnLift: Bool
    public var retainFireOnLift: Bool
    public var continueADSOutside: Bool
    public var continueFireOutside: Bool
    public var cancelReleaseShotOnBoundaryExit: Bool
    public var rearmReleaseShotOnBoundaryReturn: Bool
    public var returnFire: RingReturnFireSettings
    public init(mode: RingFireMode = .none, adsPayload: String = "", firePayload: String = "RT:1.0", pulsePressMilliseconds: Int = 35, pulseGapMilliseconds: Int = 35, retainADSOnLift: Bool = false, retainFireOnLift: Bool = false, continueADSOutside: Bool = true, continueFireOutside: Bool = true, cancelReleaseShotOnBoundaryExit: Bool = false, rearmReleaseShotOnBoundaryReturn: Bool = false, returnFire: RingReturnFireSettings = .init()) {
        self.mode = mode
        self.adsPayload = adsPayload
        self.firePayload = firePayload
        self.pulsePressMilliseconds = pulsePressMilliseconds
        self.pulseGapMilliseconds = pulseGapMilliseconds
        self.retainADSOnLift = retainADSOnLift
        self.retainFireOnLift = retainFireOnLift
        self.continueADSOutside = continueADSOutside
        self.continueFireOutside = continueFireOutside
        self.cancelReleaseShotOnBoundaryExit = cancelReleaseShotOnBoundaryExit
        self.rearmReleaseShotOnBoundaryReturn = rearmReleaseShotOnBoundaryReturn
        self.returnFire = returnFire
    }
    public func validate() throws {
        _ = try ringProgram(adsPayload); _ = try ringProgram(firePayload)
        guard (1...60_000).contains(pulsePressMilliseconds), (1...60_000).contains(pulseGapMilliseconds) else {
            throw FloatingControlError("Ring fire press and release gap must be 1–60000 ms.")
        }
        try returnFire.validate()
    }

    private enum CodingKeys: String, CodingKey { case mode, adsPayload, firePayload, pulsePressMilliseconds, pulseGapMilliseconds, retainADSOnLift, retainFireOnLift, continueADSOutside, continueFireOutside, cancelReleaseShotOnBoundaryExit, rearmReleaseShotOnBoundaryReturn, returnFire }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["mode", "adsPayload", "firePayload", "pulsePressMilliseconds", "pulseGapMilliseconds", "retainADSOnLift", "retainFireOnLift", "continueADSOutside", "continueFireOutside", "cancelReleaseShotOnBoundaryExit", "rearmReleaseShotOnBoundaryReturn", "returnFire"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(RingFireMode.self, forKey: .mode)
        adsPayload = try c.decode(String.self, forKey: .adsPayload)
        firePayload = try c.decode(String.self, forKey: .firePayload)
        pulsePressMilliseconds = try c.decode(Int.self, forKey: .pulsePressMilliseconds)
        pulseGapMilliseconds = try c.decode(Int.self, forKey: .pulseGapMilliseconds)
        retainADSOnLift = try c.decode(Bool.self, forKey: .retainADSOnLift)
        retainFireOnLift = try c.decode(Bool.self, forKey: .retainFireOnLift)
        continueADSOutside = try c.decode(Bool.self, forKey: .continueADSOutside)
        continueFireOutside = try c.decode(Bool.self, forKey: .continueFireOutside)
        cancelReleaseShotOnBoundaryExit = try c.decode(Bool.self, forKey: .cancelReleaseShotOnBoundaryExit)
        rearmReleaseShotOnBoundaryReturn = try c.decode(Bool.self, forKey: .rearmReleaseShotOnBoundaryReturn)
        returnFire = try c.decode(RingReturnFireSettings.self, forKey: .returnFire)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(adsPayload, forKey: .adsPayload)
        try c.encode(firePayload, forKey: .firePayload)
        try c.encode(pulsePressMilliseconds, forKey: .pulsePressMilliseconds)
        try c.encode(pulseGapMilliseconds, forKey: .pulseGapMilliseconds)
        try c.encode(retainADSOnLift, forKey: .retainADSOnLift)
        try c.encode(retainFireOnLift, forKey: .retainFireOnLift)
        try c.encode(continueADSOutside, forKey: .continueADSOutside)
        try c.encode(continueFireOutside, forKey: .continueFireOutside)
        try c.encode(cancelReleaseShotOnBoundaryExit, forKey: .cancelReleaseShotOnBoundaryExit)
        try c.encode(rearmReleaseShotOnBoundaryReturn, forKey: .rearmReleaseShotOnBoundaryReturn)
        try c.encode(returnFire, forKey: .returnFire)
    }
}

public struct RingAimKnob: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var x: Double
    public var y: Double
    public var targetDiameter: Double
    public var fire: RingFireSettings
    public init(id: String = "aim_1", name: String = "Aim", enabled: Bool = true, x: Double = 0, y: Double = 0, targetDiameter: Double = 48, fire: RingFireSettings = .init()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.x = x
        self.y = y
        self.targetDiameter = targetDiameter
        self.fire = fire
    }
    public func validate() throws {
        guard (1...64).contains(id.count), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 64, x.isFinite, y.isFinite, hypot(x, y) <= 1,
              targetDiameter.isFinite, targetDiameter > 0, targetDiameter <= 60_000 else {
            throw FloatingControlError("An aim knob needs a unique ID and a valid position and target size.")
        }
        try fire.validate()
    }

    private enum CodingKeys: String, CodingKey { case id, name, enabled, x, y, targetDiameter, fire }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["id", "name", "enabled", "x", "y", "targetDiameter", "fire"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        targetDiameter = try c.decode(Double.self, forKey: .targetDiameter)
        fire = try c.decode(RingFireSettings.self, forKey: .fire)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(targetDiameter, forKey: .targetDiameter)
        try c.encode(fire, forKey: .fire)
    }
}

public struct RingBoostSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var distance: Double
    public var directionalPayloads: RingDirectionalPayloads
    public var payload: String
    public var action: RingAction
    public var pulsePressMilliseconds: Int
    public var pulseGapMilliseconds: Int
    public var latchOnExit: Bool
    public var repeatAfterExit: Bool
    public var retainOnLift: Bool
    public var activationDelayMilliseconds: Int
    public var cancelDelayOnExit: Bool
    public var hysteresis: Double
    public var directTapEnabled: Bool
    public var directInnerDistance: Double
    public var directOuterDistance: Double
    public var skipDelayOnDirectTouch: Bool = false
    public init(enabled: Bool = false, distance: Double = 120, directionalPayloads: RingDirectionalPayloads = .init(), payload: String = "", action: RingAction = .hold, pulsePressMilliseconds: Int = 35, pulseGapMilliseconds: Int = 35, latchOnExit: Bool = false, repeatAfterExit: Bool = false, retainOnLift: Bool = false, activationDelayMilliseconds: Int = 0, cancelDelayOnExit: Bool = true, hysteresis: Double = 2, directTapEnabled: Bool = false, directInnerDistance: Double = 120, directOuterDistance: Double = 144) {
        self.enabled = enabled
        self.distance = distance
        self.directionalPayloads = directionalPayloads
        self.payload = payload
        self.action = action
        self.pulsePressMilliseconds = pulsePressMilliseconds
        self.pulseGapMilliseconds = pulseGapMilliseconds
        self.latchOnExit = latchOnExit
        self.repeatAfterExit = repeatAfterExit
        self.retainOnLift = retainOnLift
        self.activationDelayMilliseconds = activationDelayMilliseconds
        self.cancelDelayOnExit = cancelDelayOnExit
        self.hysteresis = hysteresis
        self.directTapEnabled = directTapEnabled
        self.directInnerDistance = directInnerDistance
        self.directOuterDistance = directOuterDistance
    }
    public func validate() throws {
        guard [distance, hysteresis, directInnerDistance, directOuterDistance].allSatisfy(\.isFinite),
              distance > 0, hysteresis >= 0, hysteresis < distance, directInnerDistance >= distance,
              directOuterDistance > directInnerDistance, directOuterDistance <= 65_536 else {
            throw FloatingControlError("Boost distances, hysteresis and finite direct hit area are invalid.")
        }
        try directionalPayloads.validate(); _ = try ringProgram(payload)
        guard (1...60_000).contains(pulsePressMilliseconds), (1...60_000).contains(pulseGapMilliseconds),
              (0...60_000).contains(activationDelayMilliseconds) else {
            throw FloatingControlError("Boost press/gap must be 1–60000 ms and delay 0–60000 ms.")
        }
        if activationDelayMilliseconds > 0 && !cancelDelayOnExit &&
            ((action == .hold && !latchOnExit) || (action == .repeat && !repeatAfterExit)) {
            throw FloatingControlError("A delay continuing after exit requires Hold latch or Repeat continuation.")
        }
    }
    public func payload(for direction: StickDirection) -> String {
        let selected = directionalPayloads.value(for: direction)
        return selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? payload : selected
    }
    var logicalKeys: Set<RingOutputKey> {
        (directionalPayloads.values + [payload]).reduce(into: []) { $0.formUnion(ringKeys($1)) }
    }
    private enum CodingKeys: String, CodingKey { case enabled, distance, directionalPayloads, payload, action, pulsePressMilliseconds, pulseGapMilliseconds, latchOnExit, repeatAfterExit, retainOnLift, activationDelayMilliseconds, cancelDelayOnExit, hysteresis, directTapEnabled, directInnerDistance, directOuterDistance, skipDelayOnDirectTouch }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "distance", "directionalPayloads", "payload", "action", "pulsePressMilliseconds", "pulseGapMilliseconds", "latchOnExit", "repeatAfterExit", "retainOnLift", "activationDelayMilliseconds", "cancelDelayOnExit", "hysteresis", "directTapEnabled", "directInnerDistance", "directOuterDistance"], optional: ["skipDelayOnDirectTouch"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skipDelayOnDirectTouch = try c.decodeIfPresent(Bool.self, forKey: .skipDelayOnDirectTouch) ?? false
        enabled = try c.decode(Bool.self, forKey: .enabled)
        distance = try c.decode(Double.self, forKey: .distance)
        directionalPayloads = try c.decode(RingDirectionalPayloads.self, forKey: .directionalPayloads)
        payload = try c.decode(String.self, forKey: .payload)
        action = try c.decode(RingAction.self, forKey: .action)
        pulsePressMilliseconds = try c.decode(Int.self, forKey: .pulsePressMilliseconds)
        pulseGapMilliseconds = try c.decode(Int.self, forKey: .pulseGapMilliseconds)
        latchOnExit = try c.decode(Bool.self, forKey: .latchOnExit)
        repeatAfterExit = try c.decode(Bool.self, forKey: .repeatAfterExit)
        retainOnLift = try c.decode(Bool.self, forKey: .retainOnLift)
        activationDelayMilliseconds = try c.decode(Int.self, forKey: .activationDelayMilliseconds)
        cancelDelayOnExit = try c.decode(Bool.self, forKey: .cancelDelayOnExit)
        hysteresis = try c.decode(Double.self, forKey: .hysteresis)
        directTapEnabled = try c.decode(Bool.self, forKey: .directTapEnabled)
        directInnerDistance = try c.decode(Double.self, forKey: .directInnerDistance)
        directOuterDistance = try c.decode(Double.self, forKey: .directOuterDistance)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        if skipDelayOnDirectTouch { try c.encode(true, forKey: .skipDelayOnDirectTouch) }
        try c.encode(enabled, forKey: .enabled)
        try c.encode(distance, forKey: .distance)
        try c.encode(directionalPayloads, forKey: .directionalPayloads)
        try c.encode(payload, forKey: .payload)
        try c.encode(action, forKey: .action)
        try c.encode(pulsePressMilliseconds, forKey: .pulsePressMilliseconds)
        try c.encode(pulseGapMilliseconds, forKey: .pulseGapMilliseconds)
        try c.encode(latchOnExit, forKey: .latchOnExit)
        try c.encode(repeatAfterExit, forKey: .repeatAfterExit)
        try c.encode(retainOnLift, forKey: .retainOnLift)
        try c.encode(activationDelayMilliseconds, forKey: .activationDelayMilliseconds)
        try c.encode(cancelDelayOnExit, forKey: .cancelDelayOnExit)
        try c.encode(hysteresis, forKey: .hysteresis)
        try c.encode(directTapEnabled, forKey: .directTapEnabled)
        try c.encode(directInnerDistance, forKey: .directInnerDistance)
        try c.encode(directOuterDistance, forKey: .directOuterDistance)
    }
}

public enum RingBoostBank: String, CaseIterable, Codable, Sendable { case movement, aim }

public struct RingBoostBandLayout: Codable, Equatable, Sendable {
    public var enabled = false
    public var boost1Distance: Double = 120
    public var boost1Thickness: Double = 40
    public var boost2Thickness: Double = 24
    public var directStartDistance: Double = 120
    public init(enabled: Bool = false, boost1Distance: Double = 120, boost1Thickness: Double = 40,
                boost2Thickness: Double = 24, directStartDistance: Double = 120) {
        self.enabled = enabled; self.boost1Distance = boost1Distance; self.boost1Thickness = boost1Thickness
        self.boost2Thickness = boost2Thickness; self.directStartDistance = directStartDistance
    }
    func validate() throws {
        let endpoints = [boost1Distance, directStartDistance].map { $0 + boost1Thickness + boost2Thickness }
        guard boost1Distance >= 0, directStartDistance >= 0, boost1Thickness > 0, boost2Thickness > 0,
              endpoints.allSatisfy({ $0.isFinite && $0 <= 65_536 }) else {
            throw FloatingControlError("Custom boost bands need positive thickness and reachable finite bounds.")
        }
    }
}

public struct RingBoostBankSettings: Codable, Equatable, Sendable {
    public var boost1 = RingBoostSettings()
    public var boost2 = RingBoostSettings(distance: 160, directInnerDistance: 160, directOuterDistance: 184)
    public var geometry = RingBoostBandLayout()
}
public struct RingBoostBanks: Codable, Equatable, Sendable {
    public var enabled = false
    public var movement = RingBoostBankSettings()
    public var aim = RingBoostBankSettings()
    public var directStartBank = RingBoostBank.movement
    public subscript(bank: RingBoostBank) -> RingBoostBankSettings {
        get { bank == .movement ? movement : aim }
        set { if bank == .movement { movement = newValue } else { aim = newValue } }
    }
}

extension RingBoostBandLayout {
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "boost1Distance", "boost1Thickness", "boost2Thickness", "directStartDistance"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        boost1Distance = try values.decode(Double.self, forKey: .boost1Distance)
        boost1Thickness = try values.decode(Double.self, forKey: .boost1Thickness)
        boost2Thickness = try values.decode(Double.self, forKey: .boost2Thickness)
        directStartDistance = try values.decode(Double.self, forKey: .directStartDistance)
        try validate()
    }
}
extension RingBoostBankSettings {
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["boost1", "boost2", "geometry"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        boost1 = try values.decode(RingBoostSettings.self, forKey: .boost1)
        boost2 = try values.decode(RingBoostSettings.self, forKey: .boost2)
        geometry = try values.decode(RingBoostBandLayout.self, forKey: .geometry)
    }
}
extension RingBoostBanks {
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["enabled", "movement", "aim", "directStartBank"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        movement = try values.decode(RingBoostBankSettings.self, forKey: .movement)
        aim = try values.decode(RingBoostBankSettings.self, forKey: .aim)
        directStartBank = try values.decode(RingBoostBank.self, forKey: .directStartBank)
    }
}

public struct FloatingRingConfig: Codable, Equatable, Sendable {
    public var innerRadius: Double
    public var movementRadius: Double
    public var movement: RingMovementSettings
    public var aim: RingAimSettings
    public var knobs: [RingAimKnob]
    public var boost1: RingBoostSettings
    public var boost2: RingBoostSettings
    public var startRole: FloatingStartRole
    public var startKnobID: String
    public var directBoostToAim: Bool
    public var directBoostAimKnobID: String
    public var directBoostTwoToOne: Bool
    public var compactAimBoosts: Bool = false
    public var adjacentMovementBoosts: Bool = false
    public var boostBanks: RingBoostBanks? = nil
    public var directBoostStartsAim: Bool = false
    public init(innerRadius: Double = 48, movementRadius: Double = 88, movement: RingMovementSettings = .init(), aim: RingAimSettings = .init(), knobs: [RingAimKnob] = [.init()], boost1: RingBoostSettings = .init(), boost2: RingBoostSettings = .init(distance: 160, directInnerDistance: 160, directOuterDistance: 184), startRole: FloatingStartRole = .movement, startKnobID: String = "aim_1", directBoostToAim: Bool = false, directBoostAimKnobID: String = "aim_1", directBoostTwoToOne: Bool = false) {
        self.innerRadius = innerRadius
        self.movementRadius = movementRadius
        self.movement = movement
        self.aim = aim
        self.knobs = knobs
        self.boost1 = boost1
        self.boost2 = boost2
        self.startRole = startRole
        self.startKnobID = startKnobID
        self.directBoostToAim = directBoostToAim
        self.directBoostAimKnobID = directBoostAimKnobID
        self.directBoostTwoToOne = directBoostTwoToOne
    }
    public func validate() throws {
        guard innerRadius.isFinite, movementRadius.isFinite, innerRadius > 0, movementRadius > innerRadius,
              movementRadius <= 30_000 else {
            throw FloatingControlError("Movement radius must exceed the positive inner aim radius.")
        }
        try movement.validate(); try aim.validate(); try boost1.validate(); try boost2.validate()
        guard (1...3).contains(knobs.count), Set(knobs.map(\.id)).count == knobs.count,
              !aim.enabled || knobs.contains(where: \.enabled), knob(startKnobID) != nil, knob(directBoostAimKnobID) != nil else {
            throw FloatingControlError("A ring needs one to three distinct aim knobs and valid saved destinations.")
        }
        for value in knobs {
            try value.validate()
            guard hypot(value.x, value.y) * innerRadius + value.targetDiameter / 2 <= innerRadius + 1e-10 else {
                throw FloatingControlError("Aim knob touch targets must fit inside the inner area.")
            }
        }
        try validateBoostPair(boost1, boost2)
        if boostBanks?.enabled != true {
            if (boostBanks == nil || (boostBanks?.movement.geometry.enabled != true && !adjacentMovementBoosts)) && boost1.distance <= movementRadius {
                throw FloatingControlError("The first movement boost must start beyond the movement radius.")
            }
            if let banks = boostBanks, !banks.aim.geometry.enabled && !compactAimBoosts && boost1.distance <= innerRadius {
                throw FloatingControlError("The first aiming boost must start beyond the aim radius.")
            }
        }
        if let banks = boostBanks {
            for role in RingBoostBank.allCases {
                let bank = banks[role], minimum = role == .aim ? innerRadius : movementRadius
                try validateBoostPair(bank.boost1, bank.boost2)
                try bank.geometry.validate()
                if bank.geometry.enabled {
                    guard bank.geometry.boost1Distance >= minimum,
                          bank.geometry.directStartDistance >= (movement.enabled ? movementRadius : innerRadius) else {
                        throw FloatingControlError("Place boost bands outside their starting area and direct touches outside the visible movement ring.")
                    }
                } else if banks.enabled && !(role == .aim ? compactAimBoosts : adjacentMovementBoosts) && bank.boost1.distance <= minimum {
                    throw FloatingControlError("The first boost must start beyond its starting area.")
                }
            }
        }
        if isActive {
            let enabled: Bool
            switch startRole {
            case .movement: enabled = movement.enabled
            case .aim: enabled = aim.enabled && knob(startKnobID)?.enabled == true
            case .boostOne: enabled = boost(.one, bank: directBoostBank).enabled && boost(.one, bank: directBoostBank).directTapEnabled
            case .boostTwo: enabled = boost(.two, bank: directBoostBank).enabled && boost(.two, bank: directBoostBank).directTapEnabled
            }
            guard enabled else { throw FloatingControlError("Select an enabled starting role.") }
            if (directBoostToAim || directBoostStartsAim) && (!aim.enabled || knob(directBoostAimKnobID)?.enabled != true) {
                throw FloatingControlError("Direct boost aiming needs an enabled destination aim knob.")
            }
        }
        if let banks = boostBanks, banks.enabled {
            for role in RingBoostBank.allCases {
                let settings = banks[role]
                try validateOutputConflicts(settings.boost1, settings.boost2, canUseAimTimer: role == .aim || (role == directBoostBank && (directBoostToAim || directBoostStartsAim)))
            }
        } else {
            try validateOutputConflicts(boost1, boost2)
        }
    }
    public var isActive: Bool { movement.enabled || aim.enabled || configuredBoosts.contains(where: \.enabled) }
    public var outputTargets: Set<ControllerControlID> {
        var result = Set(activePayloads.compactMap { try? ringProgram($0) }.flatMap(\.outputTargets))
        if movement.enabled, let channel = movement.output.logicalStick { result.insert(channel) }
        if aim.enabled, let channel = aim.tuning.output.logicalStick { result.insert(channel) }
        return result
    }
    public var hasDesktopOutputs: Bool {
        (aim.enabled && aim.tuning.output.isMouse) || activePayloads.contains { (try? ringProgram($0).hasKeyboardOrMouse) == true }
    }
    public var hasAnyOutput: Bool { !outputTargets.isEmpty || hasDesktopOutputs }
    private var activePayloads: [String] {
        var result = [String]()
        if aim.enabled {
            for knob in knobs where knob.enabled {
                result.append(knob.fire.adsPayload)
                if knob.fire.mode != .none { result.append(knob.fire.firePayload) }
            }
        }
        for boost in configuredBoosts where boost.enabled { result += [boost.payload] + boost.directionalPayloads.values }
        return result
    }
    public func knob(_ id: String) -> RingAimKnob? { knobs.first { $0.id == id } }
    public func boost(_ stage: RingBoostStage) -> RingBoostSettings { stage == .one ? boost1 : boost2 }
    private var configuredBoosts: [RingBoostSettings] {
        guard let banks = boostBanks, banks.enabled else { return [boost1, boost2] }
        return [banks.movement.boost1, banks.movement.boost2, banks.aim.boost1, banks.aim.boost2]
    }
    public var directBoostBank: RingBoostBank { bank(for: startRole, direct: boostBanks?.directStartBank ?? .movement) }
    public func bank(for role: FloatingStartRole, direct: RingBoostBank? = nil) -> RingBoostBank {
        switch role {
        case .movement: .movement
        case .aim: .aim
        case .boostOne, .boostTwo: direct ?? directBoostBank
        }
    }
    public func boost(_ stage: RingBoostStage, bank: RingBoostBank) -> RingBoostSettings {
        guard let banks = boostBanks, banks.enabled else { return boost(stage) }
        return stage == .one ? banks[bank].boost1 : banks[bank].boost2
    }
    public var requiredAndroidRingFormat: Int {
        if ([boost1, boost2] + (boostBanks.map { [$0.movement.boost1, $0.movement.boost2, $0.aim.boost1, $0.aim.boost2] } ?? [])).contains(where: \.skipDelayOnDirectTouch) { return 13 }
        if boostBanks != nil || directBoostStartsAim { return 12 }
        if compactAimBoosts || adjacentMovementBoosts || knobs.contains(where: { $0.fire.returnFire.startOnBoostEntry }) { return 11 }
        return 10
    }
    public var usesCommandModifiers: Bool { minimumCommandModifierVersion >= 14 }
    var minimumCommandModifierVersion: Int {
        let savedBoosts = [boost1, boost2] + (boostBanks.map { [$0.movement.boost1, $0.movement.boost2, $0.aim.boost1, $0.aim.boost2] } ?? [])
        let sources = knobs.flatMap { [$0.fire.adsPayload, $0.fire.firePayload] }
            + savedBoosts.flatMap { [$0.payload] + $0.directionalPayloads.values }
        return sources.map(AndroidTimingFormat.payloadVersion).max() ?? 1
    }
    public var hasExpandedRingOptions: Bool { requiredAndroidRingFormat > 10 }
    public func seededBoostBanks() -> RingBoostBanks {
        if let boostBanks { return boostBanks }
        func seed(_ role: RingBoostBank) -> RingBoostBankSettings {
            let compact = role == .aim && compactAimBoosts
            let adjacent = role == .movement && adjacentMovementBoosts
            let layout = RingBoostBandLayout(boost1Distance: compact ? innerRadius : adjacent ? movementRadius : boost1.distance,
                boost1Thickness: compact ? movementRadius - innerRadius : boost2.distance - boost1.distance,
                boost2Thickness: boost2.directOuterDistance - boost2.directInnerDistance,
                directStartDistance: compactAimBoosts || adjacentMovementBoosts ? (movement.enabled ? movementRadius : innerRadius) : boost1.directInnerDistance)
            return .init(boost1: boost1, boost2: boost2, geometry: layout)
        }
        return .init(movement: seed(.movement), aim: seed(.aim))
    }
    private func validateBoostPair(_ first: RingBoostSettings, _ second: RingBoostSettings) throws {
        try first.validate(); try second.validate()
        guard second.distance > first.distance, first.directOuterDistance <= second.directInnerDistance,
              first.activationDelayMilliseconds == 0, !first.skipDelayOnDirectTouch else {
            throw FloatingControlError("Boosts must be ordered; only Boost 2 supports activation delay and its direct-touch shortcut.")
        }
    }
    private func validateOutputConflicts(_ boost1: RingBoostSettings, _ boost2: RingBoostSettings, canUseAimTimer: Bool = true) throws {
        let active = [boost1, boost2].filter(\.enabled)
        if boost1.enabled && boost2.enabled && (boost1.action != .hold || boost2.action != .hold) &&
            !boost1.logicalKeys.isDisjoint(with: boost2.logicalKeys) {
            throw FloatingControlError("Boost stages sharing an output cannot mask each other's Tap or Repeat edges.")
        }
        for value in knobs where aim.enabled && value.enabled {
            let fire = value.fire, adsKeys = ringKeys(value.fire.adsPayload)
            let fireKeys: Set<RingOutputKey> = fire.mode == .none ? [] : ringKeys(fire.firePayload)
            guard adsKeys.isDisjoint(with: fireKeys) else {
                throw FloatingControlError("ADS and firing must use independent logical outputs.")
            }
            if canUseAimTimer && fire.returnFire.enabled && boost2.enabled && boost2.activationDelayMilliseconds > 0 &&
                !fireKeys.isDisjoint(with: boost2.logicalKeys) {
                throw FloatingControlError("Choose one delayed firing source for each logical output.")
            }
            for stage in active {
                if stage.action != .hold && !stage.logicalKeys.isDisjoint(with: adsKeys) {
                    throw FloatingControlError("Boost Tap or Repeat cannot share a held ADS output.")
                }
                if fire.mode != .none && (stage.action != .hold || fire.mode != .hold) &&
                    !stage.logicalKeys.isDisjoint(with: fireKeys) {
                    throw FloatingControlError("Boost and inner firing cannot mask each other's finite or Repeat edges.")
                }
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case innerRadius, movementRadius, movement, aim, knobs, boost1, boost2, startRole, startKnobID, directBoostToAim, directBoostAimKnobID, directBoostTwoToOne, compactAimBoosts, adjacentMovementBoosts, boostBanks, directBoostStartsAim }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["innerRadius", "movementRadius", "movement", "aim", "knobs", "boost1", "boost2", "startRole", "startKnobID", "directBoostToAim", "directBoostAimKnobID", "directBoostTwoToOne"], optional: ["compactAimBoosts", "adjacentMovementBoosts", "boostBanks", "directBoostStartsAim"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directBoostStartsAim = try c.decodeIfPresent(Bool.self, forKey: .directBoostStartsAim) ?? false
        boostBanks = try c.decodeIfPresent(RingBoostBanks.self, forKey: .boostBanks)
        adjacentMovementBoosts = try c.decodeIfPresent(Bool.self, forKey: .adjacentMovementBoosts) ?? false
        compactAimBoosts = try c.decodeIfPresent(Bool.self, forKey: .compactAimBoosts) ?? false
        innerRadius = try c.decode(Double.self, forKey: .innerRadius)
        movementRadius = try c.decode(Double.self, forKey: .movementRadius)
        movement = try c.decode(RingMovementSettings.self, forKey: .movement)
        aim = try c.decode(RingAimSettings.self, forKey: .aim)
        knobs = try c.decode([RingAimKnob].self, forKey: .knobs)
        boost1 = try c.decode(RingBoostSettings.self, forKey: .boost1)
        boost2 = try c.decode(RingBoostSettings.self, forKey: .boost2)
        startRole = try c.decode(FloatingStartRole.self, forKey: .startRole)
        startKnobID = try c.decode(String.self, forKey: .startKnobID)
        directBoostToAim = try c.decode(Bool.self, forKey: .directBoostToAim)
        directBoostAimKnobID = try c.decode(String.self, forKey: .directBoostAimKnobID)
        directBoostTwoToOne = try c.decode(Bool.self, forKey: .directBoostTwoToOne)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        if directBoostStartsAim { try c.encode(true, forKey: .directBoostStartsAim) }
        try c.encodeIfPresent(boostBanks, forKey: .boostBanks)
        if adjacentMovementBoosts { try c.encode(true, forKey: .adjacentMovementBoosts) }
        if compactAimBoosts { try c.encode(true, forKey: .compactAimBoosts) }
        try c.encode(innerRadius, forKey: .innerRadius)
        try c.encode(movementRadius, forKey: .movementRadius)
        try c.encode(movement, forKey: .movement)
        try c.encode(aim, forKey: .aim)
        try c.encode(knobs, forKey: .knobs)
        try c.encode(boost1, forKey: .boost1)
        try c.encode(boost2, forKey: .boost2)
        try c.encode(startRole, forKey: .startRole)
        try c.encode(startKnobID, forKey: .startKnobID)
        try c.encode(directBoostToAim, forKey: .directBoostToAim)
        try c.encode(directBoostAimKnobID, forKey: .directBoostAimKnobID)
        try c.encode(directBoostTwoToOne, forKey: .directBoostTwoToOne)
    }
}



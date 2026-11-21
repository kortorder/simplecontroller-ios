import Foundation

/// These are local touch observations, not measurements or inferences about a person.
public enum TouchAimMetric: String, Codable, CaseIterable, Sendable {
    case majorRadius, normalizedForce
    public var displayName:String { self == .majorRadius ? "touch radius":"supported force" }
}
public enum TouchAimMode: String, Codable, CaseIterable, Sendable { case manualThreeStage, manualTwoState, calibratedTwoState }
public enum TouchAimStageAction: String, Codable, CaseIterable, Sendable { case press, hold }
public enum TouchAimShootBehavior: String, Codable, CaseIterable, Sendable { case hold, pressOnEnter, pressOnReturn }
public enum TouchAimLevel: String, Codable, CaseIterable, Sendable { case aimOnly, low, medium, high
    public var rank: Int { switch self { case .aimOnly: -1; case .low: 0; case .medium: 1; case .high: 2 } }
}
public enum TouchAimState: String, Codable, Sendable { case idle, aim, shoot, low, medium, high, unavailable }
public enum TouchAimCalibrationQuality: String, Codable, Sendable { case good, borderline, unreliable, insufficient }
public enum TouchAimCalibrationLabel: String, Codable, Sendable { case aim, shoot }

/// Intentionally not Codable: raw metric samples stay ephemeral and local.
/// A nil force means the adapter did not establish actual hardware availability.
public struct TouchMetrics: Equatable, Sendable {
    public var majorRadius: Double?
    public var radiusTolerance: Double?
    public var normalizedForce: Double?
    public init(majorRadius: Double? = nil, radiusTolerance: Double? = nil, normalizedForce: Double? = nil) {
        self.majorRadius=majorRadius; self.radiusTolerance=radiusTolerance; self.normalizedForce=normalizedForce
    }
    public var isValid: Bool {
        [majorRadius,radiusTolerance].allSatisfy { $0.map { $0.isFinite && (0...1200).contains($0) } ?? true } &&
            (normalizedForce.map { $0.isFinite && (0...1).contains($0) } ?? true)
    }
    public var availableMetrics: Set<TouchAimMetric> { Set(TouchAimMetric.allCases.filter { value(for:$0) != nil }) }
    public func value(for metric:TouchAimMetric)->Double? { metric == .majorRadius ? majorRadius:normalizedForce }
}
public struct TouchAimSample: Equatable, Sendable {
    public var pointer: ButtonPointerSample; public var metrics: TouchMetrics; public var elapsed: Double
    public init(pointer: ButtonPointerSample, metrics: TouchMetrics, elapsed: Double) { self.pointer=pointer;self.metrics=metrics;self.elapsed=elapsed }
    public var isValid: Bool { pointer.isValid && metrics.isValid && elapsed.isFinite && (0...3600).contains(elapsed) }
}
public struct TouchAimSensorTransform: Codable, Equatable, Sendable {
    public var metric: TouchAimMetric; public var center:Double;public var scale:Double;public var weight:Double
    public init(metric:TouchAimMetric,center:Double,scale:Double,weight:Double=1) { self.metric=metric;self.center=center;self.scale=scale;self.weight=weight }
    public func validate() throws { guard center.isFinite, abs(center)<=1200, scale.isFinite, scale>0,scale<=1200,weight.isFinite,weight>0,weight<=10 else { throw ControllerPayloadError("Touch calibration transform is invalid.") } }
    private enum CodingKeys:String,CodingKey { case metric,center,scale,weight }
    public init(from decoder:Decoder)throws {
        try profileKeys(decoder,["metric","center","scale","weight"]);let c=try decoder.container(keyedBy:CodingKeys.self)
        metric=try c.decode(TouchAimMetric.self,forKey:.metric);center=try c.decode(Double.self,forKey:.center);scale=try c.decode(Double.self,forKey:.scale);weight=try c.decode(Double.self,forKey:.weight);try validate()
    }
    public func encode(to encoder:Encoder)throws { try validate();var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(metric,forKey:.metric);try c.encode(center,forKey:.center);try c.encode(scale,forKey:.scale);try c.encode(weight,forKey:.weight) }
}

/// Per-stage overrides in manual TouchAim. A blank sensitivity follows the main aim setting.
public struct TouchAimStageTuning: Codable, Equatable, Sendable {
    public var sensitivity: Double?
    public var confirmationMilliseconds: Int
    public init(sensitivity: Double? = nil, confirmationMilliseconds: Int = 0) {
        self.sensitivity = sensitivity
        self.confirmationMilliseconds = confirmationMilliseconds
    }
    public func validate() throws {
        guard sensitivity.map({ $0.isFinite && (0...5).contains($0) }) ?? true,
              (0...600_000).contains(confirmationMilliseconds) else {
            throw ControllerPayloadError("Stage sensitivity must be 0–5 and confirmation must be 0–600,000 milliseconds.")
        }
    }
    private enum CodingKeys: String, CodingKey { case sensitivity, confirmationMilliseconds }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try profileKeys(decoder, values.contains(.sensitivity) ? ["sensitivity", "confirmationMilliseconds"] : ["confirmationMilliseconds"])
        sensitivity = try values.decodeIfPresent(Double.self, forKey: .sensitivity)
        confirmationMilliseconds = try values.decodeIfPresent(Int.self, forKey: .confirmationMilliseconds) ?? 0
        try validate()
    }
}

public struct TouchAimStage: Codable, Equatable, Sendable {
    public var threshold: Double
    public var payload: String
    public var action: TouchAimStageAction
    public var tuning: TouchAimStageTuning
    public init(threshold: Double = 2, payload: String = "", action: TouchAimStageAction = .hold, tuning: TouchAimStageTuning = .init()) {
        self.threshold = threshold
        self.payload = payload
        self.action = action
        self.tuning = tuning
    }
    public func validate() throws {
        guard threshold.isFinite, (0...1_200_000).contains(threshold), payload.count<=1000 else { throw ControllerPayloadError("Touch stage threshold/payload is invalid.") }
        try tuning.validate()
        _ = try advancedButtonProgram(payload)
    }
    private enum CodingKeys: String, CodingKey { case threshold, payload, action, tuning }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var keys: Set<String> = ["threshold", "payload", "action"]
        if c.contains(.tuning) { keys.insert("tuning") }
        try profileKeys(decoder, keys)
        threshold = try c.decode(Double.self, forKey: .threshold)
        payload = try c.decode(String.self, forKey: .payload)
        action = try c.decode(TouchAimStageAction.self, forKey: .action)
        tuning = try c.decodeIfPresent(TouchAimStageTuning.self, forKey: .tuning) ?? .init()
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(threshold, forKey: .threshold)
        try c.encode(payload, forKey: .payload)
        try c.encode(action, forKey: .action)
        if tuning != .init() { try c.encode(tuning, forKey: .tuning) }
    }
}

public struct TouchAimThreeStageSettings: Codable, Equatable, Sendable {
    public var low: TouchAimStage
    public var medium: TouchAimStage
    public var high: TouchAimStage
    public var smoothing: Double
    public var hysteresis: Double
    public var keepLowerHolds: Bool
    public var aimOnlyTuning: TouchAimStageTuning
    public func tuning(for level: TouchAimLevel) -> TouchAimStageTuning {
        switch level {
        case .aimOnly: aimOnlyTuning
        case .low: low.tuning
        case .medium: medium.tuning
        case .high: high.tuning
        }
    }
    public var hasConfirmation: Bool {
        TouchAimLevel.allCases.contains { tuning(for: $0).confirmationMilliseconds > 0 }
    }
    public var hasStageTuning: Bool {
        TouchAimLevel.allCases.contains { tuning(for: $0) != .init() }
    }
    public init(low: TouchAimStage = .init(threshold:2,action:.press), medium: TouchAimStage = .init(threshold:4,payload:"LT:1.0"), high: TouchAimStage = .init(threshold:5.2,payload:"RT:1.0"), smoothing: Double = 0.35, hysteresis: Double = 0.25, keepLowerHolds: Bool = true, aimOnlyTuning: TouchAimStageTuning = .init()) {
        self.low = low
        self.medium = medium
        self.high = high
        self.smoothing = smoothing
        self.hysteresis = hysteresis
        self.aimOnlyTuning = aimOnlyTuning
        self.keepLowerHolds = keepLowerHolds
    }
    public func validate() throws {
        try aimOnlyTuning.validate()
        try low.validate();try medium.validate();try high.validate()
        guard smoothing.isFinite,(0.05...1).contains(smoothing),hysteresis.isFinite,(0...1_200_000).contains(hysteresis),medium.threshold>=low.threshold+0.01-1e-12,high.threshold>=medium.threshold+0.01-1e-12 else { throw ControllerPayloadError("Three-stage thresholds must increase by at least 0.01; smoothing must be 0.05–1.") }
    }
    private enum CodingKeys: String, CodingKey { case low, medium, high, smoothing, hysteresis, keepLowerHolds, aimOnlyTuning }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var keys: Set<String> = ["low", "medium", "high", "smoothing", "hysteresis", "keepLowerHolds"]
        if c.contains(.aimOnlyTuning) { keys.insert("aimOnlyTuning") }
        try profileKeys(decoder, keys)
        aimOnlyTuning = try c.decodeIfPresent(TouchAimStageTuning.self, forKey: .aimOnlyTuning) ?? .init()
        low = try c.decode(TouchAimStage.self, forKey: .low)
        medium = try c.decode(TouchAimStage.self, forKey: .medium)
        high = try c.decode(TouchAimStage.self, forKey: .high)
        smoothing = try c.decode(Double.self, forKey: .smoothing)
        hysteresis = try c.decode(Double.self, forKey: .hysteresis)
        keepLowerHolds = try c.decode(Bool.self, forKey: .keepLowerHolds)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        if aimOnlyTuning != .init() { try c.encode(aimOnlyTuning, forKey: .aimOnlyTuning) }
        try c.encode(low, forKey: .low)
        try c.encode(medium, forKey: .medium)
        try c.encode(high, forKey: .high)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(hysteresis, forKey: .hysteresis)
        try c.encode(keepLowerHolds, forKey: .keepLowerHolds)
    }
}

public struct TouchAimTwoStateSettings: Codable, Equatable, Sendable {
    public var shootOn: Double
    public var shootOff: Double
    public var smoothing: Double
    public var enterMilliseconds: Int
    public var returnMilliseconds: Int
    public var aimPayload: String
    public var shootPayload: String
    public var keepAimWhileShooting: Bool
    public var shootSensitivity: Double
    public var shootBehavior: TouchAimShootBehavior
    public init(shootOn: Double = 5.2, shootOff: Double = 4.95, smoothing: Double = 0.35, enterMilliseconds: Int = 90, returnMilliseconds: Int = 120, aimPayload: String = "", shootPayload: String = "RT:1.0", keepAimWhileShooting: Bool = true, shootSensitivity: Double = 1, shootBehavior: TouchAimShootBehavior = .hold) {
        self.shootOn = shootOn
        self.shootOff = shootOff
        self.smoothing = smoothing
        self.enterMilliseconds = enterMilliseconds
        self.returnMilliseconds = returnMilliseconds
        self.aimPayload = aimPayload
        self.shootPayload = shootPayload
        self.keepAimWhileShooting = keepAimWhileShooting
        self.shootSensitivity = shootSensitivity
        self.shootBehavior = shootBehavior
    }
    public func validate() throws {
        guard shootOn.isFinite,shootOff.isFinite,(0.01...1_200_000).contains(shootOn),(0...1_200_000).contains(shootOff),shootOff<=shootOn-0.01+1e-12,smoothing.isFinite,(0.05...1).contains(smoothing),(1...2000).contains(enterMilliseconds),(1...2000).contains(returnMilliseconds),shootSensitivity.isFinite,(0...5).contains(shootSensitivity),aimPayload.count<=1000,shootPayload.count<=1000 else { throw ControllerPayloadError("Two-state TouchAim thresholds, confirmation times or sensitivity are invalid.") }
        _ = try advancedButtonProgram(aimPayload);_ = try advancedButtonProgram(shootPayload)
    }
    private enum CodingKeys: String, CodingKey { case shootOn, shootOff, smoothing, enterMilliseconds, returnMilliseconds, aimPayload, shootPayload, keepAimWhileShooting, shootSensitivity, shootBehavior }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["shootOn", "shootOff", "smoothing", "enterMilliseconds", "returnMilliseconds", "aimPayload", "shootPayload", "keepAimWhileShooting", "shootSensitivity", "shootBehavior"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shootOn = try c.decode(Double.self, forKey: .shootOn)
        shootOff = try c.decode(Double.self, forKey: .shootOff)
        smoothing = try c.decode(Double.self, forKey: .smoothing)
        enterMilliseconds = try c.decode(Int.self, forKey: .enterMilliseconds)
        returnMilliseconds = try c.decode(Int.self, forKey: .returnMilliseconds)
        aimPayload = try c.decode(String.self, forKey: .aimPayload)
        shootPayload = try c.decode(String.self, forKey: .shootPayload)
        keepAimWhileShooting = try c.decode(Bool.self, forKey: .keepAimWhileShooting)
        shootSensitivity = try c.decode(Double.self, forKey: .shootSensitivity)
        shootBehavior = try c.decode(TouchAimShootBehavior.self, forKey: .shootBehavior)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shootOn, forKey: .shootOn)
        try c.encode(shootOff, forKey: .shootOff)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(enterMilliseconds, forKey: .enterMilliseconds)
        try c.encode(returnMilliseconds, forKey: .returnMilliseconds)
        try c.encode(aimPayload, forKey: .aimPayload)
        try c.encode(shootPayload, forKey: .shootPayload)
        try c.encode(keepAimWhileShooting, forKey: .keepAimWhileShooting)
        try c.encode(shootSensitivity, forKey: .shootSensitivity)
        try c.encode(shootBehavior, forKey: .shootBehavior)
    }
}

public struct TouchAimCalibrationSummary: Codable, Equatable, Sendable {
    public var label: TouchAimCalibrationLabel
    public var repetition: Int
    public var sampleCount: Int
    public var stillCount: Int
    public var movingCount: Int
    public var duration: Double
    public var radiusMedian: Double?
    public var forceMedian: Double?
    public init(label: TouchAimCalibrationLabel = .aim, repetition: Int = 0, sampleCount: Int = 0, stillCount: Int = 0, movingCount: Int = 0, duration: Double = 0, radiusMedian: Double? = nil, forceMedian: Double? = nil) {
        self.label = label
        self.repetition = repetition
        self.sampleCount = sampleCount
        self.stillCount = stillCount
        self.movingCount = movingCount
        self.duration = duration
        self.radiusMedian = radiusMedian
        self.forceMedian = forceMedian
    }
    public func validate() throws {
        guard (0...31).contains(repetition),(0...256).contains(sampleCount),(0...256).contains(stillCount),(0...256).contains(movingCount),stillCount+movingCount==sampleCount,duration.isFinite,(0...30).contains(duration),radiusMedian.map({$0.isFinite && (0...1200).contains($0)}) ?? true,forceMedian.map({$0.isFinite && (0...1).contains($0)}) ?? true else { throw ControllerPayloadError("Touch calibration summary is invalid.") }
    }
    private enum CodingKeys: String, CodingKey { case label, repetition, sampleCount, stillCount, movingCount, duration, radiusMedian, forceMedian }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["label", "repetition", "sampleCount", "stillCount", "movingCount", "duration", "radiusMedian", "forceMedian"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(TouchAimCalibrationLabel.self, forKey: .label)
        repetition = try c.decode(Int.self, forKey: .repetition)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        stillCount = try c.decode(Int.self, forKey: .stillCount)
        movingCount = try c.decode(Int.self, forKey: .movingCount)
        duration = try c.decode(Double.self, forKey: .duration)
        radiusMedian = try c.decodeIfPresent(Double.self, forKey: .radiusMedian)
        forceMedian = try c.decodeIfPresent(Double.self, forKey: .forceMedian)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(repetition, forKey: .repetition)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(stillCount, forKey: .stillCount)
        try c.encode(movingCount, forKey: .movingCount)
        try c.encode(duration, forKey: .duration)
        try c.encode(radiusMedian, forKey: .radiusMedian)
        try c.encode(forceMedian, forKey: .forceMedian)
    }
}

public struct TouchAimCalibrationProfile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var transforms: [TouchAimSensorTransform]
    public var quality: TouchAimCalibrationQuality
    public var shootOn: Double
    public var shootOff: Double
    public var smoothing: Double
    public var enterMilliseconds: Int
    public var returnMilliseconds: Int
    public var falseActivationRate: Double
    public var missedActivationRate: Double
    public var movementReducedReliability: Bool
    public var consistency: Double
    public var validationCompleted: Bool
    public var validationUnexpectedTransitions: Int
    public var summaries: [TouchAimCalibrationSummary]
    public init(schemaVersion: Int = 1, id: UUID = UUID(), name: String = "iPhone touch calibration", transforms: [TouchAimSensorTransform] = [], quality: TouchAimCalibrationQuality = .insufficient, shootOn: Double = 1, shootOff: Double = 0.75, smoothing: Double = 0.35, enterMilliseconds: Int = 90, returnMilliseconds: Int = 120, falseActivationRate: Double = 1, missedActivationRate: Double = 1, movementReducedReliability: Bool = true, consistency: Double = 0, validationCompleted: Bool = false, validationUnexpectedTransitions: Int = 0, summaries: [TouchAimCalibrationSummary] = []) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.transforms = transforms
        self.quality = quality
        self.shootOn = shootOn
        self.shootOff = shootOff
        self.smoothing = smoothing
        self.enterMilliseconds = enterMilliseconds
        self.returnMilliseconds = returnMilliseconds
        self.falseActivationRate = falseActivationRate
        self.missedActivationRate = missedActivationRate
        self.movementReducedReliability = movementReducedReliability
        self.consistency = consistency
        self.validationCompleted = validationCompleted
        self.validationUnexpectedTransitions = validationUnexpectedTransitions
        self.summaries = summaries
    }
    public func validate() throws {
        guard schemaVersion==1 else { throw ControllerPayloadError("This touch calibration version is unsupported.") }
        try validateProfileName(name)
        guard transforms.count<=2,Set(transforms.map(\.metric)).count==transforms.count,shootOn.isFinite,shootOff.isFinite,(-8...8).contains(shootOn),(-8...8).contains(shootOff),shootOff<=shootOn-0.01+1e-12,smoothing.isFinite,(0.05...1).contains(smoothing),(1...2000).contains(enterMilliseconds),(1...2000).contains(returnMilliseconds),[falseActivationRate,missedActivationRate,consistency].allSatisfy({$0.isFinite && (0...1).contains($0)}),validationUnexpectedTransitions>=0,validationUnexpectedTransitions<=10000,summaries.count<=8 else { throw ControllerPayloadError("Touch calibration detector or report is invalid.") }
        for t in transforms { try t.validate() };for summary in summaries { try summary.validate() }
        if validationCompleted && transforms.isEmpty { throw ControllerPayloadError("An empty touch calibration cannot be validated.") }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, name, transforms, quality, shootOn, shootOff, smoothing, enterMilliseconds, returnMilliseconds, falseActivationRate, missedActivationRate, movementReducedReliability, consistency, validationCompleted, validationUnexpectedTransitions, summaries }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["schemaVersion", "id", "name", "transforms", "quality", "shootOn", "shootOff", "smoothing", "enterMilliseconds", "returnMilliseconds", "falseActivationRate", "missedActivationRate", "movementReducedReliability", "consistency", "validationCompleted", "validationUnexpectedTransitions", "summaries"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        transforms = try c.decode([TouchAimSensorTransform].self, forKey: .transforms)
        quality = try c.decode(TouchAimCalibrationQuality.self, forKey: .quality)
        shootOn = try c.decode(Double.self, forKey: .shootOn)
        shootOff = try c.decode(Double.self, forKey: .shootOff)
        smoothing = try c.decode(Double.self, forKey: .smoothing)
        enterMilliseconds = try c.decode(Int.self, forKey: .enterMilliseconds)
        returnMilliseconds = try c.decode(Int.self, forKey: .returnMilliseconds)
        falseActivationRate = try c.decode(Double.self, forKey: .falseActivationRate)
        missedActivationRate = try c.decode(Double.self, forKey: .missedActivationRate)
        movementReducedReliability = try c.decode(Bool.self, forKey: .movementReducedReliability)
        consistency = try c.decode(Double.self, forKey: .consistency)
        validationCompleted = try c.decode(Bool.self, forKey: .validationCompleted)
        validationUnexpectedTransitions = try c.decode(Int.self, forKey: .validationUnexpectedTransitions)
        summaries = try c.decode([TouchAimCalibrationSummary].self, forKey: .summaries)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(transforms, forKey: .transforms)
        try c.encode(quality, forKey: .quality)
        try c.encode(shootOn, forKey: .shootOn)
        try c.encode(shootOff, forKey: .shootOff)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(enterMilliseconds, forKey: .enterMilliseconds)
        try c.encode(returnMilliseconds, forKey: .returnMilliseconds)
        try c.encode(falseActivationRate, forKey: .falseActivationRate)
        try c.encode(missedActivationRate, forKey: .missedActivationRate)
        try c.encode(movementReducedReliability, forKey: .movementReducedReliability)
        try c.encode(consistency, forKey: .consistency)
        try c.encode(validationCompleted, forKey: .validationCompleted)
        try c.encode(validationUnexpectedTransitions, forKey: .validationUnexpectedTransitions)
        try c.encode(summaries, forKey: .summaries)
    }
}

public struct TouchAimSettings: Codable, Equatable, Sendable {
    public var mode: TouchAimMode
    public var metric: TouchAimMetric
    public var metricScale: Double
    public var aim: ButtonAimTuning
    public var threeStage: TouchAimThreeStageSettings
    public var twoState: TouchAimTwoStateSettings
    public var calibration: TouchAimCalibrationProfile?
    /// Imported sensor settings are preserved for review but cannot produce stage actions until
    /// an explicit local setup or validated local calibration clears this persistent gate.
    public var requiresLocalSetup: Bool
    public init(mode: TouchAimMode = .manualThreeStage, metric: TouchAimMetric = .majorRadius, metricScale: Double = 1, aim: ButtonAimTuning = .init(origin:.controlCenter), threeStage: TouchAimThreeStageSettings = .init(), twoState: TouchAimTwoStateSettings = .init(), calibration: TouchAimCalibrationProfile? = nil, requiresLocalSetup: Bool = false) {
        self.mode = mode
        self.metric = metric
        self.metricScale = metricScale
        self.aim = aim
        self.threeStage = threeStage
        self.twoState = twoState
        self.calibration = calibration
        self.requiresLocalSetup = requiresLocalSetup
    }
    public func validate() throws {
        guard metricScale.isFinite,(0.001...1000).contains(metricScale) else { throw ControllerPayloadError("Touch metric scale must be 0.001–1000.") }
        try aim.validate();try threeStage.validate();try twoState.validate();try calibration?.validate()
        guard aim.output != .dpad, aim.autoCenter else { throw ControllerPayloadError("TouchAim supports Mouse, Game mouse and left/right sticks, and always centers on lift.") }
        if !requiresLocalSetup && mode == .calibratedTwoState && calibration?.isApplicable != true { throw ControllerPayloadError("Calibrated TouchAim needs a usable native calibration and a separate no-output validation pass.") }
    }
    private enum CodingKeys: String, CodingKey { case mode, metric, metricScale, aim, threeStage, twoState, calibration, requiresLocalSetup }
    public init(from decoder: Decoder) throws { try self.init(from: decoder, libraryVersion: ControllerProfileLibrary.currentVersion) }
    init(from decoder: Decoder, libraryVersion: Int) throws {
        var keys: Set<String> = ["mode", "metric", "metricScale", "aim", "threeStage", "twoState", "calibration"]
        if libraryVersion >= 15 { keys.insert("requiresLocalSetup") }
        try profileKeys(decoder, keys)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(TouchAimMode.self, forKey: .mode)
        metric = try c.decode(TouchAimMetric.self, forKey: .metric)
        metricScale = try c.decode(Double.self, forKey: .metricScale)
        aim = try c.decode(ButtonAimTuning.self, forKey: .aim)
        threeStage = try c.decode(TouchAimThreeStageSettings.self, forKey: .threeStage)
        twoState = try c.decode(TouchAimTwoStateSettings.self, forKey: .twoState)
        calibration = try c.decodeIfPresent(TouchAimCalibrationProfile.self, forKey: .calibration)
        requiresLocalSetup = libraryVersion < 15 ? false : try c.decode(Bool.self, forKey: .requiresLocalSetup)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(metric, forKey: .metric)
        try c.encode(metricScale, forKey: .metricScale)
        try c.encode(aim, forKey: .aim)
        try c.encode(threeStage, forKey: .threeStage)
        try c.encode(twoState, forKey: .twoState)
        try c.encode(calibration, forKey: .calibration)
        try c.encode(requiresLocalSetup, forKey: .requiresLocalSetup)
    }
}

extension TouchAimCalibrationProfile {
    public var isApplicable:Bool { (quality == .good || quality == .borderline) && validationCompleted && !transforms.isEmpty && validationUnexpectedTransitions == 0 && (try? validate()) != nil }
    public func score(_ metrics:TouchMetrics)throws->Double {
        try validate()
        guard metrics.isValid,!transforms.isEmpty else { throw ControllerPayloadError("The calibration has no available touch metric.") }
        var total=0.0,weighted=0.0
        for t in transforms {
            guard let value=metrics.value(for:t.metric) else { throw ControllerPayloadError("The calibration's \(t.metric.displayName) metric is unavailable on this touch.") }
            weighted += min(8,max(-8,(value-t.center)/t.scale))*t.weight;total += t.weight
        }
        return weighted/total
    }
}

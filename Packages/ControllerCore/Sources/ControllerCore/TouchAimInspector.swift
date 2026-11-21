import Foundation

public struct TouchMetricSummary: Equatable, Sendable {
    public var count:Int
    public var minimum:Double
    public var maximum:Double
    public var mean:Double
    public var variation:Double { maximum-minimum }
}
/// Ephemeral diagnostic only: no input-engine reference, payload parser, output or persistence API.
public struct TouchAimInspector: Sendable {
    public static let maximumSamples=256
    private var samples:[TouchMetrics]=[]
    public private(set) var latest=TouchMetrics()
    public init() {}
    public var sampleCount:Int { samples.count }
    public var summaries:[TouchAimMetric:TouchMetricSummary] {
        Dictionary(uniqueKeysWithValues:TouchAimMetric.allCases.compactMap { metric in
            let values=samples.compactMap{$0.value(for:metric)}
            guard !values.isEmpty else { return nil }
            return (metric,TouchMetricSummary(count:values.count,minimum:values.min()!,maximum:values.max()!,mean:values.reduce(0,+)/Double(values.count)))
        })
    }
    public mutating func observe(_ metrics:TouchMetrics)throws {
        guard metrics.isValid else { throw ControllerInputError.invalidPosition }
        if samples.count == Self.maximumSamples { samples.removeFirst() }
        samples.append(metrics);latest=metrics
    }
    public mutating func reset() { samples.removeAll();latest = .init() }
}

/// Raw calibration recordings deliberately do not conform to Codable.
public struct TouchAimCalibrationSample: Equatable, Sendable {
    public var metrics:TouchMetrics;public var elapsed:Double;public var moving:Bool
    public init(metrics:TouchMetrics,elapsed:Double,moving:Bool) { self.metrics=metrics;self.elapsed=elapsed;self.moving=moving }
}
public struct TouchAimCalibrationPass: Equatable, Sendable {
    public var label:TouchAimCalibrationLabel
    public var repetition:Int
    public var samples:[TouchAimCalibrationSample]
    public var completed:Bool
    public var duration:Double
    public init(label:TouchAimCalibrationLabel,repetition:Int,samples:[TouchAimCalibrationSample],completed:Bool=true,duration:Double) {
        self.label=label;self.repetition=repetition;self.samples=samples;self.completed=completed;self.duration=duration
    }
}
public struct TouchAimCalibrationValidation: Equatable, Sendable {
    public var passed:Bool
    public var unexpectedTransitions:Int
    public var falseActivationRate:Double
    public var missedActivationRate:Double
    public var explanation:String
}
public struct TouchAimCalibrationAnalysis: Equatable, Sendable {
    public var profile:TouchAimCalibrationProfile
    public var explanation:String
    public var isUsable:Bool { profile.quality == .good || profile.quality == .borderline }
}

import Foundation

/// Local timing for one reversible command in a comma-separated payload.
public struct PayloadCommandModifiers: Equatable, Sendable {
    public enum Timing: String, Sendable { case immediate = "I", sendOnRelease = "SOR" }
    public var timing: Timing?
    public var activationDelayMilliseconds: Int?
    public var holdReleaseMilliseconds: Int?
    public var repeatMilliseconds: Int?
    public var pressDurationMilliseconds: Int?

    public var isModified: Bool { minimumAndroidVersion != 0 }
    public var minimumAndroidVersion: Int {
        if pressDurationMilliseconds != nil { return 17 }
        if activationDelayMilliseconds != nil { return 16 }
        if repeatMilliseconds != nil { return 15 }
        return timing != nil || holdReleaseMilliseconds != nil ? 14 : 0
    }
    var delay: Double { Double(activationDelayMilliseconds ?? 0) / 1000 }
    var tail: Double { Double(holdReleaseMilliseconds ?? 0) / 1000 }
    var suffix: String {
        [timing.map { "(\($0.rawValue))" }, activationDelayMilliseconds.map { "(D\($0))" },
         repeatMilliseconds.map { "(R\($0))" }, holdReleaseMilliseconds.map { "(HRD\($0))" },
         pressDurationMilliseconds.map { "(U\($0))" }]
            .compactMap { $0 }.joined()
    }

    static func split(_ token: String) throws -> (String, Self) {
        let command = token.prefix { $0 != "(" && $0 != ")" }
        var suffix = token.dropFirst(command.count), result = Self()
        while !suffix.isEmpty {
            guard !command.isEmpty, suffix.first == "(", let end = suffix.firstIndex(of: ")") else {
                throw ControllerPayloadError("Enter timing after a command, such as RT:0.7(D100).")
            }
            let name = suffix[suffix.index(after: suffix.startIndex)..<end]
            suffix = suffix[suffix.index(after: end)...]
            if let timing = Timing(rawValue: String(name)) {
                guard result.timing == nil else { throw ControllerPayloadError("Choose (I) or (SOR) once per command.") }
                result.timing = timing
                continue
            }
            func number(_ prefix: String, minimum: Int, previous: Int?) throws -> Int {
                let digits = name.dropFirst(prefix.count)
                guard previous == nil, !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let value = Int(digits), (minimum...600_000).contains(value) else {
                    throw ControllerPayloadError("Use \(prefix) once with a whole number from \(minimum) through 600000 milliseconds.")
                }
                return value
            }
            if name.hasPrefix("HRD") { result.holdReleaseMilliseconds = try number("HRD", minimum: 0, previous: result.holdReleaseMilliseconds) }
            else if name.hasPrefix("R") { result.repeatMilliseconds = try number("R", minimum: 2, previous: result.repeatMilliseconds) }
            else if name.hasPrefix("D") { result.activationDelayMilliseconds = try number("D", minimum: 0, previous: result.activationDelayMilliseconds) }
            else if name.hasPrefix("U") { result.pressDurationMilliseconds = try number("U", minimum: 1, previous: result.pressDurationMilliseconds) }
            else { throw ControllerPayloadError("Unknown timing modifier (\(name)).") }
        }
        return (String(command), result)
    }

    func validate(for step: ControllerPayloadStep) throws {
        guard isModified else { return }
        guard step.isReversibleTimingCommand else {
            throw ControllerPayloadError("Timing modifiers need a reversible press, trigger pressure, or stick direction.")
        }
        if case let .triggerPulse(_, _, duration) = step, let repeatMilliseconds, duration >= Double(repeatMilliseconds) / 1000 {
            throw ControllerPayloadError("The trigger press must be shorter than its repeat interval.")
        }
        if timing == .sendOnRelease && repeatMilliseconds != nil {
            throw ControllerPayloadError("Use R for a held repeat or SOR for a release shot on this command.")
        }
        if case .triggerPulse = step, pressDurationMilliseconds != nil {
            throw ControllerPayloadError("Choose a trigger P duration or U press duration for this command.")
        }
        if let pressDurationMilliseconds, let repeatMilliseconds, pressDurationMilliseconds >= repeatMilliseconds {
            throw ControllerPayloadError("U press duration must be shorter than the R repeat interval.")
        }
    }
}

extension ControllerPayloadStep {
    var isReversibleTimingCommand: Bool {
        switch self {
        case .digital, .keyDown, .mouseDown, .fixedStick: true
        case let .triggerPressure(_, value), let .triggerPulse(_, value, _): value > 0
        default: false
        }
    }
}

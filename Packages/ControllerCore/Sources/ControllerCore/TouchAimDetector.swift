import Foundation

public enum TouchAimDetectorAction: Equatable, Sendable {
    case holdStage(TouchAimLevel), releaseStage(TouchAimLevel), pressStage(TouchAimLevel)
    case holdAim, releaseAim, holdShoot, releaseShoot, pressShoot
}

/// The same no-output classifier is used by live TouchAim and held-out calibration validation.
public struct TwoStateTouchAimDetector: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var shootOn:Double;public var shootOff:Double;public var smoothing:Double
        public var enterMilliseconds:Int;public var returnMilliseconds:Int
        public var behavior:TouchAimShootBehavior;public var hasAimPayload:Bool;public var hasShootPayload:Bool
        public var keepAimWhileShooting:Bool
        public init(shootOn:Double,shootOff:Double,smoothing:Double=0.35,enterMilliseconds:Int=90,returnMilliseconds:Int=120,
                    behavior:TouchAimShootBehavior = .hold,hasAimPayload:Bool=false,hasShootPayload:Bool=true,keepAimWhileShooting:Bool=true) {
            self.shootOn=shootOn;self.shootOff=shootOff;self.smoothing=smoothing;self.enterMilliseconds=enterMilliseconds;self.returnMilliseconds=returnMilliseconds
            self.behavior=behavior;self.hasAimPayload=hasAimPayload;self.hasShootPayload=hasShootPayload;self.keepAimWhileShooting=keepAimWhileShooting
        }
        public func validate() throws {
            guard shootOn.isFinite,shootOff.isFinite,(-1_200_000...1_200_000).contains(shootOn),(-1_200_000...1_200_000).contains(shootOff),shootOff<=shootOn-0.01+1e-12,smoothing.isFinite,(0.05...1).contains(smoothing),(1...2000).contains(enterMilliseconds),(1...2000).contains(returnMilliseconds) else { throw ControllerPayloadError("The two-state touch detector configuration is invalid.") }
        }
    }
    public let configuration:Configuration
    public private(set) var state:TouchAimState = .idle
    public private(set) var filteredScore:Double=0
    public private(set) var contactActive=false
    private var lastTime:Double?
    private var lastSampleTime:Double?
    private var enterCandidate:Double?
    private var returnCandidate:Double?
    private var returnPressArmed=false
    private var aimHeld=false
    private var shootHeld=false
    public init(configuration:Configuration)throws { try configuration.validate();self.configuration=configuration }
    public var nextDeadline:Double? {
        if let enterCandidate { return enterCandidate+Double(configuration.enterMilliseconds)/1000 }
        if let returnCandidate { return returnCandidate+Double(configuration.returnMilliseconds)/1000 }
        return nil
    }
    public mutating func begin(at time:Double=0)throws->[TouchAimDetectorAction] {
        try validateTime(time,allowRestart:true)
        var actions=end();lastTime=time;contactActive=true;state = .aim
        if configuration.hasAimPayload { aimHeld=true;actions.append(.holdAim) };return actions
    }
    public mutating func observe(score:Double,at time:Double,allowConfirmation:Bool=true)throws->[TouchAimDetectorAction] {
        guard time.isFinite,(0...3600).contains(time),lastSampleTime.map({time >= $0}) ?? true else { throw ControllerInputError.invalidTime }
        guard score.isFinite,abs(score)<=1_200_000 else { throw ControllerInputError.invalidPosition }
        guard contactActive else { return [] }
        let alpha:Double
        if let prior=lastSampleTime {
            let delta=max(0,time-prior)
            alpha=delta==0 ? 0:configuration.smoothing == 1 ? 1:1-pow(1-configuration.smoothing,delta/0.020)
        }
        else { alpha=1 }
        filteredScore += alpha*(score-filteredScore);lastSampleTime=time;lastTime=max(lastTime ?? time,time)
        return evaluate(at:time,allowConfirmation:allowConfirmation)
    }
    public mutating func tick(at time:Double)throws->[TouchAimDetectorAction] {
        try validateTime(time);lastTime=time
        guard contactActive,lastSampleTime != nil else { return [] };return evaluate(at:time)
    }
    /// Every terminal path cancels return-to-Aim firing; lift is not a state return.
    public mutating func end()->[TouchAimDetectorAction] {
        var actions:[TouchAimDetectorAction]=[]
        if shootHeld { actions.append(.releaseShoot) };if aimHeld { actions.append(.releaseAim) }
        state = .idle;filteredScore=0;contactActive=false;lastTime=nil;lastSampleTime=nil
        enterCandidate=nil;returnCandidate=nil;returnPressArmed=false;aimHeld=false;shootHeld=false
        return actions
    }
    private func validateTime(_ time:Double,allowRestart:Bool=false)throws {
        guard time.isFinite,(0...3600).contains(time),allowRestart || lastTime.map({time >= $0}) ?? true else { throw ControllerInputError.invalidTime }
    }
    private mutating func evaluate(at time:Double,allowConfirmation:Bool=true)->[TouchAimDetectorAction] {
        var actions:[TouchAimDetectorAction]=[]
        if state == .aim {
            guard filteredScore>=configuration.shootOn else { enterCandidate=nil;return [] }
            if enterCandidate == nil { enterCandidate=time }
            guard allowConfirmation,time+1e-10 >= enterCandidate!+Double(configuration.enterMilliseconds)/1000 else { return [] }
            state = .shoot;enterCandidate=nil;returnCandidate=nil
            if !configuration.keepAimWhileShooting && aimHeld { aimHeld=false;actions.append(.releaseAim) }
            switch configuration.behavior {
            case .hold:if configuration.hasShootPayload { shootHeld=true;actions.append(.holdShoot) }
            case .pressOnEnter:if configuration.hasShootPayload { actions.append(.pressShoot) }
            case .pressOnReturn:returnPressArmed=true
            }
        } else if state == .shoot {
            guard filteredScore<=configuration.shootOff else { returnCandidate=nil;return [] }
            if returnCandidate == nil { returnCandidate=time }
            guard allowConfirmation,time+1e-10 >= returnCandidate!+Double(configuration.returnMilliseconds)/1000 else { return [] }
            state = .aim;returnCandidate=nil;enterCandidate=nil
            if shootHeld { shootHeld=false;actions.append(.releaseShoot) }
            if returnPressArmed && configuration.hasShootPayload { returnPressArmed=false;actions.append(.pressShoot) }
            if configuration.hasAimPayload && !aimHeld { aimHeld=true;actions.append(.holdAim) }
        }
        return actions
    }
}

public struct TouchAimDetector: Sendable {
    public let settings:TouchAimSettings
    public private(set) var state:TouchAimState = .idle
    public private(set) var level:TouchAimLevel = .aimOnly
    public private(set) var filteredScore:Double=0
    public private(set) var issue:String?
    private var active=false
    private var hasScore=false
    private var lastTime:Double?
    private var lastObservation:Double?
    private var twoState:TwoStateTouchAimDetector?
    private var candidateStage: (level: TouchAimLevel, deadline: Double)?
    private var heldStages:Set<TouchAimLevel>=[]
    public init(settings:TouchAimSettings)throws {
        try settings.validate();self.settings=settings
        if settings.mode != .manualThreeStage {
            let two=settings.twoState,calibration=settings.mode == .calibratedTwoState ? settings.calibration:nil
            twoState=try .init(configuration:.init(shootOn:calibration?.shootOn ?? two.shootOn,shootOff:calibration?.shootOff ?? two.shootOff,
                smoothing:calibration?.smoothing ?? two.smoothing,enterMilliseconds:calibration?.enterMilliseconds ?? two.enterMilliseconds,
                returnMilliseconds:calibration?.returnMilliseconds ?? two.returnMilliseconds,behavior:two.shootBehavior,
                hasAimPayload:!(try advancedButtonProgram(two.aimPayload)).steps.isEmpty,
                hasShootPayload:!(try advancedButtonProgram(two.shootPayload)).steps.isEmpty,keepAimWhileShooting:two.keepAimWhileShooting))
        }
    }
    public var nextDeadline:Double? { settings.requiresLocalSetup ? nil : (candidateStage?.deadline ?? twoState?.nextDeadline) }
    public mutating func begin(metrics:TouchMetrics,at time:Double=0)throws->[TouchAimDetectorAction] {
        guard metrics.isValid,time.isFinite,(0...3600).contains(time) else { throw ControllerInputError.invalidPosition }
        var actions=end()
        if settings.requiresLocalSetup {
            active=true; state = .aim; lastTime=time; lastObservation=time
            return actions
        }
        do { _ = try resolvedScore(metrics) } catch { state = .unavailable;issue=(error as? LocalizedError)?.errorDescription ?? String(describing:error);return actions }
        active=true;state = .aim;issue=nil;lastTime=max(lastTime ?? time,time);lastObservation=time
        if twoState != nil { actions += try twoState!.begin(at:time) }
        actions += try observe(metrics:metrics,at:time);return actions
    }
    public mutating func observe(metrics:TouchMetrics,at time:Double,allowConfirmation:Bool=true)throws->[TouchAimDetectorAction] {
        guard metrics.isValid else { throw ControllerInputError.invalidPosition }
        guard time.isFinite,(0...3600).contains(time),lastObservation.map({time >= $0}) ?? true else { throw ControllerInputError.invalidTime };guard active else { return [] }
        if settings.requiresLocalSetup { lastTime=max(lastTime ?? time,time);lastObservation=time;return [] }
        let score:Double
        do { score=try resolvedScore(metrics)
        } catch {
            let actions=end();state = .unavailable;issue=(error as? LocalizedError)?.errorDescription ?? String(describing:error);return actions
        }
        lastTime=max(lastTime ?? time,time);lastObservation=time
        if twoState != nil {
            let actions=try twoState!.observe(score:score,at:time,allowConfirmation:allowConfirmation);state=twoState!.state;filteredScore=twoState!.filteredScore;return actions
        }
        filteredScore=hasScore ? filteredScore+settings.threeStage.smoothing*(score-filteredScore):score;hasScore=true
        let stages:[(TouchAimLevel,TouchAimStage)]=[(.low,settings.threeStage.low),(.medium,settings.threeStage.medium),(.high,settings.threeStage.high)]
        let raw=stages.last(where:{filteredScore >= $0.1.threshold})?.0 ?? .aimOnly
        let next:TouchAimLevel=raw.rank>=level.rank ? raw:stages.last(where:{$0.0.rank<=level.rank && filteredScore>=max(0,$0.1.threshold-settings.threeStage.hysteresis)})?.0 ?? .aimOnly
        guard next != level else { candidateStage = nil; return [] }
        let wait = settings.threeStage.tuning(for: next).confirmationMilliseconds
        if wait == 0 { return enter(next) }
        if candidateStage?.level != next {
            candidateStage = (next, time + Double(wait) / 1000)
        }
        return allowConfirmation ? confirmStage(at: time) : []
    }
    private mutating func confirmStage(at time: Double) -> [TouchAimDetectorAction] {
        guard let candidateStage, GestureDeadline.reached(candidateStage.deadline, at: time) else { return [] }
        return enter(candidateStage.level)
    }
    private mutating func enter(_ next: TouchAimLevel) -> [TouchAimDetectorAction] {
        candidateStage = nil
        let stages: [(TouchAimLevel, TouchAimStage)] = [(.low, settings.threeStage.low), (.medium, settings.threeStage.medium), (.high, settings.threeStage.high)]
        let desired=Set(stages.filter { (settings.threeStage.keepLowerHolds ? $0.0.rank<=next.rank:$0.0==next) && $0.1.action == .hold && !$0.1.payload.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.map(\.0))
        var actions=heldStages.subtracting(desired).sorted{$0.rank>$1.rank}.map(TouchAimDetectorAction.releaseStage)
        actions += desired.subtracting(heldStages).sorted{$0.rank<$1.rank}.map(TouchAimDetectorAction.holdStage)
        if next.rank>level.rank { actions += stages.filter{$0.0.rank>level.rank && $0.0.rank<=next.rank && (!settings.threeStage.hasConfirmation || $0.0 == next) && $0.1.action == .press && !$0.1.payload.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}.map{.pressStage($0.0)} }
        heldStages=desired;level=next;state=next == .aimOnly ? .aim:next == .low ? .low:next == .medium ? .medium:.high
        return actions
    }
    public mutating func tick(at time:Double)throws->[TouchAimDetectorAction] {
        try validateTime(time);lastTime=time;guard !settings.requiresLocalSetup,active else { return [] }
        if twoState == nil { return confirmStage(at: time) }
        let actions=try twoState!.tick(at:time);state=twoState!.state;filteredScore=twoState!.filteredScore;return actions
    }
    public mutating func end()->[TouchAimDetectorAction] {
        var actions=heldStages.sorted{$0.rank>$1.rank}.map(TouchAimDetectorAction.releaseStage)
        if twoState != nil { actions += twoState!.end() }
        candidateStage=nil;active=false;hasScore=false;lastTime=nil;lastObservation=nil;heldStages=[];level = .aimOnly;state = .idle;filteredScore=0;issue=nil
        return actions
    }
    private func resolvedScore(_ metrics:TouchMetrics)throws->Double {
        if settings.mode == .calibratedTwoState { return try settings.calibration!.score(metrics) }
        guard let raw=metrics.value(for:settings.metric) else { throw ControllerPayloadError("The selected \(settings.metric.displayName) metric is unavailable. Choose an available metric in the no-output diagnostic.") }
        return raw*settings.metricScale
    }
    private func validateTime(_ time:Double)throws {
        guard time.isFinite,(0...3600).contains(time),lastTime.map({time >= $0}) ?? true else { throw ControllerInputError.invalidTime }
    }
}

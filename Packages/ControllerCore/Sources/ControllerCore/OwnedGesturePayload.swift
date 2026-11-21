import Foundation

/// Internal shared payload claims for captured surfaces; a lease never releases another lease.
struct GesturePayloadClaims: Sendable {
    var actions:Set<ControllerControlID>=[]
    var keys:Set<KeyboardKey>=[]
    var mouse:Set<PracticeMouseButton>=[]
    var pressure:[TriggerChannel:Double]=[:]
    var hasOutput:Bool { !actions.isEmpty || !keys.isEmpty || !mouse.isEmpty || pressure.values.contains{$0>0} }
    mutating func union(_ other:Self,overridePressure:Bool=false) {
        actions.formUnion(other.actions);keys.formUnion(other.keys);mouse.formUnion(other.mouse)
        for (channel,value) in other.pressure {
            if overridePressure { pressure[channel]=value }
            else if value>0 { pressure[channel]=max(pressure[channel] ?? 0,value) }
        }
    }
}
struct OwnedGesturePayloadLease: Sendable {
    let activationID = UUID()
    var program:ControllerPayloadProgram
    var started:Double
    var expires:Double?
    var repeats:Bool
    init(program:ControllerPayloadProgram,started:Double,expires:Double?=nil,repeats:Bool=false) {
        self.program=program;self.started=started;self.expires=expires;self.repeats=repeats
    }
    func claims(at time:Double)->GesturePayloadClaims {
        guard expires.map({ !GestureDeadline.reached($0, at: time) }) ?? true else { return .init() }
        var result=GesturePayloadClaims()
        for step in program.steps {
            switch step {
            case let .digital(action):result.actions.insert(action)
            case let .keyDown(key):result.keys.insert(key)
            case let .mouseDown(button):result.mouse.insert(button)
            case let .triggerPressure(channel,value):result.pressure[channel]=value
            case let .triggerPulse(channel,value,duration):
                let on = GestureDeadline.pulse(start: started, duration: duration, repeats: repeats, at: time).on
                result.pressure[channel]=on ? value:nil
            case .fixedStick: break // Separately arbitrated by the activation's stable macro lease.
            case .wait,.mouseUp,.scrollModeToggle,.releaseAll,.cameraFollow,.autoCenter:break // Advanced surface validation excludes these.
            }
        }
        return result
    }
    func nextDeadline(after time:Double)->Double? {
        guard expires.map({ !GestureDeadline.reached($0, at: time) }) ?? true else { return nil }
        var due=expires.map{[$0]} ?? []
        for step in program.steps {
            if case let .triggerPulse(_,_,duration)=step,
               let next = GestureDeadline.pulse(start: started, duration: duration, repeats: repeats, at: time).next {
                due.append(next)
            }
        }
        return due.filter { $0.isFinite && !GestureDeadline.reached($0, at: time) }.min()
    }
}

enum AimSurfaceMath {
    static func stick(sample:ButtonPointerSample,origin:ButtonPointerSample,tuning:ButtonAimTuning)->StickPosition {
        ButtonGestureRuntime.vector(sample:sample,origin:origin,tuning:tuning)
    }
    static func mouseCurve(_ value:Double)->Double { ButtonGestureRuntime.mouseCurve(value) }
}

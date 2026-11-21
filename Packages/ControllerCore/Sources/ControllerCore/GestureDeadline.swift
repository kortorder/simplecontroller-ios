import Foundation

/// Keeps captured-surface phases consistent with the enclosing engine's one-shot scheduler.
/// Subtracting a long system uptime can lose more precision than a fixed relative epsilon.
enum GestureDeadline {
    static func tolerance(at time: Double) -> Double { max(1e-10, time.ulp * 2) }
    static func reached(_ deadline: Double, at time: Double) -> Bool {
        deadline <= time + tolerance(at: time)
    }
    static func phase(start: Double, period: Double, width: Double, at time: Double) -> (on: Bool, next: Double) {
        let count = floor((max(0, time - start) + tolerance(at: time)) / period)
        let beginning = start + count * period
        let on = !reached(beginning + width, at: time)
        return (on, on ? beginning + width : beginning + period)
    }
    static func pulse(start: Double, duration: Double, repeats: Bool, at time: Double) -> (on: Bool, next: Double?) {
        if repeats {
            let result = phase(start: start, period: duration, width: duration / 2, at: time)
            return (result.on, result.next)
        }
        let end = start + duration
        return reached(end, at: time) ? (false, nil) : (true, end)
    }
}

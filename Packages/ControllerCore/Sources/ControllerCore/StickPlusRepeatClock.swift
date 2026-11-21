import Foundation

/// One selected stick stage owns one bounded digital repeat clock. Missed edges are
/// never replayed: late delivery first observes the next edge and starts its full
/// phase there, ensuring a real off interval before another press.
struct StickPlusRepeatClock: Sendable {
    let interval: TimeInterval
    private(set) var isOn = true
    private(set) var nextDeadline: TimeInterval
    private var width: TimeInterval { min(0.05, interval / 2) }

    init(milliseconds: Int, at time: TimeInterval) {
        interval = Double(milliseconds) / 1_000
        nextDeadline = time + max(min(0.05, interval / 2), time.ulp * 4)
    }

    mutating func advance(to time: TimeInterval) {
        guard nextDeadline <= time + max(1e-10, time.ulp * 2) else { return }
        isOn.toggle()
        let duration = isOn ? width : interval - width
        nextDeadline = time + max(duration, time.ulp * 4)
    }
}

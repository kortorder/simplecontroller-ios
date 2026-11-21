import Foundation

/// Labels observed movement for no-output calibration recordings. This does not
/// classify touch pressure, choose actions, or relax calibration quality checks.
/// Actual positions within a short time window are compared, so splitting a
/// movement into many small coalesced segments does not erase that movement.
public struct TouchAimMotionWindow: Sendable {
    public static let observationWindow: TimeInterval = 0.12
    public static let minimumDisplacement = 0.75
    private static let bucketDuration: TimeInterval = 0.02
    private static let maximumBuckets = 8

    private struct Observation: Sendable {
        var x: Double
        var y: Double
        var time: TimeInterval
    }

    /// At most six actual observations per bucket, rather than an unbounded path
    /// sum. Keeping extrema also preserves brief out-and-back movement.
    private struct Bucket: Sendable {
        var first: Observation
        var last: Observation
        var minX: Observation
        var maxX: Observation
        var minY: Observation
        var maxY: Observation

        init(_ observation: Observation) {
            first = observation; last = observation
            minX = observation; maxX = observation
            minY = observation; maxY = observation
        }

        mutating func append(_ observation: Observation) {
            last = observation
            // Keep the newer observation on ties so a stationary point remains
            // represented after older observations fall out of the time window.
            if observation.x <= minX.x { minX = observation }
            if observation.x >= maxX.x { maxX = observation }
            if observation.y <= minY.y { minY = observation }
            if observation.y >= maxY.y { maxY = observation }
        }

        var observations: [Observation] { [first, last, minX, maxX, minY, maxY] }
    }

    private var buckets: [Bucket] = []
    private var lastTime: TimeInterval?
    var retainedObservationCount: Int { buckets.count * 6 }

    public init() {}

    public mutating func reset() {
        buckets.removeAll(keepingCapacity: true)
        lastTime = nil
    }

    /// `at` uses a single monotonic clock, such as UIKit's touch timestamps.
    /// Invalid observations are rejected before changing the window.
    public mutating func observe(x: Double, y: Double, at time: TimeInterval) throws -> Bool {
        guard time.isFinite, time >= 0, time + Self.observationWindow > time,
              lastTime.map({ time >= $0 }) ?? true else { throw ControllerInputError.invalidTime }
        guard x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else {
            throw ControllerInputError.invalidPosition
        }
        let observation = Observation(x: x, y: y, time: time)
        let cutoff = time - Self.observationWindow
        buckets.removeAll { $0.last.time < cutoff }
        let moving = buckets.contains { bucket in
            bucket.observations.contains {
                $0.time >= cutoff && hypot(x - $0.x, y - $0.y) > Self.minimumDisplacement
            }
        }
        if var last = buckets.last, time - last.first.time < Self.bucketDuration {
            last.append(observation)
            buckets[buckets.count - 1] = last
        } else {
            buckets.append(Bucket(observation))
        }
        if buckets.count > Self.maximumBuckets {
            buckets.removeFirst(buckets.count - Self.maximumBuckets)
        }
        lastTime = time
        return moving
    }
}

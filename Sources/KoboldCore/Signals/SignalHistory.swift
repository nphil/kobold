import Foundation

/// A fixed-capacity rolling history for one signal.
///
/// **The capacity is the whole point.** Swift Charts is comfortable to a couple
/// of thousand marks and collapses on unbounded live data — a documented case
/// went fully unresponsive after roughly 400 points appended at 40 Hz, and
/// `.drawingGroup()` did not rescue it, because the data model itself was the
/// problem. Bounding the model is the fix; every rendering trick after it is
/// only worth doing once this is in place. See docs/05.
///
/// Backed by a ring rather than an array that is appended to and trimmed: a
/// trim on every sample is O(n) copying on a path that runs for the whole
/// drive, and the allocation pattern is exactly the one that shows up as
/// dropped frames rather than as slow data.
public struct SignalHistory: Sendable, Equatable {

    /// One reading. Deliberately leaner than `SignalSample`: the id and unit are
    /// properties of the buffer, not of each point, and a `TimeInterval` does
    /// arithmetic without the bridging a `Date` implies.
    public struct Point: Sendable, Equatable {
        public let time: TimeInterval
        public let value: Double

        public init(time: TimeInterval, value: Double) {
            self.time = time
            self.value = value
        }
    }

    /// Sized for the longest window a chart offers, at the highest sample rate
    /// the transport can reach. Over-sizing costs 16 bytes a slot and nothing
    /// else; under-sizing silently shortens the history a chart can draw.
    public static let defaultCapacity = 1024

    private var storage: [Point]
    /// Index the next append writes to.
    private var head = 0
    private var count = 0

    public let capacity: Int

    public init(capacity: Int = SignalHistory.defaultCapacity) {
        self.capacity = max(1, capacity)
        storage = []
        storage.reserveCapacity(self.capacity)
    }

    public var isEmpty: Bool { count == 0 }
    public var sampleCount: Int { count }

    public mutating func append(_ value: Double, at time: TimeInterval) {
        if storage.count < capacity {
            storage.append(Point(time: time, value: value))
        } else {
            storage[head] = Point(time: time, value: value)
        }
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    /// Every retained point, oldest first.
    public var points: [Point] {
        guard count > 0 else { return [] }
        guard storage.count == capacity else { return storage }

        // Once wrapped, the oldest point sits at `head`.
        return Array(storage[head...] + storage[..<head])
    }

    /// Points at or after `time`, oldest first.
    ///
    /// Linear rather than a binary search on purpose: the ring is small and
    /// already ordered, and the caller is a chart refreshing a few times a
    /// second, not a hot loop.
    public func points(since time: TimeInterval) -> [Point] {
        points.drop { $0.time < time }.map { $0 }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        count = 0
    }
}

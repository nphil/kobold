import Foundation

/// Tunes the per-command wait window from observed behaviour.
///
/// The ELM327's own `AT ST` timeout defaults to 200 ms, and a naive client that
/// always waits that long is capped near 4–6 responses per second regardless of
/// how fast the car actually answers. Real ECU replies on CAN are often ~20–50 ms,
/// so shrinking the window toward the observed round-trip is one of the few
/// levers that materially raises sample rate.
///
/// The shape here follows AndrOBD's approach: shrink gradually while replies keep
/// arriving, and back off hard the moment one is missed. Backing off faster than
/// it advances is deliberate — an over-tight timeout turns healthy-but-slow PIDs
/// into phantom `NO DATA`, which is worse than a slightly lower poll rate.
public struct AdaptiveTiming: Sendable, Equatable {
    public private(set) var current: Duration

    public let minimum: Duration
    public let maximum: Duration

    /// Multiplier applied after a success (<1 shrinks the window).
    private let shrinkFactor: Double
    /// Multiplier applied after a timeout (>1 grows it).
    private let growthFactor: Double

    public init(initial: Duration = .milliseconds(200),
                minimum: Duration = .milliseconds(32),
                maximum: Duration = .milliseconds(1000),
                shrinkFactor: Double = 0.9,
                growthFactor: Double = 2.0) {
        self.current = initial
        self.minimum = minimum
        self.maximum = maximum
        self.shrinkFactor = shrinkFactor
        self.growthFactor = growthFactor
    }

    /// Records a successful exchange and eases the window down.
    ///
    /// Never drops below roughly twice the observed round-trip, so a single fast
    /// reply can't collapse the window to the point where normal jitter starts
    /// producing timeouts.
    public mutating func recordSuccess(roundTrip: Duration? = nil) {
        var next = current.scaled(by: shrinkFactor)
        if let roundTrip {
            let floor = roundTrip.scaled(by: 2.0)
            if next < floor { next = floor }
        }
        current = clamp(next)
    }

    /// Records a timeout or `NO DATA` and backs the window off.
    public mutating func recordTimeout() {
        current = clamp(current.scaled(by: growthFactor))
    }

    public mutating func reset(to duration: Duration) {
        current = clamp(duration)
    }

    private func clamp(_ duration: Duration) -> Duration {
        if duration < minimum { return minimum }
        if duration > maximum { return maximum }
        return duration
    }
}

extension Duration {
    /// Scales a duration by a factor, working in attoseconds to avoid the
    /// precision loss of a round trip through `Double` seconds.
    func scaled(by factor: Double) -> Duration {
        let (seconds, attoseconds) = components
        let total = Double(seconds) * 1e18 + Double(attoseconds)
        let scaled = max(0, total * factor)
        let scaledSeconds = Int64(scaled / 1e18)
        let scaledAttoseconds = Int64(scaled.truncatingRemainder(dividingBy: 1e18))
        return Duration(secondsComponent: scaledSeconds,
                        attosecondsComponent: scaledAttoseconds)
    }

    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}

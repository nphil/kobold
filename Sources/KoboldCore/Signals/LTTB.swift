import Foundation

/// Largest-Triangle-Three-Buckets downsampling.
///
/// Reduces a series to a target number of points while keeping the shape a
/// human reads off a chart. The reason it is this algorithm and not averaging:
/// **averaging erases spikes, and on this dashboard the spikes are the data.**
/// A brief knock event or a boost overshoot lasts a handful of samples, and
/// mean-downsampling smooths it into the surrounding noise — the failure mode
/// that lost a 50 ms pressure oscillation in the rocket-telemetry case
/// docs/05 cites. LTTB keeps whichever point in each bucket forms the largest
/// triangle with its neighbours, which is precisely the extremes.
///
/// O(n), single pass, no allocation beyond the result. Intended to run off the
/// main thread; it is a pure function so that is the caller's choice.
public enum LTTB {

    /// Downsamples `points` to at most `threshold` points.
    ///
    /// Returns the input untouched when it is already small enough, so callers
    /// can apply this unconditionally.
    public static func downsample(_ points: [SignalHistory.Point],
                                  to threshold: Int) -> [SignalHistory.Point] {
        // Fewer than three buckets leaves no interior to choose from, and the
        // algorithm is defined in terms of a first and last that are always
        // kept.
        guard threshold >= 3, points.count > threshold else { return points }

        var sampled: [SignalHistory.Point] = []
        sampled.reserveCapacity(threshold)

        // The first and last points are always retained, so the interior is
        // divided into `threshold - 2` buckets.
        let bucketSize = Double(points.count - 2) / Double(threshold - 2)

        sampled.append(points[0])

        // Index of the point selected from the previous bucket: one vertex of
        // every triangle considered in this one.
        var previous = 0

        for bucket in 0..<(threshold - 2) {
            // The opposite vertex is the average of the *next* bucket, which is
            // what makes the choice look ahead rather than only behind.
            let nextStart = Int((Double(bucket + 1) * bucketSize).rounded(.down)) + 1
            let nextEnd = Swift.min(Int((Double(bucket + 2) * bucketSize).rounded(.down)) + 1,
                                    points.count)

            var averageTime = 0.0
            var averageValue = 0.0

            if nextEnd > nextStart {
                for index in nextStart..<nextEnd {
                    averageTime += points[index].time
                    averageValue += points[index].value
                }
                let length = Double(nextEnd - nextStart)
                averageTime /= length
                averageValue /= length
            } else {
                // Final bucket: the last point stands in for the average.
                averageTime = points[points.count - 1].time
                averageValue = points[points.count - 1].value
            }

            let rangeStart = Int((Double(bucket) * bucketSize).rounded(.down)) + 1
            let rangeEnd = Swift.min(Int((Double(bucket + 1) * bucketSize).rounded(.down)) + 1,
                                     points.count)

            let anchor = points[previous]
            var largestArea = -1.0
            var chosen = rangeStart

            for index in rangeStart..<Swift.max(rangeEnd, rangeStart + 1) where index < points.count {
                let candidate = points[index]
                // Twice the triangle area, via the cross product. The factor of
                // two is common to every candidate, so it never changes which
                // one wins — but halving it here would be arithmetic performed
                // once per sample for no reason.
                let area = abs((anchor.time - averageTime) * (candidate.value - anchor.value)
                               - (anchor.time - candidate.time) * (averageValue - anchor.value))

                if area > largestArea {
                    largestArea = area
                    chosen = index
                }
            }

            sampled.append(points[chosen])
            previous = chosen
        }

        sampled.append(points[points.count - 1])
        return sampled
    }
}

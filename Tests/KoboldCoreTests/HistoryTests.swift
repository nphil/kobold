import XCTest
@testable import KoboldCore

final class SignalHistoryTests: XCTestCase {

    func testKeepsPointsInOrder() {
        var history = SignalHistory(capacity: 8)
        for index in 0..<5 {
            history.append(Double(index), at: TimeInterval(index))
        }

        XCTAssertEqual(history.sampleCount, 5)
        XCTAssertEqual(history.points.map(\.value), [0, 1, 2, 3, 4])
    }

    /// The reason this type exists: a live session runs for a whole drive, and
    /// an unbounded model is what makes Swift Charts collapse.
    func testCapacityIsHardAndDropsOldest() {
        var history = SignalHistory(capacity: 4)
        for index in 0..<10 {
            history.append(Double(index), at: TimeInterval(index))
        }

        XCTAssertEqual(history.sampleCount, 4)
        XCTAssertEqual(history.points.map(\.value), [6, 7, 8, 9])
    }

    /// Wrapping must not scramble the order — the ring's whole risk.
    func testOrderSurvivesManyWraps() {
        var history = SignalHistory(capacity: 3)
        for index in 0..<100 {
            history.append(Double(index), at: TimeInterval(index))
        }

        XCTAssertEqual(history.points.map(\.value), [97, 98, 99])
        XCTAssertEqual(history.points.map(\.time), [97, 98, 99])
    }

    func testExactlyFullDoesNotWrap() {
        var history = SignalHistory(capacity: 3)
        for index in 0..<3 {
            history.append(Double(index), at: TimeInterval(index))
        }
        XCTAssertEqual(history.points.map(\.value), [0, 1, 2])
    }

    func testWindowingByTime() {
        var history = SignalHistory(capacity: 16)
        for index in 0..<10 {
            history.append(Double(index), at: TimeInterval(index))
        }

        XCTAssertEqual(history.points(since: 7).map(\.value), [7, 8, 9])
        XCTAssertEqual(history.points(since: 100), [])
        XCTAssertEqual(history.points(since: 0).count, 10)
    }

    func testEmptyAndCleared() {
        var history = SignalHistory(capacity: 4)
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history.points, [])

        history.append(1, at: 0)
        XCTAssertFalse(history.isEmpty)

        history.removeAll()
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history.points, [])

        // Reusable after clearing, and still bounded.
        for index in 0..<10 { history.append(Double(index), at: TimeInterval(index)) }
        XCTAssertEqual(history.points.map(\.value), [6, 7, 8, 9])
    }
}

final class LTTBTests: XCTestCase {

    private func ramp(_ count: Int) -> [SignalHistory.Point] {
        (0..<count).map { SignalHistory.Point(time: TimeInterval($0), value: Double($0)) }
    }

    func testSmallSeriesIsReturnedUntouched() {
        let points = ramp(10)
        XCTAssertEqual(LTTB.downsample(points, to: 10), points)
        XCTAssertEqual(LTTB.downsample(points, to: 50), points)
    }

    func testDegenerateThresholdsAreRefused() {
        let points = ramp(100)
        XCTAssertEqual(LTTB.downsample(points, to: 2), points)
        XCTAssertEqual(LTTB.downsample(points, to: 0), points)
    }

    func testProducesExactlyTheRequestedCount() {
        let result = LTTB.downsample(ramp(1000), to: 100)
        XCTAssertEqual(result.count, 100)
    }

    func testEndpointsAreAlwaysKept() {
        let points = ramp(500)
        let result = LTTB.downsample(points, to: 50)

        XCTAssertEqual(result.first, points.first)
        XCTAssertEqual(result.last, points.last)
    }

    func testOutputStaysChronological() {
        let result = LTTB.downsample(ramp(777), to: 61)
        XCTAssertEqual(result.map(\.time), result.map(\.time).sorted())
    }

    /// The property the algorithm was chosen for. A single-sample spike is
    /// exactly what a boost overshoot or a knock event looks like, and mean
    /// downsampling erases it.
    func testASpikeSurvivesDownsampling() {
        var points = (0..<1000).map {
            SignalHistory.Point(time: TimeInterval($0), value: 10)
        }
        points[437] = SignalHistory.Point(time: 437, value: 250)

        let result = LTTB.downsample(points, to: 100)

        XCTAssertTrue(result.contains { $0.value == 250 },
                      "LTTB is used precisely because it preserves extremes")
    }

    /// A mean would land at 10.24 and the spike would be invisible; this is the
    /// comparison that justifies the algorithm rather than assuming it.
    func testMeanWouldHaveLostThatSpike() {
        var points = (0..<1000).map {
            SignalHistory.Point(time: TimeInterval($0), value: 10)
        }
        points[437] = SignalHistory.Point(time: 437, value: 250)

        let bucket = points[400..<500]
        let mean = bucket.map(\.value).reduce(0, +) / Double(bucket.count)

        XCTAssertLessThan(mean, 13, "averaging flattens the spike into the noise")
    }

    func testHandlesAFlatSeriesWithoutCrashing() {
        let flat = (0..<500).map { SignalHistory.Point(time: TimeInterval($0), value: 42) }
        let result = LTTB.downsample(flat, to: 50)

        XCTAssertEqual(result.count, 50)
        XCTAssertTrue(result.allSatisfy { $0.value == 42 })
    }
}

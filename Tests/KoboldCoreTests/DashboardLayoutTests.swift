import XCTest
@testable import KoboldCore

final class DashboardLayoutTests: XCTestCase {

    func testAddingKeepsOrder() {
        var layout = DashboardLayout()
        layout.add(.rpm, presentation: .gauge)
        layout.add(.speed)
        layout.add(.coolantTemp, presentation: .graph)

        XCTAssertEqual(layout.signals, [.rpm, .speed, .coolantTemp])
        XCTAssertEqual(layout.cards.map(\.presentation), [.gauge, .number, .graph])
    }

    /// One card per signal. Two cards showing the same number in different
    /// forms is clutter on a screen whose brief is to resist clutter.
    func testASignalCannotAppearTwice() {
        var layout = DashboardLayout()
        XCTAssertTrue(layout.add(.rpm))
        XCTAssertFalse(layout.add(.rpm, presentation: .graph))
        XCTAssertEqual(layout.signals, [.rpm])
    }

    func testCapIsRefusedRatherThanSilentlyShrinking() {
        var layout = DashboardLayout()
        for index in 0..<DashboardLayout.maximumCards {
            XCTAssertTrue(layout.add(SignalID("signal\(index)")))
        }
        XCTAssertTrue(layout.isFull)
        XCTAssertFalse(layout.add(.rpm), "past the cap nothing is legible at a glance")
        XCTAssertEqual(layout.cards.count, DashboardLayout.maximumCards)
    }

    func testRemoving() {
        var layout = DashboardLayout()
        layout.add(.rpm); layout.add(.speed); layout.add(.boost)

        layout.remove(.speed)
        XCTAssertEqual(layout.signals, [.rpm, .boost])

        // Removing something absent is a no-op, not a crash.
        layout.remove(.oilTemp)
        XCTAssertEqual(layout.signals, [.rpm, .boost])
    }

    func testChangingPresentation() {
        var layout = DashboardLayout()
        layout.add(.rpm, presentation: .number)

        layout.setPresentation(.graph, for: .rpm)
        XCTAssertEqual(layout.cards.first?.presentation, .graph)

        // Silently ignored for a signal that is not on the dashboard.
        layout.setPresentation(.gauge, for: .speed)
        XCTAssertEqual(layout.signals, [.rpm])
    }

    // MARK: - Moving

    func testMoveDownwards() {
        var layout = DashboardLayout()
        [SignalID.rpm, .speed, .boost, .coolantTemp].forEach { layout.add($0) }

        layout.move(from: 0, to: 2)
        XCTAssertEqual(layout.signals, [.speed, .boost, .rpm, .coolantTemp])
    }

    func testMoveUpwards() {
        var layout = DashboardLayout()
        [SignalID.rpm, .speed, .boost, .coolantTemp].forEach { layout.add($0) }

        layout.move(from: 3, to: 1)
        XCTAssertEqual(layout.signals, [.rpm, .coolantTemp, .speed, .boost])
    }

    func testMoveToItselfIsANoOp() {
        var layout = DashboardLayout()
        [SignalID.rpm, .speed].forEach { layout.add($0) }

        layout.move(from: 1, to: 1)
        XCTAssertEqual(layout.signals, [.rpm, .speed])
    }

    /// A drag can end anywhere, including off the end of the grid.
    func testOutOfRangeMovesAreClampedNotCrashes() {
        var layout = DashboardLayout()
        [SignalID.rpm, .speed, .boost].forEach { layout.add($0) }

        layout.move(from: 0, to: 99)
        XCTAssertEqual(layout.signals, [.speed, .boost, .rpm])

        layout.move(from: 2, to: -5)
        XCTAssertEqual(layout.signals, [.rpm, .speed, .boost])

        layout.move(from: 42, to: 0)
        XCTAssertEqual(layout.signals, [.rpm, .speed, .boost])
    }

    // MARK: - Resolution

    /// A layout outlives the car it was built on.
    func testCardsForAbsentSignalsAreDropped() {
        var layout = DashboardLayout()
        [SignalID.rpm, .speed, .oilTemp].forEach { layout.add($0) }

        let resolved = layout.resolved(against: [.rpm, .speed])
        XCTAssertEqual(resolved.signals, [.rpm, .speed],
                       "a card that cannot resolve renders as a permanent dash")
    }

    func testStandardLayoutOnlyUsesAvailableSignals() {
        let layout = DashboardLayout.standard(available: [.rpm, .speed, .coolantTemp])

        XCTAssertEqual(layout.signals, [.rpm, .speed, .coolantTemp])
        XCTAssertEqual(layout.cards.first?.presentation, .gauge, "engine speed leads")
    }

    func testStandardLayoutOnAVehicleWithNothingKnown() {
        XCTAssertTrue(DashboardLayout.standard(available: []).isEmpty)
    }

    // MARK: - Persistence

    func testRoundTripsThroughJSON() throws {
        var layout = DashboardLayout()
        layout.add(.rpm, presentation: .gauge)
        layout.add(.boost, presentation: .graph)

        let restored = try XCTUnwrap(DashboardLayout.decoded(from: layout.encoded()))
        XCTAssertEqual(restored, layout)
    }

    /// Persisted data is as capable of carrying nonsense as anything else,
    /// especially across versions, so decoding enforces the same invariants as
    /// the initialiser rather than trusting the file.
    func testDecodingEnforcesTheInvariants() throws {
        let duplicated = """
        {"cards":[{"signal":"rpm","presentation":"gauge"},
                  {"signal":"rpm","presentation":"graph"},
                  {"signal":"speed","presentation":"number"}]}
        """
        let layout = try XCTUnwrap(DashboardLayout.decoded(from: Data(duplicated.utf8)))
        XCTAssertEqual(layout.signals, [.rpm, .speed])
    }

    func testDecodingEnforcesTheCap() throws {
        let many = (0..<40).map { "{\"signal\":\"s\($0)\",\"presentation\":\"number\"}" }
            .joined(separator: ",")
        let layout = try XCTUnwrap(DashboardLayout.decoded(from: Data("{\"cards\":[\(many)]}".utf8)))
        XCTAssertEqual(layout.cards.count, DashboardLayout.maximumCards)
    }

    func testGarbageDecodesToNothingRatherThanThrowing() {
        XCTAssertNil(DashboardLayout.decoded(from: Data("not json".utf8)))
    }
}

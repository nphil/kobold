import XCTest
@testable import KoboldCore

/// Drag-to-reorder, minus the view.
///
/// These exist because both rules here are wrong in ways a screenshot cannot
/// show: a grid that reorders a beat too early, and a card that jumps at the
/// moment it should look most attached to the finger.
final class GridReorderTests: XCTestCase {

    /// A two-column grid of 100×80 slots with 10 between them.
    private let slots: [SignalID: CGRect] = [
        "rpm":     CGRect(x: 0,   y: 0,  width: 100, height: 80),
        "speed":   CGRect(x: 110, y: 0,  width: 100, height: 80),
        "coolant": CGRect(x: 0,   y: 90, width: 100, height: 80),
        "boost":   CGRect(x: 110, y: 90, width: 100, height: 80),
    ]

    func testTheSlotUnderTheFingerIsTheTarget() {
        XCTAssertEqual(GridReorder.target(at: CGPoint(x: 160, y: 40),
                                          in: slots, excluding: "rpm"), "speed")
        XCTAssertEqual(GridReorder.target(at: CGPoint(x: 50, y: 130),
                                          in: slots, excluding: "rpm"), "coolant")
    }

    /// The reason for containment rather than "nearest". In the gutter the
    /// finger is on nothing, and a grid that keeps swapping while you cross the
    /// gap between two slots never settles.
    func testNoTargetInTheGapBetweenSlots() {
        XCTAssertNil(GridReorder.target(at: CGPoint(x: 105, y: 40),
                                        in: slots, excluding: "rpm"))
        XCTAssertNil(GridReorder.target(at: CGPoint(x: 50, y: 85),
                                        in: slots, excluding: "rpm"))
        XCTAssertNil(GridReorder.target(at: CGPoint(x: 400, y: 400),
                                        in: slots, excluding: "rpm"))
    }

    /// A card is always over its own slot at the start of a drag. Without the
    /// exclusion it would swap with itself on the first frame, every time.
    func testACardIsNeverItsOwnTarget() {
        XCTAssertNil(GridReorder.target(at: CGPoint(x: 50, y: 40),
                                        in: slots, excluding: "rpm"))
    }

    /// Overlaps should not happen in a grid, but resolving one by dictionary
    /// order would make the resulting bug unreproducible.
    func testOverlappingSlotsResolveToTheNearestCentreNotToWhicheverCameFirst() {
        let overlapping: [SignalID: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 100),
            "b": CGRect(x: 50, y: 0, width: 100, height: 100),
        ]
        // x = 95 is inside both, and 5 points from b's centre against 45 from a's.
        for _ in 0..<20 {
            XCTAssertEqual(GridReorder.target(at: CGPoint(x: 95, y: 50),
                                              in: overlapping, excluding: "z"), "b")
        }
    }

    // MARK: - Staying under the finger

    /// The card is drawn at its slot plus the offset. When the order changes,
    /// the slot moves out from under it — and that distance has to come off the
    /// offset or the card leaps.
    func testSlotShiftIsTheDistanceTheSlotItselfTravels() {
        let shift = GridReorder.slotShift(
            from: CGRect(x: 0, y: 0, width: 100, height: 80),
            to: CGRect(x: 110, y: 90, width: 100, height: 80))
        XCTAssertEqual(shift.width, 110, accuracy: 0.0001)
        XCTAssertEqual(shift.height, 90, accuracy: 0.0001)
    }

    /// Subtracting the shift has to leave the card exactly where it was drawn,
    /// or the correction is worse than no correction.
    func testCorrectingByTheShiftLeavesTheCardVisuallyStill() {
        let slot = CGRect(x: 0, y: 90, width: 100, height: 80)
        let landing = CGRect(x: 110, y: 0, width: 100, height: 80)
        let offset = CGSize(width: 140, height: -70)
        let drawnAt = CGPoint(x: slot.midX + offset.width, y: slot.midY + offset.height)

        let shift = GridReorder.slotShift(from: slot, to: landing)
        let corrected = CGSize(width: offset.width - shift.width,
                               height: offset.height - shift.height)

        // The card now sits in `landing`, drawn with the corrected offset.
        XCTAssertEqual(landing.midX + corrected.width, drawnAt.x, accuracy: 0.0001)
        XCTAssertEqual(landing.midY + corrected.height, drawnAt.y, accuracy: 0.0001)
    }

    /// Three moves in a row, each rebasing on the last. A shift computed
    /// against the original slot every time would drift a card further from the
    /// finger with each swap.
    func testConsecutiveMovesStayPinnedToTheFinger() {
        let slots = [CGRect(x: 0, y: 0, width: 100, height: 80),
                     CGRect(x: 110, y: 0, width: 100, height: 80),
                     CGRect(x: 0, y: 90, width: 100, height: 80),
                     CGRect(x: 110, y: 90, width: 100, height: 80)]

        var home = slots[0]
        var base = CGSize.zero
        let travel = CGSize(width: 165, height: 130)   // where the finger has gone

        for landing in slots.dropFirst() {
            let shift = GridReorder.slotShift(from: home, to: landing)
            base = CGSize(width: base.width - shift.width, height: base.height - shift.height)
            home = landing

            let offset = CGSize(width: base.width + travel.width,
                                height: base.height + travel.height)
            // Drawn position must not have moved: still the original slot plus
            // however far the finger has travelled.
            XCTAssertEqual(home.midX + offset.width, slots[0].midX + travel.width,
                           accuracy: 0.0001)
            XCTAssertEqual(home.midY + offset.height, slots[0].midY + travel.height,
                           accuracy: 0.0001)
        }
    }
}

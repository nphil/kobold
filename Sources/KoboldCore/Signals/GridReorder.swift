import Foundation

/// Which slot a dragging finger is over.
///
/// Extracted from the view because it is the one part of a drag-to-reorder that
/// is not obvious and is invisible when wrong: a rule that answers "the nearest
/// card" rather than "the card under the finger" makes a grid that reorders
/// while you are still travelling between slots, and a rule with no tie-break
/// makes one that picks a different answer on different runs. Neither is
/// something a look at the screen would reliably catch.
public enum GridReorder {

    /// The card whose slot contains `point`, or `nil` when the finger is
    /// between slots.
    ///
    /// Containment rather than proximity, deliberately. On the iOS Home Screen
    /// an icon gives way once you are *on* its square, not once you are closer
    /// to it than to your own — the difference is whether a grid settles while
    /// your finger is stationary in a gap or keeps swapping as you cross one.
    ///
    /// The dragged card is excluded because its own slot travels with it, and
    /// a card that is over itself would swap with itself forever.
    public static func target(at point: CGPoint,
                              in slots: [SignalID: CGRect],
                              excluding dragged: SignalID) -> SignalID? {
        var best: (id: SignalID, distance: CGFloat)?

        for (id, frame) in slots where id != dragged {
            guard frame.contains(point) else { continue }

            // Overlapping frames should not happen in a grid, but a tie
            // resolved arbitrarily would depend on dictionary order — which
            // varies run to run and would make a reorder bug unreproducible.
            let dx = point.x - frame.midX
            let dy = point.y - frame.midY
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (id, distance)
            }
        }
        return best?.id
    }

    /// How far a card's slot travels when it moves from `slot` into `landing`.
    ///
    /// The dragged card is drawn at its slot plus an offset that follows the
    /// finger. Reordering moves the slot out from under it, so without taking
    /// this distance back off the offset the card leaps across the screen at
    /// the exact moment it should look most attached to the finger.
    ///
    /// Both frames are slots — where the layout puts a card, not where one is
    /// currently drawn. Deriving the dragged card's slot by subtracting its
    /// offset from its measured frame would work only if a `.offset` shows
    /// through to a descendant's coordinate-space query, which is not something
    /// worth betting the feel of a gesture on. The caller tracks the slot from
    /// the start of the drag instead, where the offset is known to be zero.
    public static func slotShift(from slot: CGRect, to landing: CGRect) -> CGSize {
        CGSize(width: landing.midX - slot.midX, height: landing.midY - slot.midY)
    }
}

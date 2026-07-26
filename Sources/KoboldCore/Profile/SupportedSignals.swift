import Foundation

/// Decides which requested signals this vehicle will actually answer.
///
/// Mode 01 defines `0100`, `0120`, … as bitmasks describing exactly which
/// standard PIDs a vehicle supports, and the reply to `0100` is already in hand
/// after protocol negotiation. Polling a PID the car has told you it does not
/// implement costs a full round trip and returns `NO DATA` — every pass,
/// forever — which both slows sampling and buries genuine failures in noise.
///
/// Every reference OBD-II implementation asks this question on connect. This
/// one built the decoder, tested it, and then never called it.
public enum SupportedSignals {

    /// Splits requested signals into those the vehicle reports support for and
    /// those it does not.
    ///
    /// **Only Mode 01 is filtered.** The bitmasks describe standard PIDs and say
    /// nothing whatever about manufacturer-specific modes, so Mode 21/22
    /// signals pass through untouched rather than being wrongly discarded — the
    /// interesting extended PIDs on most vehicles are exactly the ones no
    /// bitmask will ever mention.
    public static func partition(
        _ definitions: [(SignalID, SignalDefinition)],
        supported: Set<UInt8>
    ) -> (supported: [(SignalID, SignalDefinition)], unsupported: [SignalID]) {

        var kept: [(SignalID, SignalDefinition)] = []
        var dropped: [SignalID] = []

        for (id, definition) in definitions {
            guard definition.mode.caseInsensitiveCompare("01") == .orderedSame else {
                kept.append((id, definition))
                continue
            }

            // A Mode 01 PID whose identifier cannot be parsed is kept rather
            // than dropped: refusing to poll a signal is a stronger claim than
            // the profile data supports, and a malformed entry is a bug to see
            // in the logs, not one to silently hide by omission.
            guard let pid = UInt8(definition.pid, radix: 16) else {
                kept.append((id, definition))
                continue
            }

            if supported.contains(pid) {
                kept.append((id, definition))
            } else {
                dropped.append(id)
            }
        }

        return (kept, dropped)
    }
}

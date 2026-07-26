import Foundation

/// A classified ELM327 response.
///
/// The strings below are documented ELM327 behaviours, not clone quirks — they
/// appear verbatim in the Elm Electronics datasheet's error appendix. A parser
/// that treats them as data rather than errors will produce nonsense readings,
/// so classification happens before any decoding.
public enum ELM327Reply: Equatable, Sendable {
    /// `OK` — command acknowledged (typical for `AT` configuration commands).
    case ok

    /// Payload lines, already stripped of protocol chatter.
    case data(lines: [String])

    /// `NO DATA` — the `AT ST` timeout expired with nothing received. Either the
    /// ECU doesn't support the PID, or a CAN filter discarded a real reply.
    case noData

    /// `SEARCHING...` — transient protocol negotiation, not an error. Callers
    /// generally keep waiting rather than failing.
    case searching

    /// `STOPPED` — an OBD operation was interrupted, almost always because the
    /// client sent a command before the `>` prompt. Treated as a client bug.
    case stopped

    /// `BUFFER FULL` — the device's 512-byte TX buffer overflowed. Reduce
    /// verbosity (`ATH0`/`ATS0`) or narrow the CAN filter.
    case bufferFull

    /// `UNABLE TO CONNECT` — no supported protocol found (often ignition off).
    case unableToConnect

    /// `CAN ERROR` / bus fault.
    case canError

    /// `?` — command not recognised. Common on clones that advertise a firmware
    /// version they don't fully implement; probe support, don't trust `AT I`.
    case unknownCommand

    /// Anything unrecognised, preserved verbatim for diagnostics.
    case unrecognised(lines: [String])

    /// Whether this reply should be retried rather than surfaced as a failure.
    public var isTransient: Bool {
        switch self {
        case .searching, .stopped: return true
        default: return false
        }
    }

    /// Whether the reply carries decodable payload.
    public var isData: Bool {
        if case .data = self { return true }
        return false
    }
}

public enum ELM327ReplyParser {

    /// Classifies a raw response.
    ///
    /// Echo suppression (`ATE0`) is part of the init sequence, but the parser
    /// defensively drops an echoed command anyway — a reset mid-session can
    /// silently re-enable echo, and a stray echo line would otherwise be
    /// mistaken for payload.
    public static func parse(_ response: RawResponse, echoOf command: String? = nil) -> ELM327Reply {
        var lines = response.lines

        if let command, let first = lines.first,
           first.caseInsensitiveCompare(command) == .orderedSame {
            lines.removeFirst()
        }

        // Protocol negotiation chatter can precede a real payload in the same
        // response, so strip it rather than returning early.
        var sawSearching = false
        lines.removeAll { line in
            let normalised = normalise(line)
            if normalised.hasPrefix("SEARCHING") {
                sawSearching = true
                return true
            }
            return false
        }

        guard !lines.isEmpty else {
            return sawSearching ? .searching : .unrecognised(lines: [])
        }

        // A control string may arrive alongside payload; check every line.
        for line in lines {
            switch normalise(line) {
            case "NO DATA": return .noData
            case "STOPPED": return .stopped
            case "BUFFER FULL": return .bufferFull
            case "UNABLE TO CONNECT": return .unableToConnect
            case "?": return .unknownCommand
            case let normalised where normalised.hasPrefix("CAN ERROR"):
                return .canError
            default: continue
            }
        }

        if lines.count == 1, normalise(lines[0]) == "OK" { return .ok }

        // Payload lines must be hex (optionally with a `N:` ISO-TP prefix).
        let payloadLines = lines.filter { isPlausiblePayload($0) }
        guard !payloadLines.isEmpty else { return .unrecognised(lines: lines) }

        return .data(lines: payloadLines)
    }

    private static func normalise(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// A payload line is hex digits, spaces, and an optional single-digit
    /// ISO-TP sequence prefix (`0:`, `1:`, …) that `ATCAF1` prepends.
    private static func isPlausiblePayload(_ line: String) -> Bool {
        var body = line.trimmingCharacters(in: .whitespaces)
        if let colonIndex = body.firstIndex(of: ":") {
            let prefix = body[body.startIndex..<colonIndex]
            guard prefix.count == 1, prefix.allSatisfy(\.isHexDigit) else { return false }
            body = String(body[body.index(after: colonIndex)...])
        }
        let stripped = body.replacingOccurrences(of: " ", with: "")
        return !stripped.isEmpty && stripped.allSatisfy(\.isHexDigit)
    }
}

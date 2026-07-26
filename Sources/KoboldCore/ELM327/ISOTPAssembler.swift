import Foundation

/// A reassembled payload from one ECU.
public struct ECUResponse: Equatable, Sendable {
    /// CAN header the reply came from (`"7E8"` = engine), or `nil` with `ATH0`.
    public let header: String?
    /// Complete payload: response mode byte, echoed PID, then data.
    public let payload: [UInt8]

    public init(header: String?, payload: [UInt8]) {
        self.header = header
        self.payload = payload
    }

    /// Response mode (`0x41` for a Mode 01 request, `0x62` for Mode 22 — the
    /// request mode plus 0x40).
    public var mode: UInt8? { payload.first }

    /// Data bytes after the mode and echoed PID.
    ///
    /// - Parameter pidByteCount: 1 for Mode 01/02, 2 for Mode 22 (`E001`), 0 for
    ///   modes that echo no PID (Mode 03 DTC replies).
    public func data(pidByteCount: Int) -> [UInt8] {
        let offset = 1 + pidByteCount
        guard payload.count > offset else { return [] }
        return Array(payload[offset...])
    }
}

public enum ISOTPError: Error, Equatable, Sendable {
    case malformedLine(String)
    case incompleteMultiFrame(expected: Int, received: Int)
}

/// Reassembles ELM327 output into per-ECU payloads.
///
/// Handles the three shapes a real adapter emits:
///
/// 1. **Headers on, single frame** — `7E8 04 41 0C 1A F8`
///    PCI `04` = 4 payload bytes. CAN frames are padded to 8 bytes, so the PCI
///    length is what truncates the padding.
/// 2. **Headers on, multi-frame** — `7E8 10 14 …` (First Frame, 12-bit total
///    length) followed by `7E8 21 …`, `7E8 22 …` (Consecutive Frames, low nibble
///    is a sequence number that wraps at 0xF).
/// 3. **`ATCAF1` pre-parsed** — the adapter resolves ISO-TP itself and prints a
///    length line then `0:`, `1:`, `2:` prefixed continuation lines.
///
/// Replies are grouped by header because multiple ECUs answer a functional
/// broadcast, and their segment numbers interleave. That interleaving is exactly
/// the documented failure case where two ECUs both reply to a multi-frame
/// request — the real fix is filtering to one ECU with `ATCRA`/`ATSH` before
/// asking, but grouping here keeps the data straight when callers don't.
public enum ISOTPAssembler {

    public static func assemble(lines: [String]) throws -> [ECUResponse] {
        guard !lines.isEmpty else { return [] }

        if lines.contains(where: hasSequencePrefix) {
            return [try assembleSequencePrefixed(lines: lines)]
        }
        return try assembleRawFrames(lines: lines)
    }

    // MARK: - ATCAF1 sequence-prefixed form

    private static func hasSequencePrefix(_ line: String) -> Bool {
        guard let colonIndex = line.firstIndex(of: ":") else { return false }
        let prefix = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
        return prefix.count == 1 && prefix.allSatisfy(\.isHexDigit)
    }

    private static func assembleSequencePrefixed(lines: [String]) throws -> ECUResponse {
        var declaredLength: Int?
        var segments: [(sequence: Int, bytes: [UInt8])] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if hasSequencePrefix(trimmed) {
                guard let colonIndex = trimmed.firstIndex(of: ":") else {
                    throw ISOTPError.malformedLine(line)
                }
                let sequenceText = trimmed[trimmed.startIndex..<colonIndex]
                    .trimmingCharacters(in: .whitespaces)
                guard let sequence = Int(sequenceText, radix: 16) else {
                    throw ISOTPError.malformedLine(line)
                }
                let body = String(trimmed[trimmed.index(after: colonIndex)...])
                guard let bytes = Hex.bytes(from: body) else {
                    throw ISOTPError.malformedLine(line)
                }
                segments.append((sequence, bytes))
            } else if let bytes = Hex.bytes(from: trimmed), bytes.count <= 2 {
                // Bare length line printed before the segments.
                declaredLength = Int(bytes.bigEndianValue)
            }
        }

        var payload = segments.sorted { $0.sequence < $1.sequence }
            .flatMap(\.bytes)

        if let declaredLength {
            guard payload.count >= declaredLength else {
                throw ISOTPError.incompleteMultiFrame(expected: declaredLength,
                                                      received: payload.count)
            }
            payload = Array(payload.prefix(declaredLength))
        }
        return ECUResponse(header: nil, payload: payload)
    }

    // MARK: - Raw CAN frame form

    private static func assembleRawFrames(lines: [String]) throws -> [ECUResponse] {
        // Preserve first-seen header order so results are deterministic.
        var order: [String] = []
        var grouped: [String: [[UInt8]]] = [:]

        for line in lines {
            let (header, bytes) = try split(line: line)
            let key = header ?? ""
            if grouped[key] == nil {
                grouped[key] = []
                order.append(key)
            }
            grouped[key]?.append(bytes)
        }

        return try order.compactMap { key in
            guard let frames = grouped[key] else { return nil }

            // With `ATH0` the adapter's CAN auto-formatting (`ATCAF1`, the
            // default) strips the ISO-TP PCI byte along with the header, so a
            // headerless line is already pure payload. Parsing its first byte as
            // a PCI would silently discard the frame — `41 0C …` would look like
            // an unknown frame type rather than a Mode 01 reply.
            let payload = key.isEmpty
                ? frames.flatMap { $0 }
                : try reassemble(frames: frames)

            guard !payload.isEmpty else { return nil }
            return ECUResponse(header: key.isEmpty ? nil : key, payload: payload)
        }
    }

    /// Splits an optional CAN header off the front of a frame line.
    ///
    /// 11-bit headers print as 3 hex chars (`7E8`), 29-bit as 8. A line with no
    /// separate header token is `ATH0` output and is all payload.
    private static func split(line: String) throws -> (header: String?, bytes: [UInt8]) {
        let tokens = line.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { throw ISOTPError.malformedLine(line) }

        if tokens.count > 1,
           tokens[0].count == 3 || tokens[0].count == 8,
           tokens[0].allSatisfy(\.isHexDigit) {
            let body = tokens.dropFirst().joined()
            guard let bytes = Hex.bytes(from: body) else {
                throw ISOTPError.malformedLine(line)
            }
            return (tokens[0].uppercased(), bytes)
        }

        guard let bytes = Hex.bytes(from: line) else {
            throw ISOTPError.malformedLine(line)
        }
        return (nil, bytes)
    }

    private static func reassemble(frames: [[UInt8]]) throws -> [UInt8] {
        guard let first = frames.first, let pci = first.first else { return [] }

        switch pci >> 4 {
        case 0x0:
            // Single frame: low nibble is the payload length; the rest is CAN padding.
            let length = Int(pci & 0x0F)
            let body = Array(first.dropFirst())
            return Array(body.prefix(length))

        case 0x1:
            // First frame: 12-bit total length spans the PCI's low nibble and the
            // following byte.
            guard first.count >= 2 else {
                throw ISOTPError.incompleteMultiFrame(expected: 0, received: first.count)
            }
            let totalLength = (Int(pci & 0x0F) << 8) | Int(first[1])
            var payload = Array(first.dropFirst(2))

            for frame in frames.dropFirst() {
                guard let framePCI = frame.first, framePCI >> 4 == 0x2 else { continue }
                payload.append(contentsOf: frame.dropFirst())
            }

            guard payload.count >= totalLength else {
                throw ISOTPError.incompleteMultiFrame(expected: totalLength,
                                                      received: payload.count)
            }
            return Array(payload.prefix(totalLength))

        default:
            // A consecutive or flow-control frame with no preceding first frame:
            // the group is unusable on its own.
            return []
        }
    }
}

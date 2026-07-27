import Foundation

public enum DecodeError: Error, Equatable, Sendable {
    case modeMismatch(expected: UInt8, actual: UInt8?)
    case pidMismatch(expected: String, actual: String)
    case payloadTooShort(needed: Int, available: Int)
    case notNumeric
}

/// Decodes an ECU payload into a physical value using a signal definition.
public enum PIDDecoder {

    /// Validates that a payload answers the expected request, then decodes it.
    ///
    /// The mode check matters: a response mode is the request mode plus 0x40
    /// (Mode 01 → 0x41, Mode 22 → 0x62). Skipping this check is how stale or
    /// mismatched replies get decoded as plausible-but-wrong readings, which is
    /// far worse than a dropped sample.
    public static func decode(_ response: ECUResponse,
                              using definition: SignalDefinition) throws -> Double {
        guard let requestMode = Hex.bytes(from: definition.mode)?.first else {
            throw DecodeError.notNumeric
        }
        let expectedMode = requestMode &+ 0x40
        guard let actualMode = response.mode, actualMode == expectedMode else {
            throw DecodeError.modeMismatch(expected: expectedMode, actual: response.mode)
        }

        let pidByteCount = definition.pidByteCount
        if pidByteCount > 0 {
            let echoed = Array(response.payload.dropFirst().prefix(pidByteCount))
            guard echoed.count == pidByteCount else {
                throw DecodeError.payloadTooShort(needed: 1 + pidByteCount,
                                                  available: response.payload.count)
            }
            let echoedText = Hex.string(from: echoed)
            guard echoedText.caseInsensitiveCompare(definition.pid) == .orderedSame else {
                throw DecodeError.pidMismatch(expected: definition.pid.uppercased(),
                                              actual: echoedText)
            }
        }

        let data = response.data(pidByteCount: pidByteCount)
        return try decode(data: data, using: definition)
    }

    /// Decodes the data section directly, skipping mode/PID validation.
    public static func decode(data: [UInt8],
                              using definition: SignalDefinition) throws -> Double {
        let end = definition.byteOffset + definition.byteCount
        guard data.count >= end else {
            throw DecodeError.payloadTooShort(needed: end, available: data.count)
        }
        let slice = Array(data[definition.byteOffset..<end])

        switch definition.conversion {
        case .linear(let linear):
            let raw = linear.signed
                ? Self.signedValue(of: slice)
                : Double(slice.bigEndianValue)
            return linear.apply(rawValue: raw)
        case .bitfield:
            return Double(slice.bigEndianValue)
        case .ascii:
            throw DecodeError.notNumeric
        }
    }

    /// Reinterprets big-endian bytes as two's complement.
    ///
    /// Width comes from the slice, so the same code covers a one-byte value and
    /// a four-byte one: anything with the top bit set is that many counts below
    /// zero rather than a very large positive number.
    static func signedValue(of slice: [UInt8]) -> Double {
        guard let first = slice.first else { return 0 }
        let magnitude = slice.bigEndianValue
        guard first & 0x80 != 0 else { return Double(magnitude) }

        let span = UInt64(1) << (UInt64(slice.count) * 8)
        return Double(magnitude) - Double(span)
    }

    /// Decodes an ASCII payload (Mode 09 VIN and calibration IDs).
    ///
    /// Some ECUs pad the front of a VIN reply with NULs or 0x01 filler bytes, so
    /// non-printable characters are dropped rather than rendered as garbage.
    public static func decodeASCII(_ response: ECUResponse, pidByteCount: Int) -> String {
        let data = response.data(pidByteCount: pidByteCount)
        let printable = data.filter { $0 >= 0x20 && $0 < 0x7F }
        return String(decoding: printable, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Decodes the "PIDs supported" bitmask replies (`0100`, `0120`, `0140`, …).
///
/// Each reply is 4 bytes = 32 bits, where the most significant bit of byte A
/// corresponds to the PID one above the requested base. Walking these is how the
/// app discovers what a car actually answers instead of probing blindly.
public enum SupportedPIDDecoder {

    public static func supportedPIDs(from data: [UInt8], base: UInt8) -> [UInt8] {
        guard data.count >= 4 else { return [] }
        let bits = Array(data.prefix(4)).bigEndianValue
        var supported: [UInt8] = []

        for index in 0..<32 where (bits >> (31 - UInt64(index))) & 1 == 1 {
            let pid = Int(base) + index + 1
            guard pid <= 0xFF else { continue }
            supported.append(UInt8(pid))
        }
        return supported
    }
}

/// Decodes Mode 03/07/0A trouble-code replies.
public enum DTCDecoder {

    /// Converts a two-byte DTC into its display form (`P0301`, `U0100`, …).
    ///
    /// The encoding packs the system into the top two bits and the first digit
    /// into the next two, with the remaining three hex digits taken literally:
    ///
    ///     bits 15-14 → P / C / B / U
    ///     bits 13-12 → first digit (0-3)
    ///     bits 11-0  → remaining three hex digits
    public static func code(from high: UInt8, _ low: UInt8) -> String {
        let systems: [Character] = ["P", "C", "B", "U"]
        let system = systems[Int(high >> 6)]
        let firstDigit = (high >> 4) & 0b11
        let remainder = (UInt16(high & 0x0F) << 8) | UInt16(low)
        return "\(system)\(firstDigit)" + String(format: "%03X", remainder)
    }

    /// Extracts all codes from a payload, dropping the `0000` padding ECUs emit
    /// to fill the frame.
    public static func codes(from data: [UInt8]) -> [String] {
        var codes: [String] = []
        var index = 0
        while index + 1 < data.count {
            let high = data[index], low = data[index + 1]
            if high != 0 || low != 0 {
                codes.append(code(from: high, low))
            }
            index += 2
        }
        return codes
    }
}

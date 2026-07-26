import Foundation

/// Hex parsing helpers for ELM327 traffic, which is ASCII hex throughout.
public enum Hex {

    /// Parses a run of hex characters into bytes, ignoring whitespace.
    ///
    /// ELM327 output may or may not contain spaces depending on `ATS0`/`ATS1`,
    /// so the parser tolerates both forms. Returns `nil` if a non-hex,
    /// non-whitespace character is present or the digit count is odd.
    public static func bytes(from string: String) -> [UInt8]? {
        var nibbles: [UInt8] = []
        nibbles.reserveCapacity(string.count)

        for character in string.unicodeScalars {
            if character == " " || character == "\t" || character == "\r" || character == "\n" {
                continue
            }
            guard let nibble = Self.nibble(character) else { return nil }
            nibbles.append(nibble)
        }

        guard nibbles.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(nibbles.count / 2)
        for index in stride(from: 0, to: nibbles.count, by: 2) {
            bytes.append(nibbles[index] << 4 | nibbles[index + 1])
        }
        return bytes
    }

    /// Formats bytes as uppercase hex, optionally space-separated.
    public static func string(from bytes: [UInt8], separator: String = "") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    private static func nibble(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": return UInt8(scalar.value - 0x30)
        case "A"..."F": return UInt8(scalar.value - 0x41 + 10)
        case "a"..."f": return UInt8(scalar.value - 0x61 + 10)
        default: return nil
        }
    }
}

extension Collection where Element == UInt8 {
    /// Big-endian unsigned integer built from the receiver's bytes.
    ///
    /// OBD-II multi-byte values are big-endian throughout (`A` is the most
    /// significant byte), e.g. RPM = `(256·A + B) / 4`.
    var bigEndianValue: UInt64 {
        reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

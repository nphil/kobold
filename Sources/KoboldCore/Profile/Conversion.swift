import Foundation

/// Converts raw bytes into a physical value.
///
/// The linear form is deliberately general:
///
///     physical = (raw + offset) · factor / divisor + postOffset
///
/// That single expression covers essentially every SAE J1979 scalar PID as well
/// as the manufacturer-extended ones, which is why the whole PID table can be
/// data rather than a function per signal:
///
/// | Signal              | factor | divisor | postOffset | bytes |
/// |---------------------|--------|---------|------------|-------|
/// | Coolant temp        | 1      | 1       | −40        | 1     |
/// | Engine RPM          | 1      | 4       | 0          | 2     |
/// | Throttle position   | 100    | 255     | 0          | 1     |
/// | Fuel trim           | 100    | 128     | −100       | 1     |
/// | Timing advance      | 1      | 2       | −64        | 1     |
/// | Module voltage      | 1      | 1000    | 0          | 2     |
/// | Oil temp (HKMC 22)  | 0.75   | 1       | −48        | 1     |
/// | TPMS pressure (HKMC)| 1      | 5       | 0          | 1     |
public enum Conversion: Sendable, Equatable {
    case linear(LinearConversion)
    /// Raw bytes interpreted as ASCII (Mode 09 VIN, calibration IDs).
    case ascii
    /// Value is a bitfield; the decoder exposes the raw integer for callers to
    /// interpret (readiness monitors, status flags).
    case bitfield
}

public struct LinearConversion: Sendable, Equatable, Codable {
    public var factor: Double
    public var divisor: Double
    public var offset: Double
    public var postOffset: Double
    /// Whether the raw bytes are two's complement.
    ///
    /// A handful of readings are genuinely bipolar — evaporative system vapour
    /// pressure runs either side of atmospheric — and the standard spells those
    /// "signed" rather than giving them an offset. Read unsigned, `$FFFF`
    /// becomes +16,383 Pa instead of −0.25, which is not a small error in the
    /// wrong direction but a large one in the wrong direction.
    public var signed: Bool

    public init(factor: Double = 1,
                divisor: Double = 1,
                offset: Double = 0,
                postOffset: Double = 0,
                signed: Bool = false) {
        self.factor = factor
        self.divisor = divisor
        self.offset = offset
        self.postOffset = postOffset
        self.signed = signed
    }

    public func apply(rawValue: Double) -> Double {
        guard divisor != 0 else { return .nan }
        return (rawValue + offset) * factor / divisor + postOffset
    }
}

// MARK: - Codable

extension Conversion: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, factor, divisor, offset, postOffset, signed
    }

    private enum Kind: String, Codable {
        case linear, ascii, bitfield
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `kind` is optional so the common case stays terse in JSON: a bare
        // {factor, divisor, …} object is a linear conversion.
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .linear

        switch kind {
        case .ascii: self = .ascii
        case .bitfield: self = .bitfield
        case .linear:
            self = .linear(LinearConversion(
                factor: try container.decodeIfPresent(Double.self, forKey: .factor) ?? 1,
                divisor: try container.decodeIfPresent(Double.self, forKey: .divisor) ?? 1,
                offset: try container.decodeIfPresent(Double.self, forKey: .offset) ?? 0,
                postOffset: try container.decodeIfPresent(Double.self, forKey: .postOffset) ?? 0,
                signed: try container.decodeIfPresent(Bool.self, forKey: .signed) ?? false
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ascii:
            try container.encode(Kind.ascii, forKey: .kind)
        case .bitfield:
            try container.encode(Kind.bitfield, forKey: .kind)
        case .linear(let linear):
            try container.encode(Kind.linear, forKey: .kind)
            try container.encode(linear.factor, forKey: .factor)
            try container.encode(linear.divisor, forKey: .divisor)
            try container.encode(linear.offset, forKey: .offset)
            try container.encode(linear.postOffset, forKey: .postOffset)
            try container.encode(linear.signed, forKey: .signed)
        }
    }
}

// MARK: - Well-known conversions

public extension Conversion {
    static let temperatureCelsius = Conversion.linear(.init(postOffset: -40))
    static let engineRPM = Conversion.linear(.init(divisor: 4))
    static let percent = Conversion.linear(.init(factor: 100, divisor: 255))
    static let fuelTrim = Conversion.linear(.init(factor: 100, divisor: 128, postOffset: -100))
    static let timingAdvance = Conversion.linear(.init(divisor: 2, postOffset: -64))
    static let moduleVoltage = Conversion.linear(.init(divisor: 1000))
    static let massAirFlow = Conversion.linear(.init(divisor: 100))
    static let identity = Conversion.linear(.init())
}

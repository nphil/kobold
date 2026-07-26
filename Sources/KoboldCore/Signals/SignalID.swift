import Foundation

/// Identifies a logical vehicle signal (`rpm`, `coolantTemp`, `boost`, …).
///
/// Deliberately a string-backed value rather than a closed `enum`: vehicle
/// profiles are data, so a new profile can introduce signals the app was not
/// compiled with. Well-known IDs are exposed as static members for ergonomics
/// and compile-time safety where the app genuinely does know the signal.
public struct SignalID: Hashable, Sendable, RawRepresentable, Codable,
                        ExpressibleByStringLiteral, CustomStringConvertible,
                        Identifiable {
    public let rawValue: String

    /// The identifier is the name. Conformance exists so a signal can drive a
    /// SwiftUI `sheet(item:)` or `ForEach` without a wrapper type.
    public var id: String { rawValue }

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public extension SignalID {
    // SAE J1979 core set.
    static let engineLoad: SignalID = "engineLoad"
    static let coolantTemp: SignalID = "coolantTemp"
    static let shortTrimB1: SignalID = "shortTrimB1"
    static let longTrimB1: SignalID = "longTrimB1"
    static let map: SignalID = "map"
    static let rpm: SignalID = "rpm"
    static let speed: SignalID = "speed"
    static let timingAdvance: SignalID = "timingAdvance"
    static let intakeTemp: SignalID = "intakeTemp"
    static let maf: SignalID = "maf"
    static let throttle: SignalID = "throttle"
    static let baro: SignalID = "baro"
    static let moduleVoltage: SignalID = "moduleVoltage"
    static let ambientTemp: SignalID = "ambientTemp"

    // Common derived / extended signals.
    static let boost: SignalID = "boost"
    static let oilTemp: SignalID = "oilTemp"
    static let transFluidTemp: SignalID = "transFluidTemp"
}

/// Physical unit of a decoded value. Display conversion (e.g. kPa → psi) is a
/// presentation concern; the core always decodes to the canonical unit here.
public enum Unit: String, Codable, Sendable, CaseIterable {
    case none
    case rpm
    case kilometersPerHour = "kmh"
    case celsius = "degC"
    case percent = "pct"
    case kilopascal = "kPa"
    case volt = "V"
    case gramsPerSecond = "gps"
    case degree = "deg"
    case psi
    case liter = "L"
    case second = "s"

    /// Short suffix for display. Kept here so gauges and exports agree.
    public var symbol: String {
        switch self {
        case .none: return ""
        case .rpm: return "rpm"
        case .kilometersPerHour: return "km/h"
        case .celsius: return "°C"
        case .percent: return "%"
        case .kilopascal: return "kPa"
        case .volt: return "V"
        case .gramsPerSecond: return "g/s"
        case .degree: return "°"
        case .psi: return "psi"
        case .liter: return "L"
        case .second: return "s"
        }
    }
}

/// A decoded reading: a value in its canonical unit, with provenance.
public struct SignalSample: Sendable, Equatable {
    public let id: SignalID
    public let value: Double
    public let unit: Unit
    public let timestamp: Date

    public init(id: SignalID, value: Double, unit: Unit, timestamp: Date = Date()) {
        self.id = id
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
    }
}

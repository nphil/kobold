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
    case newtonMetre = "Nm"
    case kilometre = "km"
    case minute = "min"
    // Alternates, offered where a reading can sensibly be shown more than one
    // way. Never written into a profile — a profile states the unit the car
    // reports in, and these are a display choice on top of it.
    case bar
    case fahrenheit = "degF"
    case milesPerHour = "mph"
    case mile = "mi"
    case poundFoot = "lbft"

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
        case .newtonMetre: return "N⋅m"
        case .kilometre: return "km"
        case .minute: return "min"
        case .bar: return "bar"
        case .fahrenheit: return "°F"
        case .milesPerHour: return "mph"
        case .mile: return "mi"
        case .poundFoot: return "lb⋅ft"
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

// MARK: - Alternate units

public extension Unit {

    /// Ways this reading can sensibly be shown, the car's own unit first.
    ///
    /// Deliberately short. Every entry is a unit somebody actually asks for —
    /// boost in psi, temperature in Fahrenheit, torque in pound-feet — rather
    /// than everything a conversion table could offer. A menu of nine pressure
    /// units is not a feature.
    var alternatives: [Unit] {
        switch self {
        case .kilopascal: return [.kilopascal, .psi, .bar]
        case .psi: return [.psi, .kilopascal, .bar]
        case .celsius: return [.celsius, .fahrenheit]
        case .kilometersPerHour: return [.kilometersPerHour, .milesPerHour]
        case .kilometre: return [.kilometre, .mile]
        case .newtonMetre: return [.newtonMetre, .poundFoot]
        default: return [self]
        }
    }

    var hasAlternatives: Bool { alternatives.count > 1 }

    /// Converts a value expressed in this unit into another.
    ///
    /// Returns the value unchanged when the two are unrelated, so a stale
    /// preference — a signal that used to be a pressure and is now a percentage
    /// — degrades to showing the real number rather than a fabricated one.
    func convert(_ value: Double, to unit: Unit) -> Double {
        guard self != unit else { return value }

        switch (self, unit) {
        case (.kilopascal, .psi): return value * 0.145_037_7
        case (.kilopascal, .bar): return value / 100
        case (.psi, .kilopascal): return value / 0.145_037_7
        case (.psi, .bar): return value * 0.068_947_6
        case (.bar, .kilopascal): return value * 100
        case (.bar, .psi): return value / 0.068_947_6

        // The one conversion with an offset, and the one people get wrong.
        case (.celsius, .fahrenheit): return value * 9 / 5 + 32
        case (.fahrenheit, .celsius): return (value - 32) * 5 / 9

        case (.kilometersPerHour, .milesPerHour): return value * 0.621_371_2
        case (.milesPerHour, .kilometersPerHour): return value / 0.621_371_2
        case (.kilometre, .mile): return value * 0.621_371_2
        case (.mile, .kilometre): return value / 0.621_371_2
        case (.newtonMetre, .poundFoot): return value * 0.737_562_1
        case (.poundFoot, .newtonMetre): return value / 0.737_562_1

        default: return value
        }
    }

    /// Converts a range, keeping it ordered.
    ///
    /// Ordering matters because Fahrenheit and Celsius share a direction but a
    /// future unit might not, and an inverted `ClosedRange` is a crash rather
    /// than a wrong picture.
    func convert(_ range: ClosedRange<Double>, to unit: Unit) -> ClosedRange<Double> {
        let a = convert(range.lowerBound, to: unit)
        let b = convert(range.upperBound, to: unit)
        return Swift.min(a, b)...Swift.max(a, b)
    }

    /// Decimal places to show, given the value.
    ///
    /// Value-dependent for the unitless case on purpose: lambda is 0.98 and
    /// wants two, a count of warm-ups is 7 and wants none, and both are `.none`.
    func fractionDigits(for value: Double) -> Int {
        switch self {
        case .volt, .psi: return 1
        case .bar: return 2
        case .none: return value == value.rounded() ? 0 : 2
        default: return 0
        }
    }

    /// The value as it should appear, without its symbol.
    func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits(for: value))))
    }
}

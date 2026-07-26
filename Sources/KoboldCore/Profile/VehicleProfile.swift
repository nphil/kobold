import Foundation

/// How to request and decode one signal from one ECU.
public struct SignalDefinition: Codable, Sendable, Equatable {
    public let id: SignalID
    public let label: String
    /// Request header, e.g. `"7E0"` (engine) or `"7A0"` (TPMS on some HKMC cars).
    public let header: String
    /// Service/mode as hex, e.g. `"01"`, `"21"`, `"22"`.
    public let mode: String
    /// PID as hex — one byte for Mode 01 (`"0C"`), two for Mode 22 (`"E001"`).
    public let pid: String
    /// Byte offset into the data section (after mode + echoed PID).
    public let byteOffset: Int
    /// Number of bytes the value spans.
    public let byteCount: Int
    public let conversion: Conversion
    public let unit: Unit
    public let minimum: Double?
    public let maximum: Double?
    public let redline: Double?

    public init(id: SignalID,
                label: String,
                header: String,
                mode: String,
                pid: String,
                byteOffset: Int = 0,
                byteCount: Int = 1,
                conversion: Conversion,
                unit: Unit,
                minimum: Double? = nil,
                maximum: Double? = nil,
                redline: Double? = nil) {
        self.id = id
        self.label = label
        self.header = header
        self.mode = mode
        self.pid = pid
        self.byteOffset = byteOffset
        self.byteCount = byteCount
        self.conversion = conversion
        self.unit = unit
        self.minimum = minimum
        self.maximum = maximum
        self.redline = redline
    }

    /// Bytes the echoed PID occupies in the reply. Mode 03/07/0A echo no PID.
    public var pidByteCount: Int {
        switch mode {
        case "03", "04", "07", "0A": return 0
        default: return pid.count / 2
        }
    }

    /// The ELM327 command text, e.g. `"010C"`.
    public var command: String { mode.uppercased() + pid.uppercased() }
}

/// A signal computed from other signals rather than requested from the bus.
///
/// Deliberately a small closed set of operations rather than a general
/// expression language: the app should not ship a parser it cannot test, and
/// every real case so far is covered here. Boost is the motivating example —
/// on a speed-density (MAP-based) engine there is no boost PID, so it is always
/// manifold pressure minus barometric pressure.
public struct DerivedSignal: Codable, Sendable, Equatable {
    public enum Operation: Codable, Sendable, Equatable {
        /// `lhs − rhs`, optionally clamped at a lower bound (boost never < 0).
        case difference(lhs: SignalID, rhs: SignalID, clampLow: Double?)
        /// `source · factor`.
        case scaled(source: SignalID, factor: Double)
    }

    public let id: SignalID
    public let label: String
    public let operation: Operation
    public let unit: Unit
    public let minimum: Double?
    public let maximum: Double?
    public let redline: Double?

    public init(id: SignalID,
                label: String,
                operation: Operation,
                unit: Unit,
                minimum: Double? = nil,
                maximum: Double? = nil,
                redline: Double? = nil) {
        self.id = id
        self.label = label
        self.operation = operation
        self.unit = unit
        self.minimum = minimum
        self.maximum = maximum
        self.redline = redline
    }

    /// Signals this one reads.
    public var dependencies: [SignalID] {
        switch operation {
        case .difference(let lhs, let rhs, _): return [lhs, rhs]
        case .scaled(let source, _): return [source]
        }
    }

    public func evaluate(using values: [SignalID: Double]) -> Double? {
        switch operation {
        case .difference(let lhs, let rhs, let clampLow):
            guard let a = values[lhs], let b = values[rhs] else { return nil }
            let result = a - b
            if let clampLow { return Swift.max(clampLow, result) }
            return result
        case .scaled(let source, let factor):
            guard let value = values[source] else { return nil }
            return value * factor
        }
    }
}

/// A signal this vehicle is known *not* to expose, and why.
///
/// Recorded explicitly so the UI can be honest instead of showing a dead gauge.
/// Research turned up several of these for the reference car — the standard oil
/// temperature PID that never populates, and AWD/steering/brake data that simply
/// has no public PID and would need raw CAN sniffing.
public struct KnownAbsentSignal: Codable, Sendable, Equatable {
    public let id: SignalID
    public let reason: String

    public init(id: SignalID, reason: String) {
        self.id = id
        self.reason = reason
    }
}

public struct ECUHeader: Codable, Sendable, Equatable {
    public let transmit: String
    public let receive: String?

    public init(transmit: String, receive: String? = nil) {
        self.transmit = transmit
        self.receive = receive
    }
}

/// What a vehicle can report and how to decode it — entirely data.
///
/// A car is added by authoring one of these, not by changing code. Profiles
/// inherit the SAE J1979 baseline, so an unrecognised vehicle still shows the
/// standard signals rather than nothing.
public struct VehicleProfile: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// ID of a profile whose signals are inherited (typically the J1979 baseline).
    public let inherits: String?
    public let ecuHeaders: [String: ECUHeader]
    public let signals: [SignalDefinition]
    public let derivedSignals: [DerivedSignal]
    public let knownAbsent: [KnownAbsentSignal]

    public init(id: String,
                displayName: String,
                inherits: String? = nil,
                ecuHeaders: [String: ECUHeader] = [:],
                signals: [SignalDefinition] = [],
                derivedSignals: [DerivedSignal] = [],
                knownAbsent: [KnownAbsentSignal] = []) {
        self.id = id
        self.displayName = displayName
        self.inherits = inherits
        self.ecuHeaders = ecuHeaders
        self.signals = signals
        self.derivedSignals = derivedSignals
        self.knownAbsent = knownAbsent
    }
}

/// A profile with inheritance applied — what the app actually runs against.
public struct ResolvedProfile: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let signals: [SignalID: SignalDefinition]
    public let derivedSignals: [SignalID: DerivedSignal]
    public let knownAbsent: [SignalID: String]

    public init(id: String,
                displayName: String,
                signals: [SignalID: SignalDefinition],
                derivedSignals: [SignalID: DerivedSignal],
                knownAbsent: [SignalID: String]) {
        self.id = id
        self.displayName = displayName
        self.signals = signals
        self.derivedSignals = derivedSignals
        self.knownAbsent = knownAbsent
    }

    /// Every signal the profile can produce, requested or derived.
    public var allSignalIDs: Set<SignalID> {
        Set(signals.keys).union(derivedSignals.keys)
    }

    public func definition(for id: SignalID) -> SignalDefinition? { signals[id] }
}

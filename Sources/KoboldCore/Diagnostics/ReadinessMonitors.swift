import Foundation

/// Emissions readiness, decoded from Mode 01 PID `01` or `41`.
///
/// This is what an emissions test actually reads. Each monitor is a self-test
/// the ECU runs over a drive cycle; clearing trouble codes resets them all, and
/// a car with monitors still incomplete will fail an inspection even with no
/// faults stored. It is also the honest answer to "did that repair work" — a
/// monitor that has since run and completed is evidence, where a merely absent
/// code is not.
///
/// Deliberately not a dashboard signal. It is a set of flags read at rest, not
/// a number that moves while driving.
public struct ReadinessReport: Sendable, Equatable {

    /// A single self-test and how far it has got.
    public struct Monitor: Sendable, Equatable, Identifiable {
        public let name: String
        /// Whether this vehicle implements the test at all.
        public let supported: Bool
        /// Whether it has run to completion since codes were last cleared.
        public let complete: Bool

        public var id: String { name }
    }

    /// Whether the check-engine light is commanded on.
    public let malfunctionIndicatorOn: Bool

    /// How many emission-related trouble codes are stored.
    public let troubleCodeCount: Int

    /// True for a diesel. Changes what the last eight monitor bits mean, which
    /// is why it is decoded rather than assumed.
    public let compressionIgnition: Bool

    public let monitors: [Monitor]

    /// Monitors this vehicle implements. The rest describe equipment it does
    /// not have, and listing "Heated Catalyst: not supported" as an outstanding
    /// item would be inventing work.
    public var applicable: [Monitor] { monitors.filter(\.supported) }

    public var incomplete: [Monitor] { applicable.filter { !$0.complete } }
    public var isReadyForInspection: Bool { incomplete.isEmpty }

    /// Continuous monitors, in byte B.
    private static let continuousNames = ["Misfire", "Fuel System", "Comprehensive Components"]

    /// Bytes C and D, in bit order. The standard assigns these two meanings
    /// depending on ignition type, and reading a diesel's bits as a petrol
    /// car's would report tests it does not have.
    private static let sparkNames = [
        "Catalyst", "Heated Catalyst", "Evaporative System", "Secondary Air System",
        "A/C Refrigerant", "Oxygen Sensor", "Oxygen Sensor Heater", "EGR System",
    ]

    private static let compressionNames = [
        "NMHC Catalyst", "NOx/SCR Aftertreatment", "Reserved", "Boost Pressure",
        "Reserved", "Exhaust Gas Sensor", "PM Filter", "EGR/VVT System",
    ]

    /// Decodes the four data bytes of a Mode 01 PID `01`/`41` reply.
    ///
    /// The completion bits are inverted throughout: a set bit means *not*
    /// complete. That is the standard's choice, not a mistake, and it is the
    /// single easiest thing to get backwards — which would report a car that
    /// has finished nothing as ready for inspection.
    public init?(data: [UInt8]) {
        guard data.count >= 4 else { return nil }
        let (a, b, c, d) = (data[0], data[1], data[2], data[3])

        malfunctionIndicatorOn = a & 0x80 != 0
        troubleCodeCount = Int(a & 0x7F)
        compressionIgnition = b & 0x08 != 0

        var monitors: [Monitor] = []
        for (index, name) in Self.continuousNames.enumerated() {
            monitors.append(Monitor(name: name,
                                    supported: b & (1 << UInt8(index)) != 0,
                                    complete: b & (1 << UInt8(index + 4)) == 0))
        }

        let names = compressionIgnition ? Self.compressionNames : Self.sparkNames
        for (index, name) in names.enumerated() where name != "Reserved" {
            monitors.append(Monitor(name: name,
                                    supported: c & (1 << UInt8(index)) != 0,
                                    complete: d & (1 << UInt8(index)) == 0))
        }

        self.monitors = monitors
    }
}

/// Mode 01 values that are a state rather than a measurement.
///
/// Kept out of the signal pipeline entirely. Every reading in this app is a
/// `Double` that can be gauged, graphed and downsampled; "Closed loop, using
/// oxygen sensor feedback" is none of those things, and forcing it through as
/// the number 2 would produce a tile showing "2".
public enum StatusPID {

    /// Mode 01 PID `03`, first byte. One bit set at a time.
    public static func fuelSystemStatus(_ byte: UInt8) -> String? {
        switch byte {
        case 0: return nil  // This bank is not present.
        case 1: return "Open loop — engine not yet warm"
        case 2: return "Closed loop — using oxygen sensor"
        case 4: return "Open loop — driving conditions"
        case 8: return "Open loop — system fault"
        case 16: return "Closed loop — fault in an oxygen sensor"
        default: return String(format: "Unknown (0x%02X)", byte)
        }
    }

    /// Mode 01 PID `51`.
    public static func fuelType(_ byte: UInt8) -> String {
        let names = [
            "Not available", "Petrol", "Methanol", "Ethanol", "Diesel", "LPG",
            "CNG", "Propane", "Electric", "Bifuel petrol", "Bifuel methanol",
            "Bifuel ethanol", "Bifuel LPG", "Bifuel CNG", "Bifuel propane",
            "Bifuel electric", "Bifuel electric and combustion", "Hybrid petrol",
            "Hybrid ethanol", "Hybrid diesel", "Hybrid electric",
            "Hybrid electric and combustion", "Hybrid regenerative", "Bifuel hydrogen",
        ]
        guard Int(byte) < names.count else { return String(format: "Unknown (0x%02X)", byte) }
        return names[Int(byte)]
    }

    /// Mode 01 PID `13`. One bit per sensor location.
    ///
    /// Bit 0 is Bank 1 Sensor 1, counting up through that bank before moving to
    /// the next — sensor 1 being the one closest to the engine.
    public static func oxygenSensorsPresent(_ byte: UInt8) -> [String] {
        (0..<8).compactMap { bit in
            guard byte & (1 << UInt8(bit)) != 0 else { return nil }
            return "Bank \(bit / 4 + 1) Sensor \(bit % 4 + 1)"
        }
    }

    /// Mode 01 PID `1C`. Only the values a road car is likely to report are
    /// named; the rest are heavy-duty and regional variants.
    public static func obdStandard(_ byte: UInt8) -> String {
        switch byte {
        case 1: return "OBD-II (California ARB)"
        case 2: return "OBD (US EPA)"
        case 3: return "OBD and OBD-II"
        case 4: return "OBD-I"
        case 5: return "Not OBD compliant"
        case 6: return "EOBD (Europe)"
        case 7: return "EOBD and OBD-II"
        case 8: return "EOBD and OBD"
        case 9: return "EOBD, OBD and OBD-II"
        case 10: return "JOBD (Japan)"
        case 11: return "JOBD and OBD-II"
        case 12: return "JOBD and EOBD"
        case 13: return "JOBD, EOBD and OBD-II"
        default: return String(format: "Standard 0x%02X", byte)
        }
    }
}

/// Standard PIDs the app reads outside the signal pipeline.
///
/// These are states and flag sets, not measurements, so they are read on the
/// diagnostics screen rather than polled as gauges. They still need to be
/// counted as covered: a coverage report that lists them as missing is telling
/// someone to go and find data the app is already showing them one screen away.
public enum DiagnosticPIDs {
    public static let handled: Set<UInt8> = [
        0x01,  // Monitor status since codes cleared
        0x03,  // Fuel system status
        0x13,  // Oxygen sensors present
        0x1C,  // OBD standard conformance
        0x41,  // Monitor status this drive cycle
        0x51,  // Fuel type
    ]

    /// Where to tell someone to look.
    public static let surface = "Diagnostics"
}

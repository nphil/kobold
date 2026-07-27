import Foundation

/// Names for the standard SAE J1979 Mode 01 PIDs.
///
/// Deliberately *names only* — no scaling, no byte layout, no decoder. This
/// exists so the app can say "your car reports Boost Pressure Control and
/// Kobold cannot read it yet" instead of "your car reports PID 0x70", which
/// tells nobody anything. Turning one of these into a signal means adding a
/// real entry to a vehicle profile, with its formula, and that is a deliberate
/// act rather than something inferred from a name.
///
/// The catalogue is the standard's, not this car's. A PID appearing here says
/// nothing about whether any particular vehicle implements it — that is what
/// the supported-PID bitmask is for.
public enum StandardPIDCatalogue {

    public struct Entry: Sendable, Equatable {
        public let pid: UInt8
        public let name: String
        public let category: SignalCategory

        public init(pid: UInt8, name: String, category: SignalCategory) {
            self.pid = pid
            self.name = name
            self.category = category
        }

        /// `01` + two hex digits, as it would be sent.
        public var command: String { "01" + String(format: "%02X", pid) }
    }

    public static func entry(for pid: UInt8) -> Entry? { table[pid] }

    public static func name(for pid: UInt8) -> String {
        table[pid]?.name ?? String(format: "PID 0x%02X", pid)
    }

    /// Bank-select PIDs. They describe the catalogue rather than the car, so a
    /// capability report should not list them as missing features.
    public static let bankSelectors: Set<UInt8> = [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0]

    public static func isBankSelector(_ pid: UInt8) -> Bool { bankSelectors.contains(pid) }

    private static let table: [UInt8: Entry] = {
        var table: [UInt8: Entry] = [:]
        func add(_ pid: UInt8, _ name: String, _ category: SignalCategory) {
            table[pid] = Entry(pid: pid, name: name, category: category)
        }

        add(0x00, "Supported PIDs 01–20", .other)
        add(0x01, "Monitor Status Since Codes Cleared", .emissions)
        add(0x02, "Freeze Frame DTC", .emissions)
        add(0x03, "Fuel System Status", .fuel)
        add(0x04, "Calculated Engine Load", .engine)
        add(0x05, "Engine Coolant Temperature", .engine)
        add(0x06, "Short-Term Fuel Trim, Bank 1", .fuel)
        add(0x07, "Long-Term Fuel Trim, Bank 1", .fuel)
        add(0x08, "Short-Term Fuel Trim, Bank 2", .fuel)
        add(0x09, "Long-Term Fuel Trim, Bank 2", .fuel)
        add(0x0A, "Fuel Pressure", .fuel)
        add(0x0B, "Intake Manifold Absolute Pressure", .air)
        add(0x0C, "Engine Speed", .engine)
        add(0x0D, "Vehicle Speed", .drivetrain)
        add(0x0E, "Timing Advance", .engine)
        add(0x0F, "Intake Air Temperature", .air)
        add(0x10, "Mass Air Flow Rate", .air)
        add(0x11, "Throttle Position", .air)
        add(0x12, "Commanded Secondary Air Status", .emissions)
        add(0x13, "Oxygen Sensors Present (2 Banks)", .emissions)
        for (offset, pid) in (UInt8(0x14)...UInt8(0x1B)).enumerated() {
            add(pid, "Oxygen Sensor \(offset + 1)", .emissions)
        }
        add(0x1C, "OBD Standard Conformance", .other)
        add(0x1D, "Oxygen Sensors Present (4 Banks)", .emissions)
        add(0x1E, "Auxiliary Input Status", .other)
        add(0x1F, "Run Time Since Engine Start", .engine)

        add(0x20, "Supported PIDs 21–40", .other)
        add(0x21, "Distance Travelled With MIL On", .emissions)
        add(0x22, "Fuel Rail Pressure (Relative to Manifold)", .fuel)
        add(0x23, "Fuel Rail Gauge Pressure", .fuel)
        for (offset, pid) in (UInt8(0x24)...UInt8(0x2B)).enumerated() {
            add(pid, "Oxygen Sensor \(offset + 1) (Equivalence Ratio, Voltage)", .emissions)
        }
        add(0x2C, "Commanded EGR", .emissions)
        add(0x2D, "EGR Error", .emissions)
        add(0x2E, "Commanded Evaporative Purge", .emissions)
        add(0x2F, "Fuel Tank Level", .fuel)
        add(0x30, "Warm-ups Since Codes Cleared", .emissions)
        add(0x31, "Distance Since Codes Cleared", .emissions)
        add(0x32, "Evap System Vapour Pressure", .emissions)
        add(0x33, "Absolute Barometric Pressure", .air)
        for (offset, pid) in (UInt8(0x34)...UInt8(0x3B)).enumerated() {
            add(pid, "Oxygen Sensor \(offset + 1) (Equivalence Ratio, Current)", .emissions)
        }
        add(0x3C, "Catalyst Temperature, Bank 1 Sensor 1", .emissions)
        add(0x3D, "Catalyst Temperature, Bank 2 Sensor 1", .emissions)
        add(0x3E, "Catalyst Temperature, Bank 1 Sensor 2", .emissions)
        add(0x3F, "Catalyst Temperature, Bank 2 Sensor 2", .emissions)

        add(0x40, "Supported PIDs 41–60", .other)
        add(0x41, "Monitor Status This Drive Cycle", .emissions)
        add(0x42, "Control Module Voltage", .electrical)
        add(0x43, "Absolute Load Value", .engine)
        add(0x44, "Commanded Air-Fuel Equivalence Ratio", .fuel)
        add(0x45, "Relative Throttle Position", .air)
        add(0x46, "Ambient Air Temperature", .vehicle)
        add(0x47, "Absolute Throttle Position B", .air)
        add(0x48, "Absolute Throttle Position C", .air)
        add(0x49, "Accelerator Pedal Position D", .air)
        add(0x4A, "Accelerator Pedal Position E", .air)
        add(0x4B, "Accelerator Pedal Position F", .air)
        add(0x4C, "Commanded Throttle Actuator", .air)
        add(0x4D, "Time Run With MIL On", .emissions)
        add(0x4E, "Time Since Codes Cleared", .emissions)
        add(0x4F, "Maximum Equivalence Ratio, Sensor Voltage, Current and MAP", .other)
        add(0x50, "Maximum Air Flow Rate", .air)
        add(0x51, "Fuel Type", .fuel)
        add(0x52, "Ethanol Fuel Percentage", .fuel)
        add(0x53, "Absolute Evap System Vapour Pressure", .emissions)
        add(0x54, "Evap System Vapour Pressure", .emissions)
        add(0x55, "Short-Term Secondary O2 Trim, Banks 1 and 3", .emissions)
        add(0x56, "Long-Term Secondary O2 Trim, Banks 1 and 3", .emissions)
        add(0x57, "Short-Term Secondary O2 Trim, Banks 2 and 4", .emissions)
        add(0x58, "Long-Term Secondary O2 Trim, Banks 2 and 4", .emissions)
        add(0x59, "Fuel Rail Absolute Pressure", .fuel)
        add(0x5A, "Relative Accelerator Pedal Position", .air)
        add(0x5B, "Hybrid Battery Pack Remaining Life", .electrical)
        add(0x5C, "Engine Oil Temperature", .engine)
        add(0x5D, "Fuel Injection Timing", .fuel)
        add(0x5E, "Engine Fuel Rate", .fuel)
        add(0x5F, "Emission Requirements Designed To", .emissions)

        add(0x60, "Supported PIDs 61–80", .other)
        add(0x61, "Driver's Demand Engine Torque", .engine)
        add(0x62, "Actual Engine Torque", .engine)
        add(0x63, "Engine Reference Torque", .engine)
        add(0x64, "Engine Percent Torque Data", .engine)
        add(0x65, "Auxiliary Input/Output Supported", .other)
        add(0x66, "Mass Air Flow Sensor", .air)
        add(0x67, "Engine Coolant Temperature Sensors", .engine)
        add(0x68, "Intake Air Temperature Sensors", .air)
        add(0x69, "Commanded EGR and EGR Error", .emissions)
        add(0x6A, "Commanded Intake Air Flow Control", .air)
        add(0x6B, "Exhaust Gas Recirculation Temperature", .emissions)
        add(0x6C, "Commanded Throttle Actuator Control", .air)
        add(0x6D, "Fuel Pressure Control System", .fuel)
        add(0x6E, "Injection Pressure Control System", .fuel)
        add(0x6F, "Turbocharger Compressor Inlet Pressure", .air)
        add(0x70, "Boost Pressure Control", .air)
        add(0x71, "Variable Geometry Turbo Control", .air)
        add(0x72, "Wastegate Control", .air)
        add(0x73, "Exhaust Pressure", .emissions)
        add(0x74, "Turbocharger Speed", .air)
        add(0x75, "Turbocharger Temperature", .air)
        add(0x76, "Turbocharger Temperature", .air)
        add(0x77, "Charge Air Cooler Temperature", .air)
        add(0x78, "Exhaust Gas Temperature, Bank 1", .emissions)
        add(0x79, "Exhaust Gas Temperature, Bank 2", .emissions)
        add(0x7A, "Diesel Particulate Filter", .emissions)
        add(0x7B, "Diesel Particulate Filter", .emissions)
        add(0x7C, "Diesel Particulate Filter Temperature", .emissions)
        add(0x7D, "NOx NTE Control Area Status", .emissions)
        add(0x7E, "PM NTE Control Area Status", .emissions)
        add(0x7F, "Engine Run Time", .engine)

        add(0x80, "Supported PIDs 81–A0", .other)
        return table
    }()
}

import Foundation

/// What this car reports, set against what Kobold can read.
///
/// The question this answers is "am I missing anything". It is answerable
/// precisely, because the supported-PID bitmask is a declaration by the ECU
/// rather than something inferred from probing — so the gap between what the
/// car offers and what the app decodes is a fact, not an estimate.
public struct VehicleCapability: Sendable, Equatable {

    /// A PID the car reports and Kobold has no decoder for.
    public struct Gap: Sendable, Equatable, Identifiable {
        public let pid: UInt8
        public let name: String
        public let category: SignalCategory

        public var id: UInt8 { pid }
        public var command: String { "01" + String(format: "%02X", pid) }
    }

    /// Signals Kobold can decode and the car reports.
    public let readable: [SignalID]

    /// PIDs the car reports that Kobold cannot decode yet — the actionable list.
    public let gaps: [Gap]

    /// Signals defined for this vehicle that its ECUs did not declare. Usually
    /// a profile written optimistically, or a trim that lacks a sensor.
    public let undeclared: [SignalID]

    public var supportedCount: Int { readable.count + gaps.count }

    /// Vehicle-information readings the car publishes, from the Mode 09 bitmask.
    ///
    /// Reported separately rather than folded into the coverage fraction. Mode
    /// 09 is identity and calibration data, not sensor readings, and mixing the
    /// two would make a single number answer two unrelated questions badly.
    public private(set) var vehicleInfo: [VehicleInfo] = []

    public struct VehicleInfo: Sendable, Equatable, Identifiable {
        public let pid: UInt8
        public let name: String

        public var id: UInt8 { pid }
        public var command: String { "09" + String(format: "%02X", pid) }
    }

    /// Records what Mode 09 declared. Separate from `init` because it is a
    /// second round trip that may not happen — an adapter or car that will not
    /// answer `0900` must leave a capability report that is still valid.
    public mutating func recordVehicleInfo(reportedPIDs: Set<UInt8>) {
        vehicleInfo = reportedPIDs
            .subtracting(VehicleInfoCatalogue.structural)
            .compactMap { pid in
                guard let name = VehicleInfoCatalogue.name(for: pid) else { return nil }
                return VehicleInfo(pid: pid, name: name)
            }
            .sorted { $0.pid < $1.pid }
    }

    /// Display names for every signal named in `readable` and `undeclared`.
    ///
    /// Carried here so a report can be rendered from the capability alone. The
    /// alternative — handing the view the profile as well so it can look each
    /// one up — buys nothing and makes it possible to show `fuelRailPressure`
    /// to a person, which is exactly what this whole screen exists to avoid.
    private let names: [SignalID: String]

    public func name(for id: SignalID) -> String { names[id] ?? id.rawValue }

    public init(supported: Set<UInt8>, profile: ResolvedProfile) {
        // Only Mode 01 can be compared against the bitmask. Manufacturer modes
        // are not enumerable at all, so counting them here would make the
        // coverage figure quietly wrong in the flattering direction.
        var decodableByPID: [UInt8: SignalID] = [:]
        var mode01Signals: Set<SignalID> = []
        var names: [SignalID: String] = [:]

        for (id, definition) in profile.signals {
            names[id] = definition.label
            guard definition.mode.caseInsensitiveCompare("01") == .orderedSame,
                  let pid = UInt8(definition.pid, radix: 16)
            else { continue }
            decodableByPID[pid] = id
            mode01Signals.insert(id)
        }
        self.names = names

        // Bank selectors describe the catalogue rather than the car, and
        // listing "Supported PIDs 21–40" as a missing feature would be noise.
        let realPIDs = supported.subtracting(StandardPIDCatalogue.bankSelectors)

        readable = realPIDs
            .compactMap { decodableByPID[$0] }
            .sorted { $0.rawValue < $1.rawValue }

        gaps = realPIDs
            .filter { decodableByPID[$0] == nil }
            .map { pid in
                let entry = StandardPIDCatalogue.entry(for: pid)
                return Gap(pid: pid,
                           name: entry?.name ?? StandardPIDCatalogue.name(for: pid),
                           category: entry?.category ?? .other)
            }
            .sorted { $0.pid < $1.pid }

        undeclared = mode01Signals
            .filter { id in
                guard let definition = profile.signals[id],
                      let pid = UInt8(definition.pid, radix: 16) else { return false }
                return !realPIDs.contains(pid)
            }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Share of the car's reported PIDs that Kobold can decode, 0…1.
    ///
    /// Reported rather than hidden because it is the honest headline: a number
    /// that says "14 of 47" invites the obvious next question, and the gap list
    /// answers it.
    public var coverage: Double {
        guard supportedCount > 0 else { return 0 }
        return Double(readable.count) / Double(supportedCount)
    }

    /// Gaps grouped for display. A named type rather than a tuple because Swift
    /// has no key paths into tuple elements, and `ForEach` needs one.
    public struct CategoryGroup: Sendable, Equatable, Identifiable {
        public let category: SignalCategory
        public let gaps: [Gap]

        public var id: SignalCategory { category }
    }

    /// Gaps by category, in display order. Empty categories are dropped — a car
    /// missing nothing in a group should not advertise the group.
    public var gapsByCategory: [CategoryGroup] {
        SignalCategory.ordered.compactMap { category in
            let matching = gaps.filter { $0.category == category }
            return matching.isEmpty ? nil : CategoryGroup(category: category, gaps: matching)
        }
    }
}

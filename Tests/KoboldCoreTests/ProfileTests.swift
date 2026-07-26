import XCTest
@testable import KoboldCore

final class ProfileStoreTests: XCTestCase {

    private func makeSignal(_ id: SignalID, pid: String, mode: String = "01") -> SignalDefinition {
        SignalDefinition(id: id, label: id.rawValue, header: "7E0", mode: mode, pid: pid,
                         byteOffset: 0, byteCount: 1, conversion: .identity, unit: .none)
    }

    func testResolvesInheritedSignals() throws {
        let store = ProfileStore(profiles: [
            VehicleProfile(id: "base", displayName: "Base",
                           signals: [makeSignal(.rpm, pid: "0C"), makeSignal(.speed, pid: "0D")]),
            VehicleProfile(id: "child", displayName: "Child", inherits: "base",
                           signals: [makeSignal(.oilTemp, pid: "E001", mode: "22")])
        ])

        let resolved = try store.resolve(id: "child")
        XCTAssertEqual(resolved.allSignalIDs, [.rpm, .speed, .oilTemp])
        XCTAssertEqual(resolved.definition(for: .rpm)?.pid, "0C")
    }

    /// A descendant overriding an inherited signal is the mechanism that lets a
    /// car replace a standard PID with a manufacturer one.
    func testDescendantOverridesInheritedSignal() throws {
        let store = ProfileStore(profiles: [
            VehicleProfile(id: "base", displayName: "Base",
                           signals: [makeSignal(.oilTemp, pid: "5C")]),
            VehicleProfile(id: "child", displayName: "Child", inherits: "base",
                           signals: [makeSignal(.oilTemp, pid: "E001", mode: "22")])
        ])

        let resolved = try store.resolve(id: "child")
        XCTAssertEqual(resolved.definition(for: .oilTemp)?.pid, "E001")
        XCTAssertEqual(resolved.definition(for: .oilTemp)?.mode, "22")
    }

    /// Marking a signal absent must make it unrequestable, so the UI never shows
    /// a gauge the car cannot feed.
    func testKnownAbsentRemovesInheritedSignal() throws {
        let store = ProfileStore(profiles: [
            VehicleProfile(id: "base", displayName: "Base",
                           signals: [makeSignal(.maf, pid: "10"), makeSignal(.rpm, pid: "0C")]),
            VehicleProfile(id: "child", displayName: "Child", inherits: "base",
                           knownAbsent: [KnownAbsentSignal(id: .maf, reason: "speed-density engine")])
        ])

        let resolved = try store.resolve(id: "child")
        XCTAssertNil(resolved.definition(for: .maf))
        XCTAssertNotNil(resolved.definition(for: .rpm))
        XCTAssertEqual(resolved.knownAbsent[.maf], "speed-density engine")
    }

    func testMultiLevelInheritanceAppliesOldestFirst() throws {
        let store = ProfileStore(profiles: [
            VehicleProfile(id: "a", displayName: "A", signals: [makeSignal(.rpm, pid: "00")]),
            VehicleProfile(id: "b", displayName: "B", inherits: "a",
                           signals: [makeSignal(.rpm, pid: "11")]),
            VehicleProfile(id: "c", displayName: "C", inherits: "b",
                           signals: [makeSignal(.rpm, pid: "22")])
        ])
        XCTAssertEqual(try store.resolve(id: "c").definition(for: .rpm)?.pid, "22")
    }

    func testUnknownProfileThrows() {
        let store = ProfileStore(profiles: [])
        XCTAssertThrowsError(try store.resolve(id: "nope")) { error in
            XCTAssertEqual(error as? ProfileError, .unknownProfile("nope"))
        }
    }

    func testMissingParentThrows() {
        let store = ProfileStore(profiles: [
            VehicleProfile(id: "child", displayName: "Child", inherits: "ghost")
        ])
        XCTAssertThrowsError(try store.resolve(id: "child")) { error in
            XCTAssertEqual(error as? ProfileError, .unknownProfile("ghost"))
        }
    }

    func testInheritanceCycleIsDetected() {
        let store = ProfileStore(profiles: [
            VehicleProfile(id: "a", displayName: "A", inherits: "b"),
            VehicleProfile(id: "b", displayName: "B", inherits: "a")
        ])
        XCTAssertThrowsError(try store.resolve(id: "a")) { error in
            guard case ProfileError.inheritanceCycle = error else {
                return XCTFail("expected inheritanceCycle, got \(error)")
            }
        }
    }
}

final class DerivedSignalTests: XCTestCase {

    private let boost = DerivedSignal(
        id: .boost, label: "Boost",
        operation: .difference(lhs: .map, rhs: .baro, clampLow: 0),
        unit: .kilopascal
    )

    /// On a speed-density engine there is no boost PID; it is always manifold
    /// pressure minus barometric pressure.
    func testBoostUnderLoad() {
        let value = boost.evaluate(using: [.map: 180, .baro: 101])
        XCTAssertEqual(value, 79)
    }

    /// At idle the manifold is in vacuum, so the raw difference is negative.
    /// Clamping keeps the gauge at zero instead of showing negative boost.
    func testBoostClampsAtIdle() {
        XCTAssertEqual(boost.evaluate(using: [.map: 34, .baro: 101]), 0)
    }

    func testMissingDependencyYieldsNil() {
        XCTAssertNil(boost.evaluate(using: [.map: 180]))
    }

    func testDependenciesAreReported() {
        XCTAssertEqual(Set(boost.dependencies), [.map, .baro])
    }

    func testScaledOperation() {
        let kpaToPSI = DerivedSignal(id: "boostPSI", label: "Boost (psi)",
                                     operation: .scaled(source: .boost, factor: 0.145038),
                                     unit: .psi)
        let value = kpaToPSI.evaluate(using: [.boost: 100])
        XCTAssertEqual(try XCTUnwrap(value), 14.5038, accuracy: 0.0001)
    }
}

final class BundledCatalogueTests: XCTestCase {

    func testCatalogueLoadsAndResolves() throws {
        let store = try ProfileStore.bundled()
        XCTAssertNotNil(store.profile(id: ProfileStore.baselineID))

        let baseline = try store.resolveBaseline()
        XCTAssertNotNil(baseline.definition(for: .rpm))
        XCTAssertNotNil(baseline.definition(for: .coolantTemp))
    }

    func testBaselineFormulasSurviveTheJSONRoundTrip() throws {
        let baseline = try ProfileStore.bundled().resolveBaseline()

        let rpm = try XCTUnwrap(baseline.definition(for: .rpm))
        XCTAssertEqual(try PIDDecoder.decode(data: [0x0B, 0xB8], using: rpm), 750, accuracy: 0.001)

        let coolant = try XCTUnwrap(baseline.definition(for: .coolantTemp))
        XCTAssertEqual(try PIDDecoder.decode(data: [0x5A], using: coolant), 50, accuracy: 0.001)

        let voltage = try XCTUnwrap(baseline.definition(for: .moduleVoltage))
        XCTAssertEqual(try PIDDecoder.decode(data: [0x39, 0xD0], using: voltage), 14.8, accuracy: 0.001)
    }

    /// The reference vehicle is data, not code: it should resolve to the standard
    /// signals plus its manufacturer additions, minus what it genuinely can't report.
    func testReferenceVehicleResolvesAsData() throws {
        let store = try ProfileStore.bundled()
        let profile = try store.resolve(id: "genesis-g70-2020-2.0t-awd")

        // Inherited baseline signals.
        XCTAssertNotNil(profile.definition(for: .rpm))
        XCTAssertNotNil(profile.definition(for: .coolantTemp))

        // Manufacturer-extended signals, reached over Mode 22 / Mode 21.
        let oilTemp = try XCTUnwrap(profile.definition(for: .oilTemp))
        XCTAssertEqual(oilTemp.mode, "22")
        XCTAssertEqual(oilTemp.pid, "E001")
        XCTAssertEqual(try PIDDecoder.decode(data: [0x78], using: oilTemp), 42, accuracy: 0.001)

        let trans = try XCTUnwrap(profile.definition(for: .transFluidTemp))
        XCTAssertEqual(trans.header, "7E1")
        XCTAssertEqual(trans.mode, "21")

        // Boost is derived because this engine exposes no boost PID.
        let boost = try XCTUnwrap(profile.derivedSignals[.boost])
        XCTAssertEqual(boost.evaluate(using: [.map: 180, .baro: 101]), 79)

        // MAF is marked absent on this speed-density engine, so it must not be
        // requestable even though the baseline defines it.
        XCTAssertNil(profile.definition(for: .maf))
        XCTAssertNotNil(profile.knownAbsent[.maf])

        // Signals with no public PID are recorded with a reason rather than
        // silently missing.
        XCTAssertNotNil(profile.knownAbsent["htracClutchDuty"])
        XCTAssertNotNil(profile.knownAbsent["steeringAngle"])
    }

    func testProfileRoundTripsThroughJSON() throws {
        let store = try ProfileStore.bundled()
        let original = try XCTUnwrap(store.profile(id: "genesis-g70-2020-2.0t-awd"))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VehicleProfile.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}

/// Polling a PID the vehicle has said it does not implement costs a round trip
/// and returns NO DATA on every pass, forever.
final class SupportedSignalsTests: XCTestCase {

    private func mode01(_ id: String, pid: String) -> (SignalID, SignalDefinition) {
        (SignalID(id), SignalDefinition(id: SignalID(id), label: id, header: "7E0",
                                        mode: "01", pid: pid, byteOffset: 0, byteCount: 1,
                                        conversion: .identity, unit: .none,
                                        minimum: nil, maximum: nil, redline: nil))
    }

    private func mode22(_ id: String, pid: String) -> (SignalID, SignalDefinition) {
        (SignalID(id), SignalDefinition(id: SignalID(id), label: id, header: "7E0",
                                        mode: "22", pid: pid, byteOffset: 0, byteCount: 1,
                                        conversion: .identity, unit: .none,
                                        minimum: nil, maximum: nil, redline: nil))
    }

    func testKeepsOnlySupportedMode01PIDs() {
        let split = SupportedSignals.partition(
            [mode01("rpm", pid: "0C"), mode01("speed", pid: "0D"), mode01("oilTemp", pid: "5C")],
            supported: [0x0C, 0x0D]
        )

        XCTAssertEqual(split.supported.map(\.0.rawValue), ["rpm", "speed"])
        XCTAssertEqual(split.unsupported.map(\.rawValue), ["oilTemp"])
    }

    /// The bitmasks describe standard PIDs only. Manufacturer modes are exactly
    /// the interesting ones and no bitmask will ever mention them, so filtering
    /// them out would silently delete the extended signals a profile exists for.
    func testManufacturerModesArePassedThroughUnfiltered() {
        let split = SupportedSignals.partition(
            [mode22("clutchTemp", pid: "E001"), mode01("rpm", pid: "0C")],
            supported: [0x0C]
        )

        XCTAssertEqual(split.supported.map(\.0.rawValue).sorted(), ["clutchTemp", "rpm"])
        XCTAssertTrue(split.unsupported.isEmpty)
    }

    /// A malformed PID is a bug worth seeing, not one to hide by quietly
    /// declining to poll the signal.
    func testUnparseablePIDIsKeptRatherThanDropped() {
        let split = SupportedSignals.partition(
            [mode01("broken", pid: "ZZ")],
            supported: [0x0C]
        )

        XCTAssertEqual(split.supported.map(\.0.rawValue), ["broken"])
        XCTAssertTrue(split.unsupported.isEmpty)
    }

    func testEmptySupportedSetDropsEveryMode01Signal() {
        let split = SupportedSignals.partition(
            [mode01("rpm", pid: "0C"), mode22("ext", pid: "E001")],
            supported: []
        )

        // The caller treats this as implausible and falls back; the partition
        // itself just reports what the bitmask said.
        XCTAssertEqual(split.supported.map(\.0.rawValue), ["ext"])
        XCTAssertEqual(split.unsupported.map(\.rawValue), ["rpm"])
    }
}

/// Fuel-system signals, added to chase an extended-crank-after-sitting fault on
/// the reference car.
///
/// The hypothesis they exist to test is fuel rail pressure bleeding down while
/// the car sits: a healthy direct-injection rail holds pressure, a leaking pump
/// check valve or seeping injector does not, and the engine cannot fire until
/// the high-pressure pump rebuilds it. That is a number, so it is worth
/// measuring rather than guessing at.
///
/// These are SAE J1979 standard PIDs rather than anything vehicle-specific, and
/// the supported-PID bitmask decides which the car actually answers — so one it
/// does not implement is dropped at connect and named in the log, not polled
/// forever for NO DATA.
final class FuelSystemSignalTests: XCTestCase {

    private func g70() throws -> ResolvedProfile {
        try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
    }

    func testFuelSignalsResolveOnTheReferenceCar() throws {
        let profile = try g70()
        for id: SignalID in ["fuelRailPressureDirect", "fuelRailPressureRelative",
                             "fuelPressure", "fuelLevel", "runTime"] {
            XCTAssertNotNil(profile.definition(for: id), "\(id.rawValue) should resolve")
        }
    }

    func testCommandsAreWellFormed() throws {
        let profile = try g70()
        XCTAssertEqual(profile.definition(for: "fuelRailPressureDirect")?.command, "0123")
        XCTAssertEqual(profile.definition(for: "fuelRailPressureRelative")?.command, "0122")
        XCTAssertEqual(profile.definition(for: "fuelPressure")?.command, "010A")
        XCTAssertEqual(profile.definition(for: "fuelLevel")?.command, "012F")
        XCTAssertEqual(profile.definition(for: "runTime")?.command, "011F")
    }

    /// PID 23 is two bytes scaled by 10 kPa — the direct-injection rail, which
    /// runs in the hundreds of bar rather than the single digits a port-injected
    /// engine shows.
    func testDirectRailPressureScaling() throws {
        let definition = try XCTUnwrap(try g70().definition(for: "fuelRailPressureDirect"))

        // 0x0BB8 = 3000 → 30 000 kPa = 300 bar, a plausible loaded GDI rail.
        XCTAssertEqual(try PIDDecoder.decode(data: [0x0B, 0xB8], using: definition), 30_000, accuracy: 0.001)
        // The reading the bleed-down hypothesis predicts at key-on after a sit.
        XCTAssertEqual(try PIDDecoder.decode(data: [0x00, 0x00], using: definition), 0, accuracy: 0.001)
    }

    func testRelativeRailPressureScaling() throws {
        let definition = try XCTUnwrap(try g70().definition(for: "fuelRailPressureRelative"))
        // 0.079 kPa per bit.
        XCTAssertEqual(try PIDDecoder.decode(data: [0x27, 0x10], using: definition), 790, accuracy: 0.01)
    }

    func testFuelLevelIsAPercentage() throws {
        let definition = try XCTUnwrap(try g70().definition(for: "fuelLevel"))
        XCTAssertEqual(try PIDDecoder.decode(data: [0xFF], using: definition), 100, accuracy: 0.01)
        XCTAssertEqual(try PIDDecoder.decode(data: [0x80], using: definition), 50.196, accuracy: 0.01)
    }

    func testRunTimeIsSecondsUnscaled() throws {
        let definition = try XCTUnwrap(try g70().definition(for: "runTime"))
        XCTAssertEqual(try PIDDecoder.decode(data: [0x01, 0x2C], using: definition), 300, accuracy: 0.001)
    }
}

/// Names and summaries are content, and content rots quietly.
///
/// Every signal a user can be offered needs a label they can read and, where
/// there is anything worth saying, a sentence explaining it. As the catalogue
/// grows from 14 PIDs toward the ~80 the standard defines, the failure mode is
/// a new entry shipping with a camelCase identifier where its name should be —
/// which is invisible in review and obvious in the picker.
// SignalBus and LiveSignal are main-actor isolated, so the whole case is —
// matching how SignalBusTests is written rather than annotating one method,
// which the Linux test discovery cannot call.
@MainActor
final class SignalPresentationTests: XCTestCase {

    private func allDefinitions() throws -> [(SignalID, String, String?)] {
        let store = try ProfileStore.bundled()
        let profile = try store.resolve(id: "genesis-g70-2020-2.0t-awd")
        return profile.signals.map { ($0.key, $0.value.label, $0.value.summary) }
            + profile.derivedSignals.map { ($0.key, $0.value.label, $0.value.summary) }
    }

    func testEverySignalHasAHumanLabel() async throws {
        for (id, label, _) in try allDefinitions() {
            XCTAssertFalse(label.isEmpty, "\(id.rawValue) has no label")
            XCTAssertNotEqual(label, id.rawValue,
                              "\(id.rawValue) is showing its identifier as its name")
            // An identifier that leaked would be camelCase with no spaces.
            XCTAssertTrue(label.contains(" ") || label.count <= 12,
                          "\(id.rawValue) label \"\(label)\" looks like an identifier")
            XCTAssertTrue(label.first?.isUppercase ?? false,
                          "\(id.rawValue) label should be title case")
        }
    }

    /// A summary is optional by design — a name that explains itself does not
    /// need a sentence repeating it — but one that exists has to earn its space.
    func testSummariesThatExistAreSubstantive() async throws {
        for (id, _, summary) in try allDefinitions() {
            guard let summary else { continue }
            XCTAssertGreaterThan(summary.count, 20, "\(id.rawValue) summary is too terse to help")
            XCTAssertTrue(summary.hasSuffix("."), "\(id.rawValue) summary should be a sentence")
        }
    }

    /// The signals whose names genuinely do not tell a driver what they are.
    /// These are the ones the summary exists for, so their absence is a bug
    /// rather than a judgement call.
    func testTheJargonSignalsAreExplained() async throws {
        let mustExplain: Set<SignalID> = [
            "shortTrimB1", "longTrimB1", "map", "baro", "engineLoad",
            "timingAdvance", "fuelRailPressureDirect", "fuelRailPressureRelative",
            "boost", "maf",
        ]

        // Intersected with what this car actually has: `maf` is marked
        // known-absent on a speed-density engine, so it is legitimately not in
        // the resolved profile and cannot carry a summary there.
        let definitions = try allDefinitions()
        let present = Set(definitions.map(\.0))
        let explained = Set(definitions.filter { $0.2 != nil }.map(\.0))

        for id in mustExplain.intersection(present) where !explained.contains(id) {
            XCTFail("\(id.rawValue) is jargon and needs a summary")
        }
    }

    /// The summary should add to the name rather than restate it.
    func testSummariesAreNotJustTheLabelAgain() async throws {
        for (id, label, summary) in try allDefinitions() {
            guard let summary else { continue }
            XCTAssertNotEqual(summary.lowercased(), label.lowercased() + ".",
                              "\(id.rawValue) summary just repeats its label")
        }
    }

    func testSummarySurvivesOntoTheLiveSignal() async throws {
        let profile = try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
        let bus = SignalBus(profile: profile)

        let rail = try XCTUnwrap(bus.signal("fuelRailPressureDirect"))
        XCTAssertEqual(rail.label, "Fuel Rail Pressure")
        XCTAssertNotNil(rail.summary, "the picker reads this off the live signal")

        // Derived signals are offered in the picker too and need the same care.
        let boost = try XCTUnwrap(bus.signal(.boost))
        XCTAssertNotNil(boost.summary)
    }
}

/// Grouping is what keeps the picker usable as the catalogue grows.
final class SignalCategoryTests: XCTestCase {

    func testDisplayOrderIsTotalAndStable() {
        let ordered = SignalCategory.ordered
        XCTAssertEqual(ordered.count, SignalCategory.allCases.count,
                       "every category must have a place in the order")
        XCTAssertEqual(Set(ordered.map(\.displayOrder)).count, ordered.count,
                       "two categories sharing an order sort arbitrarily")
        XCTAssertEqual(ordered.first, .engine, "engine is what most questions are about")
        XCTAssertEqual(ordered.last, .other, "the residue sorts last")
    }

    func testEveryCategoryHasAName() {
        for category in SignalCategory.allCases {
            XCTAssertFalse(category.label.isEmpty)
            XCTAssertFalse(category.symbolName.isEmpty)
            XCTAssertNotEqual(category.label, category.rawValue,
                              "\(category.rawValue) is showing its raw value")
        }
    }

    /// A signal with no category lands in "Other", which is a visible defect in
    /// the picker rather than a crash — so it is worth failing the build over.
    func testEveryShippedSignalIsCategorised() throws {
        let profile = try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")

        for (id, definition) in profile.signals {
            XCTAssertNotEqual(definition.category, .other,
                              "\(id.rawValue) has no category and would land in Other")
        }
        for (id, definition) in profile.derivedSignals {
            XCTAssertNotEqual(definition.category, .other,
                              "\(id.rawValue) has no category and would land in Other")
        }
    }

    func testCategoriesAreReadFromTheNaturalJSONKey() throws {
        let profile = try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")

        XCTAssertEqual(profile.definition(for: .rpm)?.category, .engine)
        XCTAssertEqual(profile.definition(for: .map)?.category, .air)
        XCTAssertEqual(profile.definition(for: "fuelRailPressureDirect")?.category, .fuel)
        XCTAssertEqual(profile.definition(for: .speed)?.category, .drivetrain)
        XCTAssertEqual(profile.definition(for: .moduleVoltage)?.category, .electrical)
        // Derived signals are offered in the picker too and need grouping.
        XCTAssertEqual(profile.derivedSignals[.boost]?.category, .air)
    }

    /// A profile written before the field existed must still load.
    func testMissingCategoryDecodesAsOtherRatherThanFailing() throws {
        let json = """
        {"id":"legacy","label":"Legacy Signal","header":"7E0","mode":"01","pid":"0C",
         "byteOffset":0,"byteCount":2,"conversion":{"divisor":4},"unit":"rpm"}
        """
        let definition = try JSONDecoder().decode(SignalDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(definition.category, .other)
        XCTAssertNil(definition.summary)
    }

    func testCategoryRoundTripsThroughJSON() throws {
        let original = SignalDefinition(id: "x", label: "X", header: "7E0", mode: "01", pid: "0C",
                                        conversion: .identity, unit: .rpm,
                                        summary: "A test signal for round tripping.",
                                        category: .drivetrain)
        let restored = try JSONDecoder().decode(SignalDefinition.self,
                                                from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.category, .drivetrain)
        XCTAssertEqual(restored.summary, original.summary)
    }
}

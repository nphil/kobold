import XCTest
@testable import KoboldCore

/// Narrowing a profile to what a car actually reports.
///
/// The point of these is that a signal the vehicle has disclaimed must not
/// merely go unpolled — it must stop existing as far as the rest of the app is
/// concerned, because every surface builds its list from the profile.
final class RestrictedProfileTests: XCTestCase {

    private func profile() throws -> ResolvedProfile {
        try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
    }

    func testDropsMode01SignalsTheCarDidNotReport() throws {
        let full = try profile()
        // 0C rpm and 05 coolant only.
        let narrowed = full.restricted(toReportedPIDs: [0x0C, 0x05])

        XCTAssertNotNil(narrowed.signals[.rpm])
        XCTAssertNotNil(narrowed.signals[.coolantTemp])
        XCTAssertNil(narrowed.signals[.speed], "0D was not reported")
        XCTAssertNil(narrowed.signals["fuelLevel"], "2F was not reported")
    }

    /// The bitmask enumerates standard PIDs and nothing else, so silence about a
    /// manufacturer-mode signal is not a "no". Dropping these would delete the
    /// most interesting readings on the car.
    func testKeepsSignalsOutsideModeOne() throws {
        let full = try profile()
        let narrowed = full.restricted(toReportedPIDs: [0x0C])

        XCTAssertNotNil(full.signals["oilTemp"], "precondition: the profile defines it")
        XCTAssertNotNil(narrowed.signals["oilTemp"], "Mode 22 is not enumerable by bitmask")
        XCTAssertNotNil(narrowed.signals["transFluidTemp"], "Mode 21 is not enumerable either")
    }

    /// Boost is manifold pressure minus barometric. With either input missing it
    /// would be a number with nothing behind it, which is worse than an absence.
    func testDropsDerivedSignalsWhoseInputsAreGone() throws {
        let full = try profile()
        XCTAssertNotNil(full.derivedSignals["boost"], "precondition")

        // 0B manifold pressure present, 33 barometric absent.
        let narrowed = full.restricted(toReportedPIDs: [0x0B, 0x0C])
        XCTAssertNil(narrowed.derivedSignals["boost"])
        XCTAssertNotNil(narrowed.knownAbsent["boost"], "and it says why")
    }

    func testKeepsDerivedSignalsWhoseInputsSurvive() throws {
        let narrowed = try profile().restricted(toReportedPIDs: [0x0B, 0x33])
        XCTAssertNotNil(narrowed.derivedSignals["boost"])
    }

    /// A dropped signal must be recorded, not merely missing: "why is boost
    /// gone" needs an answer, and `knownAbsent` already means exactly this.
    func testDroppedSignalsAreRecordedWithAReason() throws {
        let narrowed = try profile().restricted(toReportedPIDs: [0x0C])

        let reason = try XCTUnwrap(narrowed.knownAbsent[.speed])
        XCTAssertTrue(reason.contains("010D"), "names the command it asked about: \(reason)")
    }

    /// Absences the profile already declared must survive narrowing — they are
    /// a stronger statement than the bitmask, not a weaker one.
    func testPreExistingAbsencesAreKept() throws {
        let full = try profile()
        XCTAssertNotNil(full.knownAbsent["maf"], "precondition: speed-density engine")

        let narrowed = full.restricted(toReportedPIDs: [0x0C, 0x10])
        XCTAssertNil(narrowed.signals["maf"], "declared absent outranks the bitmask")
        XCTAssertNotNil(narrowed.knownAbsent["maf"])
    }

    /// Refusing to show a signal is a stronger claim than malformed profile data
    /// supports, so an unparseable PID is kept rather than silently hidden.
    func testKeepsSignalsWithAnUnparseablePID() throws {
        let odd = SignalDefinition(id: "odd", label: "Odd", header: "7E0", mode: "01",
                                   pid: "ZZ", byteOffset: 0, byteCount: 1,
                                   conversion: .linear(LinearConversion()), unit: .none)
        let source = ResolvedProfile(id: "t", displayName: "T",
                                     signals: ["odd": odd],
                                     derivedSignals: [:], knownAbsent: [:])

        XCTAssertNotNil(source.restricted(toReportedPIDs: []).signals["odd"])
    }

    func testNarrowingToEverythingChangesNothing() throws {
        let full = try profile()
        let everyPID = Set(full.signals.values.compactMap { UInt8($0.pid, radix: 16) })

        let narrowed = full.restricted(toReportedPIDs: everyPID)
        XCTAssertEqual(narrowed.allSignalIDs, full.allSignalIDs)
    }
}

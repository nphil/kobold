import XCTest
@testable import KoboldCore

/// Emissions readiness decoding.
///
/// The completion bits are inverted — a set bit means *not* complete — which is
/// the single easiest thing here to get backwards, and getting it backwards
/// reports a car that has finished nothing as ready for inspection.
final class ReadinessTests: XCTestCase {

    /// The worked example from the SAE text: bytes 86 33 FF 63, described there
    /// as "MIL: ON; Number of emission-related DTCs: 06".
    func testMatchesTheSpecsOwnWorkedExample() throws {
        let report = try XCTUnwrap(ReadinessReport(data: [0x86, 0x33, 0xFF, 0x63]))

        XCTAssertTrue(report.malfunctionIndicatorOn)
        XCTAssertEqual(report.troubleCodeCount, 6)
        XCTAssertFalse(report.compressionIgnition, "0x33 bit 3 is clear — spark ignition")
    }

    func testReadsTheLightAndCodeCountApart() throws {
        // No light, three codes.
        let report = try XCTUnwrap(ReadinessReport(data: [0x03, 0x00, 0x00, 0x00]))
        XCTAssertFalse(report.malfunctionIndicatorOn)
        XCTAssertEqual(report.troubleCodeCount, 3)

        // Light on, no codes — the count is the low seven bits, not the byte.
        let lit = try XCTUnwrap(ReadinessReport(data: [0x80, 0x00, 0x00, 0x00]))
        XCTAssertTrue(lit.malfunctionIndicatorOn)
        XCTAssertEqual(lit.troubleCodeCount, 0)
    }

    /// A set completion bit means not complete. This is the inversion.
    func testCompletionBitsAreInverted() throws {
        // Byte C: catalyst supported. Byte D: catalyst bit set = not complete.
        let pending = try XCTUnwrap(ReadinessReport(data: [0x00, 0x00, 0x01, 0x01]))
        let catalyst = try XCTUnwrap(pending.monitors.first { $0.name == "Catalyst" })
        XCTAssertTrue(catalyst.supported)
        XCTAssertFalse(catalyst.complete)
        XCTAssertFalse(pending.isReadyForInspection)

        // Same, with the completion bit clear.
        let done = try XCTUnwrap(ReadinessReport(data: [0x00, 0x00, 0x01, 0x00]))
        XCTAssertTrue(try XCTUnwrap(done.monitors.first { $0.name == "Catalyst" }).complete)
        XCTAssertTrue(done.isReadyForInspection)
    }

    /// An unsupported monitor is not outstanding work. Listing "Heated
    /// Catalyst: not complete" on a car that has no heated catalyst would send
    /// someone driving cycles that can never finish.
    func testUnsupportedMonitorsAreNotCountedAsIncomplete() throws {
        // Nothing supported, every completion bit set.
        let report = try XCTUnwrap(ReadinessReport(data: [0x00, 0x00, 0x00, 0xFF]))

        XCTAssertTrue(report.applicable.isEmpty)
        XCTAssertTrue(report.incomplete.isEmpty)
        XCTAssertTrue(report.isReadyForInspection)
    }

    func testContinuousMonitorsComeFromByteB() throws {
        // Misfire and fuel system supported; misfire incomplete (bit 4).
        let report = try XCTUnwrap(ReadinessReport(data: [0x00, 0x13, 0x00, 0x00]))

        let misfire = try XCTUnwrap(report.monitors.first { $0.name == "Misfire" })
        XCTAssertTrue(misfire.supported)
        XCTAssertFalse(misfire.complete)

        let fuel = try XCTUnwrap(report.monitors.first { $0.name == "Fuel System" })
        XCTAssertTrue(fuel.supported)
        XCTAssertTrue(fuel.complete)
    }

    /// Bytes C and D mean different tests on a diesel. Reading one as the other
    /// reports equipment the car does not have.
    func testDieselMonitorsAreNamedDifferently() throws {
        let spark = try XCTUnwrap(ReadinessReport(data: [0x00, 0x00, 0xFF, 0x00]))
        XCTAssertTrue(spark.monitors.contains { $0.name == "Evaporative System" })
        XCTAssertFalse(spark.monitors.contains { $0.name == "PM Filter" })

        // Bit 3 of byte B marks compression ignition.
        let diesel = try XCTUnwrap(ReadinessReport(data: [0x00, 0x08, 0xFF, 0x00]))
        XCTAssertTrue(diesel.compressionIgnition)
        XCTAssertTrue(diesel.monitors.contains { $0.name == "PM Filter" })
        XCTAssertFalse(diesel.monitors.contains { $0.name == "Evaporative System" })
    }

    func testShortPayloadDecodesToNothing() {
        XCTAssertNil(ReadinessReport(data: [0x00, 0x00, 0x00]))
    }
}

final class StatusPIDTests: XCTestCase {

    func testFuelSystemStatusNamesEachState() {
        XCTAssertEqual(StatusPID.fuelSystemStatus(2), "Closed loop — using oxygen sensor")
        XCTAssertEqual(StatusPID.fuelSystemStatus(1), "Open loop — engine not yet warm")
        XCTAssertEqual(StatusPID.fuelSystemStatus(8), "Open loop — system fault")
    }

    /// Zero means "this bank does not exist", which is not a state to display.
    func testAbsentBankIsNothingRatherThanAState() {
        XCTAssertNil(StatusPID.fuelSystemStatus(0))
    }

    func testFuelTypeAndStandardAreNamed() {
        XCTAssertEqual(StatusPID.fuelType(1), "Petrol")
        XCTAssertEqual(StatusPID.fuelType(4), "Diesel")
        XCTAssertEqual(StatusPID.obdStandard(6), "EOBD (Europe)")
        XCTAssertEqual(StatusPID.obdStandard(1), "OBD-II (California ARB)")
    }

    /// An unknown value renders as its number rather than a blank or a wrong
    /// guess — the same rule the PID catalogue follows.
    func testUnknownValuesStillRenderAsSomething() {
        XCTAssertEqual(StatusPID.fuelType(0xEE), "Unknown (0xEE)")
        XCTAssertEqual(StatusPID.obdStandard(0xEE), "Standard 0xEE")
    }
}

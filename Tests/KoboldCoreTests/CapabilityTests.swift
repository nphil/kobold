import XCTest
@testable import KoboldCore

final class StandardPIDCatalogueTests: XCTestCase {

    func testNamesTheWellKnownPIDs() {
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0x0C), "Engine Speed")
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0x05), "Engine Coolant Temperature")
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0x2F), "Fuel Tank Level")
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0x23), "Fuel Rail Gauge Pressure")
        // Turbo PIDs matter on the reference car specifically.
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0x70), "Boost Pressure Control")
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0x72), "Wastegate Control")
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0x77), "Charge Air Cooler Temperature")
    }

    /// An unnamed PID must still render as something, or the capability screen
    /// shows a blank row.
    func testUnknownPIDsFallBackToTheirNumber() {
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0xF3), "PID 0xF3")
    }

    func testOxygenSensorsAreNumberedNotRepeated() {
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0x14), "Oxygen Sensor 1")
        XCTAssertEqual(StandardPIDCatalogue.name(for: 0x1B), "Oxygen Sensor 8")
    }

    func testBankSelectorsAreIdentified() {
        for pid: UInt8 in [0x00, 0x20, 0x40, 0x60, 0x80] {
            XCTAssertTrue(StandardPIDCatalogue.isBankSelector(pid))
        }
        XCTAssertFalse(StandardPIDCatalogue.isBankSelector(0x0C))
    }

    func testCommandTextIsWellFormed() {
        XCTAssertEqual(StandardPIDCatalogue.entry(for: 0x0C)?.command, "010C")
        XCTAssertEqual(StandardPIDCatalogue.entry(for: 0x05)?.command, "0105")
    }
}

final class VehicleCapabilityTests: XCTestCase {

    private func profile() throws -> ResolvedProfile {
        try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
    }

    func testSplitsWhatIsReadableFromWhatIsMissing() throws {
        // 0C rpm and 05 coolant are decodable; 70 boost control is not.
        let capability = VehicleCapability(supported: [0x0C, 0x05, 0x70],
                                           profile: try profile())

        XCTAssertTrue(capability.readable.contains(.rpm))
        XCTAssertTrue(capability.readable.contains(.coolantTemp))
        XCTAssertEqual(capability.gaps.map(\.pid), [0x70])
        XCTAssertEqual(capability.gaps.first?.name, "Boost Pressure Control")
    }

    /// "Supported PIDs 21–40" is not a feature anyone is missing.
    func testBankSelectorsAreNotReportedAsGaps() throws {
        let capability = VehicleCapability(supported: [0x00, 0x20, 0x40, 0x0C],
                                           profile: try profile())

        XCTAssertTrue(capability.gaps.isEmpty)
        XCTAssertEqual(capability.supportedCount, 1)
    }

    func testCoverageIsTheHonestFraction() throws {
        let capability = VehicleCapability(supported: [0x0C, 0x05, 0x70, 0x72],
                                           profile: try profile())

        XCTAssertEqual(capability.supportedCount, 4)
        XCTAssertEqual(capability.readable.count, 2)
        XCTAssertEqual(capability.coverage, 0.5, accuracy: 0.0001)
    }

    func testCoverageOnAVehicleThatDeclaredNothing() throws {
        let capability = VehicleCapability(supported: [], profile: try profile())
        XCTAssertEqual(capability.coverage, 0)
        XCTAssertTrue(capability.gaps.isEmpty)
    }

    /// A profile written optimistically lists signals the car never declares.
    func testSignalsTheCarDidNotDeclareAreReported() throws {
        let capability = VehicleCapability(supported: [0x0C], profile: try profile())

        XCTAssertTrue(capability.undeclared.contains(.coolantTemp),
                      "defined in the profile but not declared by this car")
        XCTAssertFalse(capability.undeclared.contains(.rpm))
    }

    /// Mode 22 signals have no bitmask, so counting them would flatter the
    /// coverage figure with signals it cannot actually verify.
    func testManufacturerModeSignalsAreExcludedFromTheComparison() throws {
        let capability = VehicleCapability(supported: [0x0C], profile: try profile())

        // oilTemp is Mode 22 on this car — neither readable-by-bitmask nor a gap
        // nor undeclared.
        XCTAssertFalse(capability.readable.contains("oilTemp"))
        XCTAssertFalse(capability.undeclared.contains("oilTemp"))
    }

    /// The capability report is rendered from itself, so it has to carry the
    /// display names — a screen that exists to stop showing people raw keys
    /// must not fall back to showing them.
    func testCarriesDisplayNamesForEverySignalItLists() throws {
        let capability = VehicleCapability(supported: [0x0C, 0x05, 0x70],
                                           profile: try profile())

        for id in capability.readable + capability.undeclared {
            let name = capability.name(for: id)
            XCTAssertFalse(name.isEmpty)
            XCTAssertNotEqual(name, id.rawValue, "\(id.rawValue) fell back to its identifier")
        }
        // The profile's own label wins over the catalogue's: the catalogue
        // names PIDs the app cannot read, and the app names what it can.
        XCTAssertEqual(capability.name(for: .rpm), "Engine RPM")
    }

    func testGapsGroupByCategory() throws {
        // 70/72 are air, 32 is emissions — all still undecoded.
        let capability = VehicleCapability(supported: [0x70, 0x72, 0x32],
                                           profile: try profile())
        let grouped = capability.gapsByCategory

        XCTAssertEqual(grouped.first?.category, .air, "air sorts before emissions")
        XCTAssertEqual(Set(grouped.map(\.category)), [.air, .emissions])
    }

    // MARK: - Mode 09

    func testRecordsVehicleInformationSeparately() throws {
        var capability = VehicleCapability(supported: [0x0C], profile: try profile())
        XCTAssertTrue(capability.vehicleInfo.isEmpty)

        // A typical reply: VIN, calibration ID, CVN, in-use tracking, ECU name,
        // plus the message-count PIDs that precede each of them.
        capability.recordVehicleInfo(reportedPIDs: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x0A])

        XCTAssertEqual(capability.vehicleInfo.map(\.pid), [0x02, 0x04, 0x06, 0x0A])
        XCTAssertEqual(capability.vehicleInfo.first?.name, "Vehicle Identification Number")
        XCTAssertEqual(capability.vehicleInfo.first?.command, "0902")
    }

    /// Mode 09 is identity data, not sensor readings. Letting it into the
    /// fraction would make one number answer two unrelated questions.
    func testVehicleInformationDoesNotChangeCoverage() throws {
        var capability = VehicleCapability(supported: [0x0C, 0x70], profile: try profile())
        let before = capability.coverage
        let count = capability.supportedCount

        capability.recordVehicleInfo(reportedPIDs: [0x02, 0x04, 0x06])

        XCTAssertEqual(capability.coverage, before)
        XCTAssertEqual(capability.supportedCount, count)
    }
}

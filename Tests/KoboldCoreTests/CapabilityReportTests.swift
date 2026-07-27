import XCTest
@testable import KoboldCore

/// The coverage report as text.
///
/// Tested because it is the only copy of these facts that survives leaving the
/// car. If a section silently stops rendering, the screen still looks right and
/// the log quietly loses the thing someone drove somewhere to collect.
final class CapabilityReportTests: XCTestCase {

    private func profile() throws -> ResolvedProfile {
        try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
    }

    private func report(_ capability: VehicleCapability) -> String {
        CapabilityReport.lines(for: capability, profileName: "Test Car")
            .joined(separator: "\n")
    }

    func testStatesCoverageAsCountsAndPercent() throws {
        // 0C and 05 decode; 70 does not. 2 of 3 = 67%.
        let capability = VehicleCapability(supported: [0x0C, 0x05, 0x70],
                                           profile: try profile())
        let text = report(capability)

        XCTAssertTrue(text.contains("Coverage: 2 of 3 reported PIDs decoded (67%)"), text)
        XCTAssertTrue(text.contains("Test Car"))
    }

    /// The gap list is the actionable half. It carries the command as well as
    /// the name so it can be looked up without the app in hand.
    func testListsGapsWithTheirCommandGroupedByCategory() throws {
        // 0170 is a control with no sensor entry and 019E has no published
        // formula, so both stay gaps as the catalogue grows.
        let capability = VehicleCapability(supported: [0x0C, 0x70, 0x9E],
                                           profile: try profile())
        let text = report(capability)

        XCTAssertTrue(text.contains("Not decoded · Air & Boost"), text)
        XCTAssertTrue(text.contains("0170 Boost Pressure Control"), text)
        XCTAssertTrue(text.contains("Not decoded · Emissions"), text)
    }

    func testNamesWhatItDecodes() throws {
        let capability = VehicleCapability(supported: [0x0C, 0x05], profile: try profile())
        let text = report(capability)

        XCTAssertTrue(text.contains("Engine RPM"), text)
        XCTAssertFalse(text.contains("rpm,"), "human names, not identifiers")
    }

    /// "Not probed" and "none answered" are different facts. Collapsing them
    /// sends someone debugging a probe that ran fine.
    func testDistinguishesAnUnprobedModuleListFromAnEmptyOne() throws {
        var capability = VehicleCapability(supported: [0x0C], profile: try profile())
        XCTAssertTrue(report(capability).contains("Modules: not probed"))

        capability.recordModules([])
        XCTAssertTrue(report(capability).contains("Modules: none answered a direct request"))

        capability.recordModules([
            .init(key: "fwdRadar", label: "Forward Radar", header: "7D0", version: "IK__SCC")
        ])
        XCTAssertTrue(report(capability).contains("Forward Radar (7D0) IK__SCC"))
    }

    func testReportsVehicleInformationAndSaysSoWhenThereIsNone() throws {
        var capability = VehicleCapability(supported: [0x0C], profile: try profile())
        XCTAssertTrue(report(capability).contains("Vehicle info: none reported"))

        capability.recordVehicleInfo(reportedPIDs: [0x02, 0x04])
        let text = report(capability)
        XCTAssertTrue(text.contains("Vehicle Identification Number"), text)
        XCTAssertTrue(text.contains("Calibration ID"), text)
    }

    /// Every line has to survive the remote log's 3.5 KB batch limit on its own,
    /// or it is the one that gets split and made unreadable.
    func testNoSingleLineIsUnreasonablyLong() throws {
        // A car declaring everything the catalogue knows: the widest report.
        var capability = VehicleCapability(supported: Set(UInt8(1)...UInt8(0x9F)),
                                           profile: try profile())
        capability.recordVehicleInfo(reportedPIDs: [0x02, 0x04, 0x06, 0x0A])

        for line in CapabilityReport.lines(for: capability, profileName: "Test Car") {
            XCTAssertLessThan(line.utf8.count, 1_800,
                              "line would be split by the log batcher: \(line.prefix(80))…")
        }
    }
}

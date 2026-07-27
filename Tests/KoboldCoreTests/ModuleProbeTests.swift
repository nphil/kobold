import XCTest
@testable import KoboldCore

/// Probing chassis and driver-assistance modules.
///
/// These modules are reachable only by addressing them directly, which means
/// changing the adapter's header state. That makes the restore path — not the
/// happy path — the thing most worth testing: a probe that leaves the header
/// pointed at the radar breaks every reading the app takes afterwards.
final class ModuleProbeTests: XCTestCase {

    private func fixture(_ extra: [String: [String]] = [:]) -> ReplayTransport.Fixture {
        var responses: [String: [String]] = [
            "ATZ": ["ELM327 v1.5"], "ATE0": ["OK"], "ATL0": ["OK"], "ATS0": ["OK"],
            "ATH1": ["OK"], "ATSP0": ["OK"], "ATDPN": ["6"],
            // Negotiation needs a live PID reply to settle the protocol.
            "0100": ["7E8 06 41 00 18 3A 80 01"],
        ]
        responses.merge(extra) { _, new in new }
        return ReplayTransport.Fixture(responses: responses, fallback: ["NO DATA"])
    }

    private func started(_ fixture: ReplayTransport.Fixture) async throws
        -> (ELM327Driver, ReplayTransport) {
        let transport = ReplayTransport(fixture: fixture)
        let driver = ELM327Driver(transport: transport, descriptor: .generic)
        try await driver.start()
        return (driver, transport)
    }

    private let radar = (key: "fwdRadar", label: "Forward Radar",
                         transmit: "7D0", receive: "7D8" as String?)

    func testReportsAModuleThatAnswers() async throws {
        // 62 F1 00 then ASCII "IK__SCC" — a plausible identification reply.
        let (driver, _) = try await started(fixture([
            "ATSH 7D0": ["OK"], "ATCRA 7D8": ["OK"],
            "22F100": ["7D8 0A 62 F1 00 49 4B 5F 5F 53 43 43"],
        ]))

        let found = await driver.identifyModules([radar])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.key, "fwdRadar")
        XCTAssertEqual(found.first?.header, "7D0")
        XCTAssertEqual(found.first?.version, "IK__SCC")
    }

    func testAModuleThatDoesNotAnswerIsSimplyAbsent() async throws {
        let (driver, _) = try await started(fixture(["ATSH 7D0": ["OK"], "ATCRA 7D8": ["OK"]]))

        let found = await driver.identifyModules([radar])
        XCTAssertTrue(found.isEmpty, "NO DATA means not fitted, not an error")
    }

    /// The important one. Whatever happens, the adapter must be left addressing
    /// the broadcast header again.
    func testRestoresTheHeaderAfterProbing() async throws {
        let (driver, transport) = try await started(fixture([
            "ATSH 7D0": ["OK"], "ATCRA 7D8": ["OK"],
            "22F100": ["7D8 0A 62 F1 00 49 4B 5F 5F 53 43 43"],
        ]))

        _ = await driver.identifyModules([radar])

        let sent = await transport.sentCommands
        XCTAssertEqual(sent.last, "ATSH 7DF", "last word must hand addressing back")
        XCTAssertTrue(sent.contains("ATAR"), "and clear the receive filter")
    }

    func testRestoresTheHeaderEvenWhenEveryModuleFails() async throws {
        let (driver, transport) = try await started(fixture())

        _ = await driver.identifyModules([radar])

        let sent = await transport.sentCommands
        XCTAssertEqual(sent.last, "ATSH 7DF")
    }

    func testProbingNothingTouchesNothing() async throws {
        let (driver, transport) = try await started(fixture())
        let before = await transport.sentCommands.count

        let found = await driver.identifyModules([])

        let after = await transport.sentCommands.count
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(before, after, "no probe targets means no round trips")
    }

    /// A binary part number is not a version string. Showing it as one would
    /// put mojibake on screen and call it firmware.
    func testBinaryIdentifiersAreNotPresentedAsText() async throws {
        let (driver, _) = try await started(fixture([
            "ATSH 7D0": ["OK"], "ATCRA 7D8": ["OK"],
            "22F100": ["7D8 07 62 F1 00 01 02 03 04"],
        ]))

        let found = await driver.identifyModules([radar])
        XCTAssertEqual(found.count, 1, "it answered, so it is present")
        XCTAssertNil(found.first?.version)
    }
}

/// The module list comes from profile data, not from code.
final class ProfileModuleTests: XCTestCase {

    private func profile() throws -> ResolvedProfile {
        try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
    }

    func testHeadersInheritThroughTheProfileChain() throws {
        let resolved = try profile()
        // Defined on the platform profile, not the specific car.
        XCTAssertEqual(resolved.ecuHeaders["tpms"]?.transmit, "7A0")
        XCTAssertEqual(resolved.ecuHeaders["engine"]?.transmit, "7E0")
    }

    func testProbesOnlyTheModulesThatNeedIntroducing() throws {
        let keys = try profile().probeableModules.map(\.key)

        XCTAssertEqual(keys, ["absEsc", "eps", "fwdCamera", "fwdRadar"])
        XCTAssertFalse(keys.contains("engine"),
                       "standard OBD modules answer a broadcast; nothing to discover")
    }

    /// Response header is request + 0x8 on this platform. A transposed digit
    /// here means the filter never matches and every module reads as absent.
    func testProbeTargetsPairRequestAndResponseCorrectly() throws {
        for (_, header) in try profile().probeableModules {
            let transmit = try XCTUnwrap(UInt16(header.transmit, radix: 16))
            let receive = try XCTUnwrap(UInt16(XCTUnwrap(header.receive), radix: 16))
            XCTAssertEqual(receive, transmit + 8, "\(header.transmit) → \(header.receive ?? "-")")
        }
    }

    /// The blind-spot radar at 0x7B7 appears in a generic manufacturer-wide list
    /// but in no G70 fingerprint. Writing it in as fact would be inventing a
    /// module, which is exactly what this probe exists to avoid.
    func testUnconfirmedModulesAreNotClaimed() throws {
        let addresses = try profile().ecuHeaders.values.map(\.transmit)
        XCTAssertFalse(addresses.contains("7B7"))
    }
}

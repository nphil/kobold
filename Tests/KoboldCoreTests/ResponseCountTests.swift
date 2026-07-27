import XCTest
@testable import KoboldCore

/// Learning how many modules answer each request, so the adapter can stop
/// waiting out its timeout.
///
/// The speed is the easy part. What these pin down is that it never costs
/// correctness: an early return that hands back the wrong module's reply would
/// be a worse bug than the slowness it cures, and it would look like valid data.
final class ResponseCountTests: XCTestCase {

    private let rpm = SignalDefinition(
        id: "rpm", label: "Engine RPM", header: "7E0", mode: "01", pid: "0C",
        byteOffset: 0, byteCount: 2,
        conversion: .linear(LinearConversion(divisor: 4)), unit: .rpm)

    private func fixture(_ extra: [String: [String]] = [:]) -> ReplayTransport.Fixture {
        var responses: [String: [String]] = [
            "ATZ": ["ELM327 v1.5"], "ATE0": ["OK"], "ATL0": ["OK"], "ATS0": ["OK"],
            "ATH1": ["OK"], "ATSP0": ["OK"], "ATDPN": ["6"],
            "0100": ["7E8 06 41 00 18 3A 80 01"],
            "010C": ["7E8 04 41 0C 0B B8"],
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

    /// The first read is heard out in full; only then is the count known.
    func testLearnsTheCountFromTheFirstReadAndUsesItAfterwards() async throws {
        let (driver, transport) = try await started(fixture())

        _ = try await driver.read(rpm)
        let afterFirst = await transport.sentCommands.filter { $0.hasPrefix("010C") }
        XCTAssertEqual(afterFirst, ["010C"], "nothing to hint with yet")

        _ = try await driver.read(rpm)
        let afterSecond = await transport.sentCommands.filter { $0.hasPrefix("010C") }
        XCTAssertEqual(afterSecond, ["010C", "010C1"], "one responder seen, so one expected")

        let hints = await driver.responseCountHints
        XCTAssertEqual(hints["010C"], 1)
    }

    /// Two modules answering means two, not one. Asking for one here would
    /// return whichever replied first and call it the engine.
    func testLearnsTheRealCountWhenSeveralModulesAnswer() async throws {
        let (driver, transport) = try await started(fixture([
            "010C": ["7E8 04 41 0C 0B B8", "7E9 04 41 0C 00 00"],
        ]))

        _ = try await driver.read(rpm)
        _ = try await driver.read(rpm)

        let hints = await driver.responseCountHints
        XCTAssertEqual(hints["010C"], 2)
        let sent = await transport.sentCommands
        XCTAssertTrue(sent.contains("010C2"), "expects both replies: \(sent)")
    }

    /// The value must still come from the addressed module, not the fast one.
    func testStillDecodesTheAddressedModulesReply() async throws {
        let (driver, _) = try await started(fixture([
            // Transmission answers first with a different value.
            "010C": ["7E9 04 41 0C 00 00", "7E8 04 41 0C 0B B8"],
        ]))

        for _ in 0..<3 {
            let value = try await driver.read(rpm)
            XCTAssertEqual(value, 750, accuracy: 0.01, "7E8 is the engine: 0x0BB8 / 4")
        }
    }

    /// Multi-frame replies are left alone on purpose — the digit's meaning for
    /// them is not documented, and oil temperature is exactly that case.
    func testDoesNotHintForMultiFrameReplies() async throws {
        let oilTemp = SignalDefinition(
            id: "oilTemp", label: "Oil Temp", header: "7E0", mode: "22", pid: "E001",
            byteOffset: 0, byteCount: 1,
            conversion: .linear(LinearConversion(factor: 0.75, postOffset: -48)), unit: .celsius)

        let (driver, transport) = try await started(fixture([
            "22E001": ["7E8 10 09 62 E0 01 78 00 00", "7E8 21 00 00 00 00 00 00"],
        ]))

        _ = try? await driver.read(oilTemp)
        _ = try? await driver.read(oilTemp)

        let hints = await driver.responseCountHints
        XCTAssertNil(hints["22E001"])
        let sent = await transport.sentCommands
        XCTAssertFalse(sent.contains("22E0011"), "multi-frame stays unoptimised: \(sent)")
    }

    /// A command whose module has no derivable response header cannot be
    /// verified, so it is never optimised.
    func testDoesNotHintWithoutAKnownResponseHeader() async throws {
        let broadcast = SignalDefinition(
            id: "x", label: "X", header: "7DF", mode: "01", pid: "0C",
            byteOffset: 0, byteCount: 2,
            conversion: .linear(LinearConversion(divisor: 4)), unit: .rpm)

        let (driver, transport) = try await started(fixture())
        _ = try await driver.read(broadcast)
        _ = try await driver.read(broadcast)

        let sent = await transport.sentCommands
        XCTAssertFalse(sent.contains("010C1"), "7DF is a broadcast, not a module: \(sent)")
    }

    /// An adapter that mishandles the digit must degrade, not fail forever.
    func testStopsHintingWhenTheAdapterCannotHonourIt() async throws {
        // Answers the plain command but not the one with the count digit —
        // exactly how a clone that ignores the feature behaves.
        let transport = ReplayTransport(fixture: ReplayTransport.Fixture(
            responses: [
                "ATZ": ["ELM327 v1.5"], "ATE0": ["OK"], "ATL0": ["OK"], "ATS0": ["OK"],
                "ATH1": ["OK"], "ATSP0": ["OK"], "ATDPN": ["6"],
                "0100": ["7E8 06 41 00 18 3A 80 01"],
                "010C": ["7E8 04 41 0C 0B B8"],
                "010C1": ["NO DATA"],
            ],
            fallback: ["NO DATA"]))
        let driver = ELM327Driver(transport: transport, descriptor: .generic)
        try await driver.start()

        // Alternating success and failure: each failure forgets the hint, each
        // success relearns it, until the driver gives up on the feature.
        for _ in 0..<12 { _ = try? await driver.read(rpm) }

        let enabled = await driver.usesResponseCounts
        XCTAssertFalse(enabled, "three strikes and the feature switches itself off")

        // And it still works afterwards.
        let value = try await driver.read(rpm)
        XCTAssertEqual(value, 750, accuracy: 0.01)
    }
}

/// The response-header rule, which decides which reply is believed.
final class ResponseHeaderTests: XCTestCase {

    /// Modules outside the engine range used to have no expected header at all,
    /// so a TPMS reply fell back to whichever ECU answered first.
    func testDerivesTheHeaderForNonEngineModules() async throws {
        let tpms = SignalDefinition(
            id: "t", label: "T", header: "7A0", mode: "22", pid: "C00B",
            byteOffset: 0, byteCount: 1,
            conversion: .linear(LinearConversion(divisor: 5)), unit: .psi)

        let transport = ReplayTransport(fixture: ReplayTransport.Fixture(
            responses: [
                "ATZ": ["ELM327 v1.5"], "ATE0": ["OK"], "ATL0": ["OK"], "ATS0": ["OK"],
                "ATH1": ["OK"], "ATSP0": ["OK"], "ATDPN": ["6"],
                "0100": ["7E8 06 41 00 18 3A 80 01"],
                // Engine answers first with rubbish; the TPMS module answers second.
                "22C00B": ["7E8 05 62 C0 0B 00", "7A8 05 62 C0 0B A0"],
            ],
            fallback: ["NO DATA"]))
        let driver = ELM327Driver(transport: transport, descriptor: .generic)
        try await driver.start()

        let value = try await driver.read(tpms)
        XCTAssertEqual(value, 32, accuracy: 0.01, "0xA0 / 5 — from 7A8, not 7E8")
    }
}

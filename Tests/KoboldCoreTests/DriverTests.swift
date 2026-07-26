import XCTest
@testable import KoboldCore

final class AdaptiveTimingTests: XCTestCase {

    func testSuccessShrinksWindow() {
        var timing = AdaptiveTiming(initial: .milliseconds(200))
        let before = timing.current
        timing.recordSuccess()
        XCTAssertLessThan(timing.current, before)
    }

    func testTimeoutGrowsWindow() {
        var timing = AdaptiveTiming(initial: .milliseconds(200))
        timing.recordTimeout()
        XCTAssertGreaterThan(timing.current, .milliseconds(200))
    }

    /// Backing off faster than it advances is deliberate: an over-tight window
    /// turns healthy-but-slow PIDs into phantom NO DATA.
    func testBackoffOutpacesRecovery() {
        var timing = AdaptiveTiming(initial: .milliseconds(200))
        timing.recordSuccess()
        timing.recordTimeout()
        XCTAssertGreaterThan(timing.current, .milliseconds(200))
    }

    func testStaysWithinBounds() {
        var timing = AdaptiveTiming(initial: .milliseconds(200),
                                    minimum: .milliseconds(50),
                                    maximum: .milliseconds(400))
        for _ in 0..<200 { timing.recordSuccess() }
        XCTAssertGreaterThanOrEqual(timing.current, .milliseconds(50))

        for _ in 0..<200 { timing.recordTimeout() }
        XCTAssertLessThanOrEqual(timing.current, .milliseconds(400))
    }

    /// A single fast reply must not collapse the window to the point where normal
    /// jitter starts producing timeouts.
    func testWindowStaysAboveObservedRoundTrip() {
        var timing = AdaptiveTiming(initial: .milliseconds(200), minimum: .milliseconds(1))
        for _ in 0..<50 { timing.recordSuccess(roundTrip: .milliseconds(40)) }
        XCTAssertGreaterThanOrEqual(timing.current, .milliseconds(80))
    }

    func testDurationScaling() {
        XCTAssertEqual(Duration.milliseconds(100).scaled(by: 2.0), .milliseconds(200))
        XCTAssertEqual(Duration.milliseconds(100).scaled(by: 0.5), .milliseconds(50))
        XCTAssertEqual(Duration.milliseconds(100).milliseconds, 100, accuracy: 0.001)
    }
}

final class AdapterRegistryTests: XCTestCase {

    func testMatchesAdvertisedNameCaseInsensitively() {
        let registry = AdapterRegistry()
        XCTAssertEqual(registry.descriptor(forAdvertisedName: "IOS-Vlink").id,
                       "vgate-icar-pro-2s")
        XCTAssertEqual(registry.descriptor(forAdvertisedName: "android-vlink").id,
                       "vgate-icar-pro-2s")
    }

    func testUnknownNameFallsBackToGeneric() {
        let registry = AdapterRegistry()
        XCTAssertEqual(registry.descriptor(forAdvertisedName: "Some Other Dongle").id,
                       "generic-elm327")
    }

    func testGenericHintStillMatchesUnknownELMAdapter() {
        let registry = AdapterRegistry()
        XCTAssertEqual(registry.descriptor(forAdvertisedName: "OBDII").id, "generic-elm327")
    }

    func testNewAdapterIsAddedAsDataOnly() {
        var registry = AdapterRegistry()
        registry.register(AdapterDescriptor(id: "veepeak-obdcheck-ble",
                                            displayName: "Veepeak OBDCheck BLE",
                                            nameMatchHints: ["veepeak"]))
        XCTAssertEqual(registry.descriptor(forAdvertisedName: "VEEPEAK-1234").id,
                       "veepeak-obdcheck-ble")
    }
}

final class ReplayTransportTests: XCTestCase {

    func testFragmentsResponsesLikeRealHardware() async throws {
        let transport = ReplayTransport(fixture: .idlingEngine())
        let stream = await transport.makeInboundStream()
        try await transport.connect()

        var assembler = ResponseAssembler()
        var collected: [RawResponse] = []

        try await transport.send(Data("010C\r".utf8))

        for await chunk in stream {
            // A real peripheral splits replies across notifications; the fixture
            // reproduces that so consumers exercise the same reassembly path.
            XCTAssertLessThanOrEqual(chunk.count, 20)
            collected.append(contentsOf: assembler.append(chunk))
            if !collected.isEmpty { break }
        }

        XCTAssertEqual(collected.first?.lines, ["7E8 04 41 0C 0B B8"])
    }

    func testRecordsSentCommands() async throws {
        let transport = ReplayTransport(fixture: .idlingEngine())
        try await transport.connect()
        try await transport.send(Data("ATZ\r".utf8))
        try await transport.send(Data("010C\r".utf8))

        let sent = await transport.sentCommands
        XCTAssertEqual(sent, ["ATZ", "010C"])
    }

    func testSendBeforeConnectThrows() async {
        let transport = ReplayTransport(fixture: .idlingEngine())
        do {
            try await transport.send(Data("010C\r".utf8))
            XCTFail("expected notConnected")
        } catch {
            XCTAssertEqual(error as? TransportError, .notConnected)
        }
    }
}

final class ELM327DriverTests: XCTestCase {

    private func makeDriver() -> (ELM327Driver, ReplayTransport) {
        let transport = ReplayTransport(fixture: .idlingEngine())
        let registry = AdapterRegistry()
        let descriptor = registry.descriptor(forAdvertisedName: "IOS-Vlink")
        return (ELM327Driver(transport: transport, descriptor: descriptor), transport)
    }

    func testStartRunsInitSequenceAndReachesReady() async throws {
        let (driver, transport) = makeDriver()
        try await driver.start()

        let phase = await driver.phase
        XCTAssertEqual(phase, .ready)

        let sent = await transport.sentCommands
        // Echo suppression must come before the other display settings, or every
        // command echoed back has to be filtered out of the first replies.
        XCTAssertEqual(Array(sent.prefix(5)), ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1"])
        XCTAssertTrue(sent.contains("ATSP0"))
        XCTAssertTrue(sent.contains("0100"))

        let negotiated = await driver.negotiatedProtocol
        XCTAssertEqual(negotiated, "6")

        await driver.stop()
    }

    func testReadsAndDecodesSignalEndToEnd() async throws {
        let (driver, _) = makeDriver()
        try await driver.start()

        let profile = try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")

        let rpm = try await driver.read(XCTUnwrap(profile.definition(for: .rpm)))
        XCTAssertEqual(rpm, 750, accuracy: 0.001)

        let coolant = try await driver.read(XCTUnwrap(profile.definition(for: .coolantTemp)))
        XCTAssertEqual(coolant, 50, accuracy: 0.001)

        // Manufacturer-extended PID over Mode 22, with a two-byte PID echo.
        let oilTemp = try await driver.read(XCTUnwrap(profile.definition(for: .oilTemp)))
        XCTAssertEqual(oilTemp, 42, accuracy: 0.001)

        await driver.stop()
    }

    /// Boost has no PID on this engine: read its inputs, then derive it.
    func testDerivesBoostFromLiveInputs() async throws {
        let (driver, _) = makeDriver()
        try await driver.start()

        let profile = try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
        let map = try await driver.read(XCTUnwrap(profile.definition(for: .map)))
        let baro = try await driver.read(XCTUnwrap(profile.definition(for: .baro)))

        let boost = try XCTUnwrap(profile.derivedSignals[.boost])
            .evaluate(using: [.map: map, .baro: baro])

        // Fixture is an idling engine: manifold in vacuum, so boost clamps to zero.
        XCTAssertEqual(map, 34, accuracy: 0.001)
        XCTAssertEqual(baro, 101, accuracy: 0.001)
        XCTAssertEqual(boost, 0)

        await driver.stop()
    }

    func testUnsupportedPIDSurfacesAsDeviceError() async throws {
        let (driver, _) = makeDriver()
        try await driver.start()

        let unsupported = SignalDefinition(
            id: "phantom", label: "Phantom", header: "7E0", mode: "01", pid: "FE",
            byteOffset: 0, byteCount: 1, conversion: .identity, unit: .none
        )
        do {
            _ = try await driver.read(unsupported)
            XCTFail("expected NO DATA to surface as an error")
        } catch {
            guard case ELM327Error.deviceError(_, let reply) = error else {
                return XCTFail("expected deviceError, got \(error)")
            }
            XCTAssertEqual(reply, .noData)
        }
        await driver.stop()
    }

    func testReadsTroubleCodes() async throws {
        let transport = ReplayTransport(fixture: .init(responses: [
            "ATZ": ["ELM327 v1.5"], "ATE0": ["OK"], "ATL0": ["OK"],
            "ATS0": ["OK"], "ATH1": ["OK"], "ATSP0": ["OK"], "ATDPN": ["6"],
            "0100": ["7E8 06 41 00 BE 3E B8 11"],
            // Two stored codes: P0301 and U0100, then frame padding.
            "03": ["7E8 06 43 02 03 01 C1 00"]
        ], fallback: ["NO DATA"]))

        let driver = ELM327Driver(transport: transport)
        try await driver.start()

        let codes = try await driver.readTroubleCodes()
        XCTAssertEqual(codes, ["P0301", "U0100"])

        await driver.stop()
    }

    func testDiscoversSupportedPIDs() async throws {
        let (driver, _) = makeDriver()
        try await driver.start()

        let supported = try await driver.discoverSupportedPIDs()
        // 0xBE3EB811 advertises PIDs 01, 03-07 among others.
        XCTAssertTrue(supported.contains(0x01))
        XCTAssertTrue(supported.contains(0x05))
        XCTAssertFalse(supported.contains(0x02))

        await driver.stop()
    }

    /// Concurrent callers must not interleave writes. Pipelining before the '>'
    /// prompt is what makes an ELM327 answer STOPPED, so the driver serialises
    /// commands even though actor reentrancy would otherwise allow overlap.
    func testConcurrentReadsAreSerialised() async throws {
        let (driver, transport) = makeDriver()
        try await driver.start()

        let profile = try ProfileStore.bundled().resolveBaseline()
        let rpm = try XCTUnwrap(profile.definition(for: .rpm))
        let speed = try XCTUnwrap(profile.definition(for: .speed))
        let coolant = try XCTUnwrap(profile.definition(for: .coolantTemp))

        async let a = driver.read(rpm)
        async let b = driver.read(speed)
        async let c = driver.read(coolant)
        let results = try await [a, b, c]

        XCTAssertEqual(Set(results), [750, 0, 50])

        // Every command must appear exactly once and in a clean sequence.
        let sent = await transport.sentCommands
        XCTAssertEqual(sent.filter { $0 == "010C" }.count, 1)
        XCTAssertEqual(sent.filter { $0 == "010D" }.count, 1)
        XCTAssertEqual(sent.filter { $0 == "0105" }.count, 1)

        await driver.stop()
    }

    /// The target hardware sleeps mid-session, presenting as a device that
    /// accepts writes and never answers. That must surface as a timeout naming
    /// the command, not a hang.
    func testCommandTimesOutWhenAdapterGoesSilent() async throws {
        let transport = ReplayTransport(fixture: .idlingEngine())
        let driver = ELM327Driver(transport: transport)
        try await driver.start()

        await transport.update(fixture: .init(responses: [:], isSilent: true))

        let definition = SignalDefinition(
            id: .rpm, label: "RPM", header: "7E0", mode: "01", pid: "0C",
            byteOffset: 0, byteCount: 2, conversion: .engineRPM, unit: .rpm
        )
        do {
            _ = try await driver.read(definition)
            XCTFail("expected a timeout")
        } catch {
            guard case ELM327Error.timeout(let command) = error else {
                return XCTFail("expected timeout, got \(error)")
            }
            XCTAssertEqual(command, "010C")
        }
        await driver.stop()
    }

    /// A reply can land before the caller has registered its waiter. Dropping it
    /// would present as a spurious timeout, so it must be buffered and matched.
    func testReplyArrivingBeforeWaiterIsNotLost() async throws {
        let transport = ReplayTransport(fixture: .idlingEngine())
        let driver = ELM327Driver(transport: transport)
        try await driver.start()

        let profile = try ProfileStore.bundled().resolveBaseline()
        let rpm = try XCTUnwrap(profile.definition(for: .rpm))

        // Repeat: the race is scheduling-dependent, so one pass proves little.
        for _ in 0..<25 {
            let value = try await driver.read(rpm)
            XCTAssertEqual(value, 750, accuracy: 0.001)
        }
        await driver.stop()
    }
}

/// `connect()` must be idempotent — see `OBDTransport.connect()`.
///
/// This is the contract `BLETransport` broke in the field: the session connects
/// first to learn the adapter's advertised name (it needs it to pick a
/// descriptor), then `ELM327Driver.start()` connects again. The BLE transport
/// responded to the second call by starting a fresh scan, skipping the
/// peripheral it was already attached to, timing out, and tearing down the live
/// connection — surfacing as `noAdapterFound` while connected. The transport
/// itself needs CoreBluetooth so it cannot be tested here, but the sequence that
/// exposed it can, against any transport.
final class TransportConnectIdempotencyTests: XCTestCase {

    func testConnectingTwiceLeavesTheLinkUp() async throws {
        let transport = ReplayTransport(fixture: .idlingEngine())

        try await transport.connect()
        try await transport.connect()

        let state = await transport.state
        XCTAssertEqual(state, .connected)
    }

    /// The exact production sequence: connect externally, then hand the already
    /// connected transport to a driver, which connects again during `start()`.
    func testDriverStartsOnAnAlreadyConnectedTransport() async throws {
        let transport = ReplayTransport(fixture: .idlingEngine())
        try await transport.connect()

        let driver = ELM327Driver(transport: transport, descriptor: .generic)
        try await driver.start()

        let state = await transport.state
        XCTAssertEqual(state, .connected, "start() must not tear down an existing link")

        // And the link is genuinely usable afterwards, not merely labelled connected.
        let rpm = try await driver.send("010C")
        XCTAssertTrue(rpm.isData)

        await driver.stop()
    }
}

/// Reconnecting must not repeat the protocol search.
///
/// The search is the slow part of connecting — the BLE link and the AT init
/// together take under three seconds, while an unassisted `ATSP0` search can
/// take tens of seconds because the adapter tries every protocol in turn. The
/// answer never changes for a given car, so it is learned once and replayed.
final class ProtocolMemoryTests: XCTestCase {

    private func fixture() -> ReplayTransport.Fixture {
        var fixture = ReplayTransport.Fixture.idlingEngine()
        // `ATDPN` reports an auto-detected protocol with a leading marker.
        fixture.responses["ATDPN"] = ["A6"]
        fixture.responses["ATSPA6"] = ["OK"]
        return fixture
    }

    func testFirstConnectionLearnsTheProtocolWithoutTheAutoMarker() async throws {
        let transport = ReplayTransport(fixture: fixture())
        let driver = ELM327Driver(transport: transport, descriptor: .generic)
        try await driver.start()

        // Stored as the bare identifier: the "A" only means "auto-detected",
        // and the caller re-applies it as the fallback prefix next time.
        let learned = await driver.negotiatedProtocol
        XCTAssertEqual(learned, "6")

        await driver.stop()
    }

    func testRememberedProtocolSkipsTheSearch() async throws {
        let transport = ReplayTransport(fixture: fixture())
        let driver = ELM327Driver(transport: transport,
                                  descriptor: .generic,
                                  preferredProtocol: "6")
        try await driver.start()

        let sent = await transport.sentCommands
        XCTAssertTrue(sent.contains("ATSPA6"),
                      "should set the remembered protocol with the auto-fallback prefix")
        XCTAssertFalse(sent.contains("ATSP0"),
                       "should not fall back to a full search when the remembered one answers")

        let phase = await driver.phase
        XCTAssertEqual(phase, .ready)

        await driver.stop()
    }

    func testNoMemoryMeansAFullSearch() async throws {
        let transport = ReplayTransport(fixture: fixture())
        let driver = ELM327Driver(transport: transport, descriptor: .generic)
        try await driver.start()

        let sent = await transport.sentCommands
        XCTAssertTrue(sent.contains("ATSP0"))
        XCTAssertFalse(sent.contains { $0.hasPrefix("ATSPA") },
                       "nothing to replay, so no protocol should be forced")

        await driver.stop()
    }

    // Not covered here: a *stale* remembered protocol degrading to a search.
    // `ReplayTransport` answers by command name alone, so it cannot express
    // "0100 fails on protocol 9 but succeeds after ATSP0" — the state the
    // fallback exists for. Writing a test against this fixture would assert
    // only that the fast path works, under a name claiming otherwise. The
    // safety net is in the command itself: `ATSP A<n>` asks the adapter to fall
    // back to searching on its own, so the behaviour belongs to the hardware
    // rather than to code this suite could exercise.
}

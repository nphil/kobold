import XCTest
@testable import KoboldCore

/// Recovery from a late reply.
///
/// Observed on the car: every read failed with `pidMismatch`, each request
/// getting the previous one's answer, and it never recovered for the life of
/// the connection. A timed-out command's reply is not cancelled — it arrives
/// late, with nobody waiting, and is buffered; the next command is then handed
/// that stale reply, its own arrives later and is buffered in turn, and the
/// offset persists.
///
/// The same fault made a 65,536-address scan complete in 68 seconds, because
/// every probe was answered instantly from the buffer, and report that the
/// module held no data.
final class DesyncTests: XCTestCase {

    private func fixture(latency: Duration = .zero,
                         silent: Bool = false) -> ReplayTransport.Fixture {
        ReplayTransport.Fixture(
            responses: [
                "ATZ": ["ELM327 v1.5"], "ATE0": ["OK"], "ATL0": ["OK"], "ATS0": ["OK"],
                "ATH1": ["OK"], "ATSP0": ["OK"], "ATDPN": ["6"],
                "0100": ["7E8 06 41 00 18 3A 80 01"],
                "010C": ["7E8 04 41 0C 0B B8"],
                "0105": ["7E8 03 41 05 5A"],
            ],
            fallback: ["NO DATA"],
            latency: latency,
            isSilent: silent)
    }

    private let rpm = SignalDefinition(
        id: "rpm", label: "Engine RPM", header: "7E0", mode: "01", pid: "0C",
        byteOffset: 0, byteCount: 2,
        conversion: .linear(LinearConversion(divisor: 4)), unit: .rpm)

    private let coolant = SignalDefinition(
        id: "coolantTemp", label: "Coolant", header: "7E0", mode: "01", pid: "05",
        byteOffset: 0, byteCount: 1,
        conversion: .linear(LinearConversion(postOffset: -40)), unit: .celsius)

    /// A read that times out must not poison the reads after it.
    ///
    /// The adapter goes quiet long enough for one command to give up, then
    /// starts answering again. Before the fix the late reply was paired with
    /// the next request and every read from then on was wrong.
    func testARepliedTooLateDoesNotShiftEverySubsequentRead() async throws {
        let transport = ReplayTransport(fixture: fixture())
        let driver = ELM327Driver(transport: transport, descriptor: .generic)
        try await driver.start()

        // Healthy to begin with.
        let before = try await driver.read(rpm)
        XCTAssertEqual(before, 750, accuracy: 0.01)

        // The adapter stops answering; this read gives up.
        await transport.update(fixture: fixture(silent: true))
        do {
            _ = try await driver.read(coolant)
            XCTFail("expected the read to time out")
        } catch {
            // Expected.
        }

        // It comes back, and the very next read must be its own answer — not
        // the one the abandoned command was still owed.
        await transport.update(fixture: fixture())
        let rpmAfter = try await driver.read(rpm)
        XCTAssertEqual(rpmAfter, 750, accuracy: 0.01, "rpm must decode as rpm")

        let coolantAfter = try await driver.read(coolant)
        XCTAssertEqual(coolantAfter, 50, accuracy: 0.01, "0x5A − 40")
    }

    /// Several consecutive failures must still leave the session recoverable.
    func testRecoversAfterASustainedOutage() async throws {
        let transport = ReplayTransport(fixture: fixture())
        let driver = ELM327Driver(transport: transport, descriptor: .generic)
        try await driver.start()

        await transport.update(fixture: fixture(silent: true))
        for _ in 0..<6 { _ = try? await driver.read(rpm) }

        await transport.update(fixture: fixture())
        // Two reads: the first may absorb an owed reply, the second must be
        // correct regardless.
        _ = try? await driver.read(rpm)
        let value = try await driver.read(coolant)
        XCTAssertEqual(value, 50, accuracy: 0.01)
    }

    /// A transport that answers inside the write must still be heard. Clearing
    /// the buffer unconditionally after sending would discard exactly this.
    func testAnImmediateReplyIsNotDiscarded() async throws {
        let transport = ReplayTransport(fixture: fixture())
        let driver = ELM327Driver(transport: transport, descriptor: .generic)
        try await driver.start()

        for _ in 0..<5 {
            let value = try await driver.read(rpm)
            XCTAssertEqual(value, 750, accuracy: 0.01)
        }
    }
}

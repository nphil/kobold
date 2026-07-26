import XCTest
@testable import KoboldCore

@MainActor
final class LiveSignalTests: XCTestCase {

    private func makeSignal() -> LiveSignal {
        LiveSignal(id: .rpm, label: "Engine RPM", unit: .rpm,
                   range: 0...8000, redline: 6500)
    }

    func testUpdateRecordsValueAndTimestamp() async {
        let signal = makeSignal()
        XCTAssertNil(signal.updatedAt)

        signal.update(value: 750)
        XCTAssertEqual(signal.value, 750)
        XCTAssertNotNil(signal.updatedAt)
        XCTAssertEqual(signal.sampleCount, 1)
    }

    func testNormalisedIsClampedToRange() async {
        let signal = makeSignal()
        signal.update(value: 4000)
        XCTAssertEqual(signal.normalised, 0.5, accuracy: 0.0001)

        // A car can report a value outside the nominal range; a gauge must not
        // draw its needle past the dial.
        signal.update(value: 99_999)
        XCTAssertEqual(signal.normalised, 1.0)
        signal.update(value: -500)
        XCTAssertEqual(signal.normalised, 0.0)
    }

    func testRedlineDetection() async {
        let signal = makeSignal()
        signal.update(value: 6000)
        XCTAssertFalse(signal.isOverRedline)
        signal.update(value: 6500)
        XCTAssertTrue(signal.isOverRedline)
    }

    /// A signal that has never reported must read as stale, so the UI dims it
    /// instead of presenting a default zero as a real measurement.
    func testUnreportedSignalIsStale() async {
        XCTAssertTrue(makeSignal().isStale())
    }

    func testStalenessFollowsTolerance() async {
        let signal = makeSignal()
        let now = Date()
        signal.update(value: 750, at: now.addingTimeInterval(-5))

        XCTAssertTrue(signal.isStale(now: now, tolerance: 2))
        XCTAssertFalse(signal.isStale(now: now, tolerance: 10))
    }

    func testZeroWidthRangeDoesNotDivideByZero() async {
        let signal = LiveSignal(id: "flat", label: "Flat", unit: .none, range: 5...5)
        signal.update(value: 5)
        XCTAssertEqual(signal.normalised, 0)
    }
}

@MainActor
final class SignalBusTests: XCTestCase {

    private func makeBus() throws -> SignalBus {
        let profile = try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
        return SignalBus(profile: profile)
    }

    func testBuildsSignalsFromProfileData() async throws {
        let bus = try makeBus()

        XCTAssertNotNil(bus.signal(.rpm))
        XCTAssertNotNil(bus.signal(.coolantTemp))
        XCTAssertNotNil(bus.signal(.oilTemp))

        // Derived signals are exposed exactly like requested ones.
        XCTAssertNotNil(bus.signal(.boost))

        // A signal the profile marks absent must not exist at all.
        XCTAssertNil(bus.signal(.maf))
    }

    func testSignalMetadataComesFromTheProfile() async throws {
        let bus = try makeBus()
        let rpm = try XCTUnwrap(bus.signal(.rpm))

        XCTAssertEqual(rpm.label, "Engine RPM")
        XCTAssertEqual(rpm.unit, .rpm)
        XCTAssertEqual(rpm.range, 0...8000)
        XCTAssertEqual(rpm.redline, 6500)
    }

    func testIngestUpdatesOnlyTheTargetSignal() async throws {
        let bus = try makeBus()
        let rpm = try XCTUnwrap(bus.signal(.rpm))
        let coolant = try XCTUnwrap(bus.signal(.coolantTemp))

        bus.ingest(id: .rpm, value: 3200)

        XCTAssertEqual(rpm.value, 3200)
        XCTAssertEqual(rpm.sampleCount, 1)
        // The unrelated signal is untouched — the property-level granularity the
        // whole design depends on.
        XCTAssertEqual(coolant.sampleCount, 0)
        XCTAssertNil(coolant.updatedAt)
    }

    /// Boost has no PID on this engine; it must behave like a normal signal once
    /// both of its inputs have reported.
    func testDerivedBoostIsComputedFromItsInputs() async throws {
        let bus = try makeBus()
        let boost = try XCTUnwrap(bus.signal(.boost))

        bus.ingest(id: .map, value: 180)
        bus.ingest(id: .baro, value: 101)

        XCTAssertEqual(boost.value, 79, accuracy: 0.001)
        XCTAssertNotNil(boost.updatedAt)
    }

    /// Publishing a derived value from a default-zero input would be confidently
    /// wrong — boost would read as full vacuum before the first baro sample.
    func testDerivedSignalWaitsForAllInputs() async throws {
        let bus = try makeBus()
        let boost = try XCTUnwrap(bus.signal(.boost))

        bus.ingest(id: .map, value: 180)

        XCTAssertNil(boost.updatedAt)
        XCTAssertTrue(boost.isStale())
    }

    func testDerivedBoostClampsAtIdle() async throws {
        let bus = try makeBus()
        let boost = try XCTUnwrap(bus.signal(.boost))

        bus.ingest(id: .baro, value: 101)
        bus.ingest(id: .map, value: 34)   // manifold in vacuum at idle

        XCTAssertEqual(boost.value, 0)
    }

    func testDerivedSignalRecomputesOnEachInputChange() async throws {
        let bus = try makeBus()
        let boost = try XCTUnwrap(bus.signal(.boost))

        bus.ingest(id: .baro, value: 101)
        bus.ingest(id: .map, value: 150)
        XCTAssertEqual(boost.value, 49, accuracy: 0.001)

        bus.ingest(id: .map, value: 200)
        XCTAssertEqual(boost.value, 99, accuracy: 0.001)
        XCTAssertEqual(boost.sampleCount, 2)
    }

    func testIngestingUnknownSignalIsIgnored() async throws {
        let bus = try makeBus()
        bus.ingest(id: "notASignal", value: 42)
        XCTAssertNil(bus.signal("notASignal"))
    }

    func testIngestSample() async throws {
        let bus = try makeBus()
        bus.ingest(SignalSample(id: .rpm, value: 2500, unit: .rpm))
        XCTAssertEqual(bus.signal(.rpm)?.value, 2500)
    }

    /// Switching vehicles is a data swap: signals the new profile lacks disappear.
    func testApplyingAnotherProfileRebuildsSignals() async throws {
        let store = try ProfileStore.bundled()
        let bus = SignalBus(profile: try store.resolve(id: "genesis-g70-2020-2.0t-awd"))
        XCTAssertNotNil(bus.signal(.oilTemp))
        XCTAssertNil(bus.signal(.maf))

        bus.apply(profile: try store.resolveBaseline())

        XCTAssertEqual(bus.profileID, ProfileStore.baselineID)
        // The baseline has no manufacturer oil-temp PID, but does have MAF.
        XCTAssertNil(bus.signal(.oilTemp))
        XCTAssertNotNil(bus.signal(.maf))
    }
}

/// The stack end to end: replayed adapter bytes become decoded, live signals.
@MainActor
final class EndToEndTests: XCTestCase {

    func testReplayedDriveFeedsTheSignalBus() async throws {
        let transport = ReplayTransport(fixture: .idlingEngine())
        let registry = AdapterRegistry()
        let driver = ELM327Driver(transport: transport,
                                  descriptor: registry.descriptor(forAdvertisedName: "IOS-Vlink"))
        try await driver.start()

        let profile = try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
        let bus = SignalBus(profile: profile)

        for id in [SignalID.rpm, .speed, .coolantTemp, .map, .baro, .oilTemp] {
            guard let definition = profile.definition(for: id) else { continue }
            let value = try await driver.read(definition)
            bus.ingest(id: id, value: value)
        }

        XCTAssertEqual(bus.signal(.rpm)?.value, 750)
        XCTAssertEqual(bus.signal(.speed)?.value, 0)
        XCTAssertEqual(bus.signal(.coolantTemp)?.value, 50)
        XCTAssertEqual(bus.signal(.oilTemp)?.value, 42)

        // Boost derives from MAP and baro without ever being requested.
        XCTAssertEqual(bus.signal(.boost)?.value, 0)      // idle: manifold in vacuum
        XCTAssertNotNil(bus.signal(.boost)?.updatedAt)

        XCTAssertFalse(try XCTUnwrap(bus.signal(.rpm)).isStale())
        await driver.stop()
    }
}

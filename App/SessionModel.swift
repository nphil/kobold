import Foundation
import Observation
import KoboldCore
import KoboldBLE
import KoboldLog

/// Cadences shared between the session and the views that animate its output.
///
/// The gauge animation duration must match the publish interval exactly. That
/// is the whole trick to smooth motion from sampled data: each new value is
/// interpolated over precisely the time until the next one arrives, so the
/// needle moves at constant velocity and never restarts mid-flight.
enum SessionTiming {
    /// How often decoded values reach the UI.
    ///
    /// Deliberately slower than the sampling loop. Values are read as fast as
    /// the adapter allows, but invalidating SwiftUI views faster than this buys
    /// nothing — nobody reads a number changing 20 times a second — while
    /// costing a full layout pass each time.
    static let publishInterval: TimeInterval = 0.1
}

/// Owns the live session: transport, driver, profile and signal bus.
///
/// The polling loop runs *off* the main actor. Decoding, transport round-trips
/// and the demo simulation are all real work, and running them on the main actor
/// puts them in direct competition with rendering — which shows up as a low
/// frame rate rather than as slow data. Only the published batch hops to main.
@MainActor
@Observable
final class SessionModel {

    enum Source: Equatable {
        case demo
        case adapter(String)

        var label: String {
            switch self {
            case .demo: return "Demo"
            case .adapter(let name): return name
            }
        }

        var isDemo: Bool { self == .demo }
    }

    private(set) var bus: SignalBus
    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var source: Source = .demo
    private(set) var profileName: String

    /// Set when a real connection attempt fails, so the UI can say why rather
    /// than silently sitting at "disconnected".
    private(set) var lastError: String?

    /// Measured end-to-end sample rate, shown because a dashboard that silently
    /// slows down is worse than one that admits it.
    private(set) var samplesPerSecond: Double = 0

    /// Signals the dashboard wants, in priority order.
    var requested: [SignalID] = [.rpm, .speed, .map, .baro, .coolantTemp, .oilTemp, .throttle, .moduleVoltage]

    private let profile: ResolvedProfile
    private var runTask: Task<Void, Never>?

    init() {
        // Degrades rather than refusing to launch: an unknown vehicle still
        // resolves against the standard OBD-II baseline, and a catalogue that
        // cannot be read at all leaves an empty profile with no signals.
        var resolved = ResolvedProfile(id: "empty", displayName: "No profile",
                                       signals: [:], derivedSignals: [:], knownAbsent: [:])
        if let store = try? ProfileStore.bundled() {
            if let specific = try? store.resolve(id: "genesis-g70-2020-2.0t-awd") {
                resolved = specific
            } else if let baseline = try? store.resolveBaseline() {
                resolved = baseline
            }
        }
        profile = resolved
        profileName = resolved.displayName
        bus = SignalBus(profile: resolved)
        Log.info(.session, "Profile resolved: \(resolved.displayName)")
    }

    // MARK: - Sessions

    func startDemo() {
        stop()
        lastError = nil
        source = .demo
        let definitions = orderedDefinitions()
        Log.info(.session, "Starting demo session with \(definitions.count) signals")
        runTask = Task { [weak self] in
            await self?.runDemo(definitions: definitions)
        }
    }

    func startAdapter() {
        stop()
        lastError = nil
        source = .adapter("Searching…")
        let definitions = orderedDefinitions()
        Log.info(.session, "Scanning for an adapter")
        runTask = Task { [weak self] in
            await self?.runAdapter(definitions: definitions)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        phase = .disconnected
        samplesPerSecond = 0
    }

    private func orderedDefinitions() -> [(SignalID, SignalDefinition)] {
        requested.compactMap { id in
            guard let definition = profile.definition(for: id) else { return nil }
            return (id, definition)
        }
    }

    // MARK: - Off-main session bodies
    //
    // `nonisolated` so the body runs on the generic executor rather than
    // inheriting the main actor from the caller.

    private nonisolated func runDemo(definitions: [(SignalID, SignalDefinition)]) async {
        var vehicle = DemoVehicle()
        let transport = ReplayTransport(fixture: vehicle.fixture())
        let driver = ELM327Driver(transport: transport, descriptor: .generic)

        await setPhase(.connecting)
        do {
            try await driver.start()
        } catch {
            Log.error(.session, "Demo session failed to start: \(error)")
            await setPhase(.failed("Demo session failed to start"))
            return
        }
        await setPhase(.ready)
        Log.info(.session, "Demo session ready")

        await pump(driver: driver, definitions: definitions, isDemo: true) { delta in
            vehicle.advance(by: delta)
            await transport.update(fixture: vehicle.fixture())
        }

        await driver.stop()
    }

    private nonisolated func runAdapter(definitions: [(SignalID, SignalDefinition)]) async {
        let registry = AdapterRegistry()

        // Which adapter this is cannot be known until one answers, so scanning
        // uses the union of every registered adapter's name and profile hints.
        let scanDescriptor = AdapterDescriptor(
            id: "scan",
            displayName: "Scanning",
            nameMatchHints: Array(Set(registry.descriptors.flatMap(\.nameMatchHints))),
            gattHints: registry.descriptors.flatMap(\.gattHints)
        )

        let transport = BLETransport(descriptor: scanDescriptor)

        await setPhase(.connecting)
        do {
            try await transport.connect()
        } catch {
            let message = Self.describe(error)
            Log.error(.transport, "Connect failed: \(message)")
            await setPhase(.failed("No adapter"))
            await setError(message)
            await setSource(.demo)
            return
        }

        let name = transport.adapterName ?? "Adapter"
        Log.info(.transport, "Connected to \(name)")
        await setSource(.adapter(name))

        let driver = ELM327Driver(transport: transport,
                                  descriptor: registry.descriptor(forAdvertisedName: name))

        await setPhase(.initialising)
        do {
            try await driver.start()
        } catch {
            Log.error(.elm327, "Initialisation failed on \(name): \(error)")
            await setPhase(.failed("Adapter did not respond"))
            await setError("Connected to \(name) but it did not complete initialisation. "
                           + "Check the adapter is seated and the ignition is on.")
            await transport.disconnect()
            return
        }

        let negotiated = await driver.negotiatedProtocol ?? "unknown"
        Log.info(.elm327, "Ready on \(name), protocol \(negotiated)")
        await setPhase(.ready)

        await pump(driver: driver, definitions: definitions, isDemo: false, tick: nil)

        await driver.stop()
    }

    /// The sampling loop.
    ///
    /// Reads as fast as the transport allows, then publishes one batch per
    /// `publishInterval`. Batching matters twice: it keeps SwiftUI invalidation
    /// at a rate a display can actually use, and it means one actor hop per pass
    /// instead of one per signal.
    private nonisolated func pump(driver: ELM327Driver,
                                  definitions: [(SignalID, SignalDefinition)],
                                  isDemo: Bool,
                                  tick: ((Double) async -> Void)?) async {
        var lastTime = ContinuousClock.now
        var windowStart = ContinuousClock.now
        var samplesInWindow = 0
        var consecutiveEmptyPasses = 0

        while !Task.isCancelled {
            let passStart = ContinuousClock.now
            let delta = Self.seconds(passStart - lastTime)
            lastTime = passStart

            if let tick { await tick(max(0, delta)) }

            var batch: [(SignalID, Double)] = []
            batch.reserveCapacity(definitions.count)

            for (id, definition) in definitions {
                guard !Task.isCancelled else { break }
                if let value = try? await driver.read(definition) {
                    batch.append((id, value))
                    samplesInWindow += 1
                }
            }

            if batch.isEmpty {
                consecutiveEmptyPasses += 1
                // A live session that stops answering entirely is a disconnect,
                // not a slow patch — this hardware sleeps and drops the link.
                if consecutiveEmptyPasses >= 10, !isDemo {
                    Log.error(.transport, "Adapter stopped responding after \(consecutiveEmptyPasses) empty passes")
                    await setPhase(.failed("Adapter stopped responding"))
                    await setError("The adapter stopped responding. It may have gone to sleep — "
                                   + "unplug it and plug it back in.")
                    break
                }
            } else {
                consecutiveEmptyPasses = 0
                await publish(batch)
            }

            let now = ContinuousClock.now
            if now - windowStart > .seconds(1) {
                let elapsed = Self.seconds(now - windowStart)
                let rate = elapsed > 0 ? Double(samplesInWindow) / elapsed : 0
                await setRate(rate)
                Log.debug(.session, "Sampling at \(Int(rate)) values/s")
                samplesInWindow = 0
                windowStart = now
            }

            // Hold the publish cadence: sleep off whatever the pass did not use.
            let spent = Self.seconds(ContinuousClock.now - passStart)
            let remaining = SessionTiming.publishInterval - spent
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    // MARK: - Main-actor mutations

    private func publish(_ batch: [(SignalID, Double)]) {
        let now = Date()
        for (id, value) in batch {
            bus.ingest(id: id, value: value, at: now)
        }
    }

    private func setPhase(_ newPhase: ConnectionPhase) { phase = newPhase }
    private func setError(_ message: String?) { lastError = message }
    private func setSource(_ newSource: Source) { source = newSource }
    private func setRate(_ rate: Double) { samplesPerSecond = rate }

    // MARK: - Helpers

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    private nonisolated static func describe(_ error: Error) -> String {
        guard let bleError = error as? BLETransport.BLEError else {
            return error.localizedDescription
        }
        switch bleError {
        case .bluetoothUnavailable(let reason):
            return reason
        case .noAdapterFound:
            return "No OBD-II adapter found. Check it is plugged in and the ignition is on."
        case .connectionFailed(let reason):
            return "Could not connect: \(reason)"
        case .serialProfileNotFound:
            return "That device does not expose a serial profile Kobold understands."
        case .notConnected:
            return "Not connected."
        }
    }
}

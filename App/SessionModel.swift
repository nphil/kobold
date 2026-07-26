import Foundation
import Observation
import KoboldCore
import KoboldBLE

/// Owns the live session: transport, driver, profile and signal bus.
///
/// The polling loop only requests signals the dashboard is actually showing.
/// Bandwidth to an ELM327 is the scarce resource — a naive one-PID-per-request
/// loop tops out around 7–8 reads a second — so spending it on gauges nobody is
/// looking at is the difference between a responsive tachometer and a laggy one.
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

    private var profile: ResolvedProfile
    private var runTask: Task<Void, Never>?

    init() {
        // Degrades rather than refusing to launch: an unknown vehicle still
        // resolves against the standard OBD-II baseline, and a catalogue that
        // cannot be read at all leaves an empty profile with no signals.
        //
        // Written as explicit branches because `??` is `rethrows`, so a throwing
        // expression on its right-hand side is rejected.
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
    }

    // MARK: - Sessions

    func startDemo() {
        stop()
        lastError = nil
        source = .demo
        runTask = Task { await runDemoSession() }
    }

    func startAdapter() {
        stop()
        lastError = nil
        source = .adapter("Searching…")
        runTask = Task { await runAdapterSession() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        phase = .disconnected
        samplesPerSecond = 0
    }

    private func runDemoSession() async {
        var vehicle = DemoVehicle()
        let transport = ReplayTransport(fixture: vehicle.fixture())
        let driver = ELM327Driver(transport: transport, descriptor: .generic)

        phase = .connecting
        do {
            try await driver.start()
        } catch {
            phase = .failed("Demo session failed to start")
            return
        }
        phase = .ready

        await poll(driver: driver) { delta in
            vehicle.advance(by: delta)
            await transport.update(fixture: vehicle.fixture())
        }

        await driver.stop()
    }

    private func runAdapterSession() async {
        let registry = AdapterRegistry()

        // Which adapter this is cannot be known until one answers, so scanning
        // uses the union of every registered adapter's name and profile hints.
        // Once connected, the descriptor is re-resolved from the advertised name
        // so the driver gets that model's timing and quirks.
        let scanDescriptor = AdapterDescriptor(
            id: "scan",
            displayName: "Scanning",
            nameMatchHints: Array(Set(registry.descriptors.flatMap(\.nameMatchHints))),
            gattHints: registry.descriptors.flatMap(\.gattHints)
        )

        let transport = BLETransport(descriptor: scanDescriptor)

        phase = .connecting
        do {
            try await transport.connect()
        } catch {
            phase = .failed("No adapter")
            lastError = describe(error)
            source = .demo
            return
        }

        let name = transport.adapterName ?? "Adapter"
        source = .adapter(name)

        let driver = ELM327Driver(transport: transport,
                                  descriptor: registry.descriptor(forAdvertisedName: name))

        phase = .initialising
        do {
            try await driver.start()
        } catch {
            phase = .failed("Adapter did not respond")
            lastError = "Connected to \(name) but it did not complete initialisation. "
                + "Check the adapter is seated and the ignition is on."
            await transport.disconnect()
            return
        }
        phase = .ready

        await poll(driver: driver, tick: nil)

        await driver.stop()
    }

    /// Shared polling loop.
    ///
    /// `tick` lets the demo session advance its simulated ECU in step with the
    /// reads; a real adapter has no equivalent because the car is the source of
    /// truth.
    private func poll(driver: ELM327Driver,
                      tick: (@Sendable (Double) async -> Void)? = nil) async {
        let interval: Duration = .milliseconds(50)
        var lastTime = ContinuousClock.now
        var samples = 0
        var window = ContinuousClock.now
        var consecutiveFailures = 0

        while !Task.isCancelled {
            let now = ContinuousClock.now
            let delta = seconds(from: now - lastTime)
            lastTime = now

            if let tick { await tick(max(0, delta)) }

            var succeededThisPass = false
            for id in requested {
                guard !Task.isCancelled else { break }
                guard let definition = profile.definition(for: id) else { continue }
                if let value = try? await driver.read(definition) {
                    bus.ingest(id: id, value: value)
                    samples += 1
                    succeededThisPass = true
                }
            }

            // A live session that stops answering entirely is a disconnect, not
            // a slow patch — this hardware sleeps and drops the link on its own.
            if succeededThisPass {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= 20, !source.isDemo {
                    phase = .failed("Adapter stopped responding")
                    lastError = "The adapter stopped responding. It may have gone to sleep — "
                        + "unplug it and plug it back in."
                    break
                }
            }

            if now - window > .seconds(1) {
                let elapsed = seconds(from: now - window)
                samplesPerSecond = elapsed > 0 ? Double(samples) / elapsed : 0
                samples = 0
                window = now
            }

            try? await Task.sleep(for: interval)
        }
    }

    private func seconds(from duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    private func describe(_ error: Error) -> String {
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

    /// Signals the active profile can produce, in a stable display order.
    var availableSignals: [SignalID] {
        requested.filter { bus.signal($0) != nil } + [.boost].filter { bus.signal($0) != nil }
    }
}

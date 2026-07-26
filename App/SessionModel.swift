import Foundation
import Observation
import KoboldCore

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
    }

    private(set) var bus: SignalBus
    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var source: Source = .demo
    private(set) var profileName: String

    /// Measured end-to-end sample rate, shown because a dashboard that silently
    /// slows down is worse than one that admits it.
    private(set) var samplesPerSecond: Double = 0

    /// Signals the dashboard wants, in priority order.
    var requested: [SignalID] = [.rpm, .speed, .map, .baro, .coolantTemp, .oilTemp, .throttle, .moduleVoltage]

    private var profile: ResolvedProfile
    private var driver: ELM327Driver?
    private var transport: ReplayTransport?
    private var runTask: Task<Void, Never>?

    init() {
        // Falls back to the standard OBD-II baseline if the bundled catalogue
        // cannot be read, so the app still runs rather than refusing to launch.
        let resolved: ResolvedProfile
        do {
            let store = try ProfileStore.bundled()
            resolved = (try? store.resolve(id: "genesis-g70-2020-2.0t-awd"))
                ?? (try store.resolveBaseline())
        } catch {
            resolved = ResolvedProfile(id: "empty", displayName: "No profile",
                                       signals: [:], derivedSignals: [:], knownAbsent: [:])
        }
        profile = resolved
        profileName = resolved.displayName
        bus = SignalBus(profile: resolved)
    }

    func startDemo() {
        stop()
        source = .demo
        runTask = Task { await runDemoSession() }
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

        self.transport = transport
        self.driver = driver

        phase = .connecting
        do {
            try await driver.start()
        } catch {
            phase = .failed("Demo session failed to start")
            return
        }
        phase = .ready

        let tick: Duration = .milliseconds(50)
        var lastTime = ContinuousClock.now
        var samples = 0
        var window = ContinuousClock.now

        while !Task.isCancelled {
            let now = ContinuousClock.now
            let delta = Double((now - lastTime).components.attoseconds) / 1e18
                + Double((now - lastTime).components.seconds)
            lastTime = now

            vehicle.advance(by: max(0, delta))
            await transport.update(fixture: vehicle.fixture())

            for id in requested {
                guard !Task.isCancelled else { break }
                guard let definition = profile.definition(for: id) else { continue }
                if let value = try? await driver.read(definition) {
                    bus.ingest(id: id, value: value)
                    samples += 1
                }
            }

            // Report the achieved rate roughly once a second.
            if now - window > .seconds(1) {
                let seconds = Double((now - window).components.seconds)
                    + Double((now - window).components.attoseconds) / 1e18
                samplesPerSecond = seconds > 0 ? Double(samples) / seconds : 0
                samples = 0
                window = now
            }

            try? await Task.sleep(for: tick)
        }

        await driver.stop()
    }

    /// Signals the active profile can produce, in a stable display order.
    var availableSignals: [SignalID] {
        requested.filter { bus.signal($0) != nil } + [.boost].filter { bus.signal($0) != nil }
    }
}

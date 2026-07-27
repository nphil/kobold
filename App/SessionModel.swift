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
        /// No source at all — nothing has been started, or the last attempt
        /// failed. Distinct from `.demo` on purpose: falling back to a "Demo"
        /// label after a failed connection reads as though synthetic data were
        /// flowing, when in fact nothing is.
        case none
        case demo
        case adapter(String)

        var label: String {
            switch self {
            case .none: return "Not connected"
            case .demo: return "Demo"
            case .adapter(let name): return name
            }
        }

        var isDemo: Bool { self == .demo }
    }

    private(set) var bus: SignalBus
    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var source: Source = .none
    private(set) var profileName: String

    /// Set when a real connection attempt fails, so the UI can say why rather
    /// than silently sitting at "disconnected".
    private(set) var lastError: String?

    /// Measured end-to-end sample rate, shown because a dashboard that silently
    /// slows down is worse than one that admits it.
    private(set) var samplesPerSecond: Double = 0

    /// What the car declared it supports, from the last capability read.
    ///
    /// Kept rather than discarded after filtering: the bitmask is the only
    /// authoritative answer to "is this app missing anything on my car", and
    /// throwing it away meant asking the question every connection and never
    /// showing anyone the answer.
    private(set) var capability: VehicleCapability?

    /// Signals the dashboard wants, in priority order.
    ///
    /// Set by the dashboard from its own layout rather than fixed here. A card
    /// nobody can see costs a round trip on every pass, and — worse — a card
    /// somebody *can* see that was never on this list sat blank forever.
    private(set) var requested: [SignalID] = []

    /// The full profile for this vehicle, before the car has had its say.
    ///
    /// Kept alongside `activeProfile` because the capability report needs to
    /// know what Kobold defines *and* what the car answered; narrowing this one
    /// would make the two halves the same and the report empty.
    private let profile: ResolvedProfile

    /// The profile as it applies to this particular car — the full profile
    /// until the supported-PID bitmask says otherwise. Everything the UI offers
    /// comes from here.
    private var activeProfile: ResolvedProfile
    private var runTask: Task<Void, Never>?

    /// Incremented by `stop()`. Every write into this model carries the
    /// generation it was produced for, and writes from an older one are
    /// dropped.
    ///
    /// Cancelling a task does not stop work already in flight: an abandoned
    /// adapter attempt sits inside a 12-second scan and then resumes and writes
    /// `phase`, `lastError` and `source` over whatever session replaced it — so
    /// a working demo would flip to "No adapter" with live data still arriving.
    private var generation = 0

    /// The transport the running session owns, so `stop()` can actually reach
    /// it. It is created inside a detached task, and without a reference here
    /// nothing could tear down an in-flight scan.
    private var activeTransport: (any OBDTransport)?

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
        activeProfile = resolved
        profileName = resolved.displayName
        bus = SignalBus(profile: resolved)
        Log.info(.session, "Profile resolved: \(resolved.displayName)")
    }

    // MARK: - Sessions

    func startDemo() {
        stop()
        lastError = nil
        source = .demo
        let generation = self.generation
        Log.info(.session, "Starting demo session with \(requested.count) signals")
        runTask = Task { [weak self] in
            await self?.runDemo(generation: generation)
        }
    }

    func startAdapter() {
        stop()
        lastError = nil
        source = .adapter("Searching…")
        let generation = self.generation
        Log.info(.session, "Scanning for an adapter")
        runTask = Task { [weak self] in
            await self?.runAdapter(generation: generation)
        }
    }

    func stop() {
        generation &+= 1
        runTask?.cancel()
        runTask = nil

        // Cancelling the task is not enough on its own — CoreBluetooth keeps
        // scanning until someone tells it to stop.
        if let transport = activeTransport {
            activeTransport = nil
            Task { await transport.disconnect() }
        }

        phase = .disconnected
        samplesPerSecond = 0
        // Whatever was on screen came from a source that no longer exists.
        // Leaving it there means the dashboard keeps asserting a speed and an
        // rpm that are not true, which is exactly the wrong failure mode for a
        // screen glanced at while driving.
        bus.resetReadings()
    }

    private func orderedDefinitions() -> [(SignalID, SignalDefinition)] {
        requested.compactMap { id in
            guard let definition = activeProfile.definition(for: id) else { return nil }
            return (id, definition)
        }
    }

    /// Sets what to poll, in priority order.
    ///
    /// The dashboard is the authority: polling something nothing displays wastes
    /// a round trip on every pass, and displaying something nothing polls is a
    /// tile that never fills in. Ordering is kept because the loop reads in
    /// order and the first card is the one being looked at.
    func request(_ ids: [SignalID]) {
        var wanted: [SignalID] = []
        var seen: Set<SignalID> = []

        // A derived signal is not itself readable — what has to be on the wire
        // is whatever it computes from.
        func add(_ id: SignalID) {
            guard seen.insert(id).inserted else { return }
            if let derived = activeProfile.derivedSignals[id] {
                derived.dependencies.forEach(add)
            } else if activeProfile.signals[id] != nil {
                wanted.append(id)
            }
        }
        ids.forEach(add)

        guard wanted != requested else { return }
        requested = wanted
        Log.debug(.session, "Polling set is now \(wanted.map(\.rawValue).joined(separator: ", "))")
    }

    // MARK: - Off-main session bodies
    //
    // `nonisolated` so the body runs on the generic executor rather than
    // inheriting the main actor from the caller.

    private nonisolated func runDemo(generation: Int) async {
        var vehicle = DemoVehicle()
        let transport = ReplayTransport(fixture: vehicle.fixture())
        let driver = ELM327Driver(transport: transport, descriptor: .generic)

        await setPhase(.connecting, generation: generation)
        do {
            try await driver.start()
        } catch {
            Log.error(.session, "Demo session failed to start: \(error)")
            await setPhase(.failed("Demo session failed to start"), generation: generation)
            return
        }
        await setPhase(.ready, generation: generation)
        Log.info(.session, "Demo session ready")

        // The demo car answers the capability question like any other, so it
        // gets narrowed like any other. Exempting it would mean the one mode
        // anybody can try without a car is the one that shows dead signals.
        await discoverCapability(using: driver, generation: generation)

        await pump(driver: driver, isDemo: true, generation: generation) { delta in
            vehicle.advance(by: delta)
            await transport.update(fixture: vehicle.fixture())
        }

        await driver.stop()
    }

    private nonisolated func runAdapter(generation: Int) async {
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
        // Handed to the model before connecting, so `stop()` can tear down a
        // scan that is still in flight. Registering it afterwards would leave
        // the 12-second scan window — the one that actually needs cancelling —
        // completely unreachable.
        await adopt(transport: transport, generation: generation)

        await setPhase(.connecting, generation: generation)
        do {
            try await transport.connect()
        } catch {
            let message = Self.describe(error)
            Log.error(.transport, "Connect failed: \(message)")
            await setPhase(.failed("No adapter"), generation: generation)
            await setError(message, generation: generation)
            // Not `.demo`: nothing is running, and labelling it "Demo" would
            // imply data is flowing when the screen is empty.
            await setSource(.none, generation: generation)
            return
        }

        let name = transport.adapterName ?? "Adapter"
        Log.info(.transport, "Connected to \(name)")
        await setSource(.adapter(name), generation: generation)

        let driver = ELM327Driver(transport: transport,
                                  descriptor: registry.descriptor(forAdvertisedName: name),
                                  preferredProtocol: Self.rememberedProtocol(for: name))

        await setPhase(.initialising, generation: generation)
        do {
            try await driver.start()
        } catch {
            let description = String(describing: error)
            Log.error(.elm327, "Initialisation failed on \(name): \(description)")
            await setPhase(.failed(Self.initFailurePhase(error)), generation: generation)
            await setError(Self.describeInitFailure(error, adapter: name), generation: generation)
            await transport.disconnect()
            return
        }

        let resolved = await driver.negotiatedProtocol
        Self.remember(protocol: resolved, for: name)

        let negotiated = resolved ?? "unknown"
        Log.info(.elm327, "Ready on \(name), protocol \(negotiated)")
        await setPhase(.ready, generation: generation)

        // Ask the car what it answers, once, instead of discovering it by
        // requesting PIDs that will never reply — every pass, forever. The
        // bitmask this reads is already implied by the 0100 reply that
        // negotiated the protocol a moment ago.
        await discoverCapability(using: driver, generation: generation)

        await pump(driver: driver, isDemo: false, generation: generation, tick: nil)

        await driver.stop()
    }

    /// The sampling loop.
    ///
    /// Reads as fast as the transport allows, then publishes one batch per
    /// `publishInterval`. Batching matters twice: it keeps SwiftUI invalidation
    /// at a rate a display can actually use, and it means one actor hop per pass
    /// instead of one per signal.
    private nonisolated func pump(driver: ELM327Driver,
                                  isDemo: Bool,
                                  generation: Int,
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

            // Re-read every pass rather than captured once, so adding a card in
            // edit mode starts filling it in without dropping the connection.
            let definitions = await activeDefinitions(generation: generation)
            guard !definitions.isEmpty else {
                // Nothing on the dashboard is not a failure to report — it is a
                // dashboard with nothing on it.
                try? await Task.sleep(for: .seconds(SessionTiming.publishInterval))
                continue
            }

            var batch: [(SignalID, Double)] = []
            batch.reserveCapacity(definitions.count)

            // Failures are collected rather than discarded. `try?` here meant a
            // session could fail with every single read erroring and no record
            // of which signal, or why — the same blind spot the init sequence
            // had, one layer further in.
            var failures: [(SignalID, Error)] = []

            for (id, definition) in definitions {
                guard !Task.isCancelled else { break }
                do {
                    let value = try await driver.read(definition)
                    batch.append((id, value))
                    samplesInWindow += 1
                } catch {
                    failures.append((id, error))
                }
            }

            if batch.isEmpty {
                consecutiveEmptyPasses += 1

                // The first pass and the decisive one, and nothing between: a
                // stuck session repeats the same line ten times a second, and
                // the remote log is rate-limited.
                if consecutiveEmptyPasses == 1 {
                    Log.warning(.elm327, "Nothing answered — \(ReadFailureSummary.describe(failures))")
                }

                if consecutiveEmptyPasses >= 10, !isDemo {
                    Log.error(.elm327, "No signal answered in \(consecutiveEmptyPasses) passes — "
                              + ReadFailureSummary.describe(failures))
                    await setPhase(.failed(Self.emptySessionPhase(failures)), generation: generation)
                    await setError(Self.describeEmptySession(failures), generation: generation)
                    break
                }
            } else {
                consecutiveEmptyPasses = 0
                await publish(batch, generation: generation)
            }

            let now = ContinuousClock.now
            if now - windowStart > .seconds(1) {
                let elapsed = Self.seconds(now - windowStart)
                let rate = elapsed > 0 ? Double(samplesInWindow) / elapsed : 0
                await setRate(rate, generation: generation)
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

    private func publish(_ batch: [(SignalID, Double)], generation: Int) {
        // Without this a final in-flight batch can repopulate the gauges
        // immediately after `stop()` cleared them.
        guard isCurrent(generation) else { return }
        let now = Date()
        for (id, value) in batch {
            bus.ingest(id: id, value: value, at: now)
        }
    }

    // Each of these drops writes from a superseded run. See `generation`.
    private func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    private func setPhase(_ newPhase: ConnectionPhase, generation: Int) {
        guard isCurrent(generation) else { return }
        phase = newPhase
    }

    private func setError(_ message: String?, generation: Int) {
        guard isCurrent(generation) else { return }
        lastError = message
    }

    private func setSource(_ newSource: Source, generation: Int) {
        guard isCurrent(generation) else { return }
        source = newSource
    }

    private func setRate(_ rate: Double, generation: Int) {
        guard isCurrent(generation) else { return }
        samplesPerSecond = rate
    }

    private func recordCapability(supported: Set<UInt8>, generation: Int) {
        guard isCurrent(generation) else { return }
        capability = VehicleCapability(supported: supported, profile: profile)

        let narrowed = profile.restricted(toReportedPIDs: supported)

        // A car that implements none of the profile's standard PIDs is far more
        // likely to be a misread bitmask than a car with no sensors, and acting
        // on it would empty the dashboard. Keep the full profile and say so.
        guard !narrowed.signals.isEmpty else {
            Log.warning(.session, "The bitmask claims this vehicle supports none of the "
                        + "profile's signals, which is implausible; keeping all of them")
            return
        }

        // Nothing dropped means the narrowed profile is the full one, so there
        // is nothing to apply. Returning early is not just an optimisation:
        // rebuilding the bus bumps its revision, which sends the dashboard back
        // to reload a layout that has not changed.
        let dropped = profile.allSignalIDs.subtracting(narrowed.allSignalIDs)
        guard !dropped.isEmpty else { return }

        Log.info(.session, "Hiding \(dropped.count) signal(s) this vehicle does not report: "
                 + dropped.map(\.rawValue).sorted().joined(separator: ", "))

        activeProfile = narrowed
        // Rebuilding the bus is what removes them from the picker, the default
        // layout and every gauge — one narrowing, inherited everywhere.
        bus.apply(profile: narrowed)
    }

    private func recordVehicleInfo(reportedPIDs: Set<UInt8>, generation: Int) {
        guard isCurrent(generation), capability != nil else { return }
        capability?.recordVehicleInfo(reportedPIDs: reportedPIDs)

    }

    private func recordModules(_ found: [ELM327Driver.ModuleIdentity], generation: Int) {
        guard isCurrent(generation), capability != nil else { return }

        capability?.recordModules(found.map {
            VehicleCapability.ModuleIdentity(key: $0.key, label: $0.label,
                                             header: $0.header, version: $0.version)
        })

    }

    /// Writes the whole coverage report to the log.
    ///
    /// The screen is not the only place this belongs. A capability read happens
    /// once, in a car, and the person reading it has better things to do than
    /// transcribe a list off a phone — so it goes where it can be read later.
    private func logCapabilityReport(generation: Int) {
        guard isCurrent(generation), let capability else { return }
        for line in CapabilityReport.lines(for: capability, profileName: profileName) {
            Log.info(.session, line)
        }
    }

    /// The same report, for sending on demand.
    var capabilityReportText: String? {
        guard let capability else { return nil }
        return CapabilityReport.lines(for: capability, profileName: profileName)
            .joined(separator: "\n")
    }

    /// Records the transport a run owns so `stop()` can tear it down.
    private func adopt(transport: any OBDTransport, generation: Int) {
        guard isCurrent(generation) else { return }
        activeTransport = transport
    }

    // MARK: - Helpers

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Supported signals

    /// Asks the car what it implements and narrows the app to that answer.
    ///
    /// Degrading to the full profile when the bitmask cannot be read is
    /// deliberate: not answering `0100`-style queries is a quirk of some clones,
    /// and it says nothing about whether the individual PIDs work. Being unable
    /// to ask is not evidence of a "no".
    private nonisolated func discoverCapability(using driver: ELM327Driver,
                                                generation: Int) async {
        guard let supported = try? await driver.discoverSupportedPIDs() else {
            Log.warning(.elm327, "Could not read the supported-PID bitmask; "
                        + "keeping every signal the profile defines")
            return
        }

        // Applied on the main actor, where the profile lives — the comparison
        // needs both halves and only one of them is available out here.
        await recordCapability(supported: supported, generation: generation)

        // A second, optional round trip. Mode 09 is the only other enumerable
        // mode, and a car or adapter that will not answer `0900` must still
        // leave the Mode 01 report intact — hence a separate try, not a
        // combined one that would lose both.
        if let info = try? await driver.discoverSupportedPIDs(mode: "09", maximumBanks: 2) {
            await recordVehicleInfo(reportedPIDs: info, generation: generation)
        } else {
            Log.info(.elm327, "No answer to the Mode 09 bitmask; vehicle information unknown")
        }

        await probeModules(using: driver, generation: generation)
        await logCapabilityReport(generation: generation)
    }

    /// Asks the modules the profile knows about whether they are fitted.
    ///
    /// Last, deliberately. It changes the adapter's header state, and doing that
    /// before the bitmask reads would put a header change between the app and
    /// the readings everything else depends on.
    private nonisolated func probeModules(using driver: ELM327Driver, generation: Int) async {
        let modules = await probeTargets()
        guard !modules.isEmpty else { return }

        let found = await driver.identifyModules(modules)
        await recordModules(found, generation: generation)
    }

    private func probeTargets() -> [(key: String, label: String, transmit: String, receive: String?)] {
        profile.probeableModules.map { entry in
            (key: entry.key,
             label: entry.header.label ?? entry.key,
             transmit: entry.header.transmit,
             receive: entry.header.receive)
        }
    }

    /// The signals to read this pass.
    ///
    /// Read per pass rather than captured at session start, so editing the
    /// dashboard changes what goes on the wire without a reconnect.
    private func activeDefinitions(generation: Int) -> [(SignalID, SignalDefinition)] {
        guard isCurrent(generation) else { return [] }
        return orderedDefinitions()
    }

    // MARK: - Diagnosing an empty session

    // Classification lives in KoboldCore (`ReadFailureSummary`) so it can be
    // tested; only the user-facing wording belongs here.

    private nonisolated static func emptySessionPhase(_ failures: [(SignalID, Error)]) -> String {
        ReadFailureSummary.allReportedNoData(failures) ? "No data from the car" : "Adapter stopped responding"
    }

    private nonisolated static func describeEmptySession(_ failures: [(SignalID, Error)]) -> String {
        if ReadFailureSummary.allReportedNoData(failures) {
            return "Connected and the protocol negotiated, but every reading came back "
                + "empty. The adapter is fine — the car is not sending anything. Start the "
                + "engine and try again; most values need a running engine, not just the "
                + "ignition."
        }
        return "The adapter stopped responding. It may have gone to sleep — "
            + "unplug it and plug it back in."
    }

    // MARK: - Remembered protocol

    // Negotiating the bus protocol from scratch is by far the slowest step in
    // connecting — the BLE link and the AT init together take under three
    // seconds, while an unassisted `ATSP0` search can take tens. The answer
    // never changes for a given car, so it is worth exactly one round trip to
    // learn and then never pay for again.
    //
    // Keyed by adapter name rather than stored globally: plugging a different
    // dongle into a different car must not inherit the wrong protocol. Being
    // wrong is cheap anyway — the driver applies it with the auto-fallback
    // prefix, so a stale value costs one short timeout, not a failure.

    // `nonisolated` like its callers: static members of a `@MainActor` type
    // inherit that isolation, so without this the two accessors below cannot
    // reach it from the off-main session body.
    private nonisolated static func protocolKey(for adapter: String) -> String {
        "protocol.\(adapter)"
    }

    private nonisolated static func rememberedProtocol(for adapter: String) -> String? {
        let stored = UserDefaults.standard.string(forKey: protocolKey(for: adapter))
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    private nonisolated static func remember(protocol negotiated: String?, for adapter: String) {
        guard let negotiated, !negotiated.isEmpty else { return }
        UserDefaults.standard.set(negotiated, forKey: protocolKey(for: adapter))
    }

    /// Turns an init failure into advice the user can act on.
    ///
    /// These two failures look identical from the outside — the BLE link is up
    /// and no data arrives — but they need opposite responses, so they must not
    /// share a message. Telling someone to check their ignition when the real
    /// fault is the adopted GATT characteristic pair sends them to the car for
    /// nothing.
    private nonisolated static func describeInitFailure(_ error: Error, adapter: String) -> String {
        switch error as? ELM327Error {
        case .adapterSilent:
            return "Connected to \(adapter) over Bluetooth, but it never answered a "
                + "single command. That points at the adapter rather than the car — "
                + "unplug it, wait a few seconds and re-seat it. If it keeps happening, "
                + "this model exposes a serial profile Kobold picked wrongly; the "
                + "details are in Diagnostics."

        case .protocolNegotiationFailed:
            return "\(adapter) is responding, but the car is not. Turn the ignition on "
                + "(engine running is most reliable) and try again — most data needs a "
                + "live ECU, not just power at the port."

        default:
            return "Connected to \(adapter) but it did not complete initialisation. "
                + "Check the adapter is seated and the ignition is on."
        }
    }

    /// Short form for the status pill.
    private nonisolated static func initFailurePhase(_ error: Error) -> String {
        switch error as? ELM327Error {
        case .adapterSilent: return "Adapter silent"
        case .protocolNegotiationFailed: return "Car not responding"
        default: return "Adapter did not respond"
        }
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

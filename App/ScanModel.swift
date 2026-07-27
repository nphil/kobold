import Foundation
import Observation
import KoboldCore
import KoboldLog

/// Sweeps a module's data identifiers, looking for readings nobody has
/// published an address for.
///
/// The factory tool shows live radar and camera data over this same port using
/// these same services, so the data exists; only the addresses are undocumented.
/// This is the search for them.
///
/// Two things make it worth running rather than guessing. Every refusal is
/// recorded with its reason, so "nothing found" can be told apart from
/// "everything is locked" — different findings with different next steps. And
/// progress persists, so an hour of sitting still is never lost to a dropped
/// connection and never has to be repeated.
@MainActor
@Observable
final class ScanModel {

    struct Target: Identifiable, Sendable {
        let key: String
        let label: String
        let transmit: String
        let receive: String?
        var id: String { key }
    }

    /// The published snapshot, refreshed a few times a second.
    ///
    /// Separate from the working copy because a sweep records tens of
    /// thousands of results and every write to an observed property invalidates
    /// the view that reads it. Publishing each one turned a background task
    /// into sixty thousand layout passes — which is what a 994 ms frame in the
    /// logs was.
    private(set) var progress = ScanProgress()

    /// The hot copy. Written per identifier, read by nothing that draws.
    @ObservationIgnored private var working = ScanProgress()

    private(set) var isRunning = false
    private(set) var currentTarget: String?
    private(set) var lastMessage: String?

    /// Live position, so a long run visibly moves rather than sitting on a
    /// percentage that changes once a minute.
    private(set) var currentService: UInt8?
    private(set) var currentIdentifier: UInt32?
    private(set) var ratePerSecond: Double = 0
    private(set) var elapsed: TimeInterval = 0

    private var task: Task<Void, Never>?
    private var startedAt: Date?
    private var countAtStart = 0
    private var lastPublish: Date?

    /// Identifiers covered since the last save. An instance property rather
    /// than a local: the sweep reports results through a concurrent closure,
    /// and a captured `var` mutated from there is a data race the compiler
    /// rightly refuses.
    private var sinceSave = 0

    /// Runs of `Service not supported`, for the same reason `sinceSave` is a
    /// property: the sweep reports through a concurrent closure.
    private var serviceRefusals = 0

    /// How many identical "this service does not exist" refusals are enough.
    ///
    /// Three rather than one because a single reply can be a stale one, and
    /// abandoning a whole service on a desynchronised read would be the same
    /// false negative this scanner exists to avoid — in the other direction.
    private static let refusalsBeforeGivingUp = 3

    /// Service 21 is one byte, so 256 addresses — small enough to always finish.
    /// Service 22 is two bytes and is where the long run goes.
    static let services: [(code: UInt8, label: String, count: UInt32)] = [
        (0x21, "Service 21", 0x100),
        (0x22, "Service 22", 0x1_0000),
    ]

    func load(from data: Data) {
        guard let stored = ScanProgress.decoded(from: data) else { return }
        working = stored
        progress = stored
    }

    func encoded() -> Data { (try? working.encoded()) ?? Data() }

    func reset() {
        stop()
        working = ScanProgress()
        progress = ScanProgress()
        lastMessage = nil
    }

    /// Seconds left at the rate measured so far, once there is enough of a
    /// sample to mean anything.
    func estimatedSecondsRemaining(for target: Target) -> TimeInterval? {
        guard isRunning, ratePerSecond > 1 else { return nil }
        return Double(remaining(for: target)) / ratePerSecond
    }

    /// Everything found so far, as text — so a run that is stopped early is
    /// still worth having.
    ///
    /// Grouped under the module it came from, with the verdict for each service
    /// above it. An address list on its own is unreadable later: `220121 → 4B`
    /// means nothing without knowing which module answered, and nothing again
    /// without knowing how many addresses were asked to produce it. Both were
    /// on screen at the time and neither survived into the export.
    func findingsText(targets: [Target]) -> String? {
        let found = progress.findings
        guard !found.isEmpty else { return nil }

        var lines = ["Deep scan findings (\(found.count))"]
        let labels = Dictionary(targets.map { ($0.key, $0.label) }, uniquingKeysWith: { a, _ in a })

        // Modules in the order they were offered, then anything left over from
        // an older run whose module is no longer in the list — dropping those
        // would quietly lose findings.
        let known = targets.map(\.key)
        let leftover = found.map(\.module).filter { !known.contains($0) }
        for module in known + Array(Set(leftover)).sorted() {
            let mine = found.filter { $0.module == module }
            guard !mine.isEmpty else { continue }

            lines.append("")
            lines.append("\(labels[module] ?? module) — \(mine.count) found")
            for service in Self.services {
                let tried = progress.triedCount(module: module, service: service.code)
                guard tried > 0 else { continue }
                lines.append("  \(service.label): "
                             + progress.verdict(module: module, service: service.code))
            }
            lines += mine.map { "  " + $0.summary }
        }
        return lines.joined(separator: "\n")
    }

    /// Total addresses left across every service for one module.
    func remaining(for target: Target) -> Int {
        Self.services.reduce(0) { total, service in
            total + Int(service.count - progress.nextIdentifier(module: target.key,
                                                                service: service.code))
        }
    }

    /// Pushes the working copy to the view, at most a few times a second.
    private func publish(force: Bool = false) {
        let now = Date()
        if !force, let last = lastPublish, now.timeIntervalSince(last) < 0.25 { return }
        lastPublish = now
        progress = working

        if let startedAt {
            elapsed = now.timeIntervalSince(startedAt)
            let done = working.totalTried - countAtStart
            ratePerSecond = elapsed > 0.5 ? Double(done) / elapsed : 0
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        currentTarget = nil
        currentService = nil
        currentIdentifier = nil
        // Whatever was reached is kept: stopping early is an expected way to
        // use this, not a failure, and the next run continues from here.
        publish(force: true)
    }

    /// Runs the sweep. `onProgress` is called periodically so the caller can
    /// persist without this type knowing about storage.
    func start(target: Target,
               driver: ELM327Driver,
               onProgress: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        currentTarget = target.key
        lastMessage = nil

        startedAt = Date()
        countAtStart = working.totalTried
        lastPublish = nil
        elapsed = 0
        ratePerSecond = 0

        Log.info(.elm327, "Scanning \(target.label) (\(target.transmit)) — "
                 + "\(remaining(for: target)) identifiers to go")

        task = Task { [weak self] in
            for service in Self.services {
                if Task.isCancelled { break }
                await self?.sweep(target: target, service: service,
                                  driver: driver, onProgress: onProgress)
            }
            self?.finish(target: target)
        }
    }

    private func sweep(target: Target,
                       service: (code: UInt8, label: String, count: UInt32),
                       driver: ELM327Driver,
                       onProgress: @escaping @MainActor () -> Void) async {

        let start = working.nextIdentifier(module: target.key, service: service.code)
        guard start < service.count else { return }

        currentService = service.code
        let identifiers = Array(start..<service.count)
        sinceSave = 0
        serviceRefusals = 0

        await driver.scanIdentifiers(
            transmit: target.transmit,
            receive: target.receive,
            service: service.code,
            identifiers: identifiers
        ) { [weak self] identifier, outcome in
            guard let self else { return false }
            return await self.absorb(module: target.key, service: service.code,
                                     count: service.count,
                                     identifier: identifier, outcome: outcome,
                                     onProgress: onProgress)
        }
        onProgress()
    }

    private func absorb(module: String,
                        service: UInt8,
                        count: UInt32,
                        identifier: UInt32,
                        outcome: ProbeOutcome,
                        onProgress: @MainActor () -> Void) -> Bool {
        working.record(module: module, service: service,
                       identifier: identifier, outcome: outcome)
        currentIdentifier = identifier

        // A module that says "I do not implement this service" is answering
        // about the service, not the address. Asking the other 65,000 addresses
        // is twenty minutes spent re-reading the first reply.
        if case .refused(0x11) = outcome {
            serviceRefusals += 1
            if serviceRefusals >= Self.refusalsBeforeGivingUp {
                working.markUnsupported(module: module, service: service, count: count)
                Log.info(.elm327, "\(String(format: "Service %02X", service)) is not implemented "
                         + "on \(module) — skipping the rest of its address space")
                publish(force: true)
                onProgress()
                return false
            }
        } else {
            serviceRefusals = 0
        }

        // A hit is published at once. Waiting a quarter-second to show the one
        // thing anybody is watching for would be a strange economy.
        var interesting = false
        if case .data(let bytes) = outcome {
            let finding = ScanFinding(module: module, service: service,
                                      identifier: identifier, bytes: bytes, refusal: nil)
            Log.info(.elm327, "Found \(finding.summary)")
            interesting = true
        } else if case .refused(let code) = outcome, NegativeResponse.meansGated(code) {
            let finding = ScanFinding(module: module, service: service,
                                      identifier: identifier, bytes: nil, refusal: code)
            Log.info(.elm327, "Gated \(finding.summary)")
            interesting = true
        }
        publish(force: interesting)

        sinceSave += 1
        if sinceSave >= 64 {
            sinceSave = 0
            onProgress()
        }
        return !Task.isCancelled
    }

    private func finish(target: Target) {
        isRunning = false
        currentTarget = nil

        currentService = nil
        currentIdentifier = nil

        for service in Self.services {
            let verdict = working.verdict(module: target.key, service: service.code)
            Log.info(.elm327, "\(target.label) \(service.label): \(verdict)")
        }

        let found = working.findings(module: target.key)
        let readable = found.filter { $0.bytes != nil }
        let gated = found.filter(\.isGated)

        // The conclusion, stated rather than left to be inferred from counts.
        //
        // Silence first, because a sweep that heard nothing has established
        // nothing — and saying "this module has no data" on the back of it is
        // worse than saying nothing at all. It reads as a completed experiment
        // and ends the investigation on a result that was never collected.
        let deaf = working.inconclusive(module: target.key)
        if !deaf.isEmpty && readable.isEmpty && gated.isEmpty {
            // Rolled back so the module is not left looking scanned. An
            // inconclusive run must cost nothing but the time it took.
            for service in deaf { working.discard(module: target.key, service: service) }

            lastMessage = "No replies at all — not even a refusal. That is not a finding "
                + "about the module: nothing was heard from it. Reconnect and try again."
            Log.warning(.elm327, "Scan of \(target.label) heard nothing back; "
                        + "discarding the sweep as inconclusive rather than recording it "
                        + "as a negative result")
        } else if !readable.isEmpty {
            lastMessage = "\(readable.count) identifiers returned data."
        } else if !gated.isEmpty {
            lastMessage = "Nothing readable, but \(gated.count) refused in a way that means "
                + "they exist and are locked. A different diagnostic session would be needed."
        } else if Self.services.allSatisfy({
            working.isUnsupported(module: target.key, service: $0.code)
        }) {
            lastMessage = "This module implements neither service. There is no address "
                + "space here to search — whatever it publishes, it publishes another way."
        } else {
            lastMessage = "Every address refused with \"does not exist\". "
                + "This module genuinely has no data there."
        }
        publish(force: true)
        Log.info(.elm327, "Scan of \(target.label): \(lastMessage ?? "")")
    }
}

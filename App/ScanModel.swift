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

    private(set) var progress = ScanProgress()
    private(set) var isRunning = false
    private(set) var currentTarget: String?
    private(set) var lastMessage: String?

    private var task: Task<Void, Never>?

    /// Identifiers covered since the last save. An instance property rather
    /// than a local: the sweep reports results through a concurrent closure,
    /// and a captured `var` mutated from there is a data race the compiler
    /// rightly refuses.
    private var sinceSave = 0

    /// Service 21 is one byte, so 256 addresses — small enough to always finish.
    /// Service 22 is two bytes and is where the long run goes.
    static let services: [(code: UInt8, label: String, count: UInt32)] = [
        (0x21, "Service 21", 0x100),
        (0x22, "Service 22", 0x1_0000),
    ]

    func load(from data: Data) {
        guard let stored = ScanProgress.decoded(from: data) else { return }
        progress = stored
    }

    func encoded() -> Data { (try? progress.encoded()) ?? Data() }

    func reset() {
        stop()
        progress = ScanProgress()
        lastMessage = nil
    }

    /// Total addresses left across every service for one module.
    func remaining(for target: Target) -> Int {
        Self.services.reduce(0) { total, service in
            total + Int(service.count - progress.nextIdentifier(module: target.key,
                                                                service: service.code))
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        currentTarget = nil
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

        let start = progress.nextIdentifier(module: target.key, service: service.code)
        guard start < service.count else { return }

        let identifiers = Array(start..<service.count)
        sinceSave = 0

        await driver.scanIdentifiers(
            transmit: target.transmit,
            receive: target.receive,
            service: service.code,
            identifiers: identifiers
        ) { [weak self] identifier, outcome in
            guard let self else { return false }
            return await self.absorb(module: target.key, service: service.code,
                                     identifier: identifier, outcome: outcome,
                                     onProgress: onProgress)
        }
    }

    private func absorb(module: String,
                        service: UInt8,
                        identifier: UInt32,
                        outcome: ProbeOutcome,
                        onProgress: @MainActor () -> Void) -> Bool {
        progress.record(module: module, service: service,
                        identifier: identifier, outcome: outcome)

        if case .data(let bytes) = outcome {
            let finding = ScanFinding(module: module, service: service,
                                      identifier: identifier, bytes: bytes, refusal: nil)
            Log.info(.elm327, "Found \(finding.summary)")
        } else if case .refused(let code) = outcome, NegativeResponse.meansGated(code) {
            let finding = ScanFinding(module: module, service: service,
                                      identifier: identifier, bytes: nil, refusal: code)
            Log.info(.elm327, "Gated \(finding.summary)")
        }

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

        for service in Self.services {
            let verdict = progress.verdict(module: target.key, service: service.code)
            Log.info(.elm327, "\(target.label) \(service.label): \(verdict)")
        }

        let found = progress.findings(module: target.key)
        let readable = found.filter { $0.bytes != nil }
        let gated = found.filter(\.isGated)

        // The conclusion, stated rather than left to be inferred from counts.
        if !readable.isEmpty {
            lastMessage = "\(readable.count) identifiers returned data."
        } else if !gated.isEmpty {
            lastMessage = "Nothing readable, but \(gated.count) refused in a way that means "
                + "they exist and are locked. A different diagnostic session would be needed."
        } else {
            lastMessage = "Everything tried reported that it does not exist. "
                + "This module has no data at those addresses."
        }
        Log.info(.elm327, "Scan of \(target.label): \(lastMessage ?? "")")
    }
}

import Foundation
import Observation

/// One live vehicle signal.
///
/// Deliberately a small object per signal rather than fields on one big model.
/// With `@Observable`, a view establishes a dependency on exactly the objects it
/// reads, so a tachometer updating at 30 Hz re-evaluates only the tachometer's
/// body. Hanging every signal off a single model would make each RPM tick
/// invalidate every gauge on screen — the classic way to lose a frame budget
/// that only shows up once several gauges are live at once.
@Observable
@MainActor
public final class LiveSignal {
    public let id: SignalID
    public let label: String
    public let unit: Unit
    public let range: ClosedRange<Double>
    public let redline: Double?

    public private(set) var value: Double
    public private(set) var updatedAt: Date?
    /// Number of samples received, for diagnostics and rate display.
    public private(set) var sampleCount: Int = 0

    public init(id: SignalID,
                label: String,
                unit: Unit,
                range: ClosedRange<Double> = 0...100,
                redline: Double? = nil,
                initialValue: Double = 0) {
        self.id = id
        self.label = label
        self.unit = unit
        self.range = range
        self.redline = redline
        self.value = initialValue
    }

    public func update(value newValue: Double, at timestamp: Date = Date()) {
        value = newValue
        updatedAt = timestamp
        sampleCount += 1
    }

    /// Whether the reading has aged past `tolerance` — used to dim a gauge
    /// rather than let it show a stale number as though it were current.
    public func isStale(now: Date = Date(), tolerance: TimeInterval = 2.0) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > tolerance
    }

    /// Position within the signal's range, clamped to 0...1 — the value a gauge
    /// actually draws with.
    public var normalised: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    public var isOverRedline: Bool {
        guard let redline else { return false }
        return value >= redline
    }
}

/// Owns the live signals for the active vehicle profile.
///
/// Built from a `ResolvedProfile`, so which signals exist is decided by data, not
/// by the code. Derived signals are recomputed whenever their inputs change,
/// which is how a value with no PID of its own (boost, on a speed-density
/// engine) behaves exactly like a requested one from the UI's point of view.
@Observable
@MainActor
public final class SignalBus {

    /// Backing store is excluded from observation: views observe the individual
    /// `LiveSignal` objects, and tracking the dictionary as well would
    /// reintroduce the coarse invalidation this design exists to avoid.
    @ObservationIgnored
    private var signals: [SignalID: LiveSignal] = [:]

    @ObservationIgnored
    private var derived: [SignalID: DerivedSignal] = [:]

    /// Reverse index: input signal → derived signals that depend on it.
    @ObservationIgnored
    private var dependents: [SignalID: [SignalID]] = [:]

    public private(set) var profileID: String
    public private(set) var profileName: String

    public init(profile: ResolvedProfile) {
        self.profileID = profile.id
        self.profileName = profile.displayName
        load(profile: profile)
    }

    private func load(profile: ResolvedProfile) {
        signals.removeAll()
        derived.removeAll()
        dependents.removeAll()

        for (id, definition) in profile.signals {
            signals[id] = LiveSignal(
                id: id,
                label: definition.label,
                unit: definition.unit,
                range: (definition.minimum ?? 0)...(definition.maximum ?? 100),
                redline: definition.redline
            )
        }

        for (id, definition) in profile.derivedSignals {
            signals[id] = LiveSignal(
                id: id,
                label: definition.label,
                unit: definition.unit,
                range: (definition.minimum ?? 0)...(definition.maximum ?? 100),
                redline: definition.redline
            )
            derived[id] = definition
            for dependency in definition.dependencies {
                dependents[dependency, default: []].append(id)
            }
        }
    }

    /// Swaps the active vehicle. Signals are rebuilt from the new profile, so a
    /// gauge bound to a signal the new car lacks simply stops resolving.
    public func apply(profile: ResolvedProfile) {
        profileID = profile.id
        profileName = profile.displayName
        load(profile: profile)
    }

    public func signal(_ id: SignalID) -> LiveSignal? { signals[id] }

    public var availableSignals: [SignalID] { Array(signals.keys) }

    /// Applies a decoded reading and recomputes anything derived from it.
    public func ingest(id: SignalID, value: Double, at timestamp: Date = Date()) {
        signals[id]?.update(value: value, at: timestamp)
        recomputeDerived(dependingOn: id, at: timestamp)
    }

    public func ingest(_ sample: SignalSample) {
        ingest(id: sample.id, value: sample.value, at: sample.timestamp)
    }

    private func recomputeDerived(dependingOn id: SignalID, at timestamp: Date) {
        guard let affected = dependents[id] else { return }

        for derivedID in affected {
            guard let definition = derived[derivedID] else { continue }

            // A derived value is only meaningful once every input has a reading;
            // computing from a default-zero input would publish a confidently
            // wrong number (boost would read as full vacuum before the first
            // barometric sample arrived).
            var inputs: [SignalID: Double] = [:]
            var haveAllInputs = true
            for dependency in definition.dependencies {
                guard let source = signals[dependency], source.updatedAt != nil else {
                    haveAllInputs = false
                    break
                }
                inputs[dependency] = source.value
            }
            guard haveAllInputs, let value = definition.evaluate(using: inputs) else { continue }
            signals[derivedID]?.update(value: value, at: timestamp)
        }
    }
}

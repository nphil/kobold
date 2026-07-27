import Foundation
import KoboldCore

/// Which unit each signal is shown in, when there is a choice.
///
/// Per signal rather than one global "metric or imperial" switch, because the
/// choice is not consistent even within one person: boost in psi and coolant in
/// Celsius is an ordinary combination, and a single toggle cannot express it.
///
/// Stored as a plain dictionary of raw values so it survives a signal being
/// renamed or removed without migration — an entry for something that no longer
/// exists is simply never looked up.
struct UnitPreferences: Codable, Equatable {

    private var choices: [String: String] = [:]

    init() {}

    /// The unit to display `signal` in: the stored choice when it is still a
    /// sensible option, otherwise the unit the car reports.
    func unit(for id: SignalID, reported: KoboldCore.Unit) -> KoboldCore.Unit {
        guard let raw = choices[id.rawValue], let chosen = KoboldCore.Unit(rawValue: raw) else {
            return reported
        }
        // Validated against the current alternatives rather than trusted. A
        // profile edit can change a signal's unit under a stored preference,
        // and converting kilopascals to miles per hour would produce a number
        // that looks real.
        return reported.alternatives.contains(chosen) ? chosen : reported
    }

    mutating func set(_ unit: KoboldCore.Unit, for id: SignalID, reported: KoboldCore.Unit) {
        if unit == reported {
            // The default is absence, not an entry equal to the default. Keeps
            // the stored blob empty for the overwhelmingly common case.
            choices.removeValue(forKey: id.rawValue)
        } else {
            choices[id.rawValue] = unit.rawValue
        }
    }

    // MARK: - Persistence

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decoded(from data: Data) -> UnitPreferences {
        guard !data.isEmpty,
              let stored = try? JSONDecoder().decode(UnitPreferences.self, from: data)
        else { return UnitPreferences() }
        return stored
    }
}

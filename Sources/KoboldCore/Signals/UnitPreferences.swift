import Foundation

/// Which unit each signal is shown in, when there is a choice.
///
/// Per signal rather than one global "metric or imperial" switch, because the
/// choice is not consistent even within one person: boost in psi and coolant in
/// Celsius is an ordinary combination, and a single toggle cannot express it.
///
/// Stored as a plain dictionary of raw values so it survives a signal being
/// renamed or removed without migration — an entry for something that no longer
/// exists is simply never looked up.
public struct UnitPreferences: Codable, Equatable, Sendable {

    private var choices: [String: String] = [:]

    public init() {}

    /// The unit to display `signal` in: the stored choice when it is still a
    /// sensible option, otherwise the unit the car reports.
    public func unit(for id: SignalID, reported: Unit) -> Unit {
        guard let raw = choices[id.rawValue], let chosen = Unit(rawValue: raw) else {
            return reported
        }
        // Validated against the current alternatives rather than trusted. A
        // profile edit can change a signal's unit under a stored preference,
        // and converting kilopascals to miles per hour would produce a number
        // that looks real.
        return reported.alternatives.contains(chosen) ? chosen : reported
    }

    public mutating func set(_ unit: Unit, for id: SignalID, reported: Unit) {
        if unit == reported {
            // The default is absence, not an entry equal to the default. Keeps
            // the stored blob empty for the overwhelmingly common case.
            choices.removeValue(forKey: id.rawValue)
        } else {
            choices[id.rawValue] = unit.rawValue
        }
    }

    // MARK: - Persistence

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decoded(from data: Data) -> UnitPreferences {
        guard !data.isEmpty,
              let stored = try? JSONDecoder().decode(UnitPreferences.self, from: data)
        else { return UnitPreferences() }
        return stored
    }
}

/// A reading as the person looking at it asked to see it.
///
/// The conversion is three lines — look the unit up, convert, format — which is
/// why it ended up written out separately in every view that shows a reading,
/// and why the hero gauge was left behind when the unit picker arrived. Nothing
/// connected the copies, so a new surface inherited none of it and a surface
/// that had been missed looked exactly like one that was right.
///
/// One value type does not stop a surface being forgotten. It makes forgetting
/// visible: a view either builds one of these or plainly does not.
public struct SignalDisplay: Equatable, Sendable {

    /// The unit on screen.
    public let unit: Unit

    /// The unit the car reports in, which is what stored values are expressed
    /// in and what every conversion here starts from.
    private let reported: Unit

    public init(reported: Unit, id: SignalID, preferences: UnitPreferences) {
        self.reported = reported
        self.unit = preferences.unit(for: id, reported: reported)
    }

    /// Convenience for the views, which hold the preferences as stored `Data`.
    public init(reported: Unit, id: SignalID, preferences: Data) {
        self.init(reported: reported, id: id,
                  preferences: UnitPreferences.decoded(from: preferences))
    }

    public var symbol: String { unit.symbol }

    /// Whether there is more than one sensible way to show this reading.
    public var hasAlternatives: Bool { reported.hasAlternatives }

    /// The units offered for it, the car's own first.
    public var alternatives: [Unit] { reported.alternatives }

    /// A stored value, in the unit being shown.
    public func value(_ stored: Double) -> Double { reported.convert(stored, to: unit) }

    /// A stored range, in the unit being shown and still ordered.
    public func range(_ stored: ClosedRange<Double>) -> ClosedRange<Double> {
        reported.convert(stored, to: unit)
    }

    /// A stored value, converted and rendered at the precision the unit earns.
    public func format(_ stored: Double) -> String { unit.format(value(stored)) }

    /// An instrument's caption: the signal's name, with the unit appended
    /// unless the name already says it.
    ///
    /// A gauge showing "112" under the word SPEED is ambiguous in a way a
    /// number card is not, because the card prints its symbol beside the value
    /// and the dial has no room to. So the caption carries it — except on the
    /// tachometer, where "ENGINE RPM · rpm" would be absurd.
    ///
    /// Matched on whole words rather than as a substring. "System Voltage"
    /// contains a "v" and "Fuel Level" contains an "l", so a substring test
    /// silently drops the unit from exactly the readings whose symbol is one
    /// letter — the ones that need it stated most.
    public func caption(for name: String) -> String {
        guard !symbol.isEmpty else { return name }
        guard !name.isEmpty else { return symbol }

        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !words.contains(Substring(symbol.lowercased())) else { return name }
        return "\(name) · \(symbol)"
    }
}

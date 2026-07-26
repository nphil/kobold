import Foundation

/// One card on the dashboard: which signal, and how it is drawn.
public struct DashboardCard: Codable, Sendable, Equatable, Identifiable {

    /// How a card renders its signal.
    ///
    /// The same reading answers different questions depending on the form. A
    /// number tells you where you are, a dial tells you where you are within a
    /// range, and a trace tells you where you have been — which is the one that
    /// finds an intermittent fault.
    public enum Presentation: String, Codable, Sendable, CaseIterable {
        /// Radial dial. Costly to draw, so it earns its place on the hero slot
        /// or on a signal genuinely read as a position within a range.
        case gauge
        /// Value, unit, and a thin bar for position in range.
        case number
        /// Sparkline over the recent window.
        case graph

        public var label: String {
            switch self {
            case .gauge: return "Gauge"
            case .number: return "Number"
            case .graph: return "Graph"
            }
        }

        public var symbolName: String {
            switch self {
            case .gauge: return "gauge.with.needle"
            case .number: return "textformat.123"
            case .graph: return "chart.xyaxis.line"
            }
        }
    }

    public var signal: SignalID
    public var presentation: Presentation

    /// A signal appears at most once, so it identifies its own card. That is a
    /// deliberate constraint rather than an oversight: two cards showing the
    /// same number in different forms is clutter, and the dashboard's whole
    /// brief is to resist clutter.
    public var id: SignalID { signal }

    public init(signal: SignalID, presentation: Presentation = .number) {
        self.signal = signal
        self.presentation = presentation
    }
}

/// The user's arrangement of the dashboard.
///
/// Ordered, because position is the arrangement — the first card is the hero
/// and gets the large treatment, and the rest flow after it. Persisted as data
/// so it survives launches, and resolved against the active vehicle at load so
/// a layout built for one car degrades gracefully on another.
public struct DashboardLayout: Codable, Sendable, Equatable {

    /// Past this, nothing on the screen is legible at a glance, which is the
    /// only thing the dashboard is for. Adding more is refused rather than
    /// silently shrinking everything below readable.
    public static let maximumCards = 12

    public private(set) var cards: [DashboardCard]

    public init(cards: [DashboardCard] = []) {
        self.cards = Array(DashboardLayout.deduplicated(cards).prefix(Self.maximumCards))
    }

    public var isEmpty: Bool { cards.isEmpty }
    public var isFull: Bool { cards.count >= Self.maximumCards }
    public var signals: [SignalID] { cards.map(\.signal) }

    public func contains(_ signal: SignalID) -> Bool {
        cards.contains { $0.signal == signal }
    }

    // MARK: - Editing

    @discardableResult
    public mutating func add(_ signal: SignalID,
                             presentation: DashboardCard.Presentation = .number) -> Bool {
        guard !contains(signal), !isFull else { return false }
        cards.append(DashboardCard(signal: signal, presentation: presentation))
        return true
    }

    public mutating func remove(_ signal: SignalID) {
        cards.removeAll { $0.signal == signal }
    }

    public mutating func setPresentation(_ presentation: DashboardCard.Presentation,
                                         for signal: SignalID) {
        guard let index = cards.firstIndex(where: { $0.signal == signal }) else { return }
        cards[index].presentation = presentation
    }

    /// Moves the card at `source` so it sits at `destination`.
    ///
    /// Takes plain indices rather than SwiftUI's `IndexSet`/offset convention,
    /// because the offset form is off by one when dragging downwards and that
    /// asymmetry is a reliable source of bugs. The caller converts.
    public mutating func move(from source: Int, to destination: Int) {
        guard cards.indices.contains(source) else { return }
        let clamped = Swift.max(0, Swift.min(destination, cards.count - 1))
        guard clamped != source else { return }

        let card = cards.remove(at: source)
        cards.insert(card, at: clamped)
    }

    // MARK: - Resolution

    /// Drops cards whose signal this vehicle does not have.
    ///
    /// A layout outlives the car it was built on — a different profile, or the
    /// same profile after the supported-PID bitmask ruled a signal out. A card
    /// bound to a signal that cannot resolve would render as a permanent dash,
    /// which reads as a broken app rather than as an absent sensor.
    public func resolved(against available: Set<SignalID>) -> DashboardLayout {
        DashboardLayout(cards: cards.filter { available.contains($0.signal) })
    }

    /// A sensible arrangement for a vehicle whose signals are known.
    ///
    /// Ordered by what a driver looks at, not alphabetically or by PID number:
    /// engine speed leads and takes the hero slot, then road speed, then the
    /// pressures and temperatures that move slowly and are checked rather than
    /// watched.
    public static func standard(available: Set<SignalID>) -> DashboardLayout {
        let preferred: [(SignalID, DashboardCard.Presentation)] = [
            (.rpm, .gauge),
            (.speed, .number),
            (.boost, .graph),
            (.coolantTemp, .number),
            (.oilTemp, .number),
            (.throttle, .graph),
            (.moduleVoltage, .number),
        ]

        var layout = DashboardLayout()
        for (signal, presentation) in preferred where available.contains(signal) {
            layout.add(signal, presentation: presentation)
        }
        return layout
    }

    // MARK: - Persistence

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) -> DashboardLayout? {
        try? JSONDecoder().decode(DashboardLayout.self, from: data)
    }

    private static func deduplicated(_ cards: [DashboardCard]) -> [DashboardCard] {
        var seen: Set<SignalID> = []
        return cards.filter { seen.insert($0.signal).inserted }
    }

    // Decoding goes through the initialiser's invariants rather than around
    // them: persisted data is as capable of carrying duplicates or an
    // over-long list as anything else, particularly across versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(cards: try container.decode([DashboardCard].self, forKey: .cards))
    }
}

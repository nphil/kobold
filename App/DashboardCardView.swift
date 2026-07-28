import SwiftUI
import KoboldCore

/// One dashboard card, drawn according to its chosen presentation.
struct DashboardCardView: View {
    @Environment(\.theme) private var theme

    /// Written by the detail sheet. Read here so a unit chosen there applies
    /// wherever the signal appears, rather than only on the screen that set it.
    @AppStorage("unitPreferences") private var storedUnits = Data()

    let card: DashboardCard
    let signal: LiveSignal
    let isEditing: Bool

    /// How much of the past a sparkline shows. Short enough that the shape is
    /// about now rather than about the drive.
    private static let sparklineWindow: TimeInterval = 60

    /// Sparkline refresh, decoupled from arrivals for the same reason the
    /// detail chart is: redrawing on every sample ties card cost to transport
    /// throughput, which gets worse precisely when sampling gets faster.
    private static let refreshInterval: TimeInterval = 0.5

    @State private var trace: [SignalHistory.Point] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            switch card.presentation {
            case .number:
                value
                ScaleBar(fraction: signal.normalised,
                         redline: signal.redlineFraction,
                         isAlarming: signal.isOverRedline)
            case .graph:
                value
                SparklineView(points: trace, isAlarming: signal.isOverRedline)
                    .frame(maxWidth: .infinity, minHeight: 28)
            case .gauge:
                // A real dial, not a fallback. It drops the graduations, needle
                // and hub — those genuinely stop working at this diameter — and
                // keeps the one thing a dial does that a number cannot: show
                // position within a range without parsing digits.
                CompactGaugeView(signal: signal)
                    // Capped because the dial is square: uncapped it would grow
                    // with the column width and tower over the number cards
                    // beside it, and the dashboard has a fixed height to live
                    // within. 84pt still gives a ~22pt centre value and a
                    // ~10pt arc — comfortably legible at a glance.
                    .frame(maxWidth: .infinity, maxHeight: 84)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel(isAlarming: signal.isOverRedline && signal.hasReading)
        .opacity(signal.isStale() && !isEditing ? 0.45 : 1)
        // The third channel, after the numeral and the bezel. Here rather than
        // on the dashboard because this view already depends on this signal's
        // value — asking the dashboard which readings are alarming would make
        // the whole screen re-evaluate on every sample, which is exactly the
        // coarse invalidation the per-signal design exists to avoid.
        //
        // On the crossing only. A reading that sits past its limit would
        // otherwise buzz for as long as it stayed there.
        .sensoryFeedback(trigger: signal.isOverRedline) { was, now in
            now && !was ? .impact(weight: .heavy, intensity: 0.8) : nil
        }
        .task(id: card.presentation) {
            guard card.presentation == .graph else { return }
            await followTrace()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signal.label)
        .accessibilityValue(signal.hasReading
                            ? "\(display.format(signal.value)) \(display.symbol)"
                            : "No reading")
    }

    // MARK: - Pieces

    private var header: some View {
        Text(signal.label.uppercased())
            .font(KoboldType.label(10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
    }

    private var value: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if signal.hasReading {
                Text(display.format(signal.value))
                    .font(KoboldType.numeral(22))
                    .monospacedDigit()
                    // Expanded numerals are wider than rounded ones, and a
                    // four-digit reading in a two-column grid is exactly the
                    // case that would otherwise truncate.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(signal.isOverRedline ? theme.danger : theme.textPrimary)
            } else {
                Text("—")
                    .font(KoboldType.numeral(22))
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)
            }

            Text(display.symbol)
                .font(KoboldType.label(12))
                .foregroundStyle(theme.textTertiary)
        }
    }

    // MARK: - Data

    private func followTrace() async {
        refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.refreshInterval))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func refresh() {
        let cutoff = Date().timeIntervalSinceReferenceDate - Self.sparklineWindow
        // A card is a few dozen points wide at most; more is cost with nothing
        // on screen to show for it.
        trace = LTTB.downsample(signal.history.points(since: cutoff), to: 80)
    }

    /// This signal as the reader asked to see it.
    private var display: SignalDisplay {
        SignalDisplay(reported: signal.unit, id: signal.id, preferences: storedUnits)
    }
}

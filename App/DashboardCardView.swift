import SwiftUI
import KoboldCore

/// One dashboard card, drawn according to its chosen presentation.
struct DashboardCardView: View {
    @Environment(\.theme) private var theme

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
                rangeBar
            case .graph:
                value
                SparklineView(points: trace, isAlarming: signal.isOverRedline)
                    .frame(maxWidth: .infinity, minHeight: 28)
            case .gauge:
                // A dial inside a small card is illegible; the gauge treatment
                // belongs to the hero slot, so a card asking for one falls back
                // to the form that still reads at this size.
                value
                rangeBar
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 1)
        )
        .opacity(signal.isStale() && !isEditing ? 0.45 : 1)
        .task(id: card.presentation) {
            guard card.presentation == .graph else { return }
            await followTrace()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signal.label)
        .accessibilityValue(signal.hasReading
                            ? "\(signal.value.formatted(.number.precision(.fractionLength(decimals)))) \(signal.unit.symbol)"
                            : "No reading")
    }

    // MARK: - Pieces

    private var header: some View {
        Text(signal.label.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
    }

    private var value: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if signal.hasReading {
                Text(signal.value, format: .number.precision(.fractionLength(decimals)))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(signal.isOverRedline ? theme.danger : theme.textPrimary)
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)
            }

            Text(signal.unit.symbol)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var rangeBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.dialTrack)
                Capsule()
                    .fill(signal.isOverRedline ? theme.danger : theme.accent)
                    .frame(width: max(3, proxy.size.width * signal.normalised))
                    .animation(KoboldMotion.gauge, value: signal.value)
            }
        }
        .frame(height: 4)
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

    private var decimals: Int {
        switch signal.unit {
        case .volt: return 1
        default: return 0
        }
    }
}

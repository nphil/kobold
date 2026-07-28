import SwiftUI
import Charts
import KoboldCore

/// One signal, over time.
///
/// Reached by tapping a gauge or tile rather than living on the dashboard.
/// The dashboard is glanced at while driving and stays deliberately sparse;
/// history is something you look at when stopped, so it gets its own surface
/// with room to be legible. See docs/06.
struct SignalDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let signal: LiveSignal

    @State private var window: Window = .oneMinute
    @State private var points: [SignalHistory.Point] = []

    /// Shared with the dashboard, so a signal reads the same wherever it
    /// appears. Choosing psi here and still seeing kPa on the tile would be a
    /// setting that only half applies.
    @AppStorage("unitPreferences") private var storedUnits = Data()

    /// How much history the chart shows.
    ///
    /// A fixed visible window rather than an ever-growing axis: an
    /// append-forever chart is the documented way to make Swift Charts
    /// unresponsive, and a minute of a drive is what you actually want to read.
    enum Window: String, CaseIterable, Identifiable {
        case thirtySeconds = "30s"
        case oneMinute = "1m"
        case fiveMinutes = "5m"

        var id: String { rawValue }

        /// Spelled out, because a menu has room for words where the segmented
        /// control it replaced had room for two characters.
        var label: String {
            switch self {
            case .thirtySeconds: return "Last 30 seconds"
            case .oneMinute: return "Last minute"
            case .fiveMinutes: return "Last 5 minutes"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .thirtySeconds: return 30
            case .oneMinute: return 60
            case .fiveMinutes: return 300
            }
        }
    }

    /// Points to draw after downsampling.
    ///
    /// Well under the couple of thousand marks Swift Charts is comfortable
    /// with, and comfortably more than a phone's width in pixels — past that,
    /// extra points are cost with nothing on screen to show for them.
    private static let drawnPointLimit = 400

    /// Chart refresh rate, deliberately decoupled from the sample rate.
    ///
    /// Samples arrive whenever the adapter answers. Redrawing a few hundred
    /// marks on every arrival would tie chart cost to transport throughput,
    /// which is exactly backwards — so the chart pulls on its own clock and the
    /// history buffer stays unobserved.
    private static let refreshInterval: TimeInterval = 0.25

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                readout
                chart
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Fascia())
            .navigationTitle(signal.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    optionsMenu
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await follow() }
    }

    // MARK: - Pieces

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if signal.hasReading {
                Text(display.format(signal.value))
                    .font(KoboldType.numeral(44))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(signal.isOverRedline ? theme.danger : theme.textPrimary)
            } else {
                Text("—")
                    .font(KoboldType.numeral(44))
                    .foregroundStyle(theme.textTertiary)
            }

            Text(display.symbol)
                .font(KoboldType.label(17))
                .foregroundStyle(theme.textTertiary)

            Spacer(minLength: 0)

            statistics
        }
    }

    @ViewBuilder
    private var statistics: some View {
        if let low = points.map(\.value).min(), let high = points.map(\.value).max() {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(format(high)) max")
                Text("\(format(low)) min")
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(theme.textTertiary)
        }
    }

    @ViewBuilder
    private var chart: some View {
        if points.count < 2 {
            // Not an error — a session that has only just started genuinely has
            // nothing to plot yet, and an empty axis says that better than a
            // flat line through one point would.
            ContentUnavailableView("Collecting",
                                   systemImage: "chart.xyaxis.line",
                                   description: Text("A moment of data is needed before there is a shape to show."))
                .frame(maxHeight: .infinity)
        } else {
            Chart(points, id: \.time) { point in
                AreaMark(
                    x: .value("Time", Date(timeIntervalSinceReferenceDate: point.time)),
                    y: .value(signal.label, shown(point.value))
                )
                .foregroundStyle(
                    LinearGradient(colors: [theme.accent.opacity(0.35), theme.accent.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )

                LineMark(
                    x: .value("Time", Date(timeIntervalSinceReferenceDate: point.time)),
                    y: .value(signal.label, shown(point.value))
                )
                .foregroundStyle(theme.accent)
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(theme.hairline)
                    AxisValueLabel(format: .dateTime.minute().second())
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(theme.hairline)
                    AxisValueLabel().foregroundStyle(theme.textTertiary)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Both choices in one place, off the chart rather than under it.
    ///
    /// The segmented control that used to sit at the bottom spent a row of a
    /// small screen on something changed rarely, and left nowhere to put the
    /// second choice when one arrived.
    private var optionsMenu: some View {
        Menu {
            Picker("Window", selection: $window) {
                ForEach(Window.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            if display.hasAlternatives {
                Divider()
                Picker("Units", selection: unitBinding) {
                    ForEach(display.alternatives, id: \.self) { unit in
                        Text(unit.symbol).tag(unit)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Chart options")
        .onChange(of: window) { _, _ in refresh() }
    }

    // MARK: - Units

    private var preferences: UnitPreferences { UnitPreferences.decoded(from: storedUnits) }

    /// This signal as the reader asked to see it. Everything drawn goes through
    /// it, so the readout, the statistics and the chart cannot disagree — and
    /// it is the same type every other surface uses, so they cannot either.
    private var display: SignalDisplay {
        SignalDisplay(reported: signal.unit, id: signal.id, preferences: preferences)
    }

    private var unitBinding: Binding<KoboldCore.Unit> {
        Binding(
            get: { display.unit },
            set: { unit in
                var updated = preferences
                updated.set(unit, for: signal.id, reported: signal.unit)
                storedUnits = updated.encoded()
            }
        )
    }

    private func shown(_ value: Double) -> Double { display.value(value) }

    // MARK: - Data

    /// Y range: the signal's declared range, tightened to what actually
    /// happened. A coolant trace against a 0–150 axis is a flat line halfway up
    /// and tells you nothing about the ten degrees it moved.
    private var domain: ClosedRange<Double> {
        let values = points.map { shown($0.value) }
        guard let low = values.min(), let high = values.max() else {
            return display.range(signal.range)
        }
        guard high > low else {
            // A perfectly flat trace still needs a non-empty domain.
            return (low - 1)...(high + 1)
        }
        let padding = (high - low) * 0.12
        return (low - padding)...(high + padding)
    }

    private func refresh() {
        let cutoff = Date().timeIntervalSinceReferenceDate - window.seconds
        points = LTTB.downsample(signal.history.points(since: cutoff),
                                 to: Self.drawnPointLimit)
    }

    /// Pulls on a fixed clock for as long as the sheet is on screen.
    ///
    /// `.task` is cancelled on dismissal, so this stops when the view goes away
    /// rather than running for the rest of the session.
    private func follow() async {
        refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.refreshInterval))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func format(_ value: Double) -> String {
        display.format(value)
    }
}

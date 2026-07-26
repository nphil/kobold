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
                windowPicker
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            .navigationTitle(signal.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
                Text(signal.value, format: .number.precision(.fractionLength(decimals)))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(signal.isOverRedline ? theme.danger : theme.textPrimary)
            } else {
                Text("—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
            }

            Text(signal.unit.symbol)
                .font(.system(size: 17, weight: .medium, design: .rounded))
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
                    y: .value(signal.label, point.value)
                )
                .foregroundStyle(
                    LinearGradient(colors: [theme.accent.opacity(0.35), theme.accent.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )

                LineMark(
                    x: .value("Time", Date(timeIntervalSinceReferenceDate: point.time)),
                    y: .value(signal.label, point.value)
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

    private var windowPicker: some View {
        Picker("Window", selection: $window) {
            ForEach(Window.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: window) { _, _ in refresh() }
    }

    // MARK: - Data

    /// Y range: the signal's declared range, tightened to what actually
    /// happened. A coolant trace against a 0–150 axis is a flat line halfway up
    /// and tells you nothing about the ten degrees it moved.
    private var domain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else {
            return signal.range
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

    private var decimals: Int {
        switch signal.unit {
        case .volt: return 1
        default: return 0
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)))
    }
}

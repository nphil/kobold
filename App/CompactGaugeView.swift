import SwiftUI
import KoboldCore

/// A real dial, sized for a dashboard card.
///
/// Same grammar as the hero tachometer — 240° sweep from the same origin, the
/// same redline band, the same cobalt-into-amber live arc — so a card reads as
/// the same instrument seen smaller, not as a different widget.
///
/// What it drops is what stops working at this size, and only that: the
/// graduations, the needle, and the hub. Twenty tick marks across a 70-point
/// dial are a grey smudge, and a needle whose length is thirty points cannot
/// resolve the value more finely than the arc already does. What survives is
/// the thing a dial is actually for — **position within a range, read without
/// parsing digits** — which is precisely what a number card cannot do.
struct CompactGaugeView: View {
    @Environment(\.theme) private var theme

    /// Written by the detail sheet. Read here so a unit chosen there applies
    /// wherever the signal appears, rather than only on the screen that set it.
    @AppStorage("unitPreferences") private var storedUnits = Data()

    let signal: LiveSignal

    private var redlineFraction: Double? {
        guard let redline = signal.redline else { return nil }
        let span = signal.range.upperBound - signal.range.lowerBound
        guard span > 0 else { return nil }
        return min(1, max(0, (redline - signal.range.lowerBound) / span))
    }

    private var sweptAngle: Double {
        KoboldDial.startAngle + KoboldDial.sweep * signal.normalised
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            // Proportionally heavier than the hero's stroke: at this diameter a
            // scaled-down line disappears, and the arc is now carrying the
            // reading on its own without a needle to help.
            let stroke = side * 0.115

            ZStack {
                DialArc(start: KoboldDial.startAngle,
                        end: KoboldDial.startAngle + KoboldDial.sweep)
                    .stroke(theme.dialTrack,
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round))

                // Under the live arc, so a value past the limit covers it.
                if let redlineFraction {
                    DialArc(start: KoboldDial.startAngle + KoboldDial.sweep * redlineFraction,
                            end: KoboldDial.startAngle + KoboldDial.sweep)
                        .stroke(theme.danger.opacity(0.85),
                                style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                }

                if signal.hasReading {
                    DialArc(start: KoboldDial.startAngle,
                            end: max(KoboldDial.startAngle + 0.001, sweptAngle))
                        .stroke(
                            LinearGradient(
                                colors: signal.isOverRedline
                                    ? [theme.danger, theme.danger]
                                    : [theme.accentDim, theme.accent],
                                startPoint: .bottomLeading, endPoint: .topTrailing
                            ),
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                        )
                        .animation(KoboldMotion.gauge, value: signal.value)
                }

                readout(side: side)
            }
            .padding(stroke / 2)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)   // the card states label and value already
    }

    private func readout(side: CGFloat) -> some View {
        VStack(spacing: 0) {
            if signal.hasReading {
                Text(displayUnit.format(shown(signal.value)))
                    // Sized against the dial rather than fixed, so the value
                    // stays proportionate whatever the grid gives the card.
                    .font(.system(size: side * 0.26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(signal.isOverRedline ? theme.danger : theme.textPrimary)
            } else {
                Text("—")
                    .font(.system(size: side * 0.26, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
            }

            Text(displayUnit.symbol)
                .font(.system(size: side * 0.11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, side * 0.08)
        .allowsHitTesting(false)
    }

    /// The unit this signal is shown in, honouring the stored choice.
    private var displayUnit: KoboldCore.Unit {
        UnitPreferences.decoded(from: storedUnits)
            .unit(for: signal.id, reported: signal.unit)
    }

    private func shown(_ value: Double) -> Double {
        signal.unit.convert(value, to: displayUnit)
    }
}

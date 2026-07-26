import SwiftUI
import KoboldCore

/// The app's signature instrument.
///
/// Deliberately the same dial grammar as the app icon — 240° sweep, the same
/// graduation rhythm, the same cobalt-into-amber progression — so the mark on
/// the home screen and the gauge inside the app read as one identity rather
/// than two unrelated drawings.
///
/// Rendering is split by how often each layer changes. The dial and its
/// graduations go through `Canvas`, which draws immediate-mode and avoids
/// creating a view per tick; a stack of twenty tick views would cost far more
/// than one canvas. The parts that move — the live arc and the needle — are
/// `Shape`s, so SwiftUI interpolates them on the display's own cadence instead
/// of the view being rebuilt per frame.
struct TachometerView: View {
    @Environment(\.theme) private var theme

    let signal: LiveSignal
    var caption: String?

    /// Sweep geometry, shared with the icon.
    private let startAngle: Double = 150
    private let sweep: Double = 240

    private var redlineFraction: Double? {
        guard let redline = signal.redline else { return nil }
        let span = signal.range.upperBound - signal.range.lowerBound
        guard span > 0 else { return nil }
        return min(1, max(0, (redline - signal.range.lowerBound) / span))
    }

    private var needleAngle: Double { startAngle + sweep * signal.normalised }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let stroke = side * 0.075

            ZStack {
                // Track.
                DialArc(start: startAngle, end: startAngle + sweep)
                    .stroke(theme.dialTrack,
                            style: StrokeStyle(lineWidth: stroke, lineCap: .round))

                // Redline band, drawn under the live arc so a value past the
                // limit covers it rather than the other way round.
                if let redlineFraction {
                    DialArc(start: startAngle + sweep * redlineFraction,
                            end: startAngle + sweep)
                        .stroke(theme.danger.opacity(0.85),
                                style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                }

                // Graduations.
                Canvas { context, size in
                    drawGraduations(in: context, size: size)
                }

                // Live value.
                DialArc(start: startAngle, end: max(startAngle + 0.001, needleAngle))
                    .stroke(
                        LinearGradient(
                            colors: [theme.accentDim, theme.accent],
                            startPoint: .bottomLeading, endPoint: .topTrailing
                        ),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                    )
                    .animation(KoboldMotion.gauge, value: signal.value)

                // Hub glow: the lit centre from the mark.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.accent.opacity(0.30), .clear],
                            center: .center, startRadius: 0, endRadius: side * 0.34
                        )
                    )
                    .allowsHitTesting(false)

                NeedleShape()
                    .fill(signal.isOverRedline ? theme.danger : theme.needle)
                    .rotationEffect(.degrees(needleAngle))
                    .animation(KoboldMotion.gauge, value: signal.value)

                hub(side: side)
                readout(side: side)
            }
            .padding(stroke / 2)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        // A Canvas-drawn dial carries no inferred meaning, so the label and
        // value are stated explicitly or VoiceOver reads nothing at all.
        .accessibilityLabel(signal.label)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard signal.hasReading else { return "No reading" }
        let value = signal.value.formatted(.number.precision(.fractionLength(0)))
        let unit = signal.unit.symbol
        let over = signal.isOverRedline ? ", above redline" : ""
        return unit.isEmpty ? "\(value)\(over)" : "\(value) \(unit)\(over)"
    }

    private func hub(side: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(theme.backgroundBottom)
                .frame(width: side * 0.155)
            Circle()
                .strokeBorder(theme.accent, lineWidth: side * 0.011)
                .frame(width: side * 0.155)
            Circle()
                .fill(theme.accent)
                .frame(width: side * 0.055)
        }
    }

    /// The value as shown, quantised to the precision the instrument actually
    /// claims. A tachometer does not know the engine's speed to the revolution,
    /// and printing it that way makes the digits churn for no information.
    private var displayedValue: Double {
        let step: Double = signal.unit == .rpm ? 10 : 1
        return (signal.value / step).rounded() * step
    }

    private func readout(side: CGFloat) -> some View {
        VStack(spacing: side * 0.012) {
            // No content transition and no animation here on purpose. A numeric
            // morph is charming when a value changes occasionally and is noise
            // when it changes ten times a second — and the morph would be
            // re-triggered before finishing anyway. Monospaced digits already
            // hold the layout still, which was the only real problem.
            // A dash when nothing has been received. The needle falls to rest at
            // the same time, so the instrument reads as "no signal" rather than
            // as a genuine zero.
            if signal.hasReading {
                Text(displayedValue, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: side * 0.155, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(signal.isOverRedline ? theme.danger : theme.textPrimary)
            } else {
                Text("—")
                    .font(.system(size: side * 0.155, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)
            }

            Text(caption ?? signal.unit.symbol.uppercased())
                .font(.system(size: side * 0.045, weight: .medium, design: .rounded))
                .tracking(side * 0.006)
                .foregroundStyle(theme.textTertiary)
        }
        .offset(y: side * 0.20)
        .allowsHitTesting(false)
    }

    private func drawGraduations(in context: GraphicsContext, size: CGSize) {
        // Trigonometry is done entirely in Double and only converted to CGPoint
        // at the end. Mixing the two invites an ambiguity between the Double and
        // CoreGraphics overloads of cos/sin, since implicit CGFloat conversion
        // makes both viable.
        let centreX = Double(size.width) / 2
        let centreY = Double(size.height) / 2
        let radius = Double(min(size.width, size.height)) / 2

        let steps = 20
        let majorEvery = 4

        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let radians: Double = Angle.degrees(startAngle + sweep * fraction).radians
            let isMajor = step % majorEvery == 0

            let directionX: Double = cos(radians)
            let directionY: Double = sin(radians)

            let outer = radius * 0.845
            let inner = radius * (isMajor ? 0.735 : 0.780)

            var path = Path()
            path.move(to: CGPoint(x: centreX + directionX * inner,
                                  y: centreY + directionY * inner))
            path.addLine(to: CGPoint(x: centreX + directionX * outer,
                                     y: centreY + directionY * outer))

            context.stroke(
                path,
                with: .color(isMajor ? theme.tickMajor : theme.tickMinor),
                style: StrokeStyle(lineWidth: radius * (isMajor ? 0.022 : 0.011),
                                   lineCap: .round)
            )
        }
    }
}

/// An arc of the dial. Animatable so the live portion interpolates rather than
/// jumping between polled values.
private struct DialArc: Shape {
    var start: Double
    var end: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set {
            start = newValue.first
            end = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(center: centre,
                    radius: radius,
                    startAngle: .degrees(start),
                    endAngle: .degrees(end),
                    clockwise: false)
        return path
    }
}

/// The needle, drawn pointing along +x from the dial centre so a rotation places
/// it. The counterweight stays inside the hub, as on the mark.
private struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let tip = radius * 0.775
        let shoulder = radius * 0.72
        let tail = -radius * 0.115
        let halfBase = radius * 0.028
        let halfTip = radius * 0.011

        var path = Path()
        path.move(to: CGPoint(x: centre.x + tail, y: centre.y - halfBase))
        path.addLine(to: CGPoint(x: centre.x + shoulder, y: centre.y - halfTip))
        path.addLine(to: CGPoint(x: centre.x + tip, y: centre.y))
        path.addLine(to: CGPoint(x: centre.x + shoulder, y: centre.y + halfTip))
        path.addLine(to: CGPoint(x: centre.x + tail, y: centre.y + halfBase))
        path.closeSubpath()
        return path
    }
}

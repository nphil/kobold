import SwiftUI
import KoboldCore

/// A signal's recent shape, small enough to live on a dashboard card.
///
/// Drawn with `Canvas` rather than Swift Charts on purpose. Charts brings axes,
/// scales, gesture handling and a full layout pass per view — worth it on the
/// detail screen, and the wrong trade twelve times over on a dashboard that has
/// a 8.3 ms frame budget to hold. This is two paths and no layout.
///
/// Deliberately axis-free: on a card the question is "what is it doing", not
/// "what exactly was it doing at 14:32:07". Precision lives one tap away.
struct SparklineView: View {
    @Environment(\.theme) private var theme

    let points: [SignalHistory.Point]
    var isAlarming: Bool = false

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard points.count > 1 else { return }

            let values = points.map(\.value)
            guard let low = values.min(), let high = values.max() else { return }

            // A flat trace still needs a non-zero span or every point lands on
            // the same row and the line vanishes.
            let span = high - low
            let range = span > 0 ? span : 1
            let base = span > 0 ? low : low - 0.5

            let firstTime = points[0].time
            let lastTime = points[points.count - 1].time
            let duration = lastTime - firstTime
            guard duration > 0 else { return }

            func position(_ point: SignalHistory.Point) -> CGPoint {
                let x = (point.time - firstTime) / duration * size.width
                let y = size.height - ((point.value - base) / range) * size.height
                return CGPoint(x: x, y: y)
            }

            var line = Path()
            line.move(to: position(points[0]))
            for point in points.dropFirst() {
                line.addLine(to: position(point))
            }

            // Filled underneath, so a card reads as a shape at a glance rather
            // than as a thread to be traced.
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            let tint = isAlarming ? theme.danger : theme.accent

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.30), tint.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(line, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        // Decorative detail of a value VoiceOver already reads from the card.
        .accessibilityHidden(true)
    }
}

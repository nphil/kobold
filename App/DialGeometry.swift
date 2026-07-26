import SwiftUI

/// The dial grammar, shared by every gauge in the app.
///
/// One sweep, one origin, everywhere — the hero tachometer, a compact card
/// gauge, and the app icon all describe the same instrument at different sizes.
/// Two gauges with different sweeps read as two unrelated drawings that happen
/// to be in the same app, which is exactly what the design language exists to
/// prevent. See docs/06.
enum KoboldDial {
    /// Where the arc begins, in degrees clockwise from the +x axis. 150° puts
    /// the origin at the lower left, as on a rev counter.
    static let startAngle: Double = 150

    /// Total travel. 240° leaves the bottom open, which is what makes the shape
    /// read as an instrument rather than as a pie chart.
    static let sweep: Double = 240
}

/// An arc of the dial. Animatable so the live portion interpolates rather than
/// jumping between polled values.
struct DialArc: Shape {
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

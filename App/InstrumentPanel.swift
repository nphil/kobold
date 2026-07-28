import SwiftUI

/// The material every surface in the app is cut from.
///
/// A card here is not a card. It is an instrument set into a panel, and
/// instruments in a cluster are all machined the same way — so the recipe lives
/// in one place rather than being retyped per surface, which is how a dashboard
/// ends up with three subtly different bezels.
///
/// **The depth is entirely structural.** A light source above and to the left, a
/// milled edge that catches it, and a face that falls away from it. Nothing is
/// layered on top: no drop shadow, no glow, no texture. That restraint is the
/// point rather than a shortcut — see docs/06 on the Taycan, where ornament is
/// what reads as cheap and an orderly high-contrast readout is what reads as
/// expensive. What makes this look like a physical part is the same thing that
/// makes a physical part look like one, which is where the light comes from.
///
/// It is also why this costs nothing per frame. Every layer here is a static
/// gradient over a fixed shape, so it rasterises once and survives every value
/// change underneath it — unlike a `.shadow`, which re-blurs an alpha mask on
/// each redraw and would land squarely on this screen's frame budget.
struct InstrumentPanel: ViewModifier {
    @Environment(\.theme) private var theme

    var cornerRadius: CGFloat = 15

    /// Warms the bevel when a reading is past its limit.
    ///
    /// The edge is the second channel. A dashboard is glanced at, and an alarm
    /// carried only by the colour of a numeral is an alarm carried by the one
    /// element the eye has to land on precisely to read. The whole tile
    /// changing shape-colour is visible in peripheral vision.
    var isAlarming: Bool = false

    /// Overrides the edge colour outright — for surfaces that mean something
    /// other than "a reading", like a warning banner.
    var tint: Color?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // Lit from above. Four percent of lightness across the
                    // face is enough to stop it reading as a flat fill, and
                    // little enough that it never announces itself.
                    shape.fill(
                        LinearGradient(colors: [theme.surfaceRaised, theme.surface],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    // One specular band at the corner nearest the light, not a
                    // gloss over the whole face. Glass catches light in one
                    // place; a uniform sheen is what a gradient looks like.
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: theme.bevelLight.opacity(0.55), location: 0),
                                .init(color: .clear, location: 0.42),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                // The milled edge: bright where it faces the light, neutral
                // across the middle, dark where it turns away. A single uniform
                // hairline is exactly the detail that reads as a rectangle with
                // a border rather than as an object with an edge.
                shape.strokeBorder(
                    LinearGradient(stops: edgeStops, startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    lineWidth: 1
                )
            }
    }

    private var edgeStops: [Gradient.Stop] {
        if let tint {
            return [
                .init(color: tint.opacity(0.75), location: 0),
                .init(color: tint.opacity(0.28), location: 1),
            ]
        }
        if isAlarming {
            return [
                .init(color: theme.danger, location: 0),
                .init(color: theme.danger.opacity(0.9), location: 0.5),
                .init(color: theme.danger.opacity(0.35), location: 1),
            ]
        }
        return [
            .init(color: theme.bevelLight, location: 0),
            .init(color: theme.hairline, location: 0.5),
            .init(color: theme.bevelDark, location: 1),
        ]
    }
}

extension View {
    /// Cuts this surface from the instrument panel material.
    func instrumentPanel(cornerRadius: CGFloat = 15,
                         isAlarming: Bool = false,
                         tint: Color? = nil) -> some View {
        modifier(InstrumentPanel(cornerRadius: cornerRadius,
                                 isAlarming: isAlarming, tint: tint))
    }
}

/// A linear scale, in the same grammar as the dials.
///
/// Replaces a plain progress capsule, which was the one element on the
/// dashboard that could have come from any app at all. A progress bar answers
/// "how far through", which is not a question a reading has — a reading has a
/// *position within a range*, with a limit somewhere near the top, and that is
/// what a gauge shows.
///
/// Three details carry it. The track is the same recess the dials sit in, so a
/// tile and a dial read as the same instrument seen two ways. The graduations
/// are cut out of the lit bar rather than drawn over the track, so they appear
/// only where there is something to measure — the way a segmented cluster bar
/// lights up. And the redline zone is stated on the scale itself, so the limit
/// is visible before it is reached rather than announced once it has been.
struct ScaleBar: View {
    @Environment(\.theme) private var theme

    /// Position within the range, 0…1.
    let fraction: Double
    /// Where the red zone starts within the range, 0…1, when there is one.
    var redline: Double?
    var isAlarming: Bool = false

    /// Segments the bar is divided into. Four is a quarter-scale, which is the
    /// coarsest division that still tells you where you are without the eye
    /// having to count.
    private static let segments = 4
    private static let height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule().fill(theme.dialTrack)

                if let redline, redline < 1 {
                    Capsule()
                        .fill(theme.danger.opacity(0.28))
                        .frame(width: max(2, width * (1 - redline)))
                        .offset(x: width * redline)
                }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: isAlarming
                                ? [theme.danger.opacity(0.75), theme.danger]
                                : [theme.accentDim, theme.accent],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(3, width * fraction))
                    .animation(KoboldMotion.gauge, value: fraction)

                // Cut last, over everything, in the colour of the gap behind
                // the panel — so they are notches in the bar rather than marks
                // on it, and vanish where the bar is unlit.
                ForEach(1..<Self.segments, id: \.self) { step in
                    Rectangle()
                        .fill(theme.backgroundBottom)
                        .frame(width: 1.5, height: Self.height)
                        .offset(x: width * Double(step) / Double(Self.segments))
                }
            }
        }
        .frame(height: Self.height)
        // Decoration around a value the card already states.
        .accessibilityHidden(true)
    }
}

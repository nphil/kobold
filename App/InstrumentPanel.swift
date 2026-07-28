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

/// The same material, cut the other way: a recess rather than a raised tile.
///
/// This is the grammar the whole screen turns on. In a real cluster the small
/// readouts sit proud of the fascia and the main dial is sunk into it, and that
/// difference is legible from a metre away without reading anything. Here it is
/// exactly one thing inverted — the light now catches the *far* wall of the
/// recess, so the bright edge is at the bottom-trailing corner and the near wall
/// casts a shadow down over the top of the face.
///
/// Getting this backwards is the classic mistake, and it does not read as
/// "slightly off": a recess lit from above pops back out and becomes a raised
/// tile with strange edges. The direction of the light is the entire signal.
struct InstrumentWell<S: InsettableShape>: ViewModifier {
    @Environment(\.theme) private var theme

    /// Generic over the shape rather than taking a corner radius, because the
    /// hero's recess is a circle and asking for one by passing a 999-point
    /// radius relies on a clamp that `.continuous` corners do not promise.
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // Darker than the fascia around it, and darkest at the top,
                    // where the near wall is in the way of the light.
                    shape.fill(
                        LinearGradient(colors: [theme.backgroundBottom, theme.surface],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    shape.fill(
                        LinearGradient(
                            stops: [
                                .init(color: theme.bevelDark, location: 0),
                                .init(color: .clear, location: 0.24),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: theme.bevelDark, location: 0),
                            .init(color: theme.hairline, location: 0.55),
                            .init(color: theme.bevelLight, location: 1),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
    }
}

/// The panel everything else is mounted on.
///
/// Three static layers: the base gradient, the room's light coming from the
/// same corner the tiles are lit from, and a vignette so the fascia curves away
/// at the edges instead of running flat to the bezel. Without the first two the
/// tiles are lit by a light source the screen never establishes, which is the
/// difference between a scene and a set of decorated rectangles.
struct Fascia: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let diagonal = max(proxy.size.width, proxy.size.height)

            ZStack {
                LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                               startPoint: .top, endPoint: .bottom)

                RadialGradient(colors: [theme.bevelLight.opacity(0.5), .clear],
                               center: UnitPoint(x: 0.16, y: -0.04),
                               startRadius: 0, endRadius: diagonal * 0.72)

                RadialGradient(colors: [.clear, theme.bevelDark.opacity(0.75)],
                               center: .center,
                               startRadius: diagonal * 0.24, endRadius: diagonal * 0.78)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    /// Sinks this surface into the fascia.
    func instrumentWell(cornerRadius: CGFloat = 26) -> some View {
        modifier(InstrumentWell(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ))
    }

    /// Sinks this surface into the fascia, in a shape of its own — a round
    /// recess for a round dial.
    func instrumentWell(shape: some InsettableShape) -> some View {
        modifier(InstrumentWell(shape: shape))
    }
}

// MARK: - Spatial continuity

/// Zoom transitions, where the platform has them.
///
/// The tile you press should become the sheet, rather than a sheet arriving
/// from somewhere else while the tile stays behind — with a dozen readings on
/// screen, "which one am I looking at" is a real question and the animation is
/// what answers it. Justified by function, which is the bar docs/06 sets for
/// this: it is spatial continuity, not decoration.
///
/// Gated because the deployment target is iOS 17 and the transition arrived in
/// 18. Availability is fixed at runtime, so the branch never changes under a
/// view and cannot cost it its identity.
extension View {
    @ViewBuilder
    func zoomSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
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

import SwiftUI

/// The colour roles the dashboard draws with.
///
/// A deliberately small first cut of the semantic token system described in
/// `docs/07-theming-system.md`. The full catalogue is generated from seed hues;
/// what matters here is that the rule holds from the first screen: **no view
/// ever names a colour directly.** Every fill goes through a role, so adding
/// themes later is a data change rather than a sweep through the UI.
///
/// Two roles are deliberately not free to re-hue. `caution` and `danger` carry
/// meaning — amber warns, red is a limit — and instrument convention is worth
/// more than palette consistency. They are tuned per theme for contrast, never
/// shifted in hue.
struct KoboldTheme: Equatable {
    let id: String
    let name: String

    // Surfaces, with elevation carried by lightness rather than shadow, which
    // is invisible on a dark background.
    let backgroundTop: Color
    let backgroundBottom: Color
    let surface: Color
    let surfaceRaised: Color
    let hairline: Color
    /// The two edges of a milled bevel: the one facing the light and the one
    /// turned away from it. Kept as roles rather than a hardcoded white and
    /// black because a warm theme wants a warm highlight — a neutral one over
    /// Ember reads as a grey smear rather than as light.
    let bevelLight: Color
    let bevelDark: Color

    // Text hierarchy.
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color

    // Identity.
    let accent: Color
    let accentDim: Color

    // Instrument parts.
    let dialTrack: Color
    let tickMajor: Color
    let tickMinor: Color
    let needle: Color

    // Protected roles.
    let caution: Color
    let danger: Color

    static let midnight = KoboldTheme(
        id: "midnight",
        name: "Midnight",
        backgroundTop: Color(red: 0.11, green: 0.13, blue: 0.17),
        backgroundBottom: Color(red: 0.04, green: 0.05, blue: 0.07),
        surface: Color(red: 0.09, green: 0.11, blue: 0.15),
        surfaceRaised: Color(red: 0.13, green: 0.15, blue: 0.20),
        hairline: Color(red: 0.20, green: 0.23, blue: 0.29),
        bevelLight: Color(red: 0.72, green: 0.80, blue: 1.00).opacity(0.22),
        bevelDark: Color(red: 0.01, green: 0.01, blue: 0.02).opacity(0.55),
        textPrimary: Color(red: 0.95, green: 0.96, blue: 0.98),
        textSecondary: Color(red: 0.66, green: 0.70, blue: 0.78),
        textTertiary: Color(red: 0.42, green: 0.46, blue: 0.54),
        // Cobalt: the element that took its name from the kobold.
        accent: Color(red: 0.23, green: 0.49, blue: 0.97),
        accentDim: Color(red: 0.11, green: 0.29, blue: 0.68),
        dialTrack: Color(red: 0.15, green: 0.18, blue: 0.23),
        tickMajor: Color(red: 0.38, green: 0.42, blue: 0.50),
        tickMinor: Color(red: 0.24, green: 0.27, blue: 0.33),
        needle: Color(red: 0.95, green: 0.96, blue: 0.98),
        caution: Color(red: 1.00, green: 0.72, blue: 0.20),
        danger: Color(red: 1.00, green: 0.54, blue: 0.17)
    )

    static let slate = KoboldTheme(
        id: "slate",
        name: "Slate",
        backgroundTop: Color(red: 0.14, green: 0.15, blue: 0.16),
        backgroundBottom: Color(red: 0.06, green: 0.06, blue: 0.07),
        surface: Color(red: 0.11, green: 0.12, blue: 0.13),
        surfaceRaised: Color(red: 0.16, green: 0.17, blue: 0.18),
        hairline: Color(red: 0.24, green: 0.25, blue: 0.27),
        bevelLight: Color(red: 0.88, green: 0.90, blue: 0.92).opacity(0.20),
        bevelDark: Color(red: 0.01, green: 0.01, blue: 0.01).opacity(0.55),
        textPrimary: Color(red: 0.96, green: 0.96, blue: 0.96),
        textSecondary: Color(red: 0.68, green: 0.69, blue: 0.71),
        textTertiary: Color(red: 0.44, green: 0.45, blue: 0.47),
        accent: Color(red: 0.36, green: 0.78, blue: 0.62),
        accentDim: Color(red: 0.16, green: 0.44, blue: 0.35),
        dialTrack: Color(red: 0.17, green: 0.18, blue: 0.19),
        tickMajor: Color(red: 0.40, green: 0.41, blue: 0.43),
        tickMinor: Color(red: 0.26, green: 0.27, blue: 0.29),
        needle: Color(red: 0.96, green: 0.96, blue: 0.96),
        caution: Color(red: 1.00, green: 0.72, blue: 0.20),
        danger: Color(red: 1.00, green: 0.54, blue: 0.17)
    )

    static let ember = KoboldTheme(
        id: "ember",
        name: "Ember",
        backgroundTop: Color(red: 0.13, green: 0.11, blue: 0.13),
        backgroundBottom: Color(red: 0.06, green: 0.04, blue: 0.05),
        surface: Color(red: 0.11, green: 0.09, blue: 0.11),
        surfaceRaised: Color(red: 0.16, green: 0.13, blue: 0.15),
        hairline: Color(red: 0.26, green: 0.21, blue: 0.24),
        bevelLight: Color(red: 1.00, green: 0.88, blue: 0.90).opacity(0.20),
        bevelDark: Color(red: 0.02, green: 0.01, blue: 0.01).opacity(0.55),
        textPrimary: Color(red: 0.97, green: 0.95, blue: 0.95),
        textSecondary: Color(red: 0.72, green: 0.67, blue: 0.68),
        textTertiary: Color(red: 0.47, green: 0.43, blue: 0.44),
        accent: Color(red: 0.85, green: 0.35, blue: 0.55),
        accentDim: Color(red: 0.48, green: 0.17, blue: 0.30),
        dialTrack: Color(red: 0.18, green: 0.15, blue: 0.17),
        tickMajor: Color(red: 0.44, green: 0.39, blue: 0.41),
        tickMinor: Color(red: 0.29, green: 0.25, blue: 0.27),
        needle: Color(red: 0.97, green: 0.95, blue: 0.95),
        caution: Color(red: 1.00, green: 0.72, blue: 0.20),
        danger: Color(red: 1.00, green: 0.54, blue: 0.17)
    )

    static let all: [KoboldTheme] = [.midnight, .slate, .ember]
}

private struct KoboldThemeKey: EnvironmentKey {
    static let defaultValue: KoboldTheme = .midnight
}

extension EnvironmentValues {
    var theme: KoboldTheme {
        get { self[KoboldThemeKey.self] }
        set { self[KoboldThemeKey.self] = newValue }
    }
}

/// The app's two voices.
///
/// One rule, and it is worth stating as a rule because it is the whole
/// typographic identity: **numbers are instrument type, words are UI type.**
///
/// Live readings are set in SF Pro Expanded. Wide numerals are what an
/// instrument cluster looks like — the width axis is doing the job a custom
/// display face would do in docs/06, without shipping a font file, losing
/// Dynamic Type, or falling back silently on a system that lacks it. Set beside
/// SF Rounded labels the pairing is deliberate rather than accidental: the two
/// are obviously different, so neither reads as a mistake.
///
/// Rounded stays everywhere words go, which is most of the app. Reversing this
/// — expanded labels, rounded numerals — would be the same two faces and would
/// look like a template, because the width would then be decorating the part of
/// the screen nobody is reading at a glance.
enum KoboldType {

    /// A live value. Always paired with `.monospacedDigit()` at the call site,
    /// so a changing reading does not shuffle its own layout.
    static func numeral(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }

    /// A name, a unit, a caption — anything made of words.
    static func label(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The app's motion signature.
///
/// Three registers, kept apart on purpose, because they answer different
/// questions.
enum KoboldMotion {
    /// Chrome: sheets, menus, state changes. Discrete events, so a spring is
    /// right — it responds to something that just happened.
    static let ui: Animation = .snappy(duration: 0.28, extraBounce: 0.02)

    /// Gauges fed by sampled data.
    ///
    /// Linear, and exactly as long as the interval between samples. This looks
    /// wrong on paper and is the only thing that works in practice: a sampled
    /// signal is not an event, it is a stream, and each value is simply the next
    /// known position. Interpolating linearly over precisely the gap to the next
    /// sample produces constant velocity and continuous motion.
    ///
    /// A spring here is actively harmful. A bouncy spring takes far longer to
    /// settle than the gap between samples, so it is re-triggered mid-flight
    /// over and over and never resolves — which reads as jitter, and gets worse
    /// the more gauges are moving at once. Easing is nearly as bad: it
    /// decelerates into every sample, so smooth motion turns into a series of
    /// visible stop-starts.
    static let gauge: Animation = .linear(duration: SessionTiming.publishInterval)

    /// Discrete instrument events — crossing a redline, a fault appearing.
    /// Here the mechanical overshoot belongs, because something did happen.
    static let alert: Animation = .spring(response: 0.28, dampingFraction: 0.58)
}

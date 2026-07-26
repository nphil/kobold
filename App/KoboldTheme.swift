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

/// The app's motion signature.
///
/// Two distinct registers, kept apart on purpose: chrome moves one way, the
/// needle another. A needle that eases like a sheet reads as a readout; one
/// that settles with a little overshoot reads as an instrument.
enum KoboldMotion {
    /// Chrome, sheets, state changes.
    static let ui: Animation = .snappy(duration: 0.28, extraBounce: 0.02)

    /// The needle: quick to respond, settles with a trace of mechanical
    /// overshoot, bounded so a fast-changing signal never looks nauseating.
    static let needle: Animation = .spring(response: 0.32, dampingFraction: 0.62)
}

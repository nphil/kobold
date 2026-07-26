import SwiftUI
import KoboldCore

struct DashboardView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(FrameRateMonitor.self) private var frameRate

    let session: SessionModel
    @Binding var themeID: String

    /// Signed overscroll pressure, −1…1. Positive means pulling down.
    @State private var pull: CGFloat = 0
    @State private var showDiagnostics = false

    private let secondary: [SignalID] = [.speed, .boost, .coolantTemp, .oilTemp, .throttle, .moduleVoltage]

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // No ScrollView. The dashboard is a panel, not a document: it sizes
            // to the screen, and the tachometer absorbs whatever space is left
            // over so everything fits without scrolling on any device.
            //
            // Nothing springs. A rubber-band on a panel that cannot move reads
            // as stutter, especially while every gauge is animating.
            VStack(spacing: 14) {
                header
                errorBanner

                if let rpm = session.bus.signal(.rpm) {
                    TachometerView(signal: rpm, caption: "RPM")
                        .frame(maxHeight: .infinity)
                }

                tiles
                footer
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)

            edgeGlow
        }
        // Simultaneous so it never swallows taps on the menus and tiles beneath.
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in pull = resistance(value.translation.height) }
                .onEnded { _ in
                    withAnimation(reduceMotion ? .linear(duration: 0.15) : KoboldMotion.ui) {
                        pull = 0
                    }
                }
        )
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
        .preferredColorScheme(.dark)
    }

    /// Maps raw drag distance onto glow intensity using UIKit's own rubber-band
    /// curve: `b(x) = (x·d·c) / (d + c·x)`.
    ///
    /// This is the same shape a scroll view uses when you drag past its end, so
    /// the resistance feels like something the platform would do rather than
    /// something invented here. `b/d` is already normalised to 0…1 and saturates,
    /// so pulling harder always gives a little more and never runs away.
    ///
    /// UIScrollView uses c = 0.55 over the full screen height; a short decorative
    /// travel budget wants a stiffer constant, or the glow barely registers
    /// before the gesture ends.
    private func resistance(_ translation: CGFloat) -> CGFloat {
        let distance = abs(Double(translation))
        let travel: Double = 110      // d — how far a full-strength pull is
        let stiffness: Double = 0.32  // c
        let banded = (distance * travel * stiffness) / (travel + stiffness * distance)
        let intensity = banded / travel
        return CGFloat(translation < 0 ? -intensity : intensity)
    }

    /// A soft bloom at whichever edge is being pulled away from.
    ///
    /// This is the whole answer to "why won't it scroll": the screen replies to
    /// the gesture instead of ignoring it, without ever moving. Tinted from the
    /// active theme's accent so it belongs to the current look.
    private var edgeGlow: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [theme.accent.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .opacity(Double(max(0, pull)))

            Spacer(minLength: 0)

            LinearGradient(colors: [.clear, theme.accent.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .opacity(Double(max(0, -pull)))
        }
        // Flattened to a single composited layer, and only its opacity is
        // animated. A `.shadow` would re-rasterise a blurred alpha mask on every
        // change, which is precisely the kind of per-frame cost this screen is
        // being cleared of.
        .drawingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // Decorative: it says nothing VoiceOver users need, and announcing it
        // would interrupt the values they are actually there for.
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Kobold")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(session.profileName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
            }

            Spacer(minLength: 8)

            statusPill
            themeButton
        }
        .padding(.top, 6)
    }

    private var statusPill: some View {
        let ready = session.phase == .ready
        let failed = isFailed(session.phase)

        return Menu {
            Button {
                session.startAdapter()
            } label: {
                Label("Connect to adapter", systemImage: "antenna.radiowaves.left.and.right")
            }
            Button {
                session.startDemo()
            } label: {
                Label("Demo mode", systemImage: "play.circle")
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(failed ? theme.danger : (ready ? theme.accent : theme.textTertiary))
                    .frame(width: 8, height: 8)
                    .opacity(ready ? 1 : 0.55)
                Text(session.source.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.surfaceRaised))
            .overlay(Capsule().strokeBorder(failed ? theme.danger.opacity(0.6) : theme.hairline,
                                            lineWidth: 1))
        }
        .animation(KoboldMotion.ui, value: ready)
        .accessibilityLabel("Data source, currently \(session.source.label)")
    }

    private func isFailed(_ phase: ConnectionPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Connection problems are stated plainly with the likely cause. This
    /// hardware fails in specific, knowable ways — asleep, unseated, ignition
    /// off — and a bare "connection error" would leave the user guessing.
    @ViewBuilder
    private var errorBanner: some View {
        if let message = session.lastError {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.caution)
                Text(message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(theme.caution.opacity(0.35), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var themeButton: some View {
        Menu {
            Button {
                showDiagnostics = true
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Divider()

            ForEach(KoboldTheme.all, id: \.id) { candidate in
                Button {
                    withAnimation(KoboldMotion.ui) { themeID = candidate.id }
                } label: {
                    if candidate.id == themeID {
                        Label(candidate.name, systemImage: "checkmark")
                    } else {
                        Text(candidate.name)
                    }
                }
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.surfaceRaised))
                .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 1))
        }
        .accessibilityLabel("Theme")
    }

    private var tiles: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 104), spacing: 10)],
            spacing: 10
        ) {
            ForEach(secondary, id: \.rawValue) { id in
                if let signal = session.bus.signal(id) {
                    SignalTileView(signal: signal)
                }
            }
        }
    }

    /// Sample rate and achieved frame rate, side by side.
    ///
    /// The frame rate is here rather than buried in a log because "it feels
    /// slow" is not something to argue about from a desk — the number settles it,
    /// and it turns amber when the app is missing the display's capability.
    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10, weight: .semibold))
                Text(session.samplesPerSecond, format: .number.precision(.fractionLength(0)))
                    .monospacedDigit()
                Text("val/s")
            }
            .foregroundStyle(theme.textTertiary)

            HStack(spacing: 5) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 10, weight: .semibold))
                Text(frameRate.framesPerSecond, format: .number.precision(.fractionLength(0)))
                    .monospacedDigit()
                Text("/ \(frameRate.maximumFramesPerSecond) fps")
            }
            .foregroundStyle(frameRateHealthy ? theme.textTertiary : theme.caution)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .padding(.top, 1)
    }

    private var frameRateHealthy: Bool {
        // Nothing measured yet reads as fine rather than alarming.
        guard frameRate.framesPerSecond > 0 else { return true }
        return frameRate.framesPerSecond >= Double(frameRate.maximumFramesPerSecond) * 0.8
    }
}

/// A single secondary readout.
struct SignalTileView: View {
    @Environment(\.theme) private var theme
    let signal: LiveSignal

    private var isStale: Bool { signal.isStale() }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(signal.label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // Instant, unanimated, monospaced. See TachometerView.readout:
                // a numeric morph re-triggered at sample rate is churn, and
                // monospaced digits already stop the layout shifting.
                //
                // A dash rather than a number when nothing has been received:
                // "0 km/h" and "no reading" are different claims, and only one
                // of them is true when the adapter has gone.
                if signal.hasReading {
                    Text(signal.value, format: .number.precision(.fractionLength(decimals)))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(valueColour)
                } else {
                    Text("—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                }

                Text(signal.unit.symbol)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
            }

            // A thin bar carries the value's position in range at a glance,
            // which a bare number cannot.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.dialTrack)
                    Capsule()
                        .fill(signal.isOverRedline ? theme.danger : theme.accent)
                        .frame(width: max(3, proxy.size.width * signal.normalised))
                        .animation(KoboldMotion.gauge, value: signal.value)
                }
            }
            .frame(height: 4)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 1)
        )
        .opacity(isStale ? 0.45 : 1)
        .animation(KoboldMotion.ui, value: isStale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signal.label)
        .accessibilityValue(signal.hasReading
                            ? "\(signal.value.formatted(.number.precision(.fractionLength(decimals)))) \(signal.unit.symbol)"
                            : "No reading")
    }

    private var decimals: Int {
        switch signal.unit {
        case .volt: return 1
        default: return 0
        }
    }

    private var valueColour: Color {
        signal.isOverRedline ? theme.danger : theme.textPrimary
    }
}

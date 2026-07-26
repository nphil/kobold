import SwiftUI
import KoboldCore

struct DashboardView: View {
    @Environment(\.theme) private var theme

    let session: SessionModel
    @Binding var themeID: String

    private let secondary: [SignalID] = [.speed, .boost, .coolantTemp, .oilTemp, .throttle, .moduleVoltage]

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    header

                    if let rpm = session.bus.signal(.rpm) {
                        TachometerView(signal: rpm, caption: "RPM")
                            .padding(.horizontal, 8)
                    }

                    tiles
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
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
        return HStack(spacing: 7) {
            Circle()
                .fill(ready ? theme.accent : theme.textTertiary)
                .frame(width: 8, height: 8)
                // A slow pulse reads as "live" without competing with the data.
                .opacity(ready ? 1 : 0.5)
            Text(session.source.label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(theme.surfaceRaised)
        )
        .overlay(
            Capsule().strokeBorder(theme.hairline, lineWidth: 1)
        )
        .animation(KoboldMotion.ui, value: ready)
    }

    private var themeButton: some View {
        Menu {
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
            columns: [GridItem(.adaptive(minimum: 148), spacing: 12)],
            spacing: 12
        ) {
            ForEach(secondary, id: \.rawValue) { id in
                if let signal = session.bus.signal(id) {
                    SignalTileView(signal: signal)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 11, weight: .semibold))
            Text(session.samplesPerSecond, format: .number.precision(.fractionLength(0)))
                .monospacedDigit()
            Text("samples/s")
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(theme.textTertiary)
        .padding(.top, 2)
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
                Text(signal.value, format: .number.precision(.fractionLength(decimals)))
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(valueColour)

                Text(signal.unit.symbol)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
            }
            .animation(KoboldMotion.ui, value: signal.value)

            // A thin bar carries the value's position in range at a glance,
            // which a bare number cannot.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.dialTrack)
                    Capsule()
                        .fill(signal.isOverRedline ? theme.danger : theme.accent)
                        .frame(width: max(3, proxy.size.width * signal.normalised))
                        .animation(KoboldMotion.needle, value: signal.value)
                }
            }
            .frame(height: 4)
        }
        .padding(13)
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
        .accessibilityValue("\(signal.value.formatted(.number.precision(.fractionLength(decimals)))) \(signal.unit.symbol)")
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

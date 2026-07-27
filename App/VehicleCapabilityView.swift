import SwiftUI
import KoboldCore

/// What the car reports, set against what Kobold can read.
///
/// Exists to answer one question — "am I missing anything on my car" — with a
/// number and a list rather than a shrug. The answer is exact, because the
/// supported-PID bitmask is a declaration by the ECU rather than something
/// inferred by probing: the car states what it implements, and the gap is
/// arithmetic from there.
struct VehicleCapabilityView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let capability: VehicleCapability?
    let profileName: String

    var body: some View {
        NavigationStack {
            Group {
                if let capability, capability.supportedCount > 0 {
                    content(for: capability)
                } else {
                    ContentUnavailableView(
                        "Not scanned yet",
                        systemImage: "car.side.and.exclamationmark",
                        description: Text("Connect to the adapter with the ignition on. The car reports what it supports as part of connecting, and it takes about a second.")
                    )
                }
            }
            .background(
                LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            .navigationTitle("Vehicle Coverage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func content(for capability: VehicleCapability) -> some View {
        List {
            Section {
                summary(for: capability)
                    .listRowBackground(Color.clear)
            }

            // Gaps first. The decoded list is reassurance; the gap list is the
            // only part anyone can act on, so it does not sit below a scroll.
            ForEach(capability.gapsByCategory) { group in
                Section {
                    ForEach(group.gaps) { gap in
                        gapRow(gap)
                    }
                } header: {
                    sectionHeader(group.category.label, symbol: group.category.symbolName)
                }
            }

            if !capability.readable.isEmpty {
                Section {
                    ForEach(capability.readable, id: \.self) { id in
                        readableRow(capability.name(for: id))
                    }
                } header: {
                    sectionHeader("Decoded", symbol: "checkmark.circle")
                } footer: {
                    Text("Kobold reads these from this car. Any of them can go on the dashboard — long-press it, then Add.")
                }
            }

            if !capability.undeclared.isEmpty {
                Section {
                    ForEach(capability.undeclared, id: \.self) { id in
                        readableRow(capability.name(for: id), muted: true)
                    }
                } header: {
                    sectionHeader("Defined but not reported", symbol: "questionmark.circle")
                } footer: {
                    Text("Kobold has a decoder for these, but this car did not declare them. Usually a profile written for a different trim.")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Summary

    private func summary(for capability: VehicleCapability) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profileName)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textTertiary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(capability.readable.count)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.accent)
                Text("of \(capability.supportedCount) reported readings")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textSecondary)
            }

            // A bar rather than a percentage alone: the shape of "most of it"
            // versus "a sliver" lands before the number is read.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.dialTrack)
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: max(4, proxy.size.width * CGFloat(capability.coverage)))
                }
            }
            .frame(height: 6)

            Text(verdict(for: capability))
                .font(.system(size: 13))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(capability.readable.count) of \(capability.supportedCount) reported readings decoded")
    }

    /// One sentence, in plain words, saying whether anything is missing.
    ///
    /// Written out rather than assembled from an inflection rule: there are two
    /// cases and both are short, which is cheaper to read than a format string
    /// that has to be decoded before it can be trusted.
    private func verdict(for capability: VehicleCapability) -> String {
        switch capability.gaps.count {
        case 0:
            return "Everything this car reports, Kobold decodes. Nothing is missing."
        case 1:
            return "One reading is reported by the car but not decoded yet. It is a standard PID, so it is a profile entry away."
        default:
            return "\(capability.gaps.count) readings are reported by the car but not decoded yet. They are standard PIDs, so each is a profile entry away."
        }
    }

    // MARK: - Rows

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(theme.textSecondary)
    }

    private func gapRow(_ gap: VehicleCapability.Gap) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(gap.name)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                // The raw command, because the person most likely to care about
                // a gap is the person about to go and look the PID up.
                Text(gap.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(gap.name), \(gap.command), not decoded yet")
    }

    private func readableRow(_ name: String, muted: Bool = false) -> some View {
        Text(name)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(muted ? theme.textTertiary : theme.textPrimary)
            .padding(.vertical, 2)
    }
}

import SwiftUI
import KoboldCore

/// Chooses a signal to add to the dashboard.
///
/// Lists only what this vehicle actually reports and does not already show, so
/// the list is short and everything on it works. Offering the full SAE
/// catalogue would mostly be offering readings that come back as `NO DATA` on
/// this car.
struct SignalPickerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Live signals rather than bare identifiers, so the list can show what
    /// each reading actually is. `fuelRailPressureDirect` is a key, not a name.
    let available: [LiveSignal]
    let onSelect: (SignalID) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if available.isEmpty {
                    ContentUnavailableView("Everything is shown",
                                           systemImage: "checkmark.circle",
                                           description: Text("Every signal this car reports is already on the dashboard."))
                } else {
                    List(available, id: \.id) { signal in
                        Button {
                            onSelect(signal.id)
                            dismiss()
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(signal.label)
                                        .font(.system(size: 16, weight: .medium, design: .rounded))
                                        .foregroundStyle(theme.textPrimary)

                                    // Smaller, underneath, and only when there
                                    // is something worth saying — a name that
                                    // explains itself does not need a sentence
                                    // repeating it.
                                    if let summary = signal.summary {
                                        Text(summary)
                                            .font(.system(size: 12))
                                            .foregroundStyle(theme.textTertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }

                                Spacer(minLength: 0)

                                Text(signal.unit.symbol)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.textTertiary)

                                Image(systemName: "plus.circle")
                                    .foregroundStyle(theme.accent)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(
                LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            .navigationTitle("Add a signal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

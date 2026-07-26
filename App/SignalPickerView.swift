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

    let available: [SignalID]
    let onSelect: (SignalID) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if available.isEmpty {
                    ContentUnavailableView("Everything is shown",
                                           systemImage: "checkmark.circle",
                                           description: Text("Every signal this car reports is already on the dashboard."))
                } else {
                    List(available) { signal in
                        Button {
                            onSelect(signal)
                            dismiss()
                        } label: {
                            HStack {
                                Text(signal.rawValue)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(theme.accent)
                            }
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

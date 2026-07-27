import SwiftUI
import KoboldCore

/// Chooses a signal to add to the dashboard.
///
/// Lists only what this vehicle reports and does not already show, so
/// everything on it works — offering the full SAE catalogue would mostly be
/// offering readings that come back as `NO DATA` on this car.
///
/// Grouped and searchable because the list is going to grow. Fourteen entries
/// sort fine alphabetically; the ~80 the standard defines do not, and by then
/// scrolling to find "Catalyst Temperature B1S1" is a chore rather than a
/// choice.
struct SignalPickerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Live signals rather than bare identifiers, so the list can show what
    /// each reading actually is. `fuelRailPressureDirect` is a key, not a name.
    let available: [LiveSignal]
    let onSelect: (SignalID) -> Void

    /// Read so the unit beside each row is the one it would be added in. A
    /// picker offering "km/h" for a signal the dashboard shows in mph is a
    /// small lie about what the choice does.
    @AppStorage("unitPreferences") private var storedUnits = Data()

    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if available.isEmpty {
                    ContentUnavailableView("Everything is shown",
                                           systemImage: "checkmark.circle",
                                           description: Text("Every signal this car reports is already on the dashboard."))
                } else if grouped.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    list
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

    private var list: some View {
        List {
            ForEach(grouped, id: \.category) { group in
                Section {
                    ForEach(group.signals, id: \.id) { signal in
                        row(for: signal)
                    }
                } header: {
                    Label(group.category.label, systemImage: group.category.symbolName)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        // Searches the summary as well as the name, so "leak" finds fuel trim
        // and "boost" finds manifold pressure — the word someone reaches for is
        // often not the word on the label.
        .searchable(text: $query, prompt: "Search signals")
    }

    private func row(for signal: LiveSignal) -> some View {
        Button {
            onSelect(signal.id)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(signal.label)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textPrimary)

                    // Smaller, underneath, and only when there is something
                    // worth saying — a name that explains itself does not need
                    // a sentence repeating it.
                    if let summary = signal.summary {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                Text(SignalDisplay(reported: signal.unit, id: signal.id,
                                   preferences: storedUnits).symbol)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)

                Image(systemName: "plus.circle")
                    .foregroundStyle(theme.accent)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Grouping

    private struct CategoryGroup {
        let category: SignalCategory
        let signals: [LiveSignal]
    }

    /// Matching signals, grouped by category in display order.
    ///
    /// Empty categories are dropped rather than shown empty: a car that reports
    /// nothing in a group should not advertise the group.
    private var grouped: [CategoryGroup] {
        let matches = available.filter(self.matches)

        return SignalCategory.ordered.compactMap { category in
            let signals = matches
                .filter { $0.category == category }
                .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            return signals.isEmpty ? nil : CategoryGroup(category: category, signals: signals)
        }
    }

    private func matches(_ signal: LiveSignal) -> Bool {
        let query = self.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }

        // The identifier is searched too. It is not shown anywhere, but anyone
        // who has read the logs or the profile JSON will have seen it, and a
        // search that fails on a name the app itself printed is annoying.
        let haystacks = [signal.label, signal.summary ?? "", signal.id.rawValue,
                         signal.category.label]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

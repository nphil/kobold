import SwiftUI
import KoboldLog

/// Diagnostics and remote logging settings.
///
/// A list-shaped screen read at rest, so unlike the dashboard it keeps standard
/// scroll indicators — "how much is left" is real information here. See
/// docs/06-design-language.md.
struct DiagnosticsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(FrameRateMonitor.self) private var frameRate

    @AppStorage("ntfyEnabled") private var ntfyEnabled = false
    @AppStorage("ntfyTopic") private var ntfyTopic = ""
    @AppStorage("ntfyLevel") private var ntfyLevelRaw = LogLevel.warning.rawValue

    @State private var entries: [LogEntry] = []
    @State private var testResult: String?
    @State private var isSendingTest = false

    private var level: LogLevel {
        LogLevel(rawValue: ntfyLevelRaw) ?? .warning
    }

    var body: some View {
        NavigationStack {
            Form {
                performanceSection
                remoteSection
                recentSection
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refresh() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var performanceSection: some View {
        Section("Performance") {
            LabeledContent("Frame rate") {
                Text("\(Int(frameRate.framesPerSecond)) / \(frameRate.maximumFramesPerSecond) fps")
                    .monospacedDigit()
            }
            LabeledContent("Worst frame") {
                Text("\(Int(frameRate.worstFrameMilliseconds)) ms")
                    .monospacedDigit()
            }
            // A single late frame is what actually reads as a stutter, so the
            // worst interval is more useful than the average it hides inside.
            Text("A frame budget is 8.3 ms at 120 Hz and 16.7 ms at 60 Hz. "
                 + "Anything much above that was visible.")
                .font(.footnote)
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var remoteSection: some View {
        Section {
            Toggle("Send logs to ntfy", isOn: $ntfyEnabled)
                .onChange(of: ntfyEnabled) { _, enabled in
                    if enabled, ntfyTopic.isEmpty {
                        ntfyTopic = NtfyConfiguration.randomTopic()
                    }
                    Task { await LoggingSetup.reconfigure() }
                }

            HStack {
                TextField("topic", text: $ntfyTopic)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    ntfyTopic = NtfyConfiguration.randomTopic()
                    Task { await LoggingSetup.reconfigure() }
                } label: {
                    Image(systemName: "die.face.5")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Generate a random topic")
            }

            Picker("Send at least", selection: $ntfyLevelRaw) {
                ForEach(LogLevel.allCases, id: \.rawValue) { candidate in
                    Text(candidate.label).tag(candidate.rawValue)
                }
            }
            .onChange(of: ntfyLevelRaw) { _, _ in
                Task { await LoggingSetup.reconfigure() }
            }

            Button {
                Task { await sendTest() }
            } label: {
                if isSendingTest {
                    ProgressView()
                } else {
                    Text("Send test message")
                }
            }
            .disabled(ntfyTopic.isEmpty || isSendingTest)

            if let testResult {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
            }
        } header: {
            Text("Remote logging")
        } footer: {
            // Stated up front rather than buried. On the public server the topic
            // name is the only thing standing between these logs and anyone who
            // guesses it, and that is worth knowing before switching this on.
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    // One literal, not concatenated: `Text` only parses markdown
                    // from a `LocalizedStringKey` literal, and `"a" + "b"` is a
                    // runtime String — the asterisks would render as asterisks.
                    Text("On ntfy.sh the topic name **is** the password. Anyone who knows or guesses it can read every message you send and publish their own. Keep the random name, or self-host if the contents matter.")
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                }
                Text("Batched every 15 seconds — the public server allows roughly "
                     + "one request per ten, and refuses more.")
            }
            .font(.footnote)
        }
    }

    private var recentSection: some View {
        Section("Recent") {
            if entries.isEmpty {
                Text("Nothing logged yet.")
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(colour(for: entry.level))
                        Text("\(entry.level.label) · \(entry.category.rawValue)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }

            Button("Refresh") { Task { await refresh() } }
            Button("Clear", role: .destructive) {
                Task {
                    await Logger.shared.clear()
                    await refresh()
                }
            }
        }
    }

    private func colour(for level: LogLevel) -> Color {
        switch level {
        case .debug: return theme.textTertiary
        case .info: return theme.textSecondary
        case .warning: return theme.caution
        case .error: return theme.danger
        }
    }

    private func refresh() async {
        entries = await Logger.shared.recent(limit: 60)
    }

    private func sendTest() async {
        isSendingTest = true
        defer { isSendingTest = false }

        let sink = NtfySink(configuration: NtfyConfiguration(topic: ntfyTopic,
                                                             minimumLevel: level))
        switch await sink.sendTest() {
        case .success:
            testResult = "Sent. Subscribe to “\(ntfyTopic)” in the ntfy app to see it."
        case .failure(let error):
            testResult = error.localizedDescription
        }
    }
}

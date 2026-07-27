import SwiftUI
import KoboldCore
import KoboldLog

/// Searches a module for data identifiers nobody has published.
///
/// Deliberately not one-tap. It is an hour of hammering a safety module with
/// requests it has never been asked before, and while every request is
/// read-only, "read-only" is a statement about what the request can command,
/// not a promise that a module handles unexpected traffic gracefully.
struct DeepScanView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let session: SessionModel
    @State private var model = ScanModel()
    @State private var isSending = false
    @State private var sendResult: String?

    @AppStorage("ntfyTopic") private var ntfyTopic = ""

    /// Persisted so an interrupted run resumes instead of restarting.
    @AppStorage("udsScanProgress") private var stored = Data()

    private var targets: [ScanModel.Target] {
        (session.capability?.modules ?? []).map {
            ScanModel.Target(key: $0.key, label: $0.label,
                             transmit: $0.header, receive: Self.responseHeader(for: $0.header))
        }
    }

    /// On 11-bit CAN the reply is request + 8.
    private static func responseHeader(for transmit: String) -> String? {
        guard let value = UInt16(transmit, radix: 16), value + 8 <= 0x7FF else { return nil }
        return String(format: "%03X", value + 8)
    }

    var body: some View {
        NavigationStack {
            Group {
                if targets.isEmpty {
                    ContentUnavailableView(
                        "No modules found",
                        systemImage: "cpu",
                        description: Text("Connect to the car first. Only modules that answered a direct request can be scanned.")
                    )
                } else {
                    list
                }
            }
            .background(
                LinearGradient(colors: [theme.backgroundTop, theme.backgroundBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            .navigationTitle("Deep Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(model.isRunning)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.isRunning)
        .task { model.load(from: stored) }
        .onDisappear { model.stop() }
    }

    private var list: some View {
        List {
            if model.isRunning { liveSection }
            safetySection

            ForEach(targets) { target in
                Section {
                    ForEach(ScanModel.services, id: \.code) { service in
                        row(target: target, service: service)
                    }
                    controls(for: target)
                } header: {
                    Label(target.label, systemImage: "cpu")
                        .foregroundStyle(theme.textSecondary)
                }
            }

            findingsSection

            if let message = model.lastMessage {
                Section {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Result").foregroundStyle(theme.textSecondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// What the sweep is doing right now.
    ///
    /// A progress bar that moves once a minute reads as a hang. The address
    /// currently being tried moves constantly, which is the difference between
    /// "this is working" and "is this working".
    private var liveSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(currentAddress)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f/s", model.ratePerSecond))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                }

                HStack(spacing: 14) {
                    tally("found", model.progress.findings.filter { $0.bytes != nil }.count,
                          theme.accent)
                    tally("gated", model.progress.findings.filter(\.isGated).count, theme.caution)
                    tally("absent", totals.absent, theme.textTertiary)
                    tally("no reply", totals.silent, theme.textTertiary)
                }

                if let seconds = remainingSeconds {
                    Text("about \(format(seconds)) left at this rate")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Label("Running", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(theme.textSecondary)
        } footer: {
            Text("Stopping is safe at any point — everything found so far is kept, and the next run picks up from the address on screen rather than starting again.")
        }
    }

    private func tally(_ label: String, _ count: Int, _ colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(count)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(colour)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var currentAddress: String {
        guard let service = model.currentService, let identifier = model.currentIdentifier else {
            return "starting…"
        }
        let width = service == 0x21 ? 2 : 4
        return String(format: "%02X%0\(width)X", service, identifier)
    }

    private var totals: (absent: Int, silent: Int) {
        (model.progress.absentTotal, model.progress.silentTotal)
    }

    private var remainingSeconds: TimeInterval? {
        guard let key = model.currentTarget,
              let target = targets.first(where: { $0.key == key }) else { return nil }
        return model.estimatedSecondsRemaining(for: target)
    }

    private func format(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds))s" }
        if seconds < 5400 { return "\(Int(seconds / 60)) min" }
        return String(format: "%.1f hours", seconds / 3600)
    }

    private var safetySection: some View {
        Section {
            Label(isMoving
                  ? "The car is moving. Scanning is disabled until it stops."
                  : "Park with the ignition on and the phone plugged in.",
                  systemImage: isMoving ? "exclamationmark.triangle" : "parkingsign.circle")
                .font(.system(size: 13))
                .foregroundStyle(isMoving ? theme.caution : theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Text("Every request here only reads — nothing can command a module to do anything. But this asks a driver-assistance module thousands of questions it has never been asked, which is not something to do while it is looking after you at speed. Progress is saved as it goes, so a run can be stopped and continued later.")
        }
    }

    /// Read from the car rather than trusted to the driver.
    ///
    /// The advice to park is easy to skim past; a speed reading is not an
    /// opinion. Falls back to allowing the scan when speed is unknown, since
    /// refusing on missing data would make this unusable on a car that does not
    /// report speed at all.
    private var isMoving: Bool {
        guard let speed = session.bus.signal(.speed), speed.updatedAt != nil else { return false }
        return speed.value > 1
    }

    private func row(target: ScanModel.Target,
                     service: (code: UInt8, label: String, count: UInt32)) -> some View {
        let done = model.progress.nextIdentifier(module: target.key, service: service.code)
        let fraction = Double(done) / Double(service.count)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(service.label)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.dialTrack)
                    Capsule().fill(theme.accent)
                        .frame(width: max(2, proxy.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 4)
            Text(model.progress.verdict(module: target.key, service: service.code))
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func controls(for target: ScanModel.Target) -> some View {
        if model.isRunning && model.currentTarget == target.key {
            Button("Stop", role: .destructive) {
                model.stop()
                stored = model.encoded()
            }
        } else {
            Button(model.remaining(for: target) == 0 ? "Scanned" : "Scan this module") {
                guard let driver = session.activeDriver else { return }
                model.start(target: target, driver: driver) {
                    stored = model.encoded()
                }
            }
            .disabled(model.isRunning || isMoving
                      || session.activeDriver == nil
                      || model.remaining(for: target) == 0)
        }
    }

    private func sendFindings() async {
        guard let text = model.findingsText else { return }
        isSending = true
        defer { isSending = false }

        let sink = NtfySink(configuration: NtfyConfiguration(topic: ntfyTopic))
        switch await sink.send(text, title: "Kobold deep scan") {
        case .success: sendResult = "Sent to “\(ntfyTopic)”."
        case .failure(let error): sendResult = error.localizedDescription
        }
    }

    @ViewBuilder
    private var findingsSection: some View {
        let findings = model.progress.findings
        if !findings.isEmpty {
            Section {
                ForEach(findings.suffix(40)) { finding in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.command)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(finding.isGated ? theme.caution : theme.accent)
                        Text(finding.summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 1)
                }

                // Available mid-run on purpose: a sweep stopped after twenty
                // minutes still found whatever it found, and that should not
                // have to wait for the other forty.
                if !ntfyTopic.isEmpty {
                    Button {
                        Task { await sendFindings() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Label("Send findings to ntfy", systemImage: "paperplane")
                        }
                    }
                    .disabled(isSending)
                }

                if let sendResult {
                    Text(sendResult)
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                }
            } header: {
                Text("Found (\(findings.count))").foregroundStyle(theme.textSecondary)
            } footer: {
                Text("Amber means the identifier exists but the module refused to hand it over — worth more than an absence, because it says the data is there. Everything found is written to the log as it happens, so a run stopped early is not a run wasted.")
            }
        }
    }
}

import SwiftUI
import KoboldCore

/// What the car says about its own health, on a surface of its own.
///
/// Everything here is read on demand and read at rest. None of it belongs on
/// the dashboard: a trouble code is not a reading, and a screen glanced at
/// while driving should carry things that change while driving. Keeping them
/// apart is also what lets this one be a list, with room for a sentence of
/// explanation next to each answer.
struct VehicleDiagnosticsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let session: SessionModel
    @State private var model = DiagnosticsModel()
    @State private var revealVIN = false
    @State private var showDeepScan = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle: prompt
                case .reading: reading
                case .failed(let message): failure(message)
                case .ready: results
                }
            }
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
                ToolbarItem(placement: .cancellationAction) {
                    if model.state == .ready {
                        Button("Re-read") { Task { await read() } }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDeepScan) { DeepScanView(session: session) }
    }

    // MARK: - States

    private var prompt: some View {
        ContentUnavailableView {
            Label("Not read yet", systemImage: "stethoscope")
        } description: {
            Text(session.activeDriver == nil
                 ? "Connect to the car first. These readings come from the ECUs, not from the app."
                 : "Reads trouble codes, emissions readiness and vehicle identity. Takes a few seconds and changes nothing on the car.")
        } actions: {
            Button("Read the car") { Task { await read() } }
                .buttonStyle(.borderedProminent)
                .disabled(session.activeDriver == nil)
        }
    }

    private var reading: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Asking the car…")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Could not read", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { Task { await read() } }
        }
    }

    private func read() async {
        guard let driver = session.activeDriver else { return }
        await model.read(using: driver, capability: session.capability)
    }

    // MARK: - Results

    private var results: some View {
        List {
            recallSection
            codesSection
            readinessSection
            statusSection
            identitySection
            modulesSection
        }
        .scrollContentBackground(.hidden)
    }

    /// Shown only when the code that gates the recall is actually present.
    ///
    /// Placed first and styled loudly because it is the one finding here worth
    /// money: the repair is covered, and the criterion is this exact code.
    @ViewBuilder
    private var recallSection: some View {
        if let code = model.fuelPumpRecallCode {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(code) is present", systemImage: "exclamationmark.shield")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.caution)
                    Text("This is the code the high-pressure fuel pump recall is gated on. Check your VIN at nhtsa.gov/recalls — if recall 023G is open, the pump is replaced free, and it is separately covered to 15 years / 150,000 miles. Do not buy a pump.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var codesSection: some View {
        Section {
            if !model.hasAnyCodes {
                Label("No trouble codes", systemImage: "checkmark.circle")
                    .foregroundStyle(theme.textSecondary)
            } else {
                codeRows("Stored", model.storedCodes,
                         note: "Confirmed faults. These turn the warning light on.")
                codeRows("Pending", model.pendingCodes,
                         note: "Seen once and not yet confirmed. They clear themselves if the fault does not repeat.")
                codeRows("Permanent", model.permanentCodes,
                         note: "Cannot be cleared with a scan tool. They clear only after the car has proved the fault is gone.")
            }
        } header: {
            sectionHeader("Trouble Codes", symbol: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func codeRows(_ title: String, _ codes: [String], note: String) -> some View {
        if !codes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
                ForEach(codes, id: \.self) { code in
                    Text(code)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                }
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var readinessSection: some View {
        if let readiness = model.readiness {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: readiness.isReadyForInspection
                          ? "checkmark.circle" : "clock.badge.exclamationmark")
                        .foregroundStyle(readiness.isReadyForInspection ? theme.accent : theme.caution)
                    Text(readiness.isReadyForInspection
                         ? "Ready for an emissions test"
                         : "^[\(readiness.incomplete.count) monitor](inflect: true) still to finish")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                }

                if readiness.malfunctionIndicatorOn {
                    Label("Warning light is on", systemImage: "light.beacon.max")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.caution)
                }

                ForEach(readiness.applicable) { monitor in
                    HStack {
                        Text(monitor.name)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: monitor.complete ? "checkmark" : "hourglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(monitor.complete ? theme.accent : theme.textTertiary)
                    }
                }
            } header: {
                sectionHeader("Emissions Readiness", symbol: "checklist")
            } footer: {
                Text("Self-tests the car runs as you drive. Clearing codes resets them all, and a car with monitors outstanding fails an inspection even with nothing wrong — which is why clearing codes before a test is a bad idea.")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if !model.fuelSystemStatus.isEmpty || model.fuelType != nil || model.obdStandard != nil {
            Section {
                ForEach(Array(model.fuelSystemStatus.enumerated()), id: \.offset) { index, status in
                    row(model.fuelSystemStatus.count > 1 ? "Fuel System \(index + 1)" : "Fuel System",
                        status)
                }
                if let fuelType = model.fuelType { row("Fuel", fuelType) }
                if let obdStandard = model.obdStandard { row("Conforms To", obdStandard) }
            } header: {
                sectionHeader("Status", symbol: "info.circle")
            } footer: {
                Text("Closed loop means the ECU is trimming fuel from the oxygen sensor. Open loop means it is running a fixed map — normal when cold, a fault if it persists.")
            }
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        if model.vin != nil || model.calibrationID != nil || model.ecuName != nil {
            Section {
                if let vin = model.vin {
                    // Hidden by default. It identifies the car and its owner,
                    // and this screen gets screenshotted.
                    Button {
                        revealVIN.toggle()
                    } label: {
                        HStack {
                            Text("VIN")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.textSecondary)
                            Spacer(minLength: 12)
                            Text(revealVIN ? vin : "•••••••••••••••••")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(theme.textPrimary)
                            Image(systemName: revealVIN ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                if let calibrationID = model.calibrationID { row("Calibration", calibrationID) }
                if let ecuName = model.ecuName { row("ECU", ecuName) }
            } header: {
                sectionHeader("Vehicle Identity", symbol: "number")
            } footer: {
                Text("The VIN checks open recalls at nhtsa.gov/recalls. The calibration ID is the ECU's software version — worth noting before a dealer visit, so you can tell afterwards whether it was reflashed. Neither is ever sent to the log.")
            }
        }
    }

    @ViewBuilder
    private var modulesSection: some View {
        if let modules = session.capability?.modules, !modules.isEmpty {
            Section {
                ForEach(modules) { module in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.label)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                        Text(module.version ?? "responds at \(module.header)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                Button {
                    showDeepScan = true
                } label: {
                    Label("Search for undocumented data", systemImage: "magnifyingglass")
                }
            } header: {
                sectionHeader("Modules", symbol: "cpu")
            } footer: {
                Text("Driver-assistance and chassis modules that answered a direct request, with their firmware. Presence and version is all that is published for these — but the factory tool reads live data from them over this same port, so the addresses exist and are simply undocumented. The search looks for them.")
            }
        }
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(theme.textSecondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

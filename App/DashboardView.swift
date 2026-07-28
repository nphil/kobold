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
    @State private var showVehicleDiagnostics = false
    @State private var showCapability = false
    /// The signal whose history sheet is open, if any.
    @State private var inspecting: SignalID?

    /// Persisted as JSON rather than as a list of names, so a card carries its
    /// presentation with it and the format can grow without a migration.
    @AppStorage("dashboardLayout") private var storedLayout = Data()

    @State private var layout = DashboardLayout()
    @State private var isEditing = false
    @State private var showSignalPicker = false

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

                hero
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
        // Long press is the whole entry point: nothing on the driving surface
        // advertises editing, because a control you can nudge at a glance is a
        // control you can nudge by accident.
        .onLongPressGesture(minimumDuration: 0.6) {
            guard !isEditing else { return }
            withAnimation(KoboldMotion.ui) { isEditing = true }
        }
        .sheet(isPresented: $showSignalPicker) {
            SignalPickerView(available: pickableSignals) { signal in
                withAnimation(KoboldMotion.ui) {
                    layout.add(signal)
                    persist()
                }
            }
        }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(session: session) }
        .sheet(isPresented: $showVehicleDiagnostics) {
            VehicleDiagnosticsView(session: session)
        }
        .sheet(isPresented: $showCapability) {
            VehicleCapabilityView(capability: session.capability,
                                  profileName: session.profileName)
        }
        .sheet(item: $inspecting) { id in
            if let signal = session.bus.signal(id) {
                SignalDetailView(signal: signal)
            }
        }
        .preferredColorScheme(.dark)
        .task { loadLayout() }
        // The car narrows the signal set partway through connecting, long after
        // this view built its layout. Without this, a card for something the
        // vehicle turned out not to report would stay on screen for the whole
        // session, permanently blank.
        .onChange(of: session.bus.revision) { loadLayout() }
    }

    // MARK: - Layout

    /// Signals the vehicle has that are not already on the dashboard.
    ///
    /// Sorted by display name, not identifier: the list is read by a person, and
    /// `fuelRailPressureDirect` sorting under F while reading as "Fuel Rail
    /// Pressure" is the kind of small wrongness that makes a list feel arbitrary.
    private var pickableSignals: [LiveSignal] {
        session.bus.availableSignals
            .filter { !layout.contains($0) }
            .compactMap { session.bus.signal($0) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func loadLayout() {
        let available = Set(session.bus.availableSignals)

        // Resolved against the car every time, not just on first load: a layout
        // outlives the vehicle it was built on, and a card bound to a signal
        // this profile lacks would sit there as a permanent dash. The signal set
        // also narrows mid-session, once the car reports what it supports.
        if let stored = DashboardLayout.decoded(from: storedLayout), !stored.isEmpty {
            layout = stored.resolved(against: available)
        } else {
            layout = DashboardLayout.standard(available: available)
        }
        syncRequests()
    }

    private func persist() {
        storedLayout = (try? layout.encoded()) ?? Data()
        syncRequests()
    }

    /// Tells the session to poll exactly what is on screen.
    ///
    /// The dashboard is the only place that knows which readings are being
    /// looked at, so it is the only place that can answer this. Keeping the two
    /// in step is also what stops a freshly added card from sitting blank.
    private func syncRequests() {
        session.request(layout.signals)
    }

    private func presentationBinding(for card: DashboardCard) -> Binding<DashboardCard.Presentation> {
        Binding(
            get: { layout.cards.first { $0.signal == card.signal }?.presentation ?? card.presentation },
            set: { layout.setPresentation($0, for: card.signal); persist() }
        )
    }

    /// Handles a drop: moves the dragged card so it takes the target's place.
    private func reorder(dragged: String?, onto target: SignalID) -> Bool {
        guard let dragged,
              let from = layout.signals.firstIndex(of: SignalID(dragged)),
              let to = layout.signals.firstIndex(of: target),
              from != to
        else { return false }

        withAnimation(KoboldMotion.ui) {
            layout.move(from: from, to: to)
            persist()
        }
        return true
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

            if isEditing {
                Button {
                    withAnimation(KoboldMotion.ui) { isEditing = false }
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.backgroundBottom)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.accent))
                }
                .accessibilityLabel("Finish editing the dashboard")
            } else {
                statusPill
                themeButton
            }
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
            // The same panel as the tiles, edged in caution rather than in
            // light. A banner that is a different material reads as a different
            // app's banner pasted in.
            .instrumentPanel(cornerRadius: 13, tint: theme.caution)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var themeButton: some View {
        Menu {
            Button {
                showVehicleDiagnostics = true
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            Button {
                showCapability = true
            } label: {
                Label("Vehicle Coverage", systemImage: "checklist")
            }

            Button {
                showDiagnostics = true
            } label: {
                Label("App & Logs", systemImage: "gearshape")
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

    /// The first card, given the room. A gauge only reads at this size, so the
    /// dial treatment belongs here and nowhere else.
    @ViewBuilder
    private var hero: some View {
        if let card = layout.cards.first, let signal = session.bus.signal(card.signal) {
            Group {
                if card.presentation == .gauge {
                    TachometerView(signal: signal, caption: signal.label.uppercased())
                } else {
                    DashboardCardView(card: card, signal: signal, isEditing: isEditing)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if !isEditing { inspecting = card.signal } }
            .overlay(alignment: .topTrailing) { editBadges(for: card) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows recent history")
        } else {
            ContentUnavailableView("Nothing on the dashboard",
                                   systemImage: "square.dashed",
                                   description: Text("Press and hold to choose what to show."))
                .frame(maxHeight: .infinity)
        }
    }

    private var tiles: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 104), spacing: 10)],
            spacing: 10
        ) {
            ForEach(Array(layout.cards.dropFirst()), id: \.id) { card in
                if let signal = session.bus.signal(card.signal) {
                    DashboardCardView(card: card, signal: signal, isEditing: isEditing)
                        .contentShape(Rectangle())
                        .onTapGesture { if !isEditing { inspecting = card.signal } }
                        .overlay(alignment: .topTrailing) { editBadges(for: card) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows recent history")
                        // String rather than a custom Transferable: the payload
                        // is one identifier and a bespoke type would be
                        // ceremony around a value that already round-trips.
                        .draggable(card.signal.rawValue) {
                            DashboardCardView(card: card, signal: signal, isEditing: false)
                                .frame(width: 120)
                                .opacity(0.9)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            reorder(dragged: items.first, onto: card.signal)
                        }
                }
            }

            if isEditing, !layout.isFull {
                addCardTile
            }
        }
    }

    /// Remove and re-present controls, shown only while editing.
    @ViewBuilder
    private func editBadges(for card: DashboardCard) -> some View {
        if isEditing {
            HStack(spacing: 6) {
                Menu {
                    Picker("Show as", selection: presentationBinding(for: card)) {
                        ForEach(DashboardCard.Presentation.allCases, id: \.self) { option in
                            Label(option.label, systemImage: option.symbolName).tag(option)
                        }
                    }
                } label: {
                    badge(systemName: card.presentation.symbolName, tint: theme.textSecondary)
                }

                Button {
                    withAnimation(KoboldMotion.ui) {
                        layout.remove(card.signal)
                        persist()
                    }
                } label: {
                    badge(systemName: "minus", tint: theme.danger)
                }
                .accessibilityLabel("Remove \(session.bus.signal(card.signal)?.label ?? card.signal.rawValue)")
            }
            .padding(6)
        }
    }

    private func badge(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(Circle().fill(theme.surfaceRaised))
            .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 1))
    }

    private var addCardTile: some View {
        Button {
            showSignalPicker = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
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

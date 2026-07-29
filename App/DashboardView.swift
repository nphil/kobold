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

    /// The card being dragged, where it is relative to its slot, and where each
    /// slot is. Only meaningful while editing.
    @State private var dragging: SignalID?
    @State private var dragOffset: CGSize = .zero
    @State private var dragBase: CGSize = .zero
    @State private var slotFrames: [SignalID: CGRect] = [:]
    /// The slot the dragged card currently belongs to. Read once at the start
    /// of the drag, when the offset is known to be zero, and then advanced by
    /// hand on each reorder — never re-measured, because by then the card is
    /// drawn somewhere else.
    @State private var dragHome: CGRect = .zero

    /// Named so the drag and the slot frames agree on an origin. The grid's own
    /// space rather than `.global`, so nothing shifts when the header changes
    /// height — an error banner appearing mid-drag would otherwise move every
    /// slot out from under the finger.
    private static let gridSpace = "dashboardGrid"

    var body: some View {
        panel
            .modifier(DashboardSheets(session: session,
                                      layout: $layout,
                                      showSignalPicker: $showSignalPicker,
                                      showDiagnostics: $showDiagnostics,
                                      showVehicleDiagnostics: $showVehicleDiagnostics,
                                      showCapability: $showCapability,
                                      inspecting: $inspecting,
                                      onChange: persist))
            .modifier(DashboardHaptics(phase: session.phase,
                                       isEditing: isEditing,
                                       dragging: dragging,
                                       order: layout.signals))
            .preferredColorScheme(.dark)
            .onChange(of: isEditing) { _, editing in if !editing { endAnyDrag() } }
            .onChange(of: inspecting) { _, _ in endAnyDrag() }
            .task { loadLayout() }
            // The car narrows the signal set partway through connecting, long
            // after this view built its layout. Without this, a card for
            // something the vehicle turned out not to report would stay on
            // screen for the whole session, permanently blank.
            .onChange(of: session.bus.revision) { loadLayout() }
    }

    private var panel: some View {
        ZStack {
            Fascia()

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
        .onLongPressGesture(minimumDuration: 0.6) { beginEditing() }
    }

    // MARK: - Layout

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
                    .font(KoboldType.label(26, weight: .semibold))
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
            .instrumentPanel(cornerRadius: 16, tint: failed ? theme.danger : nil)
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
                    // Sunk into the fascia while the tiles below sit proud of
                    // it. One dial recessed and everything else raised is how a
                    // real cluster says which instrument is the main one,
                    // without a label, a size jump or a colour doing the work.
                    //
                    // The padding is the bezel: the ring of panel between the
                    // dial's outer track and the wall of the recess. Without it
                    // the two edges land on each other and the dial reads as
                    // cropped rather than as mounted.
                    TachometerView(signal: signal, caption: signal.label.uppercased())
                        .padding(12)
                        .instrumentWell(shape: Circle())
                } else {
                    DashboardCardView(card: card, signal: signal, isEditing: isEditing)
                }
            }
            // Deliberately does not wiggle. It is the only card that cannot be
            // rearranged, and a wobble is a promise that it can be. The edit
            // badges are what put it in the mode.
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
            ForEach(Array(layout.cards.dropFirst().enumerated()), id: \.element.id) { index, card in
                if let signal = session.bus.signal(card.signal) {
                    let isMoving = dragging == card.signal

                    DashboardCardView(card: card, signal: signal, isEditing: isEditing)
                        .background(slotReader(card.signal))
                        .wiggle(isEditing && !reduceMotion && !isMoving, seed: index + 1)
                        // Lifted off the panel while it travels, and above its
                        // neighbours so it passes over them rather than through.
                        .scaleEffect(isMoving ? 1.07 : 1)
                        .offset(isMoving ? dragOffset : .zero)
                        .zIndex(isMoving ? 1 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture { if !isEditing { inspecting = card.signal } }
                        // Simultaneous so it never competes with the tap, and
                        // idempotent so the identical gesture on the panel
                        // behind can fire too without the mode flapping.
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.6)
                                .onEnded { _ in beginEditing() }
                        )
                        // Attached always and masked out when not editing, so
                        // enabling it costs no view identity — a conditional
                        // modifier here would tear the card down and back up
                        // every time the mode flips, restarting its sparkline.
                        .gesture(reorderGesture(for: card.signal),
                                 including: isEditing ? .all : .subviews)
                        .overlay(alignment: .topTrailing) { editBadges(for: card) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows recent history")
                }
            }

            if isEditing, !layout.isFull {
                addCardTile
            }
        }
        .coordinateSpace(name: Self.gridSpace)
        .onPreferenceChange(SlotFramesKey.self) { slotFrames = $0 }
        // The whole point of the thing: when the order changes, every card
        // that has to move animates to its new slot rather than teleporting.
        // Driven by the value rather than by `withAnimation` at the call site,
        // so it also covers a card being added or removed.
        .animation(reduceMotion ? .linear(duration: 0.12) : KoboldMotion.ui,
                   value: layout.signals)
    }

    private func beginEditing() {
        guard !isEditing else { return }
        withAnimation(KoboldMotion.ui) { isEditing = true }
    }

    /// Leaves no card stranded mid-lift.
    ///
    /// A drag ends by being let go, but it can also end by the mode ending
    /// under it — a sheet arriving, or Done being pressed with a finger still
    /// down. Without this the card stays scaled up and offset from its slot
    /// with nothing left to put it back.
    private func endAnyDrag() {
        guard dragging != nil else { return }
        withAnimation(reduceMotion ? .linear(duration: 0.12) : KoboldMotion.ui) {
            dragging = nil
            dragOffset = .zero
            dragBase = .zero
        }
    }

    /// Reports where a card's slot is, in the grid's own coordinate space.
    private func slotReader(_ signal: SignalID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SlotFramesKey.self,
                value: [signal: proxy.frame(in: .named(Self.gridSpace))]
            )
        }
    }

    /// Drag to reorder, in the shape the Home Screen set.
    ///
    /// The card follows the finger while the others give way underneath it,
    /// rather than nothing happening until a drop lands. That difference is the
    /// entire feel of it: a drop-based reorder gives no feedback about where
    /// the card will end up until it is already there.
    private func reorderGesture(for signal: SignalID) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                if dragging != signal {
                    dragging = signal
                    dragBase = .zero
                    dragHome = slotFrames[signal] ?? .zero
                }
                dragOffset = CGSize(width: dragBase.width + value.translation.width,
                                    height: dragBase.height + value.translation.height)

                guard let target = GridReorder.target(at: value.location,
                                                      in: slotFrames, excluding: signal),
                      let from = layout.signals.firstIndex(of: signal),
                      let to = layout.signals.firstIndex(of: target),
                      let landing = slotFrames[target]
                else { return }

                // `move` takes the card out and puts it back at `to`, so it
                // ends up in exactly the slot the target is vacating. Take that
                // distance back out of the offset and the card stays where the
                // finger left it while everything else rearranges around it.
                let shift = GridReorder.slotShift(from: dragHome, to: landing)
                dragBase.width -= shift.width
                dragBase.height -= shift.height
                dragHome = landing
                dragOffset = CGSize(width: dragBase.width + value.translation.width,
                                    height: dragBase.height + value.translation.height)

                layout.move(from: from, to: to)
            }
            .onEnded { _ in
                endAnyDrag()
                persist()
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
            .instrumentPanel(cornerRadius: 11)
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
            // An empty bay rather than a dashed rectangle: the same recess the
            // hero sits in, with nothing mounted in it yet. It reads as a space
            // for an instrument, which is what it is.
            .instrumentWell(cornerRadius: 15)
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(theme.hairline.opacity(0.7),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
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
                    .font(KoboldType.numeral(11, weight: .medium))
                    .monospacedDigit()
                Text("val/s")
            }
            .foregroundStyle(theme.textTertiary)

            HStack(spacing: 5) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 10, weight: .semibold))
                Text(frameRate.framesPerSecond, format: .number.precision(.fractionLength(0)))
                    .font(KoboldType.numeral(11, weight: .medium))
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

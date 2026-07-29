import SwiftUI
import KoboldCore

/// Everything the dashboard can present, lifted out of its body.
///
/// Five sheets and a haptic vocabulary are six modifiers that have nothing to
/// say about how the screen is laid out, and leaving them on the body was
/// enough — with everything else — to stop it compiling: Swift infers a body as
/// one expression whose type is the entire nest of `ModifiedContent`, and past
/// a certain length the solver gives up rather than slows down.
///
/// So these are here for a mechanical reason rather than a tidiness one. They
/// take plain values and bindings, which also makes each one legible on its
/// own — a list of what this screen can open, and a list of what it can be felt
/// to do.
struct DashboardSheets: ViewModifier {
    let session: SessionModel
    @Binding var layout: DashboardLayout
    @Binding var showSignalPicker: Bool
    @Binding var showDiagnostics: Bool
    @Binding var showVehicleDiagnostics: Bool
    @Binding var showCapability: Bool
    @Binding var inspecting: SignalID?

    /// Called after the layout is edited, so the change is persisted.
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showSignalPicker) {
                SignalPickerView(available: pickable) { signal in
                    withAnimation(KoboldMotion.ui) {
                        layout.add(signal)
                        onChange()
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
    }

    /// Signals the car has that are not already on the dashboard.
    ///
    /// Computed inside the sheet's builder rather than handed in, so it runs
    /// when the picker opens instead of on every evaluation of the dashboard's
    /// body — which, during a drag, is every frame. Sorting a few dozen names
    /// with `localizedStandardCompare` is cheap once and not cheap at 120 Hz.
    ///
    /// Sorted by display name rather than identifier, because the list is read
    /// by a person and `fuelRailPressureDirect` filing under F while reading as
    /// "Fuel Rail Pressure" is the kind of small wrongness that makes a list
    /// feel arbitrary.
    private var pickable: [LiveSignal] {
        session.bus.availableSignals
            .filter { !layout.contains($0) }
            .compactMap { session.bus.signal($0) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

/// The dashboard's haptic vocabulary, deliberately short.
///
/// Connecting and losing the car are the two events worth feeling without
/// looking, because both happen while the phone is mounted and the eyes are
/// elsewhere. The rest belong to rearranging, which is direct manipulation and
/// so gets the same ticks every other iOS rearrangement has.
///
/// Everything else on the dashboard is either a reading — which would buzz
/// continuously — or a deliberate tap the finger already knows it made.
///
/// `.sensoryFeedback` rather than a generator held here: it respects the system
/// haptic setting and Low Power Mode without being asked, which a hand-rolled
/// `UIImpactFeedbackGenerator` does not.
struct DashboardHaptics: ViewModifier {
    let phase: ConnectionPhase
    let isEditing: Bool
    let dragging: SignalID?
    /// The order of the cards, so a change to it can be felt.
    let order: [SignalID]

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: phase) { _, now in
                if now == .ready { return .success }
                if case .failed = now { return .error }
                return nil
            }
            // Only on entering. Leaving is a Done button, which already feels
            // like one.
            .sensoryFeedback(trigger: isEditing) { was, now in
                now && !was ? .selection : nil
            }
            // Lifting a card. Without it, a card that has not started moving
            // yet is indistinguishable from one that never will.
            .sensoryFeedback(trigger: dragging) { was, now in
                was == nil && now != nil ? .impact(weight: .light, intensity: 0.7) : nil
            }
            // And every slot it displaces on the way past.
            .sensoryFeedback(trigger: order) { _, _ in
                dragging != nil ? .selection : nil
            }
    }
}

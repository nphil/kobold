import SwiftUI
import UIKit

@main
struct KoboldApp: App {
    @State private var session = SessionModel()
    @AppStorage("themeID") private var themeID: String = KoboldTheme.midnight.id

    private var theme: KoboldTheme {
        KoboldTheme.all.first { $0.id == themeID } ?? .midnight
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(session: session, themeID: $themeID)
                .environment(\.theme, theme)
                .task {
                    // Starts in demo mode so the dashboard is alive on first
                    // launch with no adapter paired — the app should never open
                    // to an empty screen and a pairing chore.
                    session.startDemo()
                }
                // A dashboard is looked at while driving, so the screen must not
                // dim mid-glance. This also keeps the app foregrounded, which is
                // what the adapter itself requires to stay awake.
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
}

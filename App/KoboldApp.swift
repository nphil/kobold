import SwiftUI
import UIKit
import KoboldLog

@main
struct KoboldApp: App {
    @State private var session = SessionModel()
    @State private var frameRate = FrameRateMonitor()
    @AppStorage("themeID") private var themeID: String = KoboldTheme.midnight.id

    init() {
        LoggingSetup.install()
    }

    private var theme: KoboldTheme {
        KoboldTheme.all.first { $0.id == themeID } ?? .midnight
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(session: session, themeID: $themeID)
                .environment(\.theme, theme)
                .environment(frameRate)
                .task {
                    // Starts in demo mode so the dashboard is alive on first
                    // launch with no adapter paired — the app should never open
                    // to an empty screen and a pairing chore.
                    session.startDemo()
                    frameRate.start()
                }
                // A dashboard is looked at while driving, so the screen must not
                // dim mid-glance. This also keeps the app foregrounded, which is
                // what the adapter itself requires to stay awake.
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
}

/// Wires up log destinations at launch.
enum LoggingSetup {
    static func install() {
        Task.detached(priority: .utility) {
            await Logger.shared.add(sink: ConsoleSink())
            Log.info(.app, "Kobold \(Bundle.appVersion) (\(Bundle.appBuild)) launched")
        }
    }
}

extension Bundle {
    static var appVersion: String {
        main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var appBuild: String {
        main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}

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
                    // Goes straight for the adapter. An earlier version opened
                    // in demo mode so the dashboard was never empty, but a
                    // dashboard full of invented numbers is the wrong thing to
                    // show someone sitting in a car — it looks exactly like a
                    // working connection. Demo mode stays available from the
                    // source menu, chosen deliberately.
                    session.startAdapter()
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

/// Wires up log destinations, and rebuilds them when settings change.
enum LoggingSetup {

    static func install() {
        Task.detached(priority: .utility) {
            await reconfigure()
            Log.info(.app, "Kobold \(Bundle.appVersion) (\(Bundle.appBuild)) launched")
        }
    }

    /// Rebuilds the sink list from current settings.
    ///
    /// Remote logging is off unless explicitly switched on, and stays off if no
    /// topic has been chosen — shipping diagnostics to a public topic should
    /// never be something that happens by default.
    static func reconfigure() async {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "ntfyEnabled")
        let topic = defaults.string(forKey: "ntfyTopic") ?? ""
        // `integer(forKey:)` returns 0 for a key that was never written, and 0 is
        // `.debug` — which would quietly ship the whole sampling firehose to a
        // public topic for anyone who enabled the toggle without touching the
        // picker. Absence has to mean `.warning`, not "the lowest level".
        let level = (defaults.object(forKey: "ntfyLevel") as? Int)
            .flatMap(LogLevel.init(rawValue:)) ?? .warning

        await Logger.shared.removeAllSinks()
        await Logger.shared.add(sink: ConsoleSink())

        guard enabled, !topic.isEmpty else { return }
        await Logger.shared.add(
            sink: NtfySink(configuration: NtfyConfiguration(topic: topic, minimumLevel: level))
        )
        Log.info(.app, "Remote logging enabled")
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

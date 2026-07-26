import Foundation
import Observation
import QuartzCore
import UIKit
import KoboldLog

/// Measures the frame rate the app is actually achieving.
///
/// Exists because "the UI feels slow" is not a diagnosis. A `CADisplayLink`
/// fires once per delivered frame, so counting its callbacks over a window
/// gives the real rate, and comparing it against the screen's maximum says
/// whether the app is being throttled or is simply missing its budget.
///
/// The distinction matters here: on a ProMotion device the display can run at
/// 120Hz, but the system drops to 60Hz in Low Power Mode and when thermals
/// demand it, and it caps third-party apps at 60Hz entirely unless
/// `CADisableMinimumFrameDurationOnPhone` is set. Seeing 60 when the maximum
/// reads 120 is a very different problem from seeing 38 when the maximum
/// reads 60.
@MainActor
@Observable
final class FrameRateMonitor {

    /// Frames actually delivered per second, averaged over the last window.
    private(set) var framesPerSecond: Double = 0

    /// What this screen is capable of right now.
    private(set) var maximumFramesPerSecond: Int = 60

    /// Worst single-frame interval in the last window, in milliseconds.
    ///
    /// The average hides stutter: a run of good frames and one 60ms hitch still
    /// averages well, but the hitch is exactly what is visible.
    private(set) var worstFrameMilliseconds: Double = 0

    private var displayLink: CADisplayLink?
    private var frameCount = 0
    private var windowStart: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var worstInWindow: Double = 0

    /// How often to report. Long enough to be a stable average, short enough to
    /// catch a bad patch while it is happening.
    private let windowSeconds: CFTimeInterval = 2

    func start() {
        guard displayLink == nil else { return }

        maximumFramesPerSecond = UIScreen.main.maximumFramesPerSecond

        let link = CADisplayLink(target: FrameRateProxy(monitor: self),
                                 selector: #selector(FrameRateProxy.tick(_:)))
        // Ask for the full range. This is a request, not a guarantee: Core
        // Animation still arbitrates on battery and thermal state.
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: Float(maximumFramesPerSecond),
            preferred: Float(maximumFramesPerSecond)
        )
        link.add(to: .main, forMode: .common)
        displayLink = link

        windowStart = CACurrentMediaTime()
        lastFrame = windowStart
        frameCount = 0
        worstInWindow = 0

        Log.info(.ui, "Frame monitor started; display maximum \(maximumFramesPerSecond)Hz")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func frame(at timestamp: CFTimeInterval) {
        frameCount += 1

        let interval = (timestamp - lastFrame) * 1000
        if interval > worstInWindow { worstInWindow = interval }
        lastFrame = timestamp

        let elapsed = timestamp - windowStart
        guard elapsed >= windowSeconds else { return }

        framesPerSecond = Double(frameCount) / elapsed
        worstFrameMilliseconds = worstInWindow

        // Only worth a log line when it is actually bad, or debugging drowns in
        // healthy readings.
        let target = Double(maximumFramesPerSecond)
        if framesPerSecond < target * 0.8 || worstInWindow > 33 {
            Log.warning(.ui, String(format: "%.0f fps (max %d), worst frame %.0f ms",
                                    framesPerSecond, maximumFramesPerSecond, worstInWindow))
        } else {
            Log.debug(.ui, String(format: "%.0f fps (max %d)",
                                  framesPerSecond, maximumFramesPerSecond))
        }

        frameCount = 0
        worstInWindow = 0
        windowStart = timestamp
    }
}

/// CADisplayLink retains its target, so pointing it straight at the monitor
/// would create a cycle that survives `stop()`. This proxy holds the monitor
/// weakly and breaks it.
private final class FrameRateProxy: NSObject {
    private weak var monitor: FrameRateMonitor?

    init(monitor: FrameRateMonitor) {
        self.monitor = monitor
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            monitor?.frame(at: link.timestamp)
        }
    }
}

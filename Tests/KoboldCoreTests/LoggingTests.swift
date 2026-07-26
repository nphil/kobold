import XCTest
import Foundation
#if canImport(FoundationNetworking)
// URLRequest/HTTPURLResponse live here on Linux, not in Foundation.
import FoundationNetworking
#endif
@testable import KoboldLog

final class LogLevelTests: XCTestCase {

    func testLevelsOrderBySeverity() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.info)
        XCTAssertLessThan(LogLevel.info, LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.error)
    }

    func testEntryFormatsWithLevelAndCategory() {
        let entry = LogEntry(level: .warning, category: .elm327, message: "NO DATA")
        XCTAssertTrue(entry.formatted.contains("WARN"))
        XCTAssertTrue(entry.formatted.contains("elm327"))
        XCTAssertTrue(entry.formatted.contains("NO DATA"))
    }
}

final class LoggerTests: XCTestCase {

    func testEntriesAreBuffered() async {
        let logger = Logger()
        await logger.log(.info, .session, "one")
        await logger.log(.info, .session, "two")

        let recent = await logger.recent()
        XCTAssertEqual(recent.map(\.message), ["one", "two"])
    }

    func testEntriesBelowMinimumAreDropped() async {
        let logger = Logger()
        await logger.setMinimumLevel(.warning)

        await logger.log(.debug, .session, "noise")
        await logger.log(.error, .session, "signal")

        let recent = await logger.recent()
        XCTAssertEqual(recent.map(\.message), ["signal"])
    }

    /// The buffer backs an in-app log view and must not grow without bound on a
    /// path that runs continuously while driving.
    func testBufferIsBounded() async {
        let logger = Logger(bufferLimit: 10)
        for index in 0..<50 {
            await logger.log(.info, .session, "entry \(index)")
        }

        let recent = await logger.recent(limit: 100)
        XCTAssertEqual(recent.count, 10)
        // Oldest dropped, newest kept.
        XCTAssertEqual(recent.first?.message, "entry 40")
        XCTAssertEqual(recent.last?.message, "entry 49")
    }

    func testSinksReceiveEntries() async {
        let logger = Logger()
        let sink = CollectingSink()
        await logger.add(sink: sink)

        await logger.log(.error, .transport, "boom")

        let messages = await sink.messages()
        XCTAssertEqual(messages, ["boom"])
    }

    func testClearEmptiesTheBuffer() async {
        let logger = Logger()
        await logger.log(.info, .app, "something")
        await logger.clear()
        let recent = await logger.recent()
        XCTAssertTrue(recent.isEmpty)
    }
}

final class NtfyConfigurationTests: XCTestCase {

    /// On the public server the topic name is the only access control there is,
    /// so a generated one has to be long enough not to be guessable.
    func testRandomTopicIsLongAndUnpredictable() {
        let first = NtfyConfiguration.randomTopic()
        let second = NtfyConfiguration.randomTopic()

        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 20)
        XCTAssertTrue(first.hasPrefix("kobold-"))
        // Must stay within ntfy's permitted topic charset.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        XCTAssertTrue(first.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    /// Remote logging defaults must be conservative: warnings and above only,
    /// and batched slower than the public server's replenish rate.
    func testDefaultsRespectRateLimitsAndPrivacy() {
        let configuration = NtfyConfiguration(topic: "x")

        XCTAssertEqual(configuration.minimumLevel, .warning)
        XCTAssertGreaterThanOrEqual(configuration.flushInterval, 10)
        // The server turns bodies over 4 KB into attachments, which are useless
        // to read from a notification.
        XCTAssertLessThan(configuration.maximumBodyBytes, 4096)
        XCTAssertEqual(configuration.server.absoluteString, "https://ntfy.sh")
    }

    func testConfigurationRoundTripsThroughJSON() throws {
        let original = NtfyConfiguration(topic: "kobold-test", minimumLevel: .error)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NtfyConfiguration.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}

// MARK: - Helpers

private actor Collected {
    private var stored: [String] = []
    func append(_ message: String) { stored.append(message) }
    func all() -> [String] { stored }
}

private struct CollectingSink: LogSink {
    private let collected = Collected()

    func write(_ entry: LogEntry) {
        let collected = self.collected
        // Sinks are called synchronously; hop off to record without blocking.
        Task { await collected.append(entry.message) }
    }

    func messages() async -> [String] {
        // Give the detached recording task a moment to land.
        try? await Task.sleep(for: .milliseconds(50))
        return await collected.all()
    }
}

// MARK: - NtfySink delivery

final class NtfySinkDeliveryTests: XCTestCase {

    /// The bug this pins: `flush` used to cancel `flushTask` as its first
    /// statement, but on the timer path `flush` *runs on* that task — so it
    /// cancelled itself, `URLSession.data(for:)` threw `NSURLErrorCancelled`,
    /// the batch was re-queued, and the cycle repeated forever. Nothing batched
    /// was ever delivered, while the "send test message" button kept working
    /// because it ran on a fresh task. A real topic showed exactly one message.
    func testTimerDrivenDeliveryDoesNotRunOnACancelledTask() async throws {
        let recorder = Recorder()
        let sink = NtfySink(
            configuration: NtfyConfiguration(topic: "kobold-test",
                                             minimumLevel: .warning,
                                             flushInterval: 0.2),
            transport: { request in
                await recorder.record(cancelled: Task.isCancelled, request: request)
                return (Data(), HTTPURLResponse(url: request.url!,
                                                statusCode: 200,
                                                httpVersion: nil,
                                                headerFields: nil)!)
            }
        )

        sink.write(LogEntry(level: .error, category: .transport, message: "boom"))

        // Long enough for the 0.2s timer to fire on its own — no explicit flush.
        try await Task.sleep(for: .milliseconds(900))

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1, "the timer should have delivered exactly once")
        XCTAssertEqual(calls.first?.cancelled, false,
                       "delivery ran on a cancelled task, so the request would fail with -999")
    }

    /// Entries below the configured level must never leave the device.
    func testEntriesBelowMinimumLevelAreNeverTransmitted() async throws {
        let recorder = Recorder()
        let sink = NtfySink(
            configuration: NtfyConfiguration(topic: "kobold-test",
                                             minimumLevel: .warning,
                                             flushInterval: 0.2),
            transport: { request in
                await recorder.record(cancelled: Task.isCancelled, request: request)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                httpVersion: nil, headerFields: nil)!)
            }
        )

        sink.write(LogEntry(level: .debug, category: .session, message: "noise"))
        sink.write(LogEntry(level: .info, category: .session, message: "also noise"))
        // `write` hands off to the uploader's actor asynchronously, so flushing
        // immediately can outrun the enqueue.
        try await Task.sleep(for: .milliseconds(100))
        await sink.flush()

        let calls = await recorder.calls()
        XCTAssertTrue(calls.isEmpty, "nothing at or above .warning was logged")
    }

    /// The topic is appended to a base URL with no trailing slash, which is
    /// exactly where `URL(string:relativeTo:)` is easy to get wrong.
    func testTopicResolvesOntoTheServerURL() async throws {
        let recorder = Recorder()
        let sink = NtfySink(
            configuration: NtfyConfiguration(topic: "kobold-abc123", flushInterval: 0.2),
            transport: { request in
                await recorder.record(cancelled: Task.isCancelled, request: request)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                httpVersion: nil, headerFields: nil)!)
            }
        )

        sink.write(LogEntry(level: .error, category: .app, message: "x"))
        try await Task.sleep(for: .milliseconds(100))
        await sink.flush()

        let calls = await recorder.calls()
        let request = try XCTUnwrap(calls.first?.request)
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy.sh/kobold-abc123")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Tags"), "rotating_light")
    }
}

private actor Recorder {
    struct Call {
        let cancelled: Bool
        let request: URLRequest
    }

    private var stored: [Call] = []
    func record(cancelled: Bool, request: URLRequest) {
        stored.append(Call(cancelled: cancelled, request: request))
    }
    func calls() -> [Call] { stored }
}

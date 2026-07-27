import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configuration for shipping logs to an ntfy server.
public struct NtfyConfiguration: Sendable, Equatable, Codable {

    /// Topic to publish to.
    ///
    /// On the public server this *is* the credential. ntfy's own documentation
    /// puts it plainly: "the topic is essentially a password, so pick something
    /// that's not easily guessable." Anyone who knows it can read every message
    /// and publish their own.
    public var topic: String

    public var server: URL

    /// Entries below this are never transmitted.
    ///
    /// Defaults to warnings and errors. Debug traffic from the sampling loop
    /// would be both a privacy problem and a rate-limit problem, and is already
    /// available in Console and the in-app buffer.
    public var minimumLevel: LogLevel

    /// How long to accumulate before sending.
    ///
    /// The public server replenishes roughly one request per ten seconds after
    /// an initial burst, so anything faster than that earns a 429 and
    /// eventually an IP ban. Fifteen seconds leaves headroom.
    public var flushInterval: TimeInterval

    /// Flush early once the batch approaches this size.
    ///
    /// The server converts bodies over 4 KB into a downloadable attachment
    /// rather than inline text, which makes them useless to read from a
    /// notification. Staying under that keeps messages readable.
    public var maximumBodyBytes: Int

    public init(topic: String,
                server: URL = URL(string: "https://ntfy.sh")!,
                minimumLevel: LogLevel = .warning,
                flushInterval: TimeInterval = 15,
                maximumBodyBytes: Int = 3_500) {
        self.topic = topic
        self.server = server
        self.minimumLevel = minimumLevel
        self.flushInterval = flushInterval
        self.maximumBodyBytes = maximumBodyBytes
    }

    /// A long random topic, which is the only access control the public server
    /// offers. Not a substitute for self-hosting if the contents are sensitive.
    public static func randomTopic(prefix: String = "kobold") -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let suffix = String((0..<18).map { _ in alphabet.randomElement()! })
        return "\(prefix)-\(suffix)"
    }
}

/// Ships log entries to an ntfy topic.
///
/// Batched rather than per-line, for two independent reasons: the public server
/// rate-limits to roughly one request per ten seconds, and a notification per
/// log line would be unreadable even if it were allowed.
public final class NtfySink: LogSink {

    private let uploader: Uploader

    public init(configuration: NtfyConfiguration, session: URLSession = .shared) {
        uploader = Uploader(configuration: configuration, session: session, override: nil)
    }

    /// Testing seam.
    ///
    /// Exists so a test can observe the request *and the cancellation state of
    /// the task issuing it* without touching the network — which is the only way
    /// to pin down the class of bug where delivery silently runs on a cancelled
    /// task and every request fails with `NSURLErrorCancelled`.
    init(configuration: NtfyConfiguration, transport: @escaping NtfyTransport) {
        uploader = Uploader(configuration: configuration, session: .shared, override: transport)
    }

    public func write(_ entry: LogEntry) {
        let uploader = self.uploader
        Task { await uploader.enqueue(entry) }
    }

    /// Sends anything buffered immediately. Useful before backgrounding, and for
    /// a "send test message" button.
    public func flush() async {
        await uploader.flush(force: true)
    }

    public func sendTest() async -> Result<Void, Error> {
        await uploader.publish(
            body: "Kobold test message — logging is wired up correctly.",
            title: "Kobold",
            level: .info
        )
    }

    /// Publishes text immediately, ignoring `minimumLevel`.
    ///
    /// For things the person asked to be sent, which is a different question
    /// from how chatty the automatic log should be. A report someone tapped a
    /// button to get must not be silently dropped because the level happens to
    /// be set to warnings.
    public func send(_ body: String, title: String) async -> Result<Void, Error> {
        await uploader.publish(body: body, title: title, level: .info)
    }
}

/// How a request actually gets issued. Substituted in tests.
typealias NtfyTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

// MARK: - Uploader

private actor Uploader {

    private let configuration: NtfyConfiguration
    private let session: URLSession
    /// When set, replaces the real network call. `URLSession` stays a stored
    /// property rather than being captured in the closure, because it is not
    /// `Sendable` on every platform this builds for.
    private let override: NtfyTransport?

    private var pending: [LogEntry] = []
    private var pendingBytes = 0
    private var flushTask: Task<Void, Never>?

    /// Set when the server pushes back, so a rate-limited client stops digging.
    private var backoffUntil: Date?

    /// Hard cap on the buffer so a long backoff cannot grow it without bound.
    private let pendingLimit = 200

    private static func byteCount(of entries: [LogEntry]) -> Int {
        entries.reduce(0) { $0 + $1.formatted.utf8.count + 1 }
    }

    init(configuration: NtfyConfiguration, session: URLSession, override: NtfyTransport?) {
        self.configuration = configuration
        self.session = session
        self.override = override
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let override { return try await override(request) }
        return try await session.data(for: request)
    }

    func enqueue(_ entry: LogEntry) {
        guard entry.level >= configuration.minimumLevel else { return }

        pending.append(entry)
        pendingBytes += entry.formatted.utf8.count + 1

        if pending.count > pendingLimit {
            // Drop oldest: the most recent entries are the ones describing
            // whatever is going wrong now.
            pending.removeFirst(pending.count - pendingLimit)
            pendingBytes = Self.byteCount(of: pending)
        }

        if pendingBytes >= configuration.maximumBodyBytes {
            Task { await self.flush(force: false) }
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [interval = configuration.flushInterval] in
            try? await Task.sleep(for: .seconds(interval))
            // Cancelled means someone else already flushed; don't send twice.
            guard !Task.isCancelled else { return }
            await self.deliverPending(force: false)
        }
    }

    /// Flush requested from outside the timer.
    ///
    /// Safe to cancel the timer here precisely because no caller of this method
    /// is the timer task itself.
    func flush(force: Bool) async {
        flushTask?.cancel()
        flushTask = nil
        await deliverPending(force: force)
    }

    /// Sends whatever is buffered.
    ///
    /// This must never cancel `flushTask`: on the timer path it *is* the task
    /// this is running on, and cancelling it cancels the `URLSession` call
    /// below. That was a real bug — every batched entry failed with
    /// `NSURLErrorCancelled (-999)`, was re-queued, and retried forever, while
    /// the "send test message" button kept working because it ran on a fresh
    /// task. The symptom was a topic containing exactly one message.
    private func deliverPending(force: Bool) async {
        // Detached, not cancelled, so a later enqueue can schedule again.
        flushTask = nil

        guard !pending.isEmpty else { return }

        if let backoffUntil, Date() < backoffUntil, !force {
            scheduleFlush()
            return
        }

        let batch = pending
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0

        let worst = batch.map(\.level).max() ?? .info
        let body = batch.map(\.formatted).joined(separator: "\n")
        let title = "Kobold — \(batch.count) \(batch.count == 1 ? "entry" : "entries")"

        let result = await publish(body: body, title: title, level: worst)
        if case .failure = result {
            requeue(batch)
            scheduleFlush()
        }
    }

    /// Puts a failed batch back, newest-first, without exceeding the cap.
    private func requeue(_ batch: [LogEntry]) {
        // `pending` can have grown from concurrent enqueues while the request
        // was in flight, so the remaining room may be zero or negative — and
        // `Array.suffix` traps on a negative argument rather than returning
        // empty. The recent entries are the ones describing whatever is going
        // wrong, so the tail of the batch is what gets kept.
        let room = max(0, pendingLimit - pending.count)
        guard room > 0 else { return }

        pending.insert(contentsOf: batch.suffix(room), at: 0)
        pendingBytes = Self.byteCount(of: pending)
    }

    func publish(body: String, title: String, level: LogLevel) async -> Result<Void, Error> {
        guard !configuration.topic.isEmpty,
              let url = URL(string: configuration.topic, relativeTo: configuration.server)
        else {
            return .failure(NtfyError.invalidTopic)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(level.tag, forHTTPHeaderField: "Tags")
        request.setValue(priorityHeader(for: level), forHTTPHeaderField: "Priority")
        // Diagnostics are for the developer's own device; nothing here should
        // wake a phone at full volume unless it is genuinely an error.
        request.httpBody = Data(body.utf8)

        do {
            let (_, response) = try await perform(request)
            guard let http = response as? HTTPURLResponse else { return .success(()) }

            switch http.statusCode {
            case 200..<300:
                backoffUntil = nil
                return .success(())
            case 429:
                // Respect Retry-After when offered; otherwise back off well past
                // the documented replenish rate.
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init)) ?? 60
                backoffUntil = Date().addingTimeInterval(retryAfter)
                return .failure(NtfyError.rateLimited(retryAfter: retryAfter))
            default:
                return .failure(NtfyError.server(status: http.statusCode))
            }
        } catch {
            return .failure(error)
        }
    }

    private func priorityHeader(for level: LogLevel) -> String {
        switch level {
        case .debug: return "1"
        case .info: return "2"
        case .warning: return "3"
        case .error: return "4"
        }
    }
}

public enum NtfyError: Error, LocalizedError, Sendable {
    case invalidTopic
    case rateLimited(retryAfter: Double)
    case server(status: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidTopic:
            return "That topic name is not valid."
        case .rateLimited(let retryAfter):
            return "ntfy is rate limiting; retrying in \(Int(retryAfter))s."
        case .server(let status):
            return "ntfy returned HTTP \(status)."
        }
    }
}

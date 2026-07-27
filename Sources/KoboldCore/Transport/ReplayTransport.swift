import Foundation

/// A transport that answers from a fixture instead of a real adapter.
///
/// This exists so the entire stack above the transport — command loop, decoding,
/// profiles, signal bus, gauges — can be built and tested with no adapter and no
/// car. That matters more here than in most projects: the target hardware sleeps
/// when the app backgrounds and needs the engine running to answer most PIDs, so
/// hardware-in-the-loop iteration is slow and awkward.
///
/// It doubles as the backing for a demo mode, so the app can show a live-looking
/// dashboard before anything is paired.
public actor ReplayTransport: OBDTransport {

    /// Canned responses keyed by the command that triggers them.
    public struct Fixture: Sendable {
        /// Command text (no terminator, case-insensitive) → response lines.
        public var responses: [String: [String]]
        /// Returned for commands with no entry. `nil` means "NO DATA".
        public var fallback: [String]?
        /// Simulated round-trip delay.
        public var latency: Duration
        /// When true the transport accepts writes but never answers — modelling
        /// an adapter that has gone to sleep mid-session, which this class of
        /// hardware genuinely does. Distinct from an empty reply, which still
        /// emits a prompt and therefore still completes a response.
        public var isSilent: Bool

        public init(responses: [String: [String]],
                    fallback: [String]? = nil,
                    latency: Duration = .zero,
                    isSilent: Bool = false) {
            self.responses = responses
            self.fallback = fallback
            self.latency = latency
            self.isSilent = isSilent
        }
    }

    private var fixture: Fixture
    private var currentState: TransportState = .disconnected
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    /// Commands received, in order — lets tests assert on the init sequence and
    /// on batching behaviour.
    public private(set) var sentCommands: [String] = []

    public init(fixture: Fixture) {
        self.fixture = fixture
    }

    public var state: TransportState { currentState }

    public func connect() async throws {
        currentState = .connecting
        currentState = .connected
    }

    public func disconnect() async {
        currentState = .disconnected
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    /// Registers the subscription synchronously on the actor, so it is live
    /// before this returns and cannot miss a reply to an immediately-following
    /// `send`.
    public func makeInboundStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id: id) }
            }
        }
    }

    private func remove(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    public func send(_ bytes: Data) async throws {
        guard currentState == .connected else { throw TransportError.notConnected }

        let command = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        sentCommands.append(command)

        if fixture.latency > .zero {
            try? await Task.sleep(for: fixture.latency)
        }

        guard !fixture.isSilent else { return }

        let lines = fixture.responses[command]
            ?? fixture.responses[Self.withoutResponseCount(command)]
            ?? fixture.fallback
            ?? ["NO DATA"]
        emit(lines: lines)
    }

    /// Strips a trailing expected-response-count digit, the way a real adapter
    /// does before deciding what was actually requested.
    ///
    /// An ELM327 reads an odd number of hex digits as "request, then how many
    /// replies to wait for", so `010C1` and `010C` ask the same question. A
    /// fixture keyed on the plain command has to answer both, or every signal
    /// starts failing the moment the driver learns a count — which is a
    /// property of this stub, not of the car, and would have looked exactly
    /// like the optimisation being broken.
    static func withoutResponseCount(_ command: String) -> String {
        guard command.count % 2 == 1,
              command.count > 1,
              command.allSatisfy(\.isHexDigit)
        else { return command }
        return String(command.dropLast())
    }

    /// Writes a response followed by the `>` prompt, deliberately fragmented so
    /// consumers exercise the same reassembly path a real BLE peripheral forces.
    private func emit(lines: [String]) {
        var text = lines.joined(separator: "\r")
        text += "\r>"

        let bytes = Array(text.utf8)
        let chunkSize = 20  // Default ATT payload; the realistic worst case.

        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            let end = min(start + chunkSize, bytes.count)
            let chunk = Data(bytes[start..<end])
            for continuation in continuations.values {
                continuation.yield(chunk)
            }
        }
    }

    /// Replaces the fixture mid-session, for tests that simulate a car whose
    /// answers change (engine start, a fault appearing).
    public func update(fixture: Fixture) {
        self.fixture = fixture
    }
}

public extension ReplayTransport.Fixture {
    /// A fixture covering the init sequence plus a plausible idling engine.
    ///
    /// Values are hand-computed so the expected physical readings are obvious:
    /// RPM `0B B8` = 3000/4 = 750 rpm, speed `00` = 0 km/h, coolant `5A` = 90−40
    /// = 50 °C, MAP `22` = 34 kPa (idle vacuum), baro `65` = 101 kPa.
    static func idlingEngine() -> Self {
        Self(responses: [
            "ATZ": ["ELM327 v1.5"],
            "ATE0": ["OK"],
            "ATL0": ["OK"],
            "ATS0": ["OK"],
            "ATH1": ["OK"],
            "ATSP0": ["OK"],
            "ATDPN": ["6"],
            "0100": ["7E8 06 41 00 BE 3E B8 11"],
            "010C": ["7E8 04 41 0C 0B B8"],
            "010D": ["7E8 03 41 0D 00"],
            "0105": ["7E8 03 41 05 5A"],
            "010B": ["7E8 03 41 0B 22"],
            "0133": ["7E8 03 41 33 65"],
            "0111": ["7E8 03 41 11 00"],
            "010F": ["7E8 03 41 0F 46"],
            "0142": ["7E8 04 41 42 39 D0"],
            "0104": ["7E8 03 41 04 40"],
            "22E001": ["7E8 04 62 E0 01 78"],
            "03": ["7E8 02 43 00"]
        ], fallback: ["NO DATA"])
    }
}

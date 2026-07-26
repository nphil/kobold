import Foundation
import KoboldLog

public enum ELM327Error: Error, Equatable, Sendable {
    case notConnected
    case timeout(command: String)
    case deviceError(command: String, reply: ELM327Reply)
    case protocolNegotiationFailed
    case malformedResponse(String)

    /// The BLE link came up but the adapter never answered a single AT command.
    ///
    /// Distinct from `protocolNegotiationFailed` on purpose. Both used to
    /// surface as "did not complete initialisation", which sent the user to
    /// check their ignition when the real fault was that the wrong GATT
    /// characteristic pair had been adopted — a completely different fix. If
    /// the adapter is mute, nothing about the car matters yet.
    case adapterSilent(commandsTried: Int)
}

public enum ConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting
    case initialising
    case detectingProtocol
    case ready
    case failed(String)
}

/// Drives an ELM327-compatible adapter over any `OBDTransport`.
///
/// The actor exists to enforce the rule that makes these adapters behave: **one
/// command in flight at a time, and never write again until the `>` prompt has
/// come back.** Pipelining writes is the direct cause of the `STOPPED` error, and
/// it is the most common bug in naive BLE clients.
///
/// Actor isolation alone is not sufficient, because `await` points inside an
/// actor allow reentrancy — a second caller can slip in while the first is
/// suspended waiting for a reply. So commands are explicitly serialised through
/// an async gate below.
public actor ELM327Driver {

    private let transport: any OBDTransport
    private let descriptor: AdapterDescriptor

    private var assembler = ResponseAssembler()
    private var timing: AdaptiveTiming
    private var pending: CheckedContinuation<RawResponse, Error>?
    private var readerTask: Task<Void, Never>?

    /// Responses that arrived before anything was waiting for them.
    ///
    /// The reply to a command can land before the caller has registered its
    /// waiter — the write and the wait cannot be one atomic step, and a fast
    /// adapter (or a zero-latency replay transport) can answer in between.
    /// Buffering here instead of dropping is what stops that race from
    /// presenting as a spurious timeout.
    private var inbox: [RawResponse] = []

    // Async gate serialising command execution.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public private(set) var phase: ConnectionPhase = .disconnected
    /// Protocol number reported by `ATDPN`, once known.
    public private(set) var negotiatedProtocol: String?

    public init(transport: any OBDTransport,
                descriptor: AdapterDescriptor = .generic) {
        self.transport = transport
        self.descriptor = descriptor
        self.timing = AdaptiveTiming(initial: descriptor.initialTimeout)
    }

    // MARK: - Lifecycle

    /// Connects the transport, runs the init sequence, and negotiates a protocol.
    public func start() async throws {
        phase = .connecting

        // Subscribe before connecting so no early bytes are missed. The call is
        // awaited so the subscription is live before any command goes out.
        let inbound = await transport.makeInboundStream()
        readerTask = Task { [weak self] in
            for await chunk in inbound {
                await self?.ingest(chunk)
            }
        }

        do {
            try await transport.connect()
            phase = .initialising
            try await runInitSequence()
            phase = .detectingProtocol
            try await detectProtocol()
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
            throw error
        }
    }

    public func stop() async {
        readerTask?.cancel()
        readerTask = nil
        failPending(with: ELM327Error.notConnected)
        await transport.disconnect()
        assembler.reset()
        inbox.removeAll()
        phase = .disconnected
    }

    /// The init sequence. `ATE0` comes first among the display settings because
    /// every command echoed back before it lands has to be filtered out, and a
    /// stray echo is a common source of first-frame parsing failures.
    private func runInitSequence() async throws {
        var commands = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1"]
        if !descriptor.initOverrides.isEmpty {
            commands = descriptor.initOverrides
        }

        // Individually non-fatal, but collectively decisive: if *none* of these
        // draw a reply, the serial link is not working and there is no point
        // blaming the car. Previously every result was discarded with `try?`,
        // which meant a mute adapter and an asleep ECU produced identical
        // symptoms and identical (wrong) advice.
        var answered = 0
        for command in commands {
            do {
                // ATZ resets the device and answers with a banner rather than OK,
                // and a clone may answer '?' to a setting it doesn't implement.
                // Neither is fatal — probe behaviour instead of trusting the
                // version string.
                let reply = try await sendRaw(command, timeout: descriptor.resetTimeout)
                answered += 1
                Log.debug(.elm327, "\(command) -> \(reply.summary)")
            } catch {
                let description = String(describing: error)
                Log.warning(.elm327, "\(command) got no usable reply: \(description)")
            }
        }

        // Bound to immutable locals before logging: the message is an escaping
        // @Sendable autoclosure and cannot capture a mutable `var`.
        let replied = answered
        let attempted = commands.count

        guard replied > 0 else {
            Log.error(.elm327, "Adapter answered none of \(attempted) init commands — "
                      + "the serial characteristics are probably wrong")
            throw ELM327Error.adapterSilent(commandsTried: attempted)
        }

        Log.info(.elm327, "Init sequence: \(replied)/\(attempted) commands answered")
    }

    /// Auto-detects the bus protocol: `ATSP0`, provoke a real request, then read
    /// back what was negotiated with `ATDPN`.
    private func detectProtocol() async throws {
        _ = try? await sendRaw("ATSP0", timeout: descriptor.initialTimeout)

        // `0100` forces negotiation; the reply may be preceded by `SEARCHING...`,
        // which can take appreciably longer than a steady-state request.
        //
        // This is the first command that needs the *car* rather than just the
        // adapter, so it is the usual place an otherwise-healthy setup fails
        // with the ignition off. Logged either way: knowing whether the answer
        // was NO DATA, UNABLE TO CONNECT or a timeout is the whole difference
        // between "turn the key" and "the adapter is lying about its protocol".
        let probe = try await send("0100", timeout: descriptor.searchTimeout, retries: 2)
        guard probe.isData else {
            Log.error(.elm327, "Protocol negotiation failed — 0100 answered \(probe.summary). "
                      + "The adapter is responding, so this is the vehicle side: "
                      + "ignition off, or no supported protocol.")
            throw ELM327Error.protocolNegotiationFailed
        }
        Log.info(.elm327, "0100 answered \(probe.summary); protocol negotiated")

        if case .data(let lines) = try await sendRaw("ATDPN",
                                                    timeout: descriptor.initialTimeout) {
            negotiatedProtocol = lines.first
        }
    }

    // MARK: - Commands

    /// Sends a command and returns its classified reply.
    ///
    /// Transient replies (`SEARCHING...`, `STOPPED`) are retried rather than
    /// surfaced, since both mean "ask again" rather than "this failed".
    @discardableResult
    public func send(_ command: String,
                     timeout: Duration? = nil,
                     retries: Int = 1) async throws -> ELM327Reply {
        await acquire()
        defer { release() }

        var attempt = 0
        while true {
            let reply = try await sendRaw(command, timeout: timeout)

            if reply.isTransient, attempt < retries {
                attempt += 1
                continue
            }

            switch reply {
            case .bufferFull, .canError, .unableToConnect:
                throw ELM327Error.deviceError(command: command, reply: reply)
            default:
                return reply
            }
        }
    }

    /// Requests one signal and decodes it.
    public func read(_ definition: SignalDefinition) async throws -> Double {
        let reply = try await send(definition.command, retries: 1)
        guard case .data(let lines) = reply else {
            throw ELM327Error.deviceError(command: definition.command, reply: reply)
        }
        let responses = try ISOTPAssembler.assemble(lines: lines)

        // With headers on, prefer the ECU this signal expects; a functional
        // request can draw replies from several modules.
        let expected = expectedResponseHeader(for: definition.header)
        let response = responses.first { $0.header == expected } ?? responses.first

        guard let response else {
            throw ELM327Error.malformedResponse(lines.joined(separator: " | "))
        }
        return try PIDDecoder.decode(response, using: definition)
    }

    /// Reads stored trouble codes (Mode 03).
    public func readTroubleCodes() async throws -> [String] {
        let reply = try await send("03", retries: 1)
        guard case .data(let lines) = reply else { return [] }

        let responses = try ISOTPAssembler.assemble(lines: lines)
        return responses.flatMap { response -> [String] in
            // Mode 03 echoes no PID; the first data byte is the code count.
            let body = response.data(pidByteCount: 0)
            guard !body.isEmpty else { return [] }
            return DTCDecoder.codes(from: Array(body.dropFirst()))
        }
    }

    /// Walks the supported-PID bitmasks (`0100`, `0120`, …) to discover what the
    /// vehicle actually answers, rather than probing every PID blindly.
    public func discoverSupportedPIDs(maximumBanks: Int = 6) async throws -> Set<UInt8> {
        var supported: Set<UInt8> = []
        var base: UInt8 = 0x00

        for _ in 0..<maximumBanks {
            let command = "01" + String(format: "%02X", base)
            guard case .data(let lines) = try await send(command, retries: 1),
                  let response = try ISOTPAssembler.assemble(lines: lines).first
            else { break }

            let data = response.data(pidByteCount: 1)
            let pids = SupportedPIDDecoder.supportedPIDs(from: data, base: base)
            supported.formUnion(pids)

            // The last bit of each bank indicates whether the next bank exists.
            let nextBase = base &+ 0x20
            guard pids.contains(nextBase) else { break }
            base = nextBase
        }
        return supported
    }

    // MARK: - Transport plumbing

    private func sendRaw(_ command: String, timeout: Duration?) async throws -> ELM327Reply {
        guard await transport.state == .connected else {
            throw ELM327Error.notConnected
        }

        let payload = Data((command + descriptor.commandTerminator).utf8)
        let started = ContinuousClock.now

        // Discard anything unsolicited buffered before this command — a late
        // reply to a previous request must never be paired with this one.
        inbox.removeAll()

        try await transport.send(payload)

        do {
            let raw = try await awaitResponse(timeout: timeout ?? timing.current,
                                              command: command)
            timing.recordSuccess(roundTrip: ContinuousClock.now - started)
            return ELM327ReplyParser.parse(raw, echoOf: command)
        } catch {
            timing.recordTimeout()
            throw error
        }
    }

    private func awaitResponse(timeout: Duration, command: String) async throws -> RawResponse {
        // The reply may already be here — see `inbox`.
        if !inbox.isEmpty { return inbox.removeFirst() }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failPending(with: ELM327Error.timeout(command: command))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            self.pending = continuation
        }
    }

    private func ingest(_ chunk: Data) {
        for response in assembler.append(chunk) {
            deliver(response)
        }
    }

    private func deliver(_ response: RawResponse) {
        guard let continuation = pending else {
            // Nothing waiting yet. This is the normal race between writing a
            // command and registering its waiter, so buffer rather than drop;
            // `sendRaw` clears the inbox before each write, which is what keeps
            // a genuinely stale reply from being paired with the wrong command.
            inbox.append(response)
            return
        }
        pending = nil
        continuation.resume(returning: response)
    }

    private func failPending(with error: Error) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(throwing: error)
    }

    /// Maps a request header to the response header the ECU replies on.
    /// On 11-bit CAN the convention is request `7E0`–`7E7` → response `7E8`–`7EF`.
    private func expectedResponseHeader(for requestHeader: String) -> String? {
        guard requestHeader.count == 3,
              let value = UInt16(requestHeader, radix: 16) else { return nil }
        guard (0x7E0...0x7E7).contains(value) else { return nil }
        return String(format: "%03X", value + 8)
    }

    // MARK: - Serialisation gate

    private func acquire() async {
        while isBusy {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        isBusy = true
    }

    private func release() {
        isBusy = false
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

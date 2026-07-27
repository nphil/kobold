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

    /// A protocol number learned on a previous connection, if any.
    ///
    /// Supplying it turns the slowest part of connecting into the fastest: the
    /// adapter is told which protocol to use instead of discovering it, so the
    /// search is skipped entirely.
    private let preferredProtocol: String?

    public init(transport: any OBDTransport,
                descriptor: AdapterDescriptor = .generic,
                preferredProtocol: String? = nil) {
        self.transport = transport
        self.descriptor = descriptor
        self.preferredProtocol = preferredProtocol
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

        guard answered > 0 else {
            Log.error(.elm327, "Adapter answered none of \(commands.count) init commands — "
                      + "the serial characteristics are probably wrong")
            throw ELM327Error.adapterSilent(commandsTried: commands.count)
        }

        Log.info(.elm327, "Init sequence: \(answered)/\(commands.count) commands answered")
    }

    /// Auto-detects the bus protocol: `ATSP0`, provoke a real request, then read
    /// back what was negotiated with `ATDPN`.
    private func detectProtocol() async throws {
        // Fast path: a protocol already negotiated with this adapter on a
        // previous connection. The search is the slow part of connecting — the
        // link itself takes well under a second — so skipping it is the whole
        // difference between a snappy reconnect and waiting around.
        //
        // `ATSP A<n>` rather than `ATSP <n>`: the `A` means "use this one, but
        // fall back to searching if it does not answer", so a remembered
        // protocol can never strand the app on a different car or a rewired
        // bus. Being wrong costs one short timeout, not a failed connection.
        if let remembered = preferredProtocol, !remembered.isEmpty {
            _ = try? await sendRaw("ATSPA\(remembered)", timeout: descriptor.initialTimeout)

            if let reply = try? await send("0100",
                                           timeout: descriptor.searchTimeout,
                                           retries: 1),
               reply.isData {
                await readNegotiatedProtocol()
                Log.info(.elm327, "Reused protocol \(remembered) — search skipped")
                return
            }

            Log.info(.elm327, "Remembered protocol \(remembered) did not answer; "
                     + "falling back to a full search")
        }

        _ = try? await sendRaw("ATSP0", timeout: descriptor.initialTimeout)

        // `0100` forces negotiation; the reply may be preceded by `SEARCHING...`,
        // which can take appreciably longer than a steady-state request.
        //
        // This is the first command that needs the *car* rather than just the
        // adapter, so it is the usual place an otherwise-healthy setup fails
        // with the ignition off. Logged either way: knowing whether the answer
        // was NO DATA, UNABLE TO CONNECT or a timeout is the whole difference
        // between "turn the key" and "the adapter is lying about its protocol".
        let budget = descriptor.protocolSearchTimeout
        let budgetSeconds = budget.components.seconds
        Log.info(.elm327, "Negotiating protocol (0100, up to \(budgetSeconds)s)")

        let probe: ELM327Reply
        do {
            // One attempt, not several: retries multiply the budget, and three
            // tries at 25s each would be a 75-second ceiling rather than the
            // 25 this is meant to be. The adapter is already retrying
            // internally — that is what the protocol search *is*.
            probe = try await send("0100", timeout: budget, retries: 0)
        } catch ELM327Error.timeout {
            // A timeout here is not "the adapter is broken" — it answered every
            // AT command to get this far. It means the protocol search ran to
            // the end of its budget without the vehicle ever replying, which is
            // the same conclusion as UNABLE TO CONNECT and deserves the same
            // advice rather than a bare `timeout(command: "0100")`.
            Log.error(.elm327, "0100 produced nothing within \(budgetSeconds)s. The adapter is "
                      + "answering, so the vehicle side is silent: ignition off, or no "
                      + "supported protocol.")
            throw ELM327Error.protocolNegotiationFailed
        }

        guard probe.isData else {
            Log.error(.elm327, "Protocol negotiation failed — 0100 answered \(probe.summary). "
                      + "The adapter is responding, so this is the vehicle side: "
                      + "ignition off, or no supported protocol.")
            throw ELM327Error.protocolNegotiationFailed
        }
        Log.info(.elm327, "0100 answered \(probe.summary); protocol negotiated")
        await readNegotiatedProtocol()
    }

    /// Reads back what the adapter settled on, so the next connection can skip
    /// the search.
    ///
    /// `ATDPN` reports an automatically-detected protocol with a leading `A`
    /// (`A6` meaning "auto-detected, protocol 6"). That prefix is stripped
    /// before storing, because what gets replayed later is the number — the
    /// caller re-applies the auto-fallback prefix itself. Protocol identifiers
    /// are single characters `0`–`9` and `A`–`C`, so a bare `A` is a real
    /// protocol and must not be mistaken for the marker.
    private func readNegotiatedProtocol() async {
        guard case .data(let lines)? = try? await sendRaw("ATDPN",
                                                          timeout: descriptor.initialTimeout),
              var reported = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !reported.isEmpty
        else { return }

        if reported.count > 1, reported.hasPrefix("A") {
            reported.removeFirst()
        }

        negotiatedProtocol = reported
        Log.info(.elm327, "Protocol \(reported) recorded for next time")
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
        return try await sendLocked(command, timeout: timeout, retries: retries)
    }

    /// `send` without the gate, for sequences that must not be interleaved.
    ///
    /// Anything that changes the adapter's header state is one of those: a
    /// command landing between `ATSH 7D0` and the request it was set up for
    /// would be addressed to the wrong module.
    private func sendLocked(_ command: String,
                            timeout: Duration? = nil,
                            retries: Int = 1) async throws -> ELM327Reply {
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
        let command = definition.command
        let expected = expectedResponseHeader(for: definition.header)
        let hint = responseCountHint(for: command, expecting: expected)

        let reply = try await send(hint.map { command + String($0) } ?? command, retries: 1)
        guard case .data(let lines) = reply else {
            if hint != nil { forgetResponseCount(for: command, reason: "no data") }
            throw ELM327Error.deviceError(command: command, reply: reply)
        }
        let responses = try ISOTPAssembler.assemble(lines: lines)

        // With headers on, prefer the ECU this signal expects; a functional
        // request can draw replies from several modules.
        let match = responses.first { $0.header == expected }

        // Cutting the wait short must never change *which* module is believed.
        // If the reply we optimised for is not the one that came back, the hint
        // was wrong for this command — drop it and let the next pass hear
        // everyone out again.
        if hint != nil, expected != nil, match == nil {
            forgetResponseCount(for: command, reason: "wrong responder")
        } else if hint == nil {
            learnResponseCount(for: command, lines: lines, responses: responses)
        }

        guard let response = match ?? responses.first else {
            throw ELM327Error.malformedResponse(lines.joined(separator: " | "))
        }
        return try PIDDecoder.decode(response, using: definition)
    }

    // MARK: - Response-count hints

    /// How many replies each command has actually produced, once observed.
    ///
    /// An ELM327 with no idea how many modules will answer has to wait out its
    /// full timeout on every request, in case another reply is still coming.
    /// Telling it the count lets it return the moment they have all arrived —
    /// the datasheet's own example is "10 to 12 responses per second instead of
    /// the 6 obtained previously".
    ///
    /// Learned rather than assumed. Hard-coding "expect 1" would be faster
    /// immediately and wrong on any PID two modules answer: the adapter would
    /// return the first reply, which is not necessarily the one addressed, and
    /// a speed win that quietly attributes the transmission's data to the
    /// engine is worse than being slow.
    private var learnedResponseCounts: [String: Int] = [:]

    /// Set when the adapter appears not to honour the count digit at all.
    private var responseCountsDisabled = false
    private var responseCountFailures = 0

    private func responseCountHint(for command: String, expecting expected: String?) -> Int? {
        // Without a known response header there is no way to tell a correct
        // early return from a wrong one, so those commands are left alone.
        guard !responseCountsDisabled, expected != nil else { return nil }
        return learnedResponseCounts[command]
    }

    private func learnResponseCount(for command: String,
                                    lines: [String],
                                    responses: [ECUResponse]) {
        guard !responseCountsDisabled, !responses.isEmpty, responses.count < 16 else { return }

        // Only single-frame replies. The digit's meaning for a multi-frame
        // reply — frames, or complete messages? — is not documented anywhere
        // this was sourced from, and guessing wrong on the one signal that
        // needs reassembly is not worth a few milliseconds.
        guard lines.count == responses.count else { return }

        learnedResponseCounts[command] = responses.count
    }

    private func forgetResponseCount(for command: String, reason: String) {
        guard learnedResponseCounts.removeValue(forKey: command) != nil else { return }

        responseCountFailures += 1
        // A handful of these means the adapter does not implement the digit —
        // clones vary — so stop trying rather than paying a failed read per
        // signal per pass forever.
        if responseCountFailures >= 3 {
            responseCountsDisabled = true
            learnedResponseCounts.removeAll()
        }
    }

    /// Commands currently being asked with a response-count hint, for logging
    /// and tests. Empty until the first pass has been heard out in full.
    public var responseCountHints: [String: Int] { learnedResponseCounts }
    public var usesResponseCounts: Bool { !responseCountsDisabled }

    /// A module that answered a diagnostic request, and what it said it is.
    public struct ModuleIdentity: Sendable, Equatable, Identifiable {
        public let key: String
        public let label: String
        public let header: String
        /// Firmware or part identifier from `22F100`, when it decodes as text.
        public let version: String?

        public var id: String { key }
    }

    /// Asks each module whether it is there, and what version it is.
    ///
    /// Standard OBD modules answer a functional broadcast, so they need no
    /// introduction. Chassis and driver-assistance modules do not — they are
    /// reachable only by addressing them directly, which means setting the
    /// adapter's transmit header and receive filter for each one. Hence a probe
    /// rather than a list: the profile says where to look, the car says what is
    /// actually fitted.
    ///
    /// `22F100` is the identification DID. It is the only one publicly
    /// documented for these modules — there is no published DID for radar
    /// targets or lane position, so presence and version is genuinely all this
    /// can report, and claiming more would be inventing it.
    ///
    /// Never throws. A module that does not answer is the expected result on
    /// most cars, and one that fails must not take the session with it.
    public func identifyModules(
        _ modules: [(key: String, label: String, transmit: String, receive: String?)]
    ) async -> [ModuleIdentity] {

        guard !modules.isEmpty else { return [] }

        await acquire()
        var found: [ModuleIdentity] = []

        for module in modules {
            do {
                _ = try await sendLocked("ATSH \(module.transmit)", retries: 0)
                if let receive = module.receive {
                    // Without this, several modules' multi-frame replies
                    // interleave and their sequence numbers collide.
                    _ = try await sendLocked("ATCRA \(receive)", retries: 0)
                }

                let reply = try await sendLocked("22F100", timeout: .milliseconds(1200), retries: 0)
                guard case .data(let lines) = reply,
                      let response = try? ISOTPAssembler.assemble(lines: lines).first
                else { continue }

                found.append(ModuleIdentity(key: module.key,
                                            label: module.label,
                                            header: module.transmit,
                                            version: Self.identifier(from: response)))
            } catch {
                // Expected whenever a module is not fitted. Worth a line at
                // debug, not a warning: absence is the common case.
                continue
            }
        }

        // Restored unconditionally. Leaving the header pointed at the radar
        // would break every subsequent PID read, so this must happen on the
        // failure path as much as the success one — which is why nothing above
        // is allowed to throw out of this function.
        _ = try? await sendLocked("ATAR", retries: 0)
        _ = try? await sendLocked("ATSH 7DF", retries: 0)

        release()
        return found
    }

    /// Pulls a readable identifier out of a `62 F1 00 …` reply.
    ///
    /// Some modules answer with ASCII, others with a binary part number. Text
    /// is returned when it is text and nothing is returned when it is not,
    /// rather than rendering bytes as mojibake and calling it a version.
    private static func identifier(from response: ECUResponse) -> String? {
        let payload = response.data(pidByteCount: 2)
        guard !payload.isEmpty else { return nil }

        let printable = payload.filter { $0 >= 0x20 && $0 < 0x7F }
        guard printable.count >= max(4, payload.count / 2) else { return nil }

        let text = String(decoding: printable, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Reads stored trouble codes (Mode 03).
    public func readTroubleCodes(mode: String = "03") async throws -> [String] {
        let reply = try await send(mode, retries: 1)
        guard case .data(let lines) = reply else { return [] }

        let responses = try ISOTPAssembler.assemble(lines: lines)
        return responses.flatMap { response -> [String] in
            // Mode 03 echoes no PID; the first data byte is the code count.
            let body = response.data(pidByteCount: 0)
            guard !body.isEmpty else { return [] }
            return DTCDecoder.codes(from: Array(body.dropFirst()))
        }
    }

    /// Reads a Mode 09 text value — VIN, calibration ID, ECU name.
    ///
    /// Multi-frame and ASCII, so it shares nothing with the numeric path. The
    /// reply carries a message count byte before the text on some vehicles and
    /// not others, so anything outside printable ASCII is dropped rather than
    /// assumed to be a specific framing.
    public func readVehicleInfoText(pid: UInt8) async throws -> String? {
        let command = "09" + String(format: "%02X", pid)
        guard case .data(let lines) = try await send(command, retries: 1),
              let response = try ISOTPAssembler.assemble(lines: lines).first
        else { return nil }

        let payload = response.data(pidByteCount: 1)
        let printable = payload.filter { $0 >= 0x20 && $0 < 0x7F }
        let text = String(decoding: printable, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Reads the raw data bytes of one Mode 01 PID, for values that are flags
    /// or states rather than numbers.
    public func readRawPID(_ pid: UInt8) async throws -> [UInt8]? {
        let command = "01" + String(format: "%02X", pid)
        guard case .data(let lines) = try await send(command, retries: 1),
              let response = try ISOTPAssembler.assemble(lines: lines).first
        else { return nil }
        let data = response.data(pidByteCount: 1)
        return data.isEmpty ? nil : data
    }

    /// Walks the supported-PID bitmasks (`0100`, `0120`, …) to discover what the
    /// vehicle answers, rather than probing every PID blindly.
    ///
    /// The bitmask is a *declaration*, not a probe: the ECU states which PIDs it
    /// implements, so this is authoritative and does not depend on the engine
    /// running or the car moving. That is why discovery reads it instead of
    /// requesting each PID and watching for `NO DATA`, which would report a
    /// PID as absent merely because the engine was off when it was asked.
    ///
    /// **Every responder is unioned.** A functional request reaches all modules
    /// and each answers with its own capabilities — the reference car returns
    /// three responses to `0100`. Reading only the first, which this used to do,
    /// silently hid everything the transmission or any other module supports
    /// but the engine ECU does not.
    ///
    /// `mode` exists because Mode 09 (vehicle information) publishes its own
    /// bitmask at `0900` in exactly this format. Those two are the whole list:
    /// manufacturer modes have no equivalent, which is why nothing can
    /// enumerate them.
    public func discoverSupportedPIDs(mode: String = "01",
                                      maximumBanks: Int = 7) async throws -> Set<UInt8> {
        var supported: Set<UInt8> = []
        var base: UInt8 = 0x00

        for _ in 0..<maximumBanks {
            let command = mode + String(format: "%02X", base)
            guard case .data(let lines) = try await send(command, retries: 1) else { break }

            let responses = try ISOTPAssembler.assemble(lines: lines)
            guard !responses.isEmpty else { break }

            var bankPIDs: Set<UInt8> = []
            for response in responses {
                let data = response.data(pidByteCount: 1)
                bankPIDs.formUnion(SupportedPIDDecoder.supportedPIDs(from: data, base: base))
            }

            supported.formUnion(bankPIDs)

            // The last bit of a bank declares whether the next one exists. Any
            // module claiming it is enough to justify asking.
            let nextBase = base &+ 0x20
            guard bankPIDs.contains(nextBase) else { break }
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
    ///
    /// On 11-bit CAN the reply arrives at request + 8 — `7E0`→`7E8` for the
    /// engine, and equally `7A0`→`7A8` for tyre pressures or `7D0`→`7D8` for the
    /// radar. This used to answer only for `7E0`–`7E7`, which meant a reply from
    /// any other module had no expected header and fell back to whichever ECU
    /// happened to answer first.
    ///
    /// `7DF` is excluded deliberately: it is the functional broadcast address,
    /// not a module, and nothing replies from `7E7`.
    private func expectedResponseHeader(for requestHeader: String) -> String? {
        guard requestHeader.count == 3,
              let value = UInt16(requestHeader, radix: 16),
              value != 0x7DF,
              value + 8 <= 0x7FF
        else { return nil }
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

import Foundation

/// Connection lifecycle of a transport.
public enum TransportState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

public enum TransportError: Error, Equatable, Sendable {
    case notConnected
    case connectionFailed(String)
    case writeFailed(String)
    case timeout
}

/// Carries bytes to and from an ELM327-speaking device.
///
/// Everything above this protocol — the command loop, decoding, the UI — is
/// identical regardless of how bytes move. BLE is the first real implementation;
/// `ReplayTransport` and a future WiFi/TCP transport conform to the same
/// contract, which is what keeps the adapter out of the app's core.
///
/// Implementations must be safe to use from concurrent contexts; the driver
/// serialises access, but the transport may receive `disconnect()` at any time.
public protocol OBDTransport: Sendable {
    var state: TransportState { get async }

    func connect() async throws
    func disconnect() async

    /// Writes one command's bytes (including any terminator the device needs).
    func send(_ bytes: Data) async throws

    /// Inbound bytes exactly as received — possibly fragmented mid-response.
    ///
    /// BLE notify events split long replies across packets, so reassembly is the
    /// consumer's job (see `ResponseAssembler`).
    ///
    /// Deliberately `async`: the subscription must be registered before this
    /// returns, or a caller that creates the stream and immediately sends can
    /// miss the reply. Registering from a detached task loses that race.
    func makeInboundStream() async -> AsyncStream<Data>
}

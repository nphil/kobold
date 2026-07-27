// Minimal stand-ins for the Apple-only pieces SessionModel touches, so the file
// can be type-checked on Linux. Not a substitute for the iOS build — it only
// proves the concurrency/generation plumbing is well-formed.
import Foundation
@_exported import KoboldCore
@_exported import KoboldLog

public final class BLETransport: OBDTransport, @unchecked Sendable {
    public init(descriptor: AdapterDescriptor = .generic, scanTimeout: TimeInterval = 12) {}
    public var adapterName: String? { nil }
    public var state: TransportState { get async { .disconnected } }
    public func makeInboundStream() async -> AsyncStream<Data> { AsyncStream { $0.finish() } }
    public func connect() async throws {}
    public func disconnect() async {}
    public func send(_ bytes: Data) async throws {}

    public enum BLEError: Error, Sendable, Equatable {
        case bluetoothUnavailable(String), noAdapterFound, connectionFailed(String)
        case serialProfileNotFound, notConnected
    }
}

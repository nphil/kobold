import Foundation

/// Reassembles fragmented inbound bytes into complete ELM327 responses.
///
/// This is the single most load-bearing detail when talking to a BLE ELM327
/// clone: one write does **not** yield one notify packet. Replies arrive split
/// across multiple notifications (assume a 20-byte ATT payload unless the
/// peripheral negotiates more), and the only reliable "reply complete" marker is
/// the `>` prompt the device emits when it is ready for the next command.
///
/// Waiting for `>` before sending again is also what prevents the ELM327 from
/// printing `STOPPED` — that error means a command arrived while an OBD
/// operation was still in flight, which is a client bug, not a device fault.
public struct ResponseAssembler: Sendable {
    /// ELM327 ready prompt.
    public static let prompt: UInt8 = 0x3E  // '>'
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A

    private var buffer: [UInt8] = []

    /// Caps buffer growth if a device never emits a prompt (malformed firmware,
    /// or a stream that desynchronised). Generous: a multi-frame Mode 09 reply
    /// with headers on is only a few hundred bytes.
    private let maximumBufferSize: Int

    public init(maximumBufferSize: Int = 8192) {
        self.maximumBufferSize = maximumBufferSize
    }

    /// Appends inbound bytes and returns every response completed by them.
    ///
    /// A single append may complete zero, one, or several responses — the latter
    /// happens when reconnecting to a device with queued output, or when the
    /// init sequence's replies coalesce into one notification.
    public mutating func append(_ data: Data) -> [RawResponse] {
        buffer.append(contentsOf: data)

        if buffer.count > maximumBufferSize {
            // Keep the tail: the prompt we're looking for will be at the end.
            buffer.removeFirst(buffer.count - maximumBufferSize)
        }

        var responses: [RawResponse] = []
        while let promptIndex = buffer.firstIndex(of: Self.prompt) {
            let chunk = Array(buffer[buffer.startIndex..<promptIndex])
            buffer.removeSubrange(buffer.startIndex...promptIndex)
            responses.append(RawResponse(lines: Self.lines(from: chunk)))
        }
        return responses
    }

    /// Discards buffered bytes. Call on reconnect so a partial reply from a
    /// previous session cannot corrupt the first response of the new one.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Bytes currently buffered awaiting a prompt. Exposed for diagnostics.
    public var pendingByteCount: Int { buffer.count }

    private static func lines(from bytes: [UInt8]) -> [String] {
        var lines: [String] = []
        var current: [UInt8] = []

        for byte in bytes {
            if byte == carriageReturn || byte == lineFeed {
                if !current.isEmpty {
                    lines.append(decode(current))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { lines.append(decode(current)) }

        return lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        // ELM327 output is ASCII. Fall back to a lossy decode rather than
        // dropping a line, so a single corrupt byte doesn't hide a real reply.
        String(decoding: bytes, as: UTF8.self)
    }
}

/// One complete device response: the lines between two `>` prompts.
public struct RawResponse: Equatable, Sendable {
    public let lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }

    public var isEmpty: Bool { lines.isEmpty }
}

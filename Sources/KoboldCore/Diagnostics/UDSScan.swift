import Foundation

/// What a module said when asked for one data identifier.
///
/// The distinction between the cases is the entire value of a scan. A module
/// that answers "that identifier does not exist" and one that answers "it
/// exists but you may not have it" look identical if both are recorded as
/// nothing found — and they point at completely different next steps.
public enum ProbeOutcome: Sendable, Equatable {
    /// The identifier exists and these are its bytes.
    case data([UInt8])
    /// The module refused, with a reason. See `NegativeResponse`.
    case refused(UInt8)
    /// No reply at all — the module is absent, asleep, or the adapter dropped it.
    case silent

    public var isData: Bool { if case .data = self { return true }; return false }
}

/// ISO 14229 negative response codes, for the handful that change what you do
/// next.
///
/// A scan that reports only "found nothing" cannot tell an empty address space
/// from a locked one. These are what make a null result a finding rather than a
/// shrug.
public enum NegativeResponse {

    public static func describe(_ code: UInt8) -> String {
        switch code {
        case 0x10: return "General reject"
        case 0x11: return "Service not supported"
        case 0x12: return "Sub-function not supported"
        case 0x13: return "Wrong message length"
        case 0x22: return "Conditions not correct"
        case 0x31: return "Identifier not supported"
        case 0x33: return "Security access denied"
        case 0x35: return "Invalid key"
        case 0x37: return "Required time delay not expired"
        case 0x78: return "Response pending"
        case 0x7E: return "Sub-function not supported in this session"
        case 0x7F: return "Service not supported in this session"
        default: return String(format: "Reason 0x%02X", code)
        }
    }

    /// Whether this refusal means the identifier is genuinely absent.
    ///
    /// Only `requestOutOfRange` says so. Everything else is the module
    /// declining to answer something it may well have.
    public static func meansAbsent(_ code: UInt8) -> Bool { code == 0x31 }

    /// Whether this refusal implies the identifier exists but is gated —
    /// the outcome worth changing plans over.
    public static func meansGated(_ code: UInt8) -> Bool {
        [0x22, 0x33, 0x35, 0x7E, 0x7F].contains(code)
    }
}

/// One identifier that answered with something other than "does not exist".
public struct ScanFinding: Sendable, Equatable, Codable, Identifiable {
    public let module: String
    public let service: UInt8
    public let identifier: UInt32
    /// Present when the identifier returned data.
    public let bytes: [UInt8]?
    /// Present when it refused for a reason other than "does not exist".
    public let refusal: UInt8?

    public var id: String { "\(module)-\(service)-\(identifier)" }

    /// As it would be sent: `22F100`, `2101`.
    public var command: String {
        let width = service == 0x21 ? 2 : 4
        return String(format: "%02X%0\(width)X", service, identifier)
    }

    public var isGated: Bool { refusal.map(NegativeResponse.meansGated) ?? false }

    public init(module: String, service: UInt8, identifier: UInt32,
                bytes: [UInt8]?, refusal: UInt8?) {
        self.module = module
        self.service = service
        self.identifier = identifier
        self.bytes = bytes
        self.refusal = refusal
    }

    /// A one-line rendering for the log.
    public var summary: String {
        if let bytes {
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let text = Self.readableText(bytes)
            return "\(command) → \(hex)" + (text.map { " (\"\($0)\")" } ?? "")
        }
        if let refusal {
            return "\(command) → \(NegativeResponse.describe(refusal))"
        }
        return "\(command) → no reply"
    }

    /// ASCII, when the payload really is text and not bytes that happen to be
    /// printable. Requires most of the payload to be readable, not just some.
    static func readableText(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        let printable = bytes.filter { $0 >= 0x20 && $0 < 0x7F }
        guard printable.count >= (bytes.count * 3) / 4 else { return nil }
        let text = String(decoding: printable, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return text.count >= 4 ? text : nil
    }
}

/// How much of the address space has been covered, and what was found.
///
/// Persisted so a run resumes rather than restarts. A scan is an hour of
/// sitting still; losing it to a dropped Bluetooth connection would mean it
/// only ever gets attempted once.
public struct ScanProgress: Sendable, Equatable, Codable {

    /// Next identifier to try, per module and service. Absent means not started.
    public private(set) var cursor: [String: UInt32] = [:]
    public private(set) var findings: [ScanFinding] = []
    /// How many identifiers have been tried, per module and service.
    public private(set) var tried: [String: Int] = [:]
    /// How many came back "does not exist" — the true negatives.
    public private(set) var absent: [String: Int] = [:]

    public init() {}

    public static func key(module: String, service: UInt8) -> String {
        "\(module)/\(String(format: "%02X", service))"
    }

    public func nextIdentifier(module: String, service: UInt8) -> UInt32 {
        cursor[Self.key(module: module, service: service)] ?? 0
    }

    public func triedCount(module: String, service: UInt8) -> Int {
        tried[Self.key(module: module, service: service)] ?? 0
    }

    /// Records one result and advances the cursor past it.
    public mutating func record(module: String,
                                service: UInt8,
                                identifier: UInt32,
                                outcome: ProbeOutcome) {
        let key = Self.key(module: module, service: service)
        cursor[key] = identifier + 1
        tried[key, default: 0] += 1

        switch outcome {
        case .data(let bytes):
            findings.append(ScanFinding(module: module, service: service,
                                        identifier: identifier, bytes: bytes, refusal: nil))
        case .refused(let code) where !NegativeResponse.meansAbsent(code):
            findings.append(ScanFinding(module: module, service: service,
                                        identifier: identifier, bytes: nil, refusal: code))
        case .refused:
            absent[key, default: 0] += 1
        case .silent:
            break
        }
    }

    /// What the run has established, in the terms that decide what to do next.
    public func verdict(module: String, service: UInt8) -> String {
        let key = Self.key(module: module, service: service)
        let tried = tried[key] ?? 0
        guard tried > 0 else { return "not started" }

        let mine = findings.filter { $0.module == module && $0.service == service }
        let data = mine.filter { $0.bytes != nil }.count
        let gated = mine.filter(\.isGated).count
        let absent = absent[key] ?? 0

        var parts = ["\(tried) tried"]
        if data > 0 { parts.append("\(data) readable") }
        if gated > 0 { parts.append("\(gated) gated") }
        parts.append("\(absent) absent")
        return parts.joined(separator: ", ")
    }

    public func findings(module: String) -> [ScanFinding] {
        findings.filter { $0.module == module }
    }

    // MARK: - Persistence

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decoded(from data: Data) -> ScanProgress? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ScanProgress.self, from: data)
    }
}

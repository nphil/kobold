import Foundation

/// Turns a pass of failed signal reads into something a human can act on.
///
/// A sampling pass asks for every requested signal and keeps whatever answers.
/// When *nothing* answers, the interesting question is not "did it fail" but
/// "how" — and the two common answers call for opposite responses:
///
/// - Every signal reporting `NO DATA` means the adapter is healthy and
///   faithfully relaying a bus that has nothing to say. Almost always an engine
///   that is not running.
/// - Timeouts mean the adapter itself stopped talking, and the car is not yet
///   in question.
///
/// This lives here rather than in the app because it is pure classification of
/// `ELM327Error`, and because logic nobody can write a test against tends to be
/// logic nobody checked.
public enum ReadFailureSummary {

    /// Short label for why one read failed, preferring what the adapter
    /// actually said over the Swift error wrapping it.
    public static func reason(for error: Error) -> String {
        switch error as? ELM327Error {
        case .deviceError(_, let reply): return reply.summary
        case .timeout: return "timeout"
        case .malformedResponse: return "malformed reply"
        case .notConnected: return "not connected"
        case .protocolNegotiationFailed: return "protocol negotiation failed"
        case .adapterSilent: return "adapter silent"
        case .none: return String(describing: error)
        }
    }

    /// Failures grouped by reason, e.g. `NO DATA: rpm, speed; timeout: baro`.
    ///
    /// Grouped rather than listed one per line because a stuck session fails
    /// identically for every signal, and the remote log is rate-limited — the
    /// shape of the failure is the information, not its repetition.
    public static func describe(_ failures: [(SignalID, Error)]) -> String {
        guard !failures.isEmpty else { return "no signals were requested" }

        var byReason: [String: [String]] = [:]
        for (id, error) in failures {
            byReason[reason(for: error), default: []].append(id.rawValue)
        }

        return byReason
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.sorted().joined(separator: ", "))" }
            .joined(separator: "; ")
    }

    /// Whether every failure was the adapter answering "nothing here".
    ///
    /// Deliberately strict: one timeout among the `NO DATA`s means the link is
    /// also suspect, and the advice should not point confidently at the car.
    public static func allReportedNoData(_ failures: [(SignalID, Error)]) -> Bool {
        guard !failures.isEmpty else { return false }
        return failures.allSatisfy { _, error in
            if case .deviceError(_, let reply)? = error as? ELM327Error {
                return reply == .noData
            }
            return false
        }
    }
}

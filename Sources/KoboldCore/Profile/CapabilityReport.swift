import Foundation

/// The vehicle coverage report, as text.
///
/// Exists so the report is not trapped in a screen. A capability read happens
/// once per connection, in a car, usually by someone who cannot stop to take
/// notes — so the same facts the screen draws must also reach the log, where
/// they can be read later and pasted into a conversation.
///
/// Formatting lives here rather than at the call site because it is the sort of
/// thing that quietly rots: a report built inline drifts from the screen it is
/// supposed to mirror, and nothing catches it.
public enum CapabilityReport {

    /// One line per section, ready to log.
    ///
    /// Split into lines rather than returned as one block for two reasons: the
    /// remote log batches by byte count and packs short lines better than one
    /// long one, and a grep for `Not decoded` should return something readable
    /// rather than a paragraph.
    public static func lines(for capability: VehicleCapability,
                             profileName: String) -> [String] {
        var lines: [String] = ["Vehicle report · \(profileName)"]

        let percent = Int((capability.coverage * 100).rounded())
        lines.append("Coverage: \(capability.coveredCount) of \(capability.supportedCount) "
                     + "reported PIDs decoded (\(percent)%)")

        if !capability.readable.isEmpty {
            let names = capability.readable.map { capability.name(for: $0) }.sorted()
            lines += wrapped("Decoded (\(names.count))", names)
        }

        if !capability.readElsewhere.isEmpty {
            let entries = capability.readElsewhere.map { "\($0.command) \($0.name)" }
            lines += wrapped("On \(DiagnosticPIDs.surface) (\(entries.count))", entries)
        }

        // Grouped by category, which mirrors the screen and breaks the longest
        // list in the report into pieces that can be read one at a time.
        for group in capability.gapsByCategory {
            let entries = group.gaps.map { "\($0.command) \($0.name)" }
            lines += wrapped("Not decoded · \(group.category.label) (\(entries.count))", entries)
        }

        if !capability.undeclared.isEmpty {
            let names = capability.undeclared.map { capability.name(for: $0) }.sorted()
            lines += wrapped("Defined but not reported (\(names.count))", names)
        }

        lines.append("Vehicle info: " + (capability.vehicleInfo.isEmpty
            ? "none reported"
            : capability.vehicleInfo.map(\.name).joined(separator: ", ")))

        // Stated even when empty, and distinctly from "not asked". A silent
        // absence reads as "the probe did not run", which is a different fact
        // from "nothing answered" and would send someone debugging the wrong
        // thing.
        if capability.probedModules {
            lines.append("Modules: " + (capability.modules.isEmpty
                ? "none answered a direct request"
                : capability.modules.map(describe).joined(separator: ", ")))
        } else {
            lines.append("Modules: not probed")
        }

        return lines
    }

    /// Packs entries into `prefix: a, b, c` lines that each stay short enough
    /// to survive the remote log's batch limit intact.
    ///
    /// A car that declares a lot — a diesel, with every emissions PID — puts
    /// nearly eighty entries in one category, which as a single line is most of
    /// a 3.5 KB message on its own. Continuations are numbered so a reader can
    /// tell a split list from a truncated one.
    private static func wrapped(_ prefix: String,
                                _ entries: [String],
                                limit: Int = 1_200) -> [String] {
        guard !entries.isEmpty else { return [] }

        var lines: [String] = []
        var current: [String] = []
        var length = 0

        func flush() {
            guard !current.isEmpty else { return }
            let label = lines.isEmpty ? prefix : "\(prefix) cont. \(lines.count)"
            lines.append("\(label): " + current.joined(separator: ", "))
            current = []
            length = 0
        }

        for entry in entries {
            // +2 for the separator. One oversized entry still gets its own line
            // rather than being dropped: too long is recoverable, missing is not.
            if length > 0, length + entry.utf8.count + 2 > limit { flush() }
            current.append(entry)
            length += entry.utf8.count + 2
        }
        flush()
        return lines
    }

    private static func describe(_ module: VehicleCapability.ModuleIdentity) -> String {
        let version = module.version.map { " \($0)" } ?? ""
        return "\(module.label) (\(module.header))\(version)"
    }
}

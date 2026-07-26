import Foundation

/// Everything model-specific about an adapter, as data.
///
/// The point of this type is that no adapter's name ever appears in a branch.
/// Support for a new dongle is a new descriptor, not a code change — which is
/// what keeps the transport and driver honest about being adapter-agnostic.
public struct AdapterDescriptor: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let displayName: String

    /// Case-insensitive substrings matched against the advertised BLE name.
    ///
    /// Matching on a substring rather than an exact string is deliberate: these
    /// adapters advertise different names per platform (an iOS-specific name and
    /// an Android one), and picking the wrong identity is a documented
    /// first-pairing failure.
    public let nameMatchHints: [String]

    /// Known GATT profiles, tried in order before falling back to discovery.
    ///
    /// Hints only. Even within one vendor's line the UUIDs differ between models,
    /// so the transport discovers services at runtime and treats these as a fast
    /// path, never as a requirement.
    public let gattHints: [GATTProfileHint]

    /// Assumed ATT payload before any MTU negotiation. 20 bytes is the safe
    /// default; iOS cannot initiate MTU exchange as central, so a larger value is
    /// only valid if the peripheral offers it.
    public let assumedMTU: Int

    public let writeWithResponse: Bool
    public let commandTerminator: String

    /// Replaces the default init sequence entirely when non-empty.
    public let initOverrides: [String]

    public let initialTimeout: Duration
    public let resetTimeout: Duration
    /// Longer window for commands that may trigger `SEARCHING...`.
    public let searchTimeout: Duration

    /// Whether the adapter honours the expected-response-count digit (`010C1`),
    /// which removes the trailing timeout wait from every request.
    public let supportsExpectedResponseCount: Bool

    /// Whether the adapter wakes itself on bus activity. Where false, the user
    /// must physically re-seat it after it sleeps.
    public let supportsAutoWake: Bool

    /// Probe actual AT support on connect instead of trusting the reported
    /// firmware version. Clones routinely advertise a version they don't fully
    /// implement, so the version string is not a safe basis for feature gating.
    public let probeCommandsOnConnect: Bool

    public let notes: String

    public init(id: String,
                displayName: String,
                nameMatchHints: [String] = [],
                gattHints: [GATTProfileHint] = [],
                assumedMTU: Int = 20,
                writeWithResponse: Bool = true,
                commandTerminator: String = "\r",
                initOverrides: [String] = [],
                initialTimeout: Duration = .milliseconds(200),
                resetTimeout: Duration = .milliseconds(1500),
                searchTimeout: Duration = .seconds(5),
                supportsExpectedResponseCount: Bool = true,
                supportsAutoWake: Bool = false,
                probeCommandsOnConnect: Bool = true,
                notes: String = "") {
        self.id = id
        self.displayName = displayName
        self.nameMatchHints = nameMatchHints
        self.gattHints = gattHints
        self.assumedMTU = assumedMTU
        self.writeWithResponse = writeWithResponse
        self.commandTerminator = commandTerminator
        self.initOverrides = initOverrides
        self.initialTimeout = initialTimeout
        self.resetTimeout = resetTimeout
        self.searchTimeout = searchTimeout
        self.supportsExpectedResponseCount = supportsExpectedResponseCount
        self.supportsAutoWake = supportsAutoWake
        self.probeCommandsOnConnect = probeCommandsOnConnect
        self.notes = notes
    }
}

/// A known service/characteristic triple for an adapter family.
public struct GATTProfileHint: Sendable, Equatable, Codable {
    public let service: String
    public let notify: String
    public let write: String

    public init(service: String, notify: String, write: String) {
        self.service = service
        self.notify = notify
        self.write = write
    }
}

public extension AdapterDescriptor {
    /// Conservative defaults for an unrecognised ELM327-compatible adapter.
    static let generic = AdapterDescriptor(
        id: "generic-elm327",
        displayName: "Generic ELM327",
        // Only genuinely generic tokens belong here. Vendor names live on the
        // specific descriptors, or this would shadow them.
        nameMatchHints: ["obd", "elm"],
        gattHints: [
            // The widespread HM-10 style serial profile.
            GATTProfileHint(service: "FFF0", notify: "FFF1", write: "FFF2"),
            // Another common clone family.
            GATTProfileHint(service: "FFE0", notify: "FFE1", write: "FFE1")
        ],
        notes: "Fallback descriptor. Services are discovered at runtime; hints are a fast path only."
    )
}

/// The adapter catalogue.
///
/// Registry entry #1 is the reference dongle used to validate the abstraction.
/// It carries the quirks research surfaced, all as data.
public struct AdapterRegistry: Sendable {
    public private(set) var descriptors: [AdapterDescriptor]

    public init(descriptors: [AdapterDescriptor] = AdapterRegistry.builtIn) {
        self.descriptors = descriptors
    }

    public mutating func register(_ descriptor: AdapterDescriptor) {
        descriptors.removeAll { $0.id == descriptor.id }
        descriptors.append(descriptor)
    }

    /// Best descriptor for an advertised peripheral name, or the generic one.
    ///
    /// Model-specific descriptors are considered first and the generic one is a
    /// pure fallback, so a catch-all token can never outrank a real match. Among
    /// specific descriptors, the longest matching hint wins.
    public func descriptor(forAdvertisedName name: String) -> AdapterDescriptor {
        let haystack = name.lowercased()

        func longestMatch(_ descriptor: AdapterDescriptor) -> Int? {
            descriptor.nameMatchHints
                .filter { haystack.contains($0.lowercased()) }
                .map(\.count)
                .max()
        }

        let specific = descriptors
            .filter { $0.id != AdapterDescriptor.generic.id }
            .compactMap { descriptor -> (AdapterDescriptor, Int)? in
                guard let score = longestMatch(descriptor) else { return nil }
                return (descriptor, score)
            }

        if let best = specific.max(by: { $0.1 < $1.1 })?.0 { return best }
        return .generic
    }

    public static let builtIn: [AdapterDescriptor] = [
        .generic,
        AdapterDescriptor(
            id: "vgate-icar-pro-2s",
            displayName: "Vgate iCar Pro 2S",
            nameMatchHints: ["vlink", "icar", "vgate"],
            gattHints: [
                // Verified against hardware by two independent reports. Note this
                // differs from the older model in the same product line, which is
                // exactly why UUIDs are hints rather than constants.
                GATTProfileHint(service: "18F0", notify: "2AF0", write: "2AF1"),
                GATTProfileHint(service: "FFF0", notify: "FFF1", write: "FFF2")
            ],
            assumedMTU: 20,
            writeWithResponse: true,
            supportsExpectedResponseCount: true,
            supportsAutoWake: false,
            probeCommandsOnConnect: true,
            notes: """
                Sleeps roughly 20-30 minutes after ignition off and does not \
                auto-wake on most vehicles, so it may need re-seating. Hibernates \
                when the paired app leaves the foreground - a firmware behaviour \
                no client-side technique can override, and one reason live \
                sessions are foreground-only. Almost certainly a clone chip: \
                probe command support rather than trusting the reported version.
                """
        )
    ]
}

import Foundation

public enum ProfileError: Error, Equatable, Sendable {
    case unknownProfile(String)
    case inheritanceCycle(String)
    case resourceMissing(String)
}

/// Loads vehicle profiles and resolves inheritance.
///
/// Profiles are data: the bundled catalogue seeds the app, but nothing here
/// assumes a particular car exists. A vehicle the app has never seen still
/// resolves against the SAE J1979 baseline and shows the standard signals.
public struct ProfileStore: Sendable {
    public static let baselineID = "sae-j1979-core"

    private var profiles: [String: VehicleProfile]

    public init(profiles: [VehicleProfile]) {
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    public var allProfiles: [VehicleProfile] {
        profiles.values.sorted { $0.id < $1.id }
    }

    public func profile(id: String) -> VehicleProfile? { profiles[id] }

    public mutating func insert(_ profile: VehicleProfile) {
        profiles[profile.id] = profile
    }

    /// Flattens a profile and its ancestors into a single lookup table.
    ///
    /// A descendant may override an inherited signal by declaring the same ID —
    /// that is how the reference car replaces the standard oil-temperature PID
    /// (which never populates on that platform) with a manufacturer one.
    public func resolve(id: String) throws -> ResolvedProfile {
        guard let profile = profiles[id] else { throw ProfileError.unknownProfile(id) }

        // Walk to the root first, then apply from oldest to newest so later
        // definitions win.
        var chain: [VehicleProfile] = []
        var seen: Set<String> = []
        var current: VehicleProfile? = profile

        while let node = current {
            guard seen.insert(node.id).inserted else {
                throw ProfileError.inheritanceCycle(node.id)
            }
            chain.append(node)
            guard let parentID = node.inherits else { break }
            guard let parent = profiles[parentID] else {
                throw ProfileError.unknownProfile(parentID)
            }
            current = parent
        }

        var signals: [SignalID: SignalDefinition] = [:]
        var derived: [SignalID: DerivedSignal] = [:]
        var absent: [SignalID: String] = [:]
        var headers: [String: ECUHeader] = [:]

        for node in chain.reversed() {
            for signal in node.signals { signals[signal.id] = signal }
            for signal in node.derivedSignals { derived[signal.id] = signal }
            for entry in node.knownAbsent { absent[entry.id] = entry.reason }
            // Inherited like everything else: a platform profile can describe
            // the modules every car on it has, and a specific car add its own.
            for (key, header) in node.ecuHeaders { headers[key] = header }
        }

        // A signal explicitly marked absent must not remain requestable, even if
        // the baseline defines it.
        for id in absent.keys {
            signals.removeValue(forKey: id)
            derived.removeValue(forKey: id)
        }

        return ResolvedProfile(id: profile.id,
                               displayName: profile.displayName,
                               signals: signals,
                               derivedSignals: derived,
                               knownAbsent: absent,
                               ecuHeaders: headers)
    }

    /// Baseline-only profile, used when no vehicle has been selected.
    public func resolveBaseline() throws -> ResolvedProfile {
        try resolve(id: Self.baselineID)
    }
}

// MARK: - Bundled catalogue

/// On-disk shape of the bundled profile catalogue.
public struct ProfileCatalogue: Codable, Sendable {
    public let schemaVersion: Int
    public let profiles: [VehicleProfile]

    public init(schemaVersion: Int, profiles: [VehicleProfile]) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }
}

public extension ProfileStore {
    /// Loads the catalogue shipped with the package.
    static func bundled() throws -> ProfileStore {
        guard let url = Bundle.module.url(forResource: "profiles", withExtension: "json") else {
            throw ProfileError.resourceMissing("profiles.json")
        }
        let data = try Data(contentsOf: url)
        let catalogue = try JSONDecoder().decode(ProfileCatalogue.self, from: data)
        return ProfileStore(profiles: catalogue.profiles)
    }
}

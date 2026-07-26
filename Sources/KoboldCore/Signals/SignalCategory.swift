import Foundation

/// What part of the car a signal describes.
///
/// Exists because a flat list stops working. Fourteen signals sort fine
/// alphabetically; the ~80 the standard defines do not, and "Catalyst
/// Temperature B1S1" landing between "Barometric Pressure" and "Coolant
/// Temperature" helps nobody. Grouping turns a list you scan into a list you
/// navigate.
///
/// Kept deliberately coarse. A taxonomy fine enough to be precise is one where
/// people cannot predict which drawer a thing is in, and the point of the
/// grouping is that you can guess where to look.
public enum SignalCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case engine
    case fuel
    case air
    case emissions
    case drivetrain
    case electrical
    case vehicle
    /// Anything uncategorised — including data written by an older version
    /// that predates this field.
    case other

    public var label: String {
        switch self {
        case .engine: return "Engine"
        case .fuel: return "Fuel"
        case .air: return "Air & Boost"
        case .emissions: return "Emissions"
        case .drivetrain: return "Drivetrain"
        case .electrical: return "Electrical"
        case .vehicle: return "Vehicle"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .engine: return "engine.combustion"
        case .fuel: return "fuelpump"
        case .air: return "wind"
        case .emissions: return "smoke"
        case .drivetrain: return "gearshape.2"
        case .electrical: return "bolt"
        case .vehicle: return "car"
        case .other: return "square.grid.2x2"
        }
    }

    /// Display order, chosen by how often a driver goes looking rather than
    /// alphabetically — engine first because that is what most questions are
    /// about, `other` last because it is a residue rather than a category.
    public var displayOrder: Int {
        switch self {
        case .engine: return 0
        case .air: return 1
        case .fuel: return 2
        case .drivetrain: return 3
        case .electrical: return 4
        case .emissions: return 5
        case .vehicle: return 6
        case .other: return 7
        }
    }

    /// Every category, in the order they should appear.
    public static var ordered: [SignalCategory] {
        allCases.sorted { $0.displayOrder < $1.displayOrder }
    }
}

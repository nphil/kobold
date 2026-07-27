import XCTest
@testable import KoboldCore

/// Alternate units.
///
/// A conversion that is quietly wrong is worse than none at all: the number
/// still looks like a reading, and boost in the wrong scale reads as a healthy
/// engine or a broken one depending on which way the error goes.
final class UnitConversionTests: XCTestCase {

    func testPressureConversions() {
        // 100 kPa is 1 bar and 14.5038 psi — the definition, not a rounding.
        XCTAssertEqual(Unit.kilopascal.convert(100, to: .bar), 1, accuracy: 0.0001)
        XCTAssertEqual(Unit.kilopascal.convert(100, to: .psi), 14.5038, accuracy: 0.001)
        // A boost reading someone would recognise: 200 kPa absolute ≈ 29 psi.
        XCTAssertEqual(Unit.kilopascal.convert(200, to: .psi), 29.0075, accuracy: 0.001)
    }

    /// The only conversion with an offset, and the one that gets written as a
    /// bare multiplication.
    func testTemperatureUsesTheOffset() {
        XCTAssertEqual(Unit.celsius.convert(0, to: .fahrenheit), 32, accuracy: 0.001)
        XCTAssertEqual(Unit.celsius.convert(100, to: .fahrenheit), 212, accuracy: 0.001)
        XCTAssertEqual(Unit.celsius.convert(-40, to: .fahrenheit), -40, accuracy: 0.001)
        // Coolant at operating temperature.
        XCTAssertEqual(Unit.celsius.convert(90, to: .fahrenheit), 194, accuracy: 0.001)
    }

    func testSpeedDistanceAndTorque() {
        XCTAssertEqual(Unit.kilometersPerHour.convert(100, to: .milesPerHour),
                       62.137, accuracy: 0.001)
        XCTAssertEqual(Unit.kilometre.convert(160.934, to: .mile), 100, accuracy: 0.01)
        // This engine's reference torque, near enough.
        XCTAssertEqual(Unit.newtonMetre.convert(353, to: .poundFoot), 260.36, accuracy: 0.01)
    }

    /// Every conversion has to survive a round trip, or the preference itself
    /// becomes lossy as someone flips between units.
    func testConversionsRoundTrip() {
        for unit in Unit.allCases {
            for other in unit.alternatives {
                let there = unit.convert(1234.5, to: other)
                let back = other.convert(there, to: unit)
                XCTAssertEqual(back, 1234.5, accuracy: 0.001,
                               "\(unit.rawValue) → \(other.rawValue) → \(unit.rawValue)")
            }
        }
    }

    /// An unrelated pair must return the value untouched rather than invent
    /// one. A stale preference should degrade to the truth.
    func testUnrelatedUnitsAreLeftAlone() {
        XCTAssertEqual(Unit.kilopascal.convert(42, to: .milesPerHour), 42)
        XCTAssertEqual(Unit.percent.convert(42, to: .fahrenheit), 42)
    }

    func testAlternativesAlwaysLeadWithTheReportedUnit() {
        for unit in Unit.allCases {
            XCTAssertEqual(unit.alternatives.first, unit, unit.rawValue)
            XCTAssertEqual(Set(unit.alternatives).count, unit.alternatives.count,
                           "\(unit.rawValue) lists a duplicate")
        }
    }

    /// Ranges must not come back inverted — a reversed ClosedRange traps.
    func testRangeConversionStaysOrdered() {
        let converted = Unit.celsius.convert((-40.0)...150.0, to: .fahrenheit)
        XCTAssertLessThan(converted.lowerBound, converted.upperBound)
        XCTAssertEqual(converted.lowerBound, -40, accuracy: 0.001)
        XCTAssertEqual(converted.upperBound, 302, accuracy: 0.001)
    }

    /// Lambda and a count of warm-ups are both unitless and want different
    /// precision, so the decision cannot be made from the unit alone.
    func testUnitlessPrecisionFollowsTheValue() {
        XCTAssertEqual(Unit.none.format(0.98), "0.98")
        XCTAssertEqual(Unit.none.format(7), "7")
        XCTAssertEqual(Unit.volt.format(14.32), "14.3")
        XCTAssertEqual(Unit.bar.format(1.234), "1.23")
    }
}

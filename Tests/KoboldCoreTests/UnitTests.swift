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

/// The stored choice, and the one type every surface reads it through.
///
/// These exist because the failure was not a wrong conversion — it was a
/// screen that never asked. Four views each carried their own copy of "look up
/// the unit, convert, format", and the hero gauge, added first, was never
/// given one.
final class SignalDisplayTests: XCTestCase {

    // Qualified: `Unit` in a type position is ambiguous with `Foundation.Unit`,
    // which XCTest drags in. Member lookup below resolves on its own.
    private func display(_ id: SignalID,
                         reported: KoboldCore.Unit,
                         chosen: KoboldCore.Unit? = nil) -> SignalDisplay {
        var preferences = UnitPreferences()
        if let chosen { preferences.set(chosen, for: id, reported: reported) }
        return SignalDisplay(reported: reported, id: id, preferences: preferences)
    }

    func testWithoutAChoiceTheCarsOwnUnitIsUsedUnconverted() {
        let speed = display(.speed, reported: .kilometersPerHour)
        XCTAssertEqual(speed.unit, .kilometersPerHour)
        XCTAssertEqual(speed.value(100), 100)
        XCTAssertEqual(speed.symbol, "km/h")
    }

    func testAChosenUnitConvertsTheValueAndTheSymbol() {
        let speed = display(.speed, reported: .kilometersPerHour, chosen: .milesPerHour)
        XCTAssertEqual(speed.unit, .milesPerHour)
        XCTAssertEqual(speed.value(100), 62.137, accuracy: 0.001)
        XCTAssertEqual(speed.symbol, "mph")
        XCTAssertEqual(speed.format(100), "62")
    }

    /// The choice is per signal, so switching speed to mph must not drag the
    /// coolant gauge into Fahrenheit with it.
    func testTheChoiceDoesNotLeakToOtherSignals() {
        var preferences = UnitPreferences()
        preferences.set(.milesPerHour, for: .speed, reported: .kilometersPerHour)

        let coolant = SignalDisplay(reported: .celsius, id: .coolantTemp,
                                    preferences: preferences)
        XCTAssertEqual(coolant.unit, .celsius)
        XCTAssertEqual(coolant.value(90), 90)
    }

    /// A preference stored against a signal whose unit later changes must
    /// degrade to the real reading rather than convert between unrelated units.
    func testAStalePreferenceFallsBackToWhatTheCarReports() {
        var preferences = UnitPreferences()
        preferences.set(.milesPerHour, for: .boost, reported: .kilometersPerHour)

        // The profile now says boost is a pressure.
        let boost = SignalDisplay(reported: .kilopascal, id: .boost, preferences: preferences)
        XCTAssertEqual(boost.unit, .kilopascal)
        XCTAssertEqual(boost.value(200), 200)
    }

    func testRangesConvertAndStayOrdered() {
        let coolant = display(.coolantTemp, reported: .celsius, chosen: .fahrenheit)
        let range = coolant.range((-40.0)...150.0)
        XCTAssertLessThan(range.lowerBound, range.upperBound)
        XCTAssertEqual(range.lowerBound, -40, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 302, accuracy: 0.001)
    }

    /// Precision comes from the unit on screen, not the one the car reports.
    func testPrecisionFollowsTheUnitBeingShown() {
        let boost = display(.boost, reported: .kilopascal, chosen: .psi)
        XCTAssertEqual(boost.format(200), "29.0")
        XCTAssertEqual(display(.boost, reported: .kilopascal).format(200), "200")
    }

    func testAlternativesComeFromTheCarsUnitNotTheChosenOne() {
        let boost = display(.boost, reported: .kilopascal, chosen: .psi)
        XCTAssertTrue(boost.hasAlternatives)
        // Leading with the car's own unit is what lets the picker offer a way
        // back; leading with the chosen one would strand a preference.
        XCTAssertEqual(boost.alternatives.first, .kilopascal)
        XCTAssertTrue(boost.alternatives.contains(.psi))

        XCTAssertFalse(display(.rpm, reported: .rpm).hasAlternatives)
    }

    /// The preferences blob is written on every change and read on every draw.
    func testPreferencesRoundTripAndDefaultToEmpty() {
        var preferences = UnitPreferences()
        preferences.set(.fahrenheit, for: .coolantTemp, reported: .celsius)

        let restored = UnitPreferences.decoded(from: preferences.encoded())
        XCTAssertEqual(restored.unit(for: .coolantTemp, reported: .celsius), .fahrenheit)

        // Absence is the default, and unreadable data is absence rather than a
        // crash — a corrupt blob should cost the preference, not the app.
        XCTAssertEqual(UnitPreferences.decoded(from: Data()), UnitPreferences())
        XCTAssertEqual(UnitPreferences.decoded(from: Data("not json".utf8)),
                       UnitPreferences())
    }

    // MARK: - Instrument captions

    func testTheCaptionCarriesTheUnitBeingShown() {
        XCTAssertEqual(display(.speed, reported: .kilometersPerHour).caption(for: "VEHICLE SPEED"),
                       "VEHICLE SPEED · km/h")
        XCTAssertEqual(display(.speed, reported: .kilometersPerHour, chosen: .milesPerHour)
                        .caption(for: "VEHICLE SPEED"),
                       "VEHICLE SPEED · mph")
    }

    /// The tachometer, which would otherwise read "ENGINE RPM · rpm".
    func testANameThatAlreadySaysTheUnitDoesNotRepeatIt() {
        XCTAssertEqual(display(.rpm, reported: .rpm).caption(for: "ENGINE RPM"), "ENGINE RPM")
        XCTAssertEqual(display(.rpm, reported: .rpm).caption(for: "Engine rpm"), "Engine rpm")
    }

    /// The reason the match is on whole words: a substring test drops the unit
    /// from every reading whose symbol is a single letter, which is exactly the
    /// set that most needs it stated.
    func testASymbolThatHappensToAppearInsideAWordIsStillShown() {
        XCTAssertEqual(display(.moduleVoltage, reported: .volt).caption(for: "SYSTEM VOLTAGE"),
                       "SYSTEM VOLTAGE · V")
        XCTAssertEqual(display("fuelLevel", reported: .liter).caption(for: "FUEL LEVEL"),
                       "FUEL LEVEL · L")
    }

    func testAUnitlessReadingGetsNoSeparator() {
        XCTAssertEqual(display("warmups", reported: .none).caption(for: "WARM-UPS"), "WARM-UPS")
        XCTAssertEqual(display(.speed, reported: .kilometersPerHour).caption(for: ""), "km/h")
    }

    /// Choosing the car's own unit clears the entry rather than storing one
    /// equal to the default.
    func testChoosingTheReportedUnitClearsTheEntry() {
        var preferences = UnitPreferences()
        preferences.set(.milesPerHour, for: .speed, reported: .kilometersPerHour)
        preferences.set(.kilometersPerHour, for: .speed, reported: .kilometersPerHour)
        XCTAssertEqual(preferences, UnitPreferences())
    }
}

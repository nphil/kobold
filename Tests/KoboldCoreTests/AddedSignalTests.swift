import XCTest
@testable import KoboldCore

/// Decoding the signals added from the reference car's own supported-PID report.
///
/// Every one of these is a formula transcribed from the standard, and a
/// transcription error does not announce itself: a wrong divisor produces a
/// number that looks like a reading. Each case here is hand-computed from the
/// raw bytes so the arithmetic is checkable by eye.
final class AddedSignalTests: XCTestCase {

    private func definition(_ id: SignalID) throws -> SignalDefinition {
        let profile = try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
        return try XCTUnwrap(profile.signals[id], "\(id.rawValue) is not in the profile")
    }

    private func decode(_ id: SignalID, _ data: [UInt8]) throws -> Double {
        let definition = try definition(id)
        return try PIDDecoder.decode(data: data, using: definition)
    }

    /// The one this car needs: it reports no 0123, but it does report 0159.
    func testFuelRailAbsolutePressure() throws {
        // 10 × 0x0FA0 = 40,000 kPa? No — 0x0190 = 400, ×10 = 4,000 kPa = 40 bar,
        // which is warm idle on a Theta-II GDI.
        XCTAssertEqual(try decode("fuelRailAbsPressure", [0x01, 0x90]), 4_000, accuracy: 0.01)
        // Full load: 0x07D0 = 2000, ×10 = 20,000 kPa = 200 bar.
        XCTAssertEqual(try decode("fuelRailAbsPressure", [0x07, 0xD0]), 20_000, accuracy: 0.01)
    }

    func testAbsoluteLoadExceedsOneHundredPercentUnderBoost() throws {
        // 100 × 0x00FF / 255 = 100%.
        XCTAssertEqual(try decode("absoluteLoad", [0x00, 0xFF]), 100, accuracy: 0.01)
        // 0x01FE = 510, × 100 / 255 = 200% — which a turbo really does reach.
        XCTAssertEqual(try decode("absoluteLoad", [0x01, 0xFE]), 200, accuracy: 0.01)
    }

    func testLambdaSignalsAreRatiosAroundOne() throws {
        // 2 × 0x8000 / 65536 = 1.0 exactly — stoichiometric.
        XCTAssertEqual(try decode("commandedAFR", [0x80, 0x00]), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try decode("o2Lambda", [0x80, 0x00]), 1.0, accuracy: 0.0001)
        // 0x6666 = 26214, × 2 / 65536 = 0.7999 — rich, as commanded under boost.
        XCTAssertEqual(try decode("commandedAFR", [0x66, 0x66]), 0.8, accuracy: 0.001)
    }

    func testTorquePercentagesAreOffsetByOneTwentyFive() throws {
        XCTAssertEqual(try decode("actualTorque", [125]), 0, accuracy: 0.01)
        XCTAssertEqual(try decode("actualTorque", [200]), 75, accuracy: 0.01)
        XCTAssertEqual(try decode("frictionTorque", [120]), -5, accuracy: 0.01)
    }

    func testReferenceTorqueIsPlainNewtonMetres() throws {
        // 0x015E = 350 N⋅m, which is about right for this engine.
        XCTAssertEqual(try decode("referenceTorque", [0x01, 0x5E]), 350, accuracy: 0.01)
        XCTAssertEqual(try definition("referenceTorque").unit, .newtonMetre)
    }

    func testPercentageSignalsScaleByTwoFiftyFive() throws {
        for id: SignalID in ["relativeThrottle", "throttleB", "pedalD", "pedalE",
                             "commandedThrottle"] {
            XCTAssertEqual(try decode(id, [0xFF]), 100, accuracy: 0.01, id.rawValue)
            XCTAssertEqual(try decode(id, [0x00]), 0, accuracy: 0.01, id.rawValue)
        }
    }

    func testCatalystTemperatureIsTenthsOfADegreeOffsetByForty() throws {
        // 0x1C20 = 7200, /10 = 720, −40 = 680 °C. Hot, and normal once lit off.
        XCTAssertEqual(try decode("catalystTempB1S1", [0x1C, 0x20]), 680, accuracy: 0.01)
        // The all-zero case must read −40, not 0 — the offset is the whole point.
        XCTAssertEqual(try decode("catalystTempB1S2", [0x00, 0x00]), -40, accuracy: 0.01)
    }

    func testSecondaryOxygenTrimIsCentredOnZero() throws {
        XCTAssertEqual(try decode("secondaryTrimShort", [128]), 0, accuracy: 0.01)
        XCTAssertEqual(try decode("secondaryTrimLong", [128]), 0, accuracy: 0.01)
        // 100 × 64 / 128 − 100 = −50%.
        XCTAssertEqual(try decode("secondaryTrimShort", [64]), -50, accuracy: 0.01)
    }

    func testOxygenSensorVoltage() throws {
        // 0xC8 = 200, / 200 = 1.0 V.
        XCTAssertEqual(try decode("o2Sensor2Voltage", [0xC8]), 1.0, accuracy: 0.001)
    }

    /// Four bytes, not two — the only signal in the set that is.
    func testOdometerIsFourBytesInTenthsOfAKilometre() throws {
        // 0x0007A120 = 500,000 → 50,000.0 km.
        XCTAssertEqual(try decode("odometer", [0x00, 0x07, 0xA1, 0x20]), 50_000, accuracy: 0.1)
        XCTAssertEqual(try definition("odometer").byteCount, 4)
    }

    func testDistanceAndTimeCountersAreRawSixteenBitValues() throws {
        XCTAssertEqual(try decode("distanceWithMIL", [0x00, 0x00]), 0, accuracy: 0.01)
        XCTAssertEqual(try decode("distanceSinceCleared", [0x01, 0x00]), 256, accuracy: 0.01)
        XCTAssertEqual(try decode("timeWithMIL", [0x00, 0x2A]), 42, accuracy: 0.01)
        XCTAssertEqual(try decode("warmupsSinceCleared", [7]), 7, accuracy: 0.01)
    }

    /// Every added signal must carry the things the UI now promises: a readable
    /// name, a sentence explaining it, and a category to file it under.
    func testEverySignalIsPresentableToAPerson() throws {
        let profile = try ProfileStore.bundled().resolve(id: "genesis-g70-2020-2.0t-awd")
        for (id, definition) in profile.signals {
            XCTAssertFalse(definition.label.isEmpty, id.rawValue)
            XCTAssertNotEqual(definition.label, id.rawValue, "\(id.rawValue) has no real name")
            XCTAssertNotNil(definition.summary, "\(id.rawValue) has no description")
            XCTAssertNotEqual(definition.category, .other, "\(id.rawValue) is uncategorised")
        }
    }
}

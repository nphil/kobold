import XCTest
@testable import KoboldCore

// MARK: - ISO-TP

final class ISOTPAssemblerTests: XCTestCase {

    func testSingleFrameStripsCANPadding() throws {
        // PCI 04 = four payload bytes; the trailing 00s are frame padding and
        // must not be decoded as data.
        let responses = try ISOTPAssembler.assemble(lines: ["7E8 04 41 0C 0B B8 00 00"])
        XCTAssertEqual(responses.count, 1)
        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.header, "7E8")
        XCTAssertEqual(response.payload, [0x41, 0x0C, 0x0B, 0xB8])
    }

    func testMultiFrameReassemblesToDeclaredLength() throws {
        // First frame declares 0x014 = 20 bytes total; consecutive frames carry
        // the remainder. This is a Mode 09 VIN reply.
        let responses = try ISOTPAssembler.assemble(lines: [
            "7E8 10 14 49 02 01 31 47 31",
            "7E8 21 4A 43 35 34 34 34 52",
            "7E8 22 37 32 35 32 33 36 37"
        ])
        XCTAssertEqual(responses.count, 1)
        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.payload.count, 20)
        XCTAssertEqual(Array(response.payload.prefix(3)), [0x49, 0x02, 0x01])
    }

    func testGroupsRepliesByECU() throws {
        // A functional request draws answers from several modules; their frames
        // interleave and must not be concatenated together.
        let responses = try ISOTPAssembler.assemble(lines: [
            "7E8 04 41 0C 0B B8",
            "7E9 04 41 0C 00 00"
        ])
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses.first?.header, "7E8")
        XCTAssertEqual(responses.first?.payload, [0x41, 0x0C, 0x0B, 0xB8])
        XCTAssertEqual(responses.last?.header, "7E9")
        XCTAssertEqual(responses.last?.payload, [0x41, 0x0C, 0x00, 0x00])
    }

    /// With `ATH0` the adapter's CAN auto-formatting removes the ISO-TP PCI byte
    /// along with the header, so the line is already pure payload. Treating its
    /// first byte as a PCI would discard the frame entirely.
    func testHeaderlessOutputIsAllPayload() throws {
        let responses = try ISOTPAssembler.assemble(lines: ["41 0C 0B B8"])
        XCTAssertEqual(responses.count, 1)
        let response = try XCTUnwrap(responses.first)
        XCTAssertNil(response.header)
        XCTAssertEqual(response.payload, [0x41, 0x0C, 0x0B, 0xB8])
    }

    func testHeaderlessMultiLineOutputIsConcatenated() throws {
        let responses = try ISOTPAssembler.assemble(lines: ["49 02 01 31", "47 31 4A 43"])
        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.payload, [0x49, 0x02, 0x01, 0x31, 0x47, 0x31, 0x4A, 0x43])
    }

    func testSequencePrefixedFormIsReassembledInOrder() throws {
        // ATCAF1 resolves ISO-TP itself and prints a length line then N: segments.
        let responses = try ISOTPAssembler.assemble(lines: [
            "014",
            "0: 49 02 01 31 47 31",
            "1: 4A 43 35 34 34 34 52",
            "2: 37 32 35 32 33 36 37"
        ])
        XCTAssertEqual(responses.count, 1)
        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.payload.count, 20)
        XCTAssertEqual(Array(response.payload.prefix(2)), [0x49, 0x02])
    }

    func testSequencePrefixedFormToleratesOutOfOrderSegments() throws {
        let responses = try ISOTPAssembler.assemble(lines: [
            "1: 04 05 06",
            "0: 01 02 03"
        ])
        XCTAssertEqual(responses.first?.payload, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
    }

    func testTruncatedMultiFrameThrows() {
        // Declaring 20 bytes but delivering 6 is a real failure, not something to
        // paper over with a short payload.
        XCTAssertThrowsError(
            try ISOTPAssembler.assemble(lines: ["7E8 10 14 49 02 01 31 47 31"])
        ) { error in
            guard case ISOTPError.incompleteMultiFrame = error else {
                return XCTFail("expected incompleteMultiFrame, got \(error)")
            }
        }
    }

    func testEmptyInputYieldsNoResponses() throws {
        XCTAssertTrue(try ISOTPAssembler.assemble(lines: []).isEmpty)
    }
}

// MARK: - Conversions and PID decoding

final class ConversionTests: XCTestCase {

    /// Every formula below is hand-computed from the SAE J1979 definition, so a
    /// regression in the generic linear engine shows up as a wrong physical value
    /// rather than a passing-but-meaningless test.
    func testStandardFormulas() {
        // Coolant temp: A − 40. 0x5A = 90 → 50 °C
        assertDecode(.temperatureCelsius, bytes: [0x5A], equals: 50)

        // RPM: (256A + B) / 4. 0x0BB8 = 3000 → 750 rpm
        assertDecode(.engineRPM, bytes: [0x0B, 0xB8], equals: 750)

        // Throttle: A · 100 / 255. 0xFF → 100 %
        assertDecode(.percent, bytes: [0xFF], equals: 100)
        assertDecode(.percent, bytes: [0x00], equals: 0)

        // Fuel trim: A · 100 / 128 − 100. 0x80 = 128 → 0 %
        assertDecode(.fuelTrim, bytes: [0x80], equals: 0)
        assertDecode(.fuelTrim, bytes: [0x00], equals: -100)

        // Timing advance: A / 2 − 64. 0x80 = 128 → 0°
        assertDecode(.timingAdvance, bytes: [0x80], equals: 0)

        // Module voltage: (256A + B) / 1000. 0x39D0 = 14800 → 14.8 V
        assertDecode(.moduleVoltage, bytes: [0x39, 0xD0], equals: 14.8)

        // MAF: (256A + B) / 100. 0x0100 = 256 → 2.56 g/s
        assertDecode(.massAirFlow, bytes: [0x01, 0x00], equals: 2.56)
    }

    func testManufacturerExtendedFormulas() {
        // Oil temp (Mode 22): A · 0.75 − 48. 0x78 = 120 → 42 °C
        let oilTemp = Conversion.linear(.init(factor: 0.75, postOffset: -48))
        assertDecode(oilTemp, bytes: [0x78], equals: 42)

        // TPMS pressure: raw / 5. 0xAA = 170 → 34 psi
        let tpms = Conversion.linear(.init(divisor: 5))
        assertDecode(tpms, bytes: [0xAA], equals: 34)
    }

    func testDivisorOfZeroYieldsNaNRatherThanCrashing() {
        let broken = LinearConversion(divisor: 0)
        XCTAssertTrue(broken.apply(rawValue: 100).isNaN)
    }

    private func assertDecode(_ conversion: Conversion,
                              bytes: [UInt8],
                              equals expected: Double,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        let definition = SignalDefinition(
            id: "test", label: "Test", header: "7E0", mode: "01", pid: "00",
            byteOffset: 0, byteCount: bytes.count,
            conversion: conversion, unit: .none
        )
        do {
            let value = try PIDDecoder.decode(data: bytes, using: definition)
            XCTAssertEqual(value, expected, accuracy: 0.0001, file: file, line: line)
        } catch {
            XCTFail("decode threw: \(error)", file: file, line: line)
        }
    }
}

final class PIDDecoderTests: XCTestCase {

    private let rpm = SignalDefinition(
        id: .rpm, label: "Engine RPM", header: "7E0", mode: "01", pid: "0C",
        byteOffset: 0, byteCount: 2, conversion: .engineRPM, unit: .rpm
    )

    func testDecodesValidatedResponse() throws {
        let response = ECUResponse(header: "7E8", payload: [0x41, 0x0C, 0x0B, 0xB8])
        XCTAssertEqual(try PIDDecoder.decode(response, using: rpm), 750, accuracy: 0.001)
    }

    /// A response mode is the request mode plus 0x40. Decoding a reply to a
    /// different request would yield a plausible but wrong reading, which is
    /// worse than dropping the sample.
    func testRejectsWrongMode() {
        let response = ECUResponse(header: "7E8", payload: [0x62, 0x0C, 0x0B, 0xB8])
        XCTAssertThrowsError(try PIDDecoder.decode(response, using: rpm)) { error in
            guard case DecodeError.modeMismatch = error else {
                return XCTFail("expected modeMismatch, got \(error)")
            }
        }
    }

    func testRejectsWrongPID() {
        let response = ECUResponse(header: "7E8", payload: [0x41, 0x0D, 0x0B, 0xB8])
        XCTAssertThrowsError(try PIDDecoder.decode(response, using: rpm)) { error in
            guard case DecodeError.pidMismatch = error else {
                return XCTFail("expected pidMismatch, got \(error)")
            }
        }
    }

    func testRejectsShortPayload() {
        let response = ECUResponse(header: "7E8", payload: [0x41, 0x0C, 0x0B])
        XCTAssertThrowsError(try PIDDecoder.decode(response, using: rpm)) { error in
            guard case DecodeError.payloadTooShort = error else {
                return XCTFail("expected payloadTooShort, got \(error)")
            }
        }
    }

    /// Mode 22 echoes a two-byte PID, so the data offset differs from Mode 01.
    func testHandlesTwoBytePIDEcho() throws {
        let oilTemp = SignalDefinition(
            id: .oilTemp, label: "Oil Temp", header: "7E0", mode: "22", pid: "E001",
            byteOffset: 0, byteCount: 1,
            conversion: .linear(.init(factor: 0.75, postOffset: -48)), unit: .celsius
        )
        let response = ECUResponse(header: "7E8", payload: [0x62, 0xE0, 0x01, 0x78])
        XCTAssertEqual(try PIDDecoder.decode(response, using: oilTemp), 42, accuracy: 0.001)
    }

    /// VIN replies are commonly front-padded with a non-printable filler byte
    /// (here `0x01`), which must not leak into the decoded string.
    func testDecodesASCIIAndDropsFiller() {
        let response = ECUResponse(
            header: "7E8",
            payload: [0x49, 0x02, 0x01] + Array("KM8J3CA46JU".utf8)
        )
        XCTAssertEqual(PIDDecoder.decodeASCII(response, pidByteCount: 1), "KM8J3CA46JU")
    }
}

// MARK: - Supported PIDs and DTCs

final class SupportedPIDDecoderTests: XCTestCase {

    func testHighestBitMapsToFirstPIDAfterBase() {
        XCTAssertEqual(SupportedPIDDecoder.supportedPIDs(from: [0x80, 0x00, 0x00, 0x00],
                                                         base: 0x00),
                       [0x01])
    }

    func testDecodesRealisticBitmask() {
        // 0xBE3EB811 — the leading 0xBE = 1011 1110 covers PIDs 01–08.
        let supported = SupportedPIDDecoder.supportedPIDs(from: [0xBE, 0x3E, 0xB8, 0x11],
                                                          base: 0x00)
        XCTAssertEqual(Array(supported.prefix(6)), [0x01, 0x03, 0x04, 0x05, 0x06, 0x07])
        XCTAssertFalse(supported.contains(0x02))
    }

    func testHonoursBaseOffsetForHigherBanks() {
        XCTAssertEqual(SupportedPIDDecoder.supportedPIDs(from: [0x80, 0x00, 0x00, 0x00],
                                                         base: 0x20),
                       [0x21])
    }

    func testShortPayloadYieldsNothing() {
        XCTAssertTrue(SupportedPIDDecoder.supportedPIDs(from: [0x80, 0x00], base: 0).isEmpty)
    }
}

final class DTCDecoderTests: XCTestCase {

    /// The two high bits select P/C/B/U and the next two give the first digit;
    /// the remaining twelve bits are three literal hex digits.
    func testEncodesEachSystemLetter() {
        XCTAssertEqual(DTCDecoder.code(from: 0x03, 0x01), "P0301")
        XCTAssertEqual(DTCDecoder.code(from: 0x43, 0x01), "C0301")
        XCTAssertEqual(DTCDecoder.code(from: 0x83, 0x01), "B0301")
        XCTAssertEqual(DTCDecoder.code(from: 0xC1, 0x00), "U0100")
    }

    func testEncodesNonZeroFirstDigit() {
        // 0b00_01_0001 → P1, remainder 0x120
        XCTAssertEqual(DTCDecoder.code(from: 0x11, 0x20), "P1120")
    }

    func testPreservesHexDigits() {
        XCTAssertEqual(DTCDecoder.code(from: 0x0A, 0xBC), "P0ABC")
    }

    func testExtractsMultipleCodesAndDropsPadding() {
        // ECUs pad the frame with 0000 once codes run out.
        let codes = DTCDecoder.codes(from: [0x03, 0x01, 0xC1, 0x00, 0x00, 0x00])
        XCTAssertEqual(codes, ["P0301", "U0100"])
    }

    func testNoCodesYieldsEmpty() {
        XCTAssertTrue(DTCDecoder.codes(from: [0x00, 0x00]).isEmpty)
    }
}

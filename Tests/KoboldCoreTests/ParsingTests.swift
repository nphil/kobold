import XCTest
@testable import KoboldCore

// MARK: - Hex

final class HexTests: XCTestCase {

    func testParsesWithAndWithoutSpaces() {
        XCTAssertEqual(Hex.bytes(from: "410C0BB8"), [0x41, 0x0C, 0x0B, 0xB8])
        XCTAssertEqual(Hex.bytes(from: "41 0C 0B B8"), [0x41, 0x0C, 0x0B, 0xB8])
        XCTAssertEqual(Hex.bytes(from: "41\t0C\r0B B8"), [0x41, 0x0C, 0x0B, 0xB8])
    }

    func testIsCaseInsensitive() {
        XCTAssertEqual(Hex.bytes(from: "abcdef"), Hex.bytes(from: "ABCDEF"))
    }

    func testRejectsOddDigitCountAndNonHex() {
        XCTAssertNil(Hex.bytes(from: "410"))
        XCTAssertNil(Hex.bytes(from: "41ZZ"))
    }

    func testEmptyStringParsesToNoBytes() {
        XCTAssertEqual(Hex.bytes(from: ""), [])
    }

    func testFormatsUppercasePadded() {
        XCTAssertEqual(Hex.string(from: [0x0B, 0xB8]), "0BB8")
        XCTAssertEqual(Hex.string(from: [0x0B, 0xB8], separator: " "), "0B B8")
    }

    func testBigEndianValue() {
        XCTAssertEqual([0x0B, 0xB8].bigEndianValue, 3000)
        XCTAssertEqual([UInt8(0xFF)].bigEndianValue, 255)
        XCTAssertEqual([UInt8]().bigEndianValue, 0)
    }
}

// MARK: - Response assembly

final class ResponseAssemblerTests: XCTestCase {

    func testAssemblesResponseSplitAcrossFragments() {
        var assembler = ResponseAssembler()

        // A real BLE peripheral splits replies across notifications; nothing is
        // complete until the '>' prompt arrives.
        XCTAssertTrue(assembler.append(Data("7E8 04 41".utf8)).isEmpty)
        XCTAssertTrue(assembler.append(Data(" 0C 0B B8\r".utf8)).isEmpty)

        let responses = assembler.append(Data(">".utf8))
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.lines, ["7E8 04 41 0C 0B B8"])
    }

    func testSplitsMultipleLines() {
        var assembler = ResponseAssembler()
        let responses = assembler.append(Data("7E8 10 14 49 02\r7E8 21 01 31\r>".utf8))
        XCTAssertEqual(responses.first?.lines, ["7E8 10 14 49 02", "7E8 21 01 31"])
    }

    func testHandlesSeveralResponsesInOneFragment() {
        var assembler = ResponseAssembler()
        let responses = assembler.append(Data("OK\r>OK\r>41 0C 0B B8\r>".utf8))
        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(responses[0].lines, ["OK"])
        XCTAssertEqual(responses[2].lines, ["41 0C 0B B8"])
    }

    func testToleratesCRLFAndBlankLines() {
        var assembler = ResponseAssembler()
        let responses = assembler.append(Data("\r\n41 0C 0B B8\r\n\r\n>".utf8))
        XCTAssertEqual(responses.first?.lines, ["41 0C 0B B8"])
    }

    func testResetDiscardsPartialResponse() {
        var assembler = ResponseAssembler()
        _ = assembler.append(Data("7E8 04 41".utf8))
        XCTAssertGreaterThan(assembler.pendingByteCount, 0)

        assembler.reset()
        XCTAssertEqual(assembler.pendingByteCount, 0)

        // A stale fragment must not corrupt the next session's first reply.
        let responses = assembler.append(Data("41 0D 00\r>".utf8))
        XCTAssertEqual(responses.first?.lines, ["41 0D 00"])
    }

    func testBufferIsBoundedWhenPromptNeverArrives() {
        var assembler = ResponseAssembler(maximumBufferSize: 64)
        for _ in 0..<50 {
            _ = assembler.append(Data(String(repeating: "A", count: 32).utf8))
        }
        XCTAssertLessThanOrEqual(assembler.pendingByteCount, 64)
    }
}

// MARK: - Reply classification

final class ELM327ReplyTests: XCTestCase {

    private func parse(_ lines: [String], echoOf command: String? = nil) -> ELM327Reply {
        ELM327ReplyParser.parse(RawResponse(lines: lines), echoOf: command)
    }

    func testClassifiesControlStrings() {
        XCTAssertEqual(parse(["OK"]), .ok)
        XCTAssertEqual(parse(["NO DATA"]), .noData)
        XCTAssertEqual(parse(["STOPPED"]), .stopped)
        XCTAssertEqual(parse(["BUFFER FULL"]), .bufferFull)
        XCTAssertEqual(parse(["UNABLE TO CONNECT"]), .unableToConnect)
        XCTAssertEqual(parse(["?"]), .unknownCommand)
        XCTAssertEqual(parse(["CAN ERROR"]), .canError)
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(parse(["no data"]), .noData)
        XCTAssertEqual(parse(["  Ok  "]), .ok)
    }

    func testSearchingAloneIsTransient() {
        XCTAssertEqual(parse(["SEARCHING..."]), .searching)
        XCTAssertTrue(parse(["SEARCHING..."]).isTransient)
    }

    /// `SEARCHING...` frequently precedes a real payload in the same response.
    /// Returning early on it would throw away the answer.
    func testSearchingIsStrippedWhenPayloadFollows() {
        XCTAssertEqual(parse(["SEARCHING...", "41 0C 0B B8"]),
                       .data(lines: ["41 0C 0B B8"]))
    }

    func testStripsEchoedCommand() {
        XCTAssertEqual(parse(["010C", "41 0C 0B B8"], echoOf: "010C"),
                       .data(lines: ["41 0C 0B B8"]))
    }

    func testDoesNotStripPayloadThatMerelyResemblesEcho() {
        // Without an expected echo, a hex line is payload.
        XCTAssertEqual(parse(["010C"]), .data(lines: ["010C"]))
    }

    func testAcceptsSequencePrefixedPayload() {
        XCTAssertEqual(parse(["0: 49 02 01 31", "1: 47 31 4A 43"]),
                       .data(lines: ["0: 49 02 01 31", "1: 47 31 4A 43"]))
    }

    func testNonHexNoiseIsUnrecognised() {
        XCTAssertEqual(parse(["ELM327 v1.5"]), .unrecognised(lines: ["ELM327 v1.5"]))
    }

    func testErrorStringWinsOverPayloadInSameResponse() {
        XCTAssertEqual(parse(["41 0C 0B B8", "STOPPED"]), .stopped)
    }
}

/// Frames captured verbatim from a Genesis G70 2020 2.0T over a Vgate iCar
/// Pro 2S, protocol 6 (ISO 15765-4, 11-bit, 500 kbps), engine idling.
///
/// The init sequence sends `ATS0`, so the adapter runs the CAN header straight
/// into the payload with no separator: `7E803410588`, not `7E8 03 41 05 88`.
/// The splitter only handled the spaced form, so every one of these — all
/// perfectly valid — was discarded as `malformedLine`, and the app reported
/// that the car was not answering while it answered everything.
final class UnspacedHeaderFrameTests: XCTestCase {

    func testSingleFrameWithUnspacedElevenBitHeader() throws {
        let responses = try ISOTPAssembler.assemble(lines: ["7E803410588"])

        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.header, "7E8")
        // PCI 0x03 declares three payload bytes: mode 0x41, PID 0x05, value 0x88.
        XCTAssertEqual(response.payload, [0x41, 0x05, 0x88])
    }

    func testRPMFromTheSecondECU() throws {
        let responses = try ISOTPAssembler.assemble(lines: ["7E904410C0C08"])

        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.header, "7E9")
        XCTAssertEqual(response.payload, [0x41, 0x0C, 0x0C, 0x08])
    }

    /// Two ECUs answering the same functional request must stay separate, which
    /// is the entire reason headers are left on.
    func testTwoECUsAreKeptApart() throws {
        let responses = try ISOTPAssembler.assemble(lines: ["7E803410588", "7E903410D00"])

        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(responses.map(\.header), ["7E8", "7E9"])
        XCTAssertEqual(responses[0].payload, [0x41, 0x05, 0x88])
        XCTAssertEqual(responses[1].payload, [0x41, 0x0D, 0x00])
    }

    /// The Mode 22 oil-temperature reply arrives as an ISO-TP first frame,
    /// captured here without its consecutive frames.
    ///
    /// Asserting the *incomplete* result on purpose: the header is now parsed
    /// correctly, which is what changed, and a first frame on its own really is
    /// incomplete. Reporting a partial payload as though it were an answer would
    /// decode oil temperature from whatever bytes happened to arrive.
    func testLoneFirstFrameIsReportedAsIncompleteNotMalformed() {
        XCTAssertThrowsError(try ISOTPAssembler.assemble(lines: ["7E8102D62E0019FB73F"])) { error in
            guard case .incompleteMultiFrame(let expected, let received)? = error as? ISOTPError else {
                return XCTFail("expected incompleteMultiFrame, got \(error)")
            }
            XCTAssertEqual(expected, 45, "0x02D declared in the first frame")
            XCTAssertEqual(received, 6, "eight bytes less the two PCI bytes")
        }
    }

    /// A complete multi-frame reply reassembles across unspaced headers.
    func testMultiFrameReassemblesWithUnspacedHeaders() throws {
        let responses = try ISOTPAssembler.assemble(lines: [
            "7E8100A62E0019FB73F",   // first frame: 10 bytes total, 6 carried
            "7E82111223344000000",   // consecutive #1: 7 more, padded
        ])

        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.header, "7E8")
        // Truncated to the declared length, so the CAN padding is dropped.
        XCTAssertEqual(response.payload,
                       [0x62, 0xE0, 0x01, 0x9F, 0xB7, 0x3F, 0x11, 0x22, 0x33, 0x44])
    }

    /// The spaced form must keep working — nothing guarantees ATS0 succeeded.
    func testSpacedFormStillParses() throws {
        let responses = try ISOTPAssembler.assemble(lines: ["7E8 03 41 05 88"])

        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.header, "7E8")
        XCTAssertEqual(response.payload, [0x41, 0x05, 0x88])
    }
}

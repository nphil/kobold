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

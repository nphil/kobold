import XCTest
@testable import KoboldCore

/// Sweeping a module for undocumented data identifiers.
///
/// The point of these is the distinction a naive scanner loses: "this address
/// holds nothing" and "this address holds something you may not have" look the
/// same if both are recorded as a miss, and they lead to completely different
/// next steps.
final class UDSScanTests: XCTestCase {

    // MARK: - Classification

    func testPositiveResponseIsData() {
        // 62 F1 00 <data> — Service 22 answered.
        let response = ECUResponse(header: "7D8", payload: [0x62, 0xF1, 0x00, 0x41, 0x42])
        XCTAssertEqual(ELM327Driver.classify(response, service: 0x22), .data([0x41, 0x42]))
    }

    func testServiceTwentyOneEchoesOnlyOneIdentifierByte() {
        let response = ECUResponse(header: "7E9", payload: [0x61, 0xA0, 0x12, 0x34])
        XCTAssertEqual(ELM327Driver.classify(response, service: 0x21), .data([0x12, 0x34]))
    }

    /// A refusal is three bytes that would otherwise look exactly like a
    /// finding, and there are far more refusals than findings in a sweep.
    func testNegativeResponseIsARefusalNotData() {
        let response = ECUResponse(header: "7D8", payload: [0x7F, 0x22, 0x31])
        XCTAssertEqual(ELM327Driver.classify(response, service: 0x22), .refused(0x31))

        let locked = ECUResponse(header: "7D8", payload: [0x7F, 0x22, 0x33])
        XCTAssertEqual(ELM327Driver.classify(locked, service: 0x22), .refused(0x33))
    }

    /// Another module's traffic must not be counted as this module's answer.
    func testAReplyToADifferentServiceIsIgnored() {
        let response = ECUResponse(header: "7E8", payload: [0x41, 0x0C, 0x0B, 0xB8])
        XCTAssertEqual(ELM327Driver.classify(response, service: 0x22), .silent)
    }

    /// The one a service check cannot catch. Every command in a sweep is a
    /// `22`, so a reply that is one address stale looks perfectly valid — and
    /// recorded as a finding it invents data at an address that holds none.
    func testAReplyEchoingADifferentIdentifierIsNotAFinding() {
        let stale = ECUResponse(header: "7D8", payload: [0x62, 0x01, 0x20, 0x4B])
        XCTAssertEqual(ELM327Driver.classify(stale, service: 0x22, identifier: 0x0121),
                       .silent)
        XCTAssertEqual(ELM327Driver.classify(stale, service: 0x22, identifier: 0x0120),
                       .data([0x4B]))
    }

    /// A refusal echoes no identifier, so it must still be read as a refusal.
    func testARefusalIsStillARefusalWhenAnIdentifierIsExpected() {
        let response = ECUResponse(header: "7D8", payload: [0x7F, 0x22, 0x31])
        XCTAssertEqual(ELM327Driver.classify(response, service: 0x22, identifier: 0x0121),
                       .refused(0x31))
    }

    func testServiceTwentyOneEchoIsOneByteWide() {
        let response = ECUResponse(header: "7D9", payload: [0x61, 0xA0, 0x12])
        XCTAssertEqual(ELM327Driver.classify(response, service: 0x21, identifier: 0xA0),
                       .data([0x12]))
        XCTAssertEqual(ELM327Driver.classify(response, service: 0x21, identifier: 0xA1),
                       .silent)
    }

    // MARK: - What a null result means

    func testOnlyRequestOutOfRangeMeansAbsent() {
        XCTAssertTrue(NegativeResponse.meansAbsent(0x31))
        for code: UInt8 in [0x22, 0x33, 0x35, 0x7E, 0x7F] {
            XCTAssertFalse(NegativeResponse.meansAbsent(code), String(code, radix: 16))
            XCTAssertTrue(NegativeResponse.meansGated(code), String(code, radix: 16))
        }
    }

    /// The whole design: an address that says "not supported" is noise, and one
    /// that says "denied" is the finding.
    func testAbsentIdentifiersAreCountedButGatedOnesAreKept() {
        var progress = ScanProgress()
        for identifier in UInt32(0)..<UInt32(50) {
            progress.record(module: "fwdRadar", service: 0x22,
                            identifier: identifier, outcome: .refused(0x31))
        }
        XCTAssertTrue(progress.findings.isEmpty, "50 absent addresses are not 50 findings")

        progress.record(module: "fwdRadar", service: 0x22,
                        identifier: 0x0200, outcome: .refused(0x33))
        XCTAssertEqual(progress.findings.count, 1)
        XCTAssertTrue(progress.findings[0].isGated)

        let verdict = progress.verdict(module: "fwdRadar", service: 0x22)
        XCTAssertTrue(verdict.contains("50 absent"), verdict)
        XCTAssertTrue(verdict.contains("1 gated"), verdict)
    }

    // MARK: - Resuming

    /// An hour of sitting still must never be repeated because Bluetooth
    /// dropped.
    func testProgressResumesWhereItStopped() throws {
        var progress = ScanProgress()
        for identifier in UInt32(0)..<UInt32(1000) {
            progress.record(module: "absEsc", service: 0x22,
                            identifier: identifier, outcome: .refused(0x31))
        }
        progress.record(module: "absEsc", service: 0x22,
                        identifier: 1000, outcome: .data([0x01, 0x02]))

        let restored = try XCTUnwrap(ScanProgress.decoded(from: progress.encoded()))
        XCTAssertEqual(restored.nextIdentifier(module: "absEsc", service: 0x22), 1001)
        XCTAssertEqual(restored.triedCount(module: "absEsc", service: 0x22), 1001)
        XCTAssertEqual(restored.findings.count, 1)
        XCTAssertEqual(restored.findings[0].bytes, [0x01, 0x02])
    }

    func testCursorsAreIndependentPerModuleAndService() {
        var progress = ScanProgress()
        progress.record(module: "absEsc", service: 0x21, identifier: 5, outcome: .silent)

        XCTAssertEqual(progress.nextIdentifier(module: "absEsc", service: 0x21), 6)
        XCTAssertEqual(progress.nextIdentifier(module: "absEsc", service: 0x22), 0)
        XCTAssertEqual(progress.nextIdentifier(module: "fwdRadar", service: 0x21), 0)
    }

    // MARK: - Silence is not absence

    /// The failure that actually happened: a sweep where every probe was
    /// silent reported itself as "this module has no data at those addresses",
    /// which is a confident negative drawn from no evidence whatsoever.
    func testASweepThatHeardNothingIsInconclusiveNotNegative() {
        var progress = ScanProgress()
        for identifier in UInt32(0)..<UInt32(500) {
            progress.record(module: "fwdRadar", service: 0x22,
                            identifier: identifier, outcome: .silent)
        }

        XCTAssertTrue(progress.heardNothing(module: "fwdRadar", service: 0x22))
        XCTAssertEqual(progress.inconclusive(module: "fwdRadar"), [0x22])

        let verdict = progress.verdict(module: "fwdRadar", service: 0x22)
        XCTAssertTrue(verdict.contains("500 no reply"), verdict)
        XCTAssertFalse(verdict.contains("absent"), "silence is not absence: \(verdict)")
    }

    /// One genuine refusal is enough to make a sweep evidence.
    func testASweepWithRefusalsIsConclusive() {
        var progress = ScanProgress()
        progress.record(module: "absEsc", service: 0x22, identifier: 0, outcome: .silent)
        progress.record(module: "absEsc", service: 0x22, identifier: 1, outcome: .refused(0x31))

        XCTAssertFalse(progress.heardNothing(module: "absEsc", service: 0x22))
        XCTAssertTrue(progress.inconclusive(module: "absEsc").isEmpty)
    }

    /// An inconclusive run must leave no trace, or the module reads as fully
    /// scanned and can never be retried.
    func testDiscardingAnInconclusiveSweepAllowsItToBeRunAgain() {
        var progress = ScanProgress()
        for identifier in UInt32(0)..<UInt32(0x1_0000) {
            progress.record(module: "fwdRadar", service: 0x22,
                            identifier: identifier, outcome: .silent)
        }
        XCTAssertEqual(progress.nextIdentifier(module: "fwdRadar", service: 0x22), 0x1_0000)

        progress.discard(module: "fwdRadar", service: 0x22)

        XCTAssertEqual(progress.nextIdentifier(module: "fwdRadar", service: 0x22), 0)
        XCTAssertEqual(progress.triedCount(module: "fwdRadar", service: 0x22), 0)
        XCTAssertEqual(progress.verdict(module: "fwdRadar", service: 0x22), "not started")
    }

    /// Discarding one sweep must not touch another module's completed work.
    func testDiscardingLeavesOtherModulesAlone() {
        var progress = ScanProgress()
        progress.record(module: "absEsc", service: 0x22, identifier: 7, outcome: .data([1]))
        progress.record(module: "fwdRadar", service: 0x22, identifier: 7, outcome: .silent)

        progress.discard(module: "fwdRadar", service: 0x22)

        XCTAssertEqual(progress.findings(module: "absEsc").count, 1)
        XCTAssertEqual(progress.nextIdentifier(module: "absEsc", service: 0x22), 8)
    }

    // MARK: - A service the module does not implement

    /// The waste this exists to stop: three modules each answered "Service not
    /// supported" 256 times, which is 768 probes to learn what the first reply
    /// already said.
    func testAnUnimplementedServiceSkipsTheRestOfItsAddressSpace() {
        var progress = ScanProgress()
        for identifier in UInt32(0)..<UInt32(3) {
            progress.record(module: "absEsc", service: 0x21,
                            identifier: identifier, outcome: .refused(0x11))
        }
        progress.markUnsupported(module: "absEsc", service: 0x21, count: 0x100)

        XCTAssertTrue(progress.isUnsupported(module: "absEsc", service: 0x21))
        XCTAssertEqual(progress.nextIdentifier(module: "absEsc", service: 0x21), 0x100,
                       "the sweep must read as finished, not as stopped early")

        let verdict = progress.verdict(module: "absEsc", service: 0x21)
        XCTAssertTrue(verdict.contains("not implemented"), verdict)
        XCTAssertTrue(verdict.contains("3"), verdict)

        // Service 22 is a separate question and must be untouched.
        XCTAssertFalse(progress.isUnsupported(module: "absEsc", service: 0x22))
        XCTAssertEqual(progress.nextIdentifier(module: "absEsc", service: 0x22), 0)
    }

    func testDiscardingClearsTheUnsupportedVerdictToo() {
        var progress = ScanProgress()
        progress.record(module: "absEsc", service: 0x21, identifier: 0, outcome: .refused(0x11))
        progress.markUnsupported(module: "absEsc", service: 0x21, count: 0x100)

        progress.discard(module: "absEsc", service: 0x21)

        XCTAssertFalse(progress.isUnsupported(module: "absEsc", service: 0x21))
        XCTAssertEqual(progress.nextIdentifier(module: "absEsc", service: 0x21), 0)
    }

    /// Progress saved before this field existed must still load. An hour of
    /// scanning is not an acceptable price for adding a property.
    func testProgressSavedBeforeTheUnsupportedFieldExistedStillDecodes() throws {
        let legacy = """
        {"cursor":{"absEsc/22":41},"findings":[],"tried":{"absEsc/22":41},\
        "absent":{"absEsc/22":41},"silent":{}}
        """
        let restored = try XCTUnwrap(ScanProgress.decoded(from: Data(legacy.utf8)))
        XCTAssertEqual(restored.nextIdentifier(module: "absEsc", service: 0x22), 41)
        XCTAssertFalse(restored.isUnsupported(module: "absEsc", service: 0x22))
    }

    func testUnsupportedSurvivesARoundTrip() throws {
        var progress = ScanProgress()
        progress.record(module: "absEsc", service: 0x21, identifier: 0, outcome: .refused(0x11))
        progress.markUnsupported(module: "absEsc", service: 0x21, count: 0x100)

        let restored = try XCTUnwrap(ScanProgress.decoded(from: progress.encoded()))
        XCTAssertTrue(restored.isUnsupported(module: "absEsc", service: 0x21))
    }

    // MARK: - Rendering

    func testCommandTextMatchesWhatWasSent() {
        let two = ScanFinding(module: "m", service: 0x22, identifier: 0xF100,
                              bytes: [0x00], refusal: nil)
        XCTAssertEqual(two.command, "22F100")

        let one = ScanFinding(module: "m", service: 0x21, identifier: 0xA0,
                              bytes: [0x00], refusal: nil)
        XCTAssertEqual(one.command, "21A0")
    }

    /// Text is surfaced when the payload really is text. Bytes that merely
    /// happen to be printable are not — a version string is worth reading and
    /// two coincidental letters are misleading.
    func testTextIsRecognisedOnlyWhenMostOfThePayloadIsReadable() {
        XCTAssertEqual(ScanFinding.readableText(Array("IK__SCC".utf8)), "IK__SCC")
        XCTAssertNil(ScanFinding.readableText([0x41, 0x42, 0x00, 0x01, 0x02, 0x03]))
        XCTAssertNil(ScanFinding.readableText([0x41, 0x42]))
    }
}

import XCTest
@testable import ELMterm

final class OBD2AnalyzerTests: XCTestCase {

    func test_annotateIncoming_visibleSingleFrameLengthByte_decodesNegativeResponse() {
        let analyzer = OBD2Analyzer()

        let output = analyzer.annotateIncoming("7E8 03 7F 01 11")

        XCTAssertNotNil(output)
        XCTAssertEqual(output?.headline, "❌ Negative Response (NRC 0x11)")
        XCTAssertTrue(output?.details.contains("Single-frame length byte 0x03 stripped before decoding") == true)
        XCTAssertTrue(output?.details.contains("Service 0x01 failed") == true)
        XCTAssertTrue(output?.details.contains("Service not supported") == true)
        XCTAssertTrue(output?.details.contains("Hex: 7F 01 11") == true)
    }

    func test_legacyMultiLine_reassemblesVIN_onFinalize() {
        let analyzer = OBD2Analyzer()

        let lines = [
            "49 02 01 00 00 00 57",
            "49 02 02 44 58 2D 53",
            "49 02 03 49 4D 30 30",
            "49 02 04 31 39 32 31",
            "49 02 05 32 33 34 35",
        ]
        for line in lines {
            let progress = analyzer.annotateIncoming(line)
            XCTAssertTrue(progress?.headline.hasPrefix("📦 Legacy multi-line") == true)
        }

        let finalized = analyzer.finalizeReassembly()
        XCTAssertEqual(finalized.count, 1)
        XCTAssertEqual(finalized.first?.headline, "✅ Mode 09 PID 02: Vehicle Identification Number")
        XCTAssertTrue(finalized.first?.details.contains("VIN: WDX-SIM0019212345") == true)

        // State must be drained so a later response doesn't inherit it.
        XCTAssertTrue(analyzer.finalizeReassembly().isEmpty)
    }

    func test_livePIDs_decodeEngineeringUnits() {
        let cases = [
            ("41 0C 1A F9", "Engine RPM: 1726.25 rpm"),
            ("41 05 7B", "Engine coolant temperature: 83 °C"),
            ("41 42 36 B0", "Control module voltage: 14.000 V"),
            ("41 10 01 F4", "MAF air flow rate: 5.00 g/s"),
        ]
        for (frame, expected) in cases {
            let output = OBD2Analyzer().annotateIncoming(frame)
            XCTAssertTrue(output?.details.contains(expected) == true, "\(frame): \(String(describing: output))")
        }
    }

    func test_livePIDs_truncatedPayloadDoesNotInventValue() {
        let output = OBD2Analyzer().annotateIncoming("41 0C 1A")
        XCTAssertFalse(output?.details.contains(where: { $0.contains("rpm") }) == true)
    }

    func test_otherModes_doNotUseMode01PIDLayout() {
        for frame in ["42 0C 00 1A F8", "49 05 01"] {
            let output = OBD2Analyzer().annotateIncoming(frame)
            XCTAssertFalse(output?.details.contains(where: { $0.contains("rpm") || $0.contains("°C") }) == true)
        }
    }

    func test_isotp_sequenceErrorDiscardsIncompleteMessage() {
        let analyzer = OBD2Analyzer()
        _ = analyzer.annotateIncoming("7E8 10 14 49 02 01 57 41 55")
        XCTAssertEqual(analyzer.annotateIncoming("7E8 22 5A 5A 5A 38 54 38 42")?.headline, "⚠️ ISO-TP Sequence Error")
        XCTAssertEqual(analyzer.annotateIncoming("7E8 21 5A 5A 5A 38 54 38 42")?.headline, "⚠️ ISO-TP Consecutive Frame (orphaned)")
    }

    // MARK: - DTC decoding

    func test_dtcDecoder_obd2TwoByteCode() {
        XCTAssertEqual(DTCDecoder.code(0x01, 0x33), "P0133")
        XCTAssertEqual(DTCDecoder.code(0x43, 0x00), "C0300")
        XCTAssertEqual(DTCDecoder.code(0x81, 0x55), "B0155")
        XCTAssertEqual(DTCDecoder.code(0xC1, 0x00), "U0100")
        XCTAssertEqual(DTCDecoder.code(0x01, 0x00, 0x21), "P0100-21")
    }

    func test_dtcDecoder_statusFlags() {
        XCTAssertEqual(DTCDecoder.statusFlags(0x00), [])
        XCTAssertEqual(DTCDecoder.statusFlags(0x08), ["confirmed"])
        XCTAssertEqual(DTCDecoder.statusFlags(0x09), ["testFailed", "confirmed"])
    }

    func test_annotateIncoming_mode03_decodesStoredDTCs() {
        let analyzer = OBD2Analyzer()

        let output = analyzer.annotateIncoming("7E8 43 01 33 01 71")

        XCTAssertEqual(output?.headline, "✅ Mode 03: 2 stored DTCs")
        XCTAssertTrue(output?.details.contains("P0133 — O2 Sensor Circuit Slow Response (Bank 1, Sensor 1)") == true)
        XCTAssertTrue(output?.details.contains("P0171 — System Too Lean (Bank 1)") == true)
    }

    func test_annotateIncoming_mode03_noDTCs() {
        let analyzer = OBD2Analyzer()

        let output = analyzer.annotateIncoming("7E8 43 00 00")

        XCTAssertEqual(output?.headline, "✅ Mode 03: no stored DTCs")
    }

    func test_annotateIncoming_uds19_decodesDTCWithStatus() {
        let analyzer = OBD2Analyzer()

        // 59 02 <mask=FF> | DTC 01 71 00 (P0171) status 0x09 | DTC 01 33 00 status 0x08
        let output = analyzer.annotateIncoming("7E8 59 02 FF 01 71 00 09 01 33 00 08")

        XCTAssertEqual(output?.headline, "UDS Read DTC information")
        XCTAssertTrue(output?.details.contains { $0.hasPrefix("P0171-00 — System Too Lean (Bank 1)") && $0.contains("testFailed, confirmed") } == true)
        XCTAssertTrue(output?.details.contains { $0.hasPrefix("P0133-00") && $0.contains("confirmed") } == true)
    }

    func test_annotateOutgoing_afterAutoSearch_showsInferredCANFrame() {
        let analyzer = OBD2Analyzer()

        XCTAssertFalse(analyzer.annotateOutgoing("0100")?.details.contains { $0.hasPrefix("CAN frame (inferred)") } == true)
        _ = analyzer.annotateIncoming("SEARCHING...")
        _ = analyzer.annotateIncoming("41 00 BE 1F A8 13")
        _ = analyzer.annotateOutgoing("ATH1")
        XCTAssertFalse(analyzer.annotateOutgoing("0100")?.details.contains { $0.hasPrefix("CAN frame (inferred)") } == true)
        _ = analyzer.annotateIncoming("7E8 06 41 00 BE 1F A8 13")

        let output = analyzer.annotateOutgoing("0902")
        XCTAssertEqual(output?.details.first, "CAN frame (inferred): 7DF 02 09 02")
    }

    func test_annotateOutgoing_unknownProtocol_hintsOncePerUnknownPhase() {
        let analyzer = OBD2Analyzer()
        let hint = "CAN frame unknown – protocol not determined yet (try ATDPN)"

        XCTAssertEqual(analyzer.annotateOutgoing("0100")?.details.first, hint)
        XCTAssertFalse(analyzer.annotateOutgoing("0100")?.details.contains(hint) == true)

        _ = analyzer.annotateOutgoing("ATSP6")
        XCTAssertFalse(analyzer.annotateOutgoing("0100")?.details.contains(hint) == true)

        _ = analyzer.annotateOutgoing("ATZ")
        XCTAssertEqual(analyzer.annotateOutgoing("0100")?.details.first, hint)
    }

    func test_annotateOutgoing_nonCANProtocol_showsNoHint() {
        let analyzer = OBD2Analyzer()
        _ = analyzer.annotateOutgoing("ATSP3")

        XCTAssertFalse(analyzer.annotateOutgoing("0100")?.details.contains { $0.hasPrefix("CAN frame") } == true)
    }
}

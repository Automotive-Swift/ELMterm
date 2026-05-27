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
}

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
}

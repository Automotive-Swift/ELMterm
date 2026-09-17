import XCTest
@testable import ELMterm

final class CommandLineTests: XCTestCase {
    func test_invalidTimeouts_rejectedBeforeConnecting() {
        for flag in ["--timeout", "--response-timeout"] {
            for value in ["0", "-1", "nan", "inf", "1e100"] {
                XCTAssertThrowsError(try ELMterm.parse(["tcp://localhost:1", flag, value]), "\(flag) \(value)")
            }
        }
    }

    func test_emptyOrMultilineBatchCommand_rejected() {
        for command in ["", " ", "ATI\rATZ", "ATI\nATZ"] {
            XCTAssertThrowsError(try ELMterm.parse(["tcp://localhost:1", "--exec", command]))
        }
    }

    func test_historyDepth_explicitZeroPreserved() throws {
        let options = try ELMterm.parse(["tcp://localhost:1", "--history-depth", "0"])
        XCTAssertEqual(options.historyDepth, 0)
        XCTAssertNil(try ELMterm.parse(["tcp://localhost:1"]).historyDepth)
        XCTAssertThrowsError(try ELMterm.parse(["tcp://localhost:1", "--history-depth", "-1"]))
    }

    func test_periodicInterval_rejectsNonfiniteAndOverflow() {
        for interval in ["inf", "nan", "1e100", "1e308m", "0", "-1s"] {
            XCTAssertNil(PeriodicScheduler.parseInterval(interval), interval)
        }
        XCTAssertEqual(PeriodicScheduler.parseInterval("500ms"), 0.5)
        XCTAssertEqual(PeriodicScheduler.parseInterval("2s"), 2)
        XCTAssertEqual(PeriodicScheduler.parseInterval("1m"), 60)
    }
}

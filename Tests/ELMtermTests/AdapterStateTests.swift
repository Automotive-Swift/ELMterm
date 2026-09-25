import XCTest
@testable import ELMterm

final class AdapterStateTests: XCTestCase {

    private func state(after commands: [String]) -> AdapterState {
        var state = AdapterState()
        commands.forEach { state.observeCommand($0) }
        return state
    }

    func test_canFrame_unknownProtocol_returnsNil() {
        XCTAssertNil(AdapterState().canFrame(for: [0x01, 0x00]))
        XCTAssertNil(self.state(after: ["ATSP0"]).canFrame(for: [0x01, 0x00]))
        XCTAssertNil(self.state(after: ["ATSPA6"]).canFrame(for: [0x01, 0x00]))
    }

    func test_canFrame_nonCANProtocol_returnsNil() {
        XCTAssertNil(self.state(after: ["ATSP3"]).canFrame(for: [0x01, 0x00]))
    }

    func test_canFrame_11BitDefaults_addsPCIWithoutPadding() {
        XCTAssertEqual(self.state(after: ["at sp 6"]).canFrame(for: [0x01, 0x00]), "7DF 02 01 00")
    }

    func test_canFrame_29BitDefaults_usesFunctionalAddress() {
        XCTAssertEqual(self.state(after: ["ATSP7"]).canFrame(for: [0x01, 0x00]), "18DB33F1 02 01 00")
    }

    func test_canFrame_explicitHeaders_honorWidthAndPriority() {
        XCTAssertEqual(self.state(after: ["ATSP6", "ATSH7E0"]).canFrame(for: [0x22, 0xF1, 0x90]), "7E0 03 22 F1 90")
        XCTAssertEqual(self.state(after: ["ATSP7", "ATSHDA10F1"]).canFrame(for: [0x3E, 0x00]), "18DA10F1 02 3E 00")
        XCTAssertEqual(self.state(after: ["ATSP7", "ATCP1A", "ATSHDA10F1"]).canFrame(for: [0x3E, 0x00]), "1ADA10F1 02 3E 00")
        XCTAssertEqual(self.state(after: ["ATSP9", "ATSH18DA17F1"]).canFrame(for: [0x3E, 0x00]), "18DA17F1 02 3E 00")
    }

    func test_canFrame_autoFormattingOff_sendsBytesVerbatim() {
        let state = self.state(after: ["ATSP6", "ATCAF0"])
        XCTAssertEqual(state.canFrame(for: [0x02, 0x01, 0x00]), "7DF 02 01 00")
        XCTAssertNil(state.canFrame(for: Array(repeating: 0x00, count: 9)))
    }

    func test_canFrame_extendedAddress_precedesPCI() {
        let state = self.state(after: ["ATSP6", "ATSH6F1", "ATCEA10"])
        XCTAssertEqual(state.canFrame(for: [0x3E, 0x00]), "6F1 10 02 3E 00")
        XCTAssertNil(state.canFrame(for: [0x2E, 0xF1, 0x90, 0x01, 0x02, 0x03, 0x04]))
    }

    func test_canFrame_multiFrameRequest_returnsNil() {
        XCTAssertNil(self.state(after: ["ATSP6"]).canFrame(for: Array(repeating: 0x00, count: 8)))
    }

    func test_reset_forgetsEverything() {
        XCTAssertNil(self.state(after: ["ATSP6", "ATSH7E0", "ATZ"]).canFrame(for: [0x01, 0x00]))
        XCTAssertEqual(self.state(after: ["ATSP6", "ATSH7E0", "ATD", "ATSP6"]).canFrame(for: [0x01, 0x00]), "7DF 02 01 00")
    }

    func test_observeResponse_protocolQueries_determineProtocol() {
        var state = self.state(after: ["ATDPN"])
        state.observeResponse("A7")
        XCTAssertEqual(state.busProtocol, .can29)

        state.observeCommand("ATDP")
        state.observeResponse("AUTO, ISO 15765-4 (CAN 11/500)")
        XCTAssertEqual(state.busProtocol, .can11)

        state.observeCommand("ATDP")
        state.observeResponse("AUTO, SAE J1850 PWM")
        XCTAssertEqual(state.busProtocol, .other)

        state.observeCommand("ATDP")
        state.observeResponse("AUTO")
        XCTAssertNil(state.busProtocol)
    }

    func test_observeResponse_headered11BitReply_detectsProtocolDuringAutoSearch() {
        var state = AdapterState()
        state.observeResponse("41 00 BE 1F A8 13")
        XCTAssertNil(state.busProtocol)
        state.observeResponse("7E8 06 41 00 BE 1F A8 13")
        XCTAssertEqual(state.busProtocol, .can11)
    }

    func test_observeResponse_withoutPendingQuery_keepsExplicitProtocol() {
        var state = self.state(after: ["ATSP7"])
        state.observeResponse("7E8 06 41 00 BE 1F A8 13")
        XCTAssertEqual(state.busProtocol, .can29)
    }
}

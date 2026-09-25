import Foundation

/// Mirrors the subset of ELM327 configuration that decides how a request is framed on the bus.
///
/// The terminal never sees the bus itself, so everything here is inferred from the commands we
/// sent and the adapter's replies. Whenever a piece of state is unknown (automatic protocol
/// search, a reset, an unsupported protocol) `canFrame(for:)` returns `nil` rather than guessing.
struct AdapterState {

    enum BusProtocol: Equatable {
        case can11
        case can29
        /// Anything we can't (yet) render as a CAN frame: J1850, ISO 9141, KWP, J1939, user CAN.
        case other
    }

    private enum PendingQuery {
        case protocolNumber
        case protocolDescription
    }

    private static let defaultPriority: UInt8 = 0x18
    private static let default11BitHeader: UInt32 = 0x7DF
    private static let default29BitTarget: UInt32 = 0xDB33F1

    private(set) var busProtocol: BusProtocol?
    private var explicitHeader: (value: UInt32, digits: Int)?
    private var priority: UInt8 = Self.defaultPriority
    private var autoFormatting = true
    private var extendedAddress: UInt8?
    private var pendingQuery: PendingQuery?

    mutating func observeCommand(_ line: String) {

        let command = line.uppercased().filter { !$0.isWhitespace }
        self.pendingQuery = nil
        guard command.hasPrefix("AT") else { return }
        let body = command.dropFirst(2)

        if ["Z", "WS", "D"].contains(body) {
            self = AdapterState()
            return
        }
        if body == "DPN" {
            self.pendingQuery = .protocolNumber
            return
        }
        if body == "DP" {
            self.pendingQuery = .protocolDescription
            return
        }
        if body == "CAF0" || body == "CAF1" {
            self.autoFormatting = body == "CAF1"
            return
        }
        if body.hasPrefix("SP") || body.hasPrefix("TP") {
            let argument = body.dropFirst(2)
            // "A" (automatic with a preferred protocol) can still fall back to a different one.
            self.busProtocol = argument.hasPrefix("A") ? nil : Self.busProtocol(forProtocolNumber: argument)
            return
        }
        if body.hasPrefix("SH") {
            let argument = body.dropFirst(2)
            guard [3, 6, 8].contains(argument.count), let value = UInt32(argument, radix: 16) else { return }
            self.explicitHeader = (value, argument.count)
            return
        }
        if body.hasPrefix("CP") {
            guard let value = UInt8(body.dropFirst(2), radix: 16) else { return }
            self.priority = value & 0x1F
            return
        }
        if body.hasPrefix("CEA") {
            self.extendedAddress = UInt8(body.dropFirst(3), radix: 16)
            return
        }
    }

    mutating func observeResponse(_ line: String) {

        let response = line.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch self.pendingQuery {
            case .protocolNumber:
                let number = response.hasPrefix("A") ? response.dropFirst() : Substring(response)
                self.busProtocol = Self.busProtocol(forProtocolNumber: number)
                self.pendingQuery = nil
                return
            case .protocolDescription:
                self.busProtocol = Self.busProtocol(forDescription: response)
                self.pendingQuery = nil
                return
            case nil:
                break
        }

        // Auto-search leaves the protocol unknown; a headered 11-bit reply is proof enough.
        // 29-bit headers print as four separate bytes and are indistinguishable from payload here.
        guard self.busProtocol == nil else { return }
        let tokens = response.split(separator: " ")
        guard tokens.count >= 2,
              tokens[0].count == 3, tokens[0].allSatisfy(\.isHexDigit),
              tokens.dropFirst().allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return }
        self.busProtocol = .can11
    }

    /// The CAN frame the adapter will transmit for `payload`, without padding (matching how the
    /// adapter displays received frames), or `nil` if it can't be determined as a single frame.
    func canFrame(for payload: [UInt8]) -> String? {

        let header: String
        switch self.busProtocol {
            case .can11:
                header = String(format: "%03X", self.header11)
            case .can29:
                header = String(format: "%08X", self.header29)
            case .other, nil:
                return nil
        }

        var data: [UInt8] = self.extendedAddress.map { [$0] } ?? []
        if self.autoFormatting {
            data.append(UInt8(payload.count))
        }
        data += payload
        guard !payload.isEmpty, data.count <= 8 else { return nil }

        return ([header] + data.map { String(format: "%02X", $0) }).joined(separator: " ")
    }

    private var header11: UInt32 {
        guard let explicitHeader else { return Self.default11BitHeader }
        return explicitHeader.value & 0x7FF
    }

    private var header29: UInt32 {
        let priority = UInt32(self.priority) << 24
        guard let explicitHeader else { return priority | Self.default29BitTarget }
        return explicitHeader.digits == 8 ? explicitHeader.value & 0x1FFF_FFFF : priority | explicitHeader.value
    }

    private static func busProtocol(forProtocolNumber number: Substring) -> BusProtocol? {
        switch number {
            case "6", "8": .can11
            case "7", "9": .can29
            case "1", "2", "3", "4", "5", "A", "B", "C": .other
            default: nil
        }
    }

    private static func busProtocol(forDescription description: String) -> BusProtocol? {
        if description.contains("ISO 15765-4") {
            if description.contains("CAN 11") { return .can11 }
            if description.contains("CAN 29") { return .can29 }
        }
        let knownFamilies = ["SAE", "ISO", "USER"]
        return knownFamilies.contains(where: description.contains) ? .other : nil
    }
}

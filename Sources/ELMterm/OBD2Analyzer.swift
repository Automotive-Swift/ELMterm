import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

enum AdapterMessage {
    enum Direction {
        case incoming
        case outgoing
    }
}

struct AnalyzerOutput {
    let headline: String
    let details: [String]
}

/// Provides lightweight semantic hints for OBD-II frames.
final class OBD2Analyzer {

    private struct ISOTPKey: Hashable {
        let canId: UInt32?
        let extendedAddress: UInt8?
    }

    private struct ISOTPReassembly {
        var totalLength: Int
        var buffer: [UInt8]
        var nextSequence: UInt8
    }

    private var isotpStates: [ISOTPKey: ISOTPReassembly] = [:]
    private var isotpNeedsHeaders = false
    private var configuredExtendedAddress: UInt8?

    /// Legacy (non-CAN) multi-line OBD reassembly. K-Line/ISO 9141-2/KWP split
    /// a long mode-09 reply across several `49 PID seq <data>` lines that share
    /// no length header — unlike ISO-TP, completion is signalled by the
    /// adapter's prompt, so the controller drains this via `finalizeReassembly`.
    private struct LegacyFrameKey: Hashable {
        let header: UInt32?
        let pid: UInt8
    }

    private struct LegacyFrameGroup {
        var frames: [(sequence: UInt8, data: [UInt8])] = []
    }

    private var legacyFrameStates: [LegacyFrameKey: LegacyFrameGroup] = [:]
    /// Mode-09 PIDs whose reply is an ASCII/string value segmented across lines.
    private static let legacyStringPIDs: Set<UInt8> = [0x02, 0x04, 0x06, 0x0A]

    private let atCommands: [String: String] = [
        "ATZ": "Reset adapter",
        "ATWS": "Warm start",
        "ATI": "Adapter identification",
        "ATE0": "Echo off",
        "ATE1": "Echo on",
        "ATL0": "Disable linefeeds",
        "ATL1": "Enable linefeeds",
        "ATS0": "Disable spaces",
        "ATS1": "Enable spaces",
        "ATH1": "Show headers",
        "ATH0": "Hide headers",
        "ATSP0": "Automatic protocol detection",
        "ATAL": "Allow long messages",
    ]

    private let stCommands: [String: String] = [
        "STI": "STN chip identification",
        "STDI": "Device identifier",
        "STDIX": "Extended device identifier",
        "STSBR": "Set baud rate",
        "STSLBR": "Set low-speed baud rate",
        "STSN": "Set serial number",
        "STRSN": "Read serial number",
        "STMA": "Monitor all messages",
        "STMFR": "STN Manufacturer",
        "STFMR": "Flow control mode receive",
        "STFAP": "Flow control address pair",
        "STFCP": "Flow control CAN protocol",
        "STPX": "Protocol index",
        "STTPTX": "Tester present transmit",
        "STSLCAN": "Switch to CAN mode",
        "STCSWM": "CAN silent/warm mode",
        "STCFC": "CAN flow control",
        "STCFCPA": "CAN flow control pair address",
        "STCFCP": "CAN flow control protocol",
        "STCSM": "CAN silent mode",
        "STCMM": "CAN monitor mode",
        "STCSMT": "CAN silent mode timeout",
    ]

    private struct PIDInfo {
        let description: String
        let formatter: ([UInt8]) -> String?
    }

    private let pidDatabase: [UInt8: PIDInfo] = [
        0x04: .init(description: "Calculated engine load", formatter: OBD2Analyzer.percent255),
        0x05: .init(description: "Engine coolant temperature", formatter: OBD2Analyzer.tempMinus40),
        0x06: .init(description: "Short term fuel trim (Bank 1)", formatter: OBD2Analyzer.fuelTrim),
        0x07: .init(description: "Long term fuel trim (Bank 1)", formatter: OBD2Analyzer.fuelTrim),
        0x08: .init(description: "Short term fuel trim (Bank 2)", formatter: OBD2Analyzer.fuelTrim),
        0x09: .init(description: "Long term fuel trim (Bank 2)", formatter: OBD2Analyzer.fuelTrim),
        0x0A: .init(description: "Fuel pressure", formatter: { bytes in
            guard let a = bytes.first else { return nil }
            return "\(Int(a) * 3) kPa"
        }),
        0x0B: .init(description: "Intake manifold absolute pressure", formatter: { bytes in
            guard let a = bytes.first else { return nil }
            return "\(a) kPa"
        }),
        0x0C: .init(description: "Engine RPM", formatter: { bytes in
            guard bytes.count >= 2 else { return nil }
            let value = (Int(bytes[0]) << 8 | Int(bytes[1])) / 4
            return "\(value) rpm"
        }),
        0x0D: .init(description: "Vehicle speed", formatter: { bytes in
            guard let a = bytes.first else { return nil }
            return "\(a) km/h"
        }),
        0x0E: .init(description: "Timing advance", formatter: { bytes in
            guard let a = bytes.first else { return nil }
            return String(format: "%.1f° before TDC", Double(a) / 2.0 - 64.0)
        }),
        0x0F: .init(description: "Intake air temperature", formatter: OBD2Analyzer.tempMinus40),
        0x10: .init(description: "MAF air flow rate", formatter: { bytes in
            guard bytes.count >= 2 else { return nil }
            let value = Double(Int(bytes[0]) << 8 | Int(bytes[1])) / 100.0
            return String(format: "%.2f g/s", value)
        }),
        0x11: .init(description: "Throttle position", formatter: OBD2Analyzer.percent255),
        0x1F: .init(description: "Run time since engine start", formatter: { bytes in
            guard bytes.count >= 2 else { return nil }
            return "\(Int(bytes[0]) << 8 | Int(bytes[1])) s"
        }),
        0x21: .init(description: "Distance with MIL on", formatter: OBD2Analyzer.distanceKm),
        0x23: .init(description: "Fuel rail gauge pressure", formatter: { bytes in
            guard bytes.count >= 2 else { return nil }
            return "\((Int(bytes[0]) << 8 | Int(bytes[1])) * 10) kPa"
        }),
        0x2C: .init(description: "Commanded EGR", formatter: OBD2Analyzer.percent255),
        0x2D: .init(description: "EGR error", formatter: OBD2Analyzer.fuelTrim),
        0x2F: .init(description: "Fuel level", formatter: OBD2Analyzer.percent255),
        0x31: .init(description: "Distance since codes cleared", formatter: OBD2Analyzer.distanceKm),
        0x33: .init(description: "Absolute barometric pressure", formatter: { bytes in
            guard let a = bytes.first else { return nil }
            return "\(a) kPa"
        }),
        0x42: .init(description: "Control module voltage", formatter: { bytes in
            guard bytes.count >= 2 else { return nil }
            let value = Double(Int(bytes[0]) << 8 | Int(bytes[1])) / 1000.0
            return String(format: "%.3f V", value)
        }),
        0x43: .init(description: "Absolute load value", formatter: { bytes in
            guard bytes.count >= 2 else { return nil }
            let value = Double(Int(bytes[0]) << 8 | Int(bytes[1])) * 100.0 / 255.0
            return String(format: "%.1f %%", value)
        }),
        0x44: .init(description: "Commanded equivalence ratio (λ)", formatter: { bytes in
            guard bytes.count >= 2 else { return nil }
            let value = Double(Int(bytes[0]) << 8 | Int(bytes[1])) / 32768.0
            return String(format: "%.3f", value)
        }),
        0x45: .init(description: "Relative throttle position", formatter: OBD2Analyzer.percent255),
        0x46: .init(description: "Ambient air temperature", formatter: OBD2Analyzer.tempMinus40),
        0x49: .init(description: "Accelerator pedal position D", formatter: OBD2Analyzer.percent255),
        0x4A: .init(description: "Accelerator pedal position E", formatter: OBD2Analyzer.percent255),
        0x5C: .init(description: "Engine oil temperature", formatter: OBD2Analyzer.tempMinus40),
        0x5E: .init(description: "Engine fuel rate", formatter: { bytes in
            guard bytes.count >= 2 else { return nil }
            let value = Double(Int(bytes[0]) << 8 | Int(bytes[1])) / 20.0
            return String(format: "%.2f L/h", value)
        }),
    ]

    /// Shared PID formatters for the common encodings (SAE J1979).
    private static func percent255(_ bytes: [UInt8]) -> String? {
        guard let a = bytes.first else { return nil }
        return String(format: "%.1f %%", Double(a) * 100.0 / 255.0)
    }
    private static func tempMinus40(_ bytes: [UInt8]) -> String? {
        guard let a = bytes.first else { return nil }
        return "\(Int(a) - 40) °C"
    }
    private static func fuelTrim(_ bytes: [UInt8]) -> String? {
        guard let a = bytes.first else { return nil }
        return String(format: "%.1f %%", Double(a) * 100.0 / 128.0 - 100.0)
    }
    private static func distanceKm(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 2 else { return nil }
        return "\(Int(bytes[0]) << 8 | Int(bytes[1])) km"
    }

    private let obd2ModeDescriptions: [UInt8: String] = [
        0x01: "Show current data",
        0x02: "Show freeze frame data",
        0x03: "Show stored diagnostic trouble codes",
        0x04: "Clear diagnostic trouble codes",
        0x05: "Test results, oxygen sensor monitoring",
        0x06: "Test results, other component/system monitoring",
        0x07: "Show pending diagnostic trouble codes",
        0x08: "Control operation of on-board component/system",
        0x09: "Request vehicle information",
        0x0A: "Permanent diagnostic trouble codes",
    ]

    private let udsModeDescriptions: [UInt8: String] = [
        0x10: "Diagnostic session control",
        0x11: "ECU reset",
        0x14: "Clear diagnostic information",
        0x19: "Read DTC information",
        0x22: "Read data by identifier",
        0x23: "Read memory by address",
        0x27: "Security access",
        0x28: "Communication control",
        0x2E: "Write data by identifier",
        0x31: "Routine control",
        0x34: "Request download",
        0x35: "Request upload",
        0x36: "Transfer data",
        0x37: "Request transfer exit",
        0x3E: "Tester present",
        0x85: "Control DTC setting",
    ]

    // Well-known DIDs (ISO 14229 Annex C) for services 0x22/0x2E
    private let didDescriptions: [UInt16: String] = [
        0xF180: "Boot software identification",
        0xF186: "Active diagnostic session",
        0xF187: "Spare part number",
        0xF188: "ECU software number",
        0xF189: "ECU software version number",
        0xF18A: "System supplier identifier",
        0xF18B: "ECU manufacturing date",
        0xF18C: "ECU serial number",
        0xF190: "VIN",
        0xF191: "ECU hardware number",
        0xF192: "System supplier ECU hardware number",
        0xF193: "System supplier ECU hardware version",
        0xF194: "System supplier ECU software number",
        0xF195: "System supplier ECU software version",
        0xF197: "System name or engine type",
        0xF199: "Programming date",
        0xF19E: "ASAM/ODX file identifier",
        0xF1A0: "Diagnostic version",
    ]

    // Sub-function descriptions per UDS service
    private let udsSubFunctions: [UInt8: [UInt8: String]] = [
        0x10: [  // Diagnostic session control
            0x01: "Default session",
            0x02: "Programming session",
            0x03: "Extended diagnostic session",
        ],
        0x11: [  // ECU reset
            0x01: "Hard reset",
            0x02: "Key off/on reset",
            0x03: "Soft reset",
        ],
        0x19: [  // Read DTC information
            0x01: "Report number of DTC by status mask",
            0x02: "Report DTC by status mask",
            0x03: "Report DTC snapshot identification",
            0x04: "Report DTC snapshot record by DTC number",
            0x06: "Report DTC extended data record by DTC number",
            0x0A: "Report supported DTCs",
            0x0E: "Report most recent confirmed DTC",
            0x13: "Report emissions-related OBD DTC by status mask",
            0x14: "Report DTC fault detection counter",
        ],
        0x28: [  // Communication control
            0x00: "Enable Rx and Tx",
            0x01: "Enable Rx, disable Tx",
            0x02: "Disable Rx, enable Tx",
            0x03: "Disable Rx and Tx",
        ],
        0x31: [  // Routine control
            0x01: "Start routine",
            0x02: "Stop routine",
            0x03: "Request routine results",
        ],
        0x3E: [  // Tester present
            0x00: "Zero sub-function",
        ],
        0x85: [  // Control DTC setting
            0x01: "On",
            0x02: "Off",
        ],
    ]

    private func describeUDSSubParameters(mode: UInt8, bytes: [UInt8]) -> [String] {
        var result: [String] = []

        switch mode {
            case 0x22, 0x2E:
                // Read/Write data by identifier: next 2 bytes are DID
                guard bytes.count >= 3 else { break }
                let did = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
                let didHex = String(format: "%04X", did)
                if let name = self.didDescriptions[did] {
                    result.append("DID \(didHex): \(name)")
                } else {
                    result.append("DID \(didHex)")
                }

            case 0x27:
                // Security access: odd = request seed, even = send key
                guard bytes.count >= 2 else { break }
                let subFn = bytes[1] & 0x7F
                let level = (subFn + 1) / 2
                let step = subFn.isMultiple(of: 2) ? "Send key" : "Request seed"
                result.append("\(step) (level \(level))")

            case 0x31:
                // Routine control: sub-function + 2-byte routine ID
                guard bytes.count >= 2 else { break }
                let subFn = bytes[1] & 0x7F
                if let desc = self.udsSubFunctions[0x31]?[subFn] {
                    result.append(desc)
                }
                if bytes.count >= 4 {
                    let routineId = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
                    result.append("Routine ID \(String(format: "%04X", routineId))")
                }

            default:
                guard bytes.count >= 2 else { break }
                let subFn = bytes[1] & 0x7F
                if let desc = self.udsSubFunctions[mode]?[subFn] {
                    result.append(desc)
                }
        }

        return result
    }

    func annotateOutgoing(_ line: String) -> AnalyzerOutput? {

        let upper = line.uppercased()
        self.updateAdapterState(for: upper)
        if upper.hasPrefix("AT") {
            let match = self.atCommands.first { upper.hasPrefix($0.key) }
            if let (command, description) = match {
                return AnalyzerOutput(
                    headline: "ELM adapter command \(command)",
                    details: [description]
                )
            }
            return AnalyzerOutput(headline: "ELM adapter command", details: [])
        }

        if upper.hasPrefix("ST") {
            let match = self.stCommands.first { upper.hasPrefix($0.key) }
            if let (command, description) = match {
                return AnalyzerOutput(
                    headline: "STN adapter command \(command)",
                    details: [description]
                )
            }
            return AnalyzerOutput(headline: "STN adapter command", details: [])
        }

        guard let bytes = Self.bytes(fromHexLike: upper), let mode = bytes.first else {
            return nil
        }

        self.isotpStates.removeAll()
        self.isotpNeedsHeaders = false
        self.legacyFrameStates.removeAll()

        var details: [String] = []
        let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        details.append("Hex: \(hexBytes)")

        let isOBD2 = mode <= 0x0F
        let protocolName = isOBD2 ? "OBD-II" : "UDS/KWP"
        let modeDescriptions = isOBD2 ? self.obd2ModeDescriptions : self.udsModeDescriptions

        if isOBD2 && bytes.count > 1 {
            let pid = bytes[1]
            if let info = self.pidDatabase[pid] {
                details.append("PID \(String(format: "%02X", pid)): \(info.description)")
            } else {
                details.append("PID \(String(format: "%02X", pid))")
            }
        }

        if let description = modeDescriptions[mode] {
            if !isOBD2 {
                let subParts = self.describeUDSSubParameters(mode: mode, bytes: bytes)
                details.append(([description] + subParts).joined(separator: " · "))
            } else {
                details.append(description)
            }
        } else if !isOBD2 {
            let subParts = self.describeUDSSubParameters(mode: mode, bytes: bytes)
            if !subParts.isEmpty {
                details.append(subParts.joined(separator: " · "))
            }
        }

        guard !details.isEmpty else { return nil }
        return AnalyzerOutput(headline: "\(protocolName) request (mode \(String(format: "%02X", mode)))", details: details)
    }

    /// True for an OBD-II DTC report response (mode 03/07/0A).
    private static let obd2DTCModes: Set<UInt8> = [0x03, 0x07, 0x0A]

    /// Decode an OBD-II mode 03/07/0A response into a headline + DTC lines.
    /// `payload` is everything after the response mode byte (0x43/0x47/0x4A).
    private func obd2DTCDetails(mode: UInt8, payload: [UInt8]) -> (headline: String, lines: [String]) {
        var bytes = payload
        // Some CAN ECUs prefix a DTC count byte, leaving an odd byte count.
        if !bytes.count.isMultiple(of: 2) { bytes = Array(bytes.dropFirst()) }
        var codes: [String] = []
        var index = 0
        while index + 1 < bytes.count {
            let high = bytes[index]
            let low = bytes[index + 1]
            index += 2
            if high == 0, low == 0 { continue }   // padding / empty slot
            codes.append(DTCDecoder.code(high, low))
        }

        let label: String
        switch mode {
            case 0x03: label = "stored"
            case 0x07: label = "pending"
            case 0x0A: label = "permanent"
            default: label = "reported"
        }
        let modeHex = String(format: "%02X", mode)
        guard !codes.isEmpty else {
            return ("✅ Mode \(modeHex): no \(label) DTCs", [])
        }
        let lines = codes.map { DTCDecoder.describe($0) }
        return ("✅ Mode \(modeHex): \(codes.count) \(label) DTC\(codes.count == 1 ? "" : "s")", lines)
    }

    /// Decode a UDS ReadDTCInformation (0x59) response into detail lines, or an
    /// empty array when the subfunction isn't one we render DTC records for.
    private func udsReadDTCDetails(bytes: [UInt8]) -> [String] {
        guard bytes.count >= 2 else { return [] }
        let subFunction = bytes[1] & 0x7F

        switch subFunction {
            case 0x01:   // report number of DTC by status mask
                guard bytes.count >= 6 else { return [] }
                let count = Int(bytes[4]) << 8 | Int(bytes[5])
                return ["\(count) matching DTC(s)"]

            case 0x02, 0x0A, 0x13, 0x15:   // status-mask / supported: 4-byte records
                var records = Array(bytes.dropFirst(3))   // skip 59, subfn, statusAvailabilityMask
                var lines: [String] = []
                while records.count >= 4 {
                    let baseCode = DTCDecoder.code(records[0], records[1])
                    let fullCode = DTCDecoder.code(records[0], records[1], records[2])
                    let flags = DTCDecoder.statusFlags(records[3])
                    records.removeFirst(4)
                    var line = fullCode
                    if let description = DTCDecoder.description(for: baseCode) {
                        line += " — \(description)"
                    }
                    if !flags.isEmpty {
                        line += "  [\(flags.joined(separator: ", "))]"
                    }
                    lines.append(line)
                }
                return lines

            default:
                return []
        }
    }

    private func decodeCompleteISOTPMessage(_ bytes: [UInt8]) -> AnalyzerOutput {
        let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = Self.asciiRepresentation(from: bytes)

        var details: [String] = []
        details.append("Hex: \(hexBytes)")
        details.append("ASCII: \(ascii)")

        guard bytes.count >= 2 else {
            return AnalyzerOutput(headline: "✅ ISO-TP Complete Message", details: details)
        }

        let responseMode = bytes[0]
        let mode = responseMode & 0x3F

        // Special handling for VIN (mode 09, PID 02)
        if responseMode == 0x49 && bytes.count >= 3 && bytes[1] == 0x02 {
            let vinBytes = Array(bytes.dropFirst(3))
            let vin = String(bytes: vinBytes, encoding: .ascii) ?? "Invalid VIN"
            details.append("Vehicle Identification Number (VIN): \(vin)")
            return AnalyzerOutput(headline: "✅ ISO-TP: VIN Response", details: details)
        }

        let isOBD2 = mode <= 0x0F
        let protocolName = isOBD2 ? "OBD-II" : "UDS/KWP"
        let modeDescriptions = isOBD2 ? self.obd2ModeDescriptions : self.udsModeDescriptions

        if isOBD2, Self.obd2DTCModes.contains(mode) {
            let (headline, dtcLines) = self.obd2DTCDetails(mode: mode, payload: Array(bytes.dropFirst()))
            details.append(contentsOf: dtcLines)
            return AnalyzerOutput(headline: headline, details: details)
        }

        if !isOBD2, mode == 0x19 {
            let dtcLines = self.udsReadDTCDetails(bytes: bytes)
            if !dtcLines.isEmpty {
                if let description = modeDescriptions[mode] {
                    let subParts = self.describeUDSSubParameters(mode: mode, bytes: bytes)
                    details.append((["Mode 19: \(description)"] + subParts).joined(separator: " · "))
                }
                details.append(contentsOf: dtcLines)
                return AnalyzerOutput(headline: "✅ ISO-TP: UDS Read DTC information", details: details)
            }
        }

        if let description = modeDescriptions[mode] {
            let modePrefix = "Mode \(String(format: "%02X", mode)): \(description)"
            if !isOBD2 {
                let subParts = self.describeUDSSubParameters(mode: mode, bytes: bytes)
                details.append(([modePrefix] + subParts).joined(separator: " · "))
            } else {
                details.append(modePrefix)
            }
        } else if !isOBD2 {
            let subParts = self.describeUDSSubParameters(mode: mode, bytes: bytes)
            if !subParts.isEmpty {
                details.append(subParts.joined(separator: " · "))
            }
        }

        return AnalyzerOutput(headline: "✅ ISO-TP: \(protocolName) Complete Message", details: details)
    }

    /// Accumulate a legacy multi-line mode-09 segment (`49 PID seq <data>`).
    /// Returns a per-line progress annotation when the line is recognised as
    /// part of such a reply, otherwise nil so the generic decoder takes over.
    private func accumulateLegacyFrame(header: UInt32?, bytes: [UInt8]) -> AnalyzerOutput? {
        guard bytes.count >= 4, bytes[0] == 0x49 else { return nil }
        let pid = bytes[1]
        guard Self.legacyStringPIDs.contains(pid) else { return nil }

        let sequence = bytes[2]
        let data = Array(bytes.dropFirst(3))
        let key = LegacyFrameKey(header: header, pid: pid)

        // A sequence of 1 begins a fresh message; drop any stale partial.
        if sequence <= 0x01 {
            self.legacyFrameStates[key] = LegacyFrameGroup()
        }
        var group = self.legacyFrameStates[key] ?? LegacyFrameGroup()
        group.frames.append((sequence: sequence, data: data))
        self.legacyFrameStates[key] = group

        let accumulated = group.frames.reduce(0) { $0 + $1.data.count }
        let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return AnalyzerOutput(
            headline: "📦 Legacy multi-line (mode 09 PID \(String(format: "%02X", pid)), frame \(sequence))",
            details: [
                "Hex: \(hexBytes)",
                "\(accumulated) bytes across \(group.frames.count) frame(s), waiting for prompt…",
            ]
        )
    }

    /// Drain any pending legacy multi-line replies. Called by the controller
    /// once the adapter's prompt marks the end of a response.
    func finalizeReassembly() -> [AnalyzerOutput] {
        guard !self.legacyFrameStates.isEmpty else { return [] }
        let pending = self.legacyFrameStates
        self.legacyFrameStates.removeAll()
        return pending
            .sorted { $0.key.pid < $1.key.pid }
            .map { self.decodeLegacyMessage(pid: $0.key.pid, group: $0.value) }
    }

    private func decodeLegacyMessage(pid: UInt8, group: LegacyFrameGroup) -> AnalyzerOutput {
        let payload = group.frames
            .sorted { $0.sequence < $1.sequence }
            .flatMap { $0.data }
        let hexBytes = payload.map { String(format: "%02X", $0) }.joined(separator: " ")

        var details = ["Hex: \(hexBytes)"]
        let pidHex = String(format: "%02X", pid)

        switch pid {
            case 0x02:
                // VIN: strip the leading zero padding, then read as ASCII.
                let trimmed = Array(payload.drop(while: { $0 == 0x00 }))
                let vin = String(bytes: trimmed, encoding: .ascii) ?? Self.asciiRepresentation(from: trimmed)
                details.append("VIN: \(vin)")
                return AnalyzerOutput(headline: "✅ Mode 09 PID 02: Vehicle Identification Number", details: details)

            case 0x04, 0x0A:
                // Calibration ID / ECU name: ASCII, NUL bytes separate entries.
                let text = Self.asciiRepresentation(from: payload.map { $0 == 0x00 ? 0x20 : $0 }).trimmed
                let label = pid == 0x04 ? "Calibration ID" : "ECU name"
                details.append("\(label): \(text)")
                return AnalyzerOutput(headline: "✅ Mode 09 PID \(pidHex): \(label)", details: details)

            default:
                // CVN (0x06) and anything else: keep as raw hex.
                return AnalyzerOutput(headline: "✅ Mode 09 PID \(pidHex): reassembled (\(payload.count) bytes)", details: details)
        }
    }

    func annotateIncoming(_ line: String) -> AnalyzerOutput? {

        let upper = line.uppercased()
        if upper.contains("NO DATA") {
            return AnalyzerOutput(headline: "Adapter status", details: ["No ECU replied to this request"])
        }
        if upper.contains("SEARCHING") {
            return AnalyzerOutput(headline: "Adapter status", details: ["Adapter is still trying to lock on a protocol"])
        }
        if upper == "OK" {
            return AnalyzerOutput(headline: "Adapter acknowledged command", details: [])
        }

        guard let parsed = Self.parseResponse(upper), parsed.bytes.count >= 2 else {
            return nil
        }

        var bytes = parsed.bytes
        let (extendedAddressNote, extendedAddress) = self.stripExtendedAddressIfNeeded(from: &bytes)
        let lengthByteNote = Self.stripSingleFrameLengthByteIfNeeded(from: &bytes, header: parsed.header)
        guard bytes.count >= 2 else { return nil }

        let isotpKey = ISOTPKey(canId: parsed.header, extendedAddress: extendedAddress)

        // Check for negative response (7F xx yy)
        if bytes[0] == 0x7F && bytes.count >= 3 {
            let serviceId = bytes[1]
            let nrcCode = bytes[2]
            let nrcDescription = Self.nrcDescription(for: nrcCode)
            let isResponsePending = nrcCode == 0x78

            let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = Self.asciiRepresentation(from: bytes)

            var details: [String] = []
            if let note = extendedAddressNote { details.append(note) }
            if let note = lengthByteNote { details.append(note) }
            if isResponsePending {
                details.append("Service 0x\(String(format: "%02X", serviceId)) response pending")
            } else {
                details.append("Service 0x\(String(format: "%02X", serviceId)) failed")
            }
            if !isResponsePending {
                details.append(nrcDescription)
                details.append("Hex: \(hexBytes)")
                details.append("ASCII: \(ascii)")
            }

            let headline = isResponsePending
                ? "⏳ ECU busy (NRC 0x78)"
                : "❌ Negative Response (NRC 0x\(String(format: "%02X", nrcCode)))"

            return AnalyzerOutput(
                headline: headline,
                details: details
            )
        }

        // Check for ISO-TP frames
        let frameType = bytes[0] >> 4

        // First Frame (0x10-0x1F)
        if frameType == 0x1 && bytes.count >= 2 {
            if parsed.header == nil, !self.isotpStates.isEmpty {
                self.isotpStates.removeAll()
                self.isotpNeedsHeaders = true
                return AnalyzerOutput(
                    headline: "⚠️ ISO-TP multi-ECU response without headers",
                    details: ["Enable ATH1 or filter responses (e.g., ATCRA) to decode multi-frame messages."]
                )
            }
            if parsed.header == nil, self.isotpNeedsHeaders {
                return AnalyzerOutput(
                    headline: "⚠️ ISO-TP disabled without headers",
                    details: ["Multiple responders detected; enable ATH1 to reassemble."]
                )
            }
            let lengthHigh = Int(bytes[0] & 0x0F)
            let lengthLow = Int(bytes[1])
            let totalLength = (lengthHigh << 8) | lengthLow
            let dataBytes = Array(bytes.dropFirst(2))

            self.isotpStates[isotpKey] = ISOTPReassembly(
                totalLength: totalLength,
                buffer: dataBytes,
                nextSequence: 1
            )

            let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            var details: [String] = []
            if let note = extendedAddressNote { details.append(note) }
            if let note = lengthByteNote { details.append(note) }
            details.append("Hex: \(hexBytes)")
            details.append("Multi-frame message started, waiting for consecutive frames...")
            return AnalyzerOutput(
                headline: "📦 ISO-TP First Frame (1/\(totalLength) bytes)",
                details: details
            )
        }

        // Consecutive Frame (0x20-0x2F)
        if frameType == 0x2 {
            if parsed.header == nil, self.isotpNeedsHeaders {
                return AnalyzerOutput(
                    headline: "⚠️ ISO-TP disabled without headers",
                    details: ["Multiple responders detected; enable ATH1 to reassemble."]
                )
            }
            let sequence = bytes[0] & 0x0F
            let dataBytes = Array(bytes.dropFirst(1))

            guard var state = self.isotpStates[isotpKey] else {
                let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                var details: [String] = []
                if let note = extendedAddressNote { details.append(note) }
                if let note = lengthByteNote { details.append(note) }
                details.append("Hex: \(hexBytes)")
                details.append("Received consecutive frame without first frame")
                return AnalyzerOutput(
                    headline: "⚠️ ISO-TP Consecutive Frame (orphaned)",
                    details: details
                )
            }

            guard sequence == state.nextSequence else {
                self.isotpStates.removeValue(forKey: isotpKey)
                let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                var details: [String] = []
                if let note = extendedAddressNote { details.append(note) }
                if let note = lengthByteNote { details.append(note) }
                details.append("Hex: \(hexBytes)")
                details.append("Expected sequence \(state.nextSequence), got \(sequence)")
                return AnalyzerOutput(
                    headline: "⚠️ ISO-TP Sequence Error",
                    details: details
                )
            }

            state.buffer.append(contentsOf: dataBytes)
            state.nextSequence = (state.nextSequence + 1) & 0x0F

            if state.buffer.count >= state.totalLength {
                let completeMessage = Array(state.buffer.prefix(state.totalLength))
                self.isotpStates.removeValue(forKey: isotpKey)
                return self.decodeCompleteISOTPMessage(completeMessage)
            } else {
                self.isotpStates[isotpKey] = state
                let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                let progress = "\(state.buffer.count)/\(state.totalLength)"
                var details: [String] = []
                if let note = extendedAddressNote { details.append(note) }
                if let note = lengthByteNote { details.append(note) }
                details.append("Hex: \(hexBytes)")
                details.append("Sequence \(sequence), waiting for more frames...")
                return AnalyzerOutput(
                    headline: "📦 ISO-TP Consecutive Frame (\(progress) bytes)",
                    details: details
                )
            }
        }

        if let progress = self.accumulateLegacyFrame(header: parsed.header, bytes: bytes) {
            return progress
        }

        let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = Self.asciiRepresentation(from: bytes)

        let responseMode = bytes[0]
        let mode = responseMode & 0x3F
        let pid = bytes[1]
        let payload = Array(bytes.dropFirst(2))

        let isOBD2 = mode <= 0x0F
        let protocolName = isOBD2 ? "OBD-II" : "UDS/KWP"
        let modeDescriptions = isOBD2 ? self.obd2ModeDescriptions : self.udsModeDescriptions

        var details: [String] = []
        if let note = extendedAddressNote { details.append(note) }
        if let note = lengthByteNote { details.append(note) }
        details.append("Hex: \(hexBytes)")
        details.append("ASCII: \(ascii)")

        if isOBD2, Self.obd2DTCModes.contains(mode) {
            let (headline, dtcLines) = self.obd2DTCDetails(mode: mode, payload: Array(bytes.dropFirst()))
            details.append(contentsOf: dtcLines)
            return AnalyzerOutput(headline: headline, details: details)
        }

        if !isOBD2, mode == 0x19 {
            let dtcLines = self.udsReadDTCDetails(bytes: bytes)
            if !dtcLines.isEmpty {
                if let description = modeDescriptions[mode] {
                    let subParts = self.describeUDSSubParameters(mode: mode, bytes: bytes)
                    details.append((["Mode 19: \(description)"] + subParts).joined(separator: " · "))
                }
                details.append(contentsOf: dtcLines)
                return AnalyzerOutput(headline: "UDS Read DTC information", details: details)
            }
        }

        if isOBD2, let info = self.pidDatabase[pid], let formatted = info.formatter(payload) {
            let headline = "\(protocolName) response (mode \(String(format: "%02X", mode)))"
            details.append("\(info.description): \(formatted)")
            return AnalyzerOutput(headline: headline, details: details)
        }

        if let description = modeDescriptions[mode] {
            let modePrefix = "Mode \(String(format: "%02X", mode)): \(description)"
            if !isOBD2 {
                let subParts = self.describeUDSSubParameters(mode: mode, bytes: bytes)
                details.append(([modePrefix] + subParts).joined(separator: " · "))
            } else {
                details.append(modePrefix)
            }
        } else if !isOBD2 {
            let subParts = self.describeUDSSubParameters(mode: mode, bytes: bytes)
            if !subParts.isEmpty {
                details.append(subParts.joined(separator: " · "))
            }
        }

        return AnalyzerOutput(headline: "\(protocolName) response", details: details)
    }

    private func updateAdapterState(for command: String) {
        if command.hasPrefix("ATCEA") {
            let suffix = command.dropFirst("ATCEA".count)
            if let value = Self.hexByte(from: suffix) {
                self.configuredExtendedAddress = value
            } else if suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.configuredExtendedAddress = nil
            }
            self.isotpStates.removeAll()
            self.isotpNeedsHeaders = false
            return
        }

        if command.hasPrefix("ATCER") {
            let suffix = command.dropFirst("ATCER".count)
            if let value = Self.hexByte(from: suffix) {
                self.configuredExtendedAddress = value
            } else if suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.configuredExtendedAddress = nil
            }
            self.isotpStates.removeAll()
            self.isotpNeedsHeaders = false
            return
        }

        let resetCommands = ["ATZ", "ATWS", "ATD", "ATPC"]
        if resetCommands.contains(where: { command.hasPrefix($0) }) {
            self.configuredExtendedAddress = nil
            self.isotpStates.removeAll()
            self.isotpNeedsHeaders = false
            self.legacyFrameStates.removeAll()
        }
    }

    private static func hexByte(from substring: Substring) -> UInt8? {
        let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty, normalized.count <= 2 else { return nil }
        return UInt8(normalized, radix: 16)
    }

    private func stripExtendedAddressIfNeeded(from bytes: inout [UInt8]) -> (String?, UInt8?) {
        guard let first = bytes.first else { return (nil, nil) }

        if let configuredExtendedAddress, first == configuredExtendedAddress {
            bytes.removeFirst()
            return (
                "CAN extended address 0x\(String(format: "%02X", configuredExtendedAddress)) stripped before decoding",
                configuredExtendedAddress
            )
        }

        // When the adapter uses CAN extended addressing but no ATCER value was recorded,
        // the first byte will not look like an ISO-TP PCI but the remainder will.
        // Avoid false positives when the first byte already looks like an OBD/UDS response.
        guard bytes.count >= 2 else { return (nil, nil) }
        let serviceByte = bytes[0]
        if serviceByte == 0x7F || (0x40...0x7F).contains(serviceByte) {
            return (nil, nil)
        }
        let remainder = Array(bytes.dropFirst())
        if !Self.looksLikeISOTPFrame(bytes), Self.looksLikeISOTPFrame(remainder) {
            let stripped = bytes.removeFirst()
            return (
                "CAN extended address 0x\(String(format: "%02X", stripped)) stripped heuristically before decoding",
                stripped
            )
        }
        return (nil, nil)
    }

    private static func stripSingleFrameLengthByteIfNeeded(from bytes: inout [UInt8], header: UInt32?) -> String? {
        guard header != nil, let first = bytes.first else { return nil }

        let payloadLength = Int(first & 0x0F)
        guard first >> 4 == 0x0, (1...7).contains(payloadLength), bytes.count >= payloadLength + 1 else {
            return nil
        }

        let candidatePayload = Array(bytes.dropFirst().prefix(payloadLength))
        guard let serviceByte = candidatePayload.first, serviceByte == 0x7F || (serviceByte & 0x40) == 0x40 else {
            return nil
        }

        bytes = candidatePayload
        return "Single-frame length byte 0x\(String(format: "%02X", first)) stripped before decoding"
    }

    private static func looksLikeISOTPFrame(_ bytes: [UInt8]) -> Bool {
        guard let first = bytes.first else { return false }
        let frameType = first >> 4

        switch frameType {
            case 0x0:    // Single frame
                let payloadLength = Int(first & 0x0F)
                return payloadLength >= 1 && payloadLength <= 7 && bytes.count >= payloadLength + 1
            case 0x1:    // First frame
                return bytes.count >= 3
            case 0x2:    // Consecutive frame
                return bytes.count >= 2
            case 0x3:    // Flow control frame
                return bytes.count >= 3
            default:
                return false
        }
    }

    func hint(for buffer: String) -> (String?, (Int, Int, Int)?) {

        let trimmed = buffer.trimmed.uppercased()
        let spacing = "   "

        if trimmed.hasPrefix(":") {
            return ("\(spacing)Meta command", (20, 60, 180))
        }
        if trimmed.hasPrefix("ST") {
            if let hint = self.stCommands.first(where: { trimmed.hasPrefix($0.key) })?.value {
                return ("\(spacing)\(hint)", (90, 30, 120))
            }
            return ("\(spacing)STN adapter command", (90, 30, 120))
        }
        if trimmed.hasPrefix("AT") {
            if let hint = self.atCommands.first(where: { trimmed.hasPrefix($0.key) })?.value {
                return ("\(spacing)\(hint)", (30, 120, 60))
            }
            return ("\(spacing)ELM adapter command", (30, 120, 60))
        }
        if trimmed.count >= 2, let bytes = Self.bytes(fromHexLike: trimmed), let mode = bytes.first {
            let isOBD2 = mode <= 0x0F
            let modeDescriptions = isOBD2 ? self.obd2ModeDescriptions : self.udsModeDescriptions
            if let modeDescription = modeDescriptions[mode] {
                return ("\(spacing)\(modeDescription)", (180, 90, 0))
            }
        }
        return (nil, nil)
    }

    private static func bytes(fromHexLike text: String) -> [UInt8]? {

        let normalized = text.replacingOccurrences(of: " ", with: "")
        guard normalized.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<next]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private struct ParsedResponse {
        let header: UInt32?
        let bytes: [UInt8]
    }

    private static func parseResponse(_ text: String) -> ParsedResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if tokens.count >= 2,
           let headerToken = tokens.first,
           (headerToken.count == 3 || headerToken.count == 8),
           headerToken.allSatisfy({ $0.isHexDigit }),
           tokens.dropFirst().allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isHexDigit }) }) {
            let header = UInt32(headerToken, radix: 16)
            let bytes = tokens.dropFirst().compactMap { UInt8($0, radix: 16) }
            return bytes.isEmpty ? nil : ParsedResponse(header: header, bytes: bytes)
        }

        let cleaned = trimmed.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
        var header: UInt32?
        var dataStart = cleaned.startIndex
        let length = cleaned.count

        if length >= 3, length % 2 == 1 {
            let maybeHeader = cleaned.prefix(3)
            if maybeHeader.allSatisfy({ $0.isHexDigit }) {
                header = UInt32(maybeHeader, radix: 16)
                dataStart = cleaned.index(cleaned.startIndex, offsetBy: 3)
            }
        }

        if header == nil, length >= 8 {
            let maybeExtended = cleaned.prefix(8)
            if maybeExtended.allSatisfy({ $0.isHexDigit }), maybeExtended.hasPrefix("18") {
                header = UInt32(maybeExtended, radix: 16)
                dataStart = cleaned.index(cleaned.startIndex, offsetBy: 8)
            }
        }

        let dataString = String(cleaned[dataStart...])
        guard !dataString.isEmpty else { return nil }

        var bytes: [UInt8] = []
        var index = dataString.endIndex

        while index > dataString.startIndex {
            let remaining = dataString.distance(from: dataString.startIndex, to: index)
            if remaining >= 2 {
                let start = dataString.index(index, offsetBy: -2)
                let byteString = dataString[start..<index]
                guard let byte = UInt8(byteString, radix: 16) else { return nil }
                bytes.insert(byte, at: 0)
                index = start
            } else {
                break
            }
        }

        return bytes.isEmpty ? nil : ParsedResponse(header: header, bytes: bytes)
    }

    private static func asciiRepresentation(_ text: String) -> String {
        text.compactMap { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            guard (0x20...0x7E).contains(scalar) else { return "." }
            return String(char)
        }.joined()
    }

    private static func asciiRepresentation(from bytes: [UInt8]) -> String {
        bytes.map { byte in
            (0x20...0x7E).contains(Int(byte)) ? String(UnicodeScalar(byte)) : "."
        }.joined()
    }

    private static func nrcDescription(for code: UInt8) -> String {
        switch code {
        case 0x10: return "General reject"
        case 0x11: return "Service not supported"
        case 0x12: return "Sub-function not supported"
        case 0x13: return "Incorrect message length or invalid format"
        case 0x14: return "Response too long"
        case 0x21: return "Busy, repeat request"
        case 0x22: return "Conditions not correct"
        case 0x23: return "Routine not complete or service in process"
        case 0x24: return "Request sequence error"
        case 0x25: return "No response from subnet component"
        case 0x31: return "Request out of range"
        case 0x33: return "Security access denied"
        case 0x35: return "Invalid key"
        case 0x36: return "Exceed number of attempts"
        case 0x37: return "Required time delay not expired"
        case 0x40: return "Download not accepted"
        case 0x41: return "Improper download type"
        case 0x42: return "Cannot download to specified address"
        case 0x43: return "Cannot download number of bytes requested"
        case 0x50: return "Upload not accepted"
        case 0x51: return "Improper upload type"
        case 0x52: return "Cannot upload from specified address"
        case 0x53: return "Cannot upload number of bytes requested"
        case 0x70: return "Upload/download not accepted"
        case 0x71: return "Transfer data suspended"
        case 0x72: return "General programming failure"
        case 0x73: return "Wrong block sequence counter"
        case 0x77: return "Block transfer data checksum error"
        case 0x78: return "Request correctly received, response pending"
        case 0x7E: return "Sub-function not supported in active session"
        case 0x7F: return "Service not supported in active session"
        case 0x80: return "Service not supported in active diagnostic mode"
        case 0x81: return "RPM too high"
        case 0x82: return "RPM too low"
        case 0x83: return "Engine is running"
        case 0x84: return "Engine is not running"
        case 0x85: return "Engine run time too low"
        case 0x86: return "Temperature too high"
        case 0x87: return "Temperature too low"
        case 0x88: return "Vehicle speed too high"
        case 0x89: return "Vehicle speed too low"
        case 0x8A: return "Throttle/pedal too high"
        case 0x8B: return "Throttle/pedal too low"
        case 0x8C: return "Transmission range not in neutral"
        case 0x8D: return "Transmission range not in gear"
        case 0x8F: return "Brake switch not closed"
        case 0x90: return "Shifter lever not in park"
        case 0x91: return "Torque converter clutch locked"
        case 0x92: return "Voltage too high"
        case 0x93: return "Voltage too low"
        case 0xF1: return "Gateway locked communication"
        case 0xFA: return "Checksum error"
        case 0xFB: return "ECU erasing flash"
        case 0xFC: return "ECU programming flash"
        case 0xFD: return "Erasing error"
        case 0xFE: return "Programming error"
        default: return "Unknown NRC (0x\(String(format: "%02X", code)))"
        }
    }
}

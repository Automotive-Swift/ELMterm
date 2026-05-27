import Foundation

/// Decodes diagnostic trouble codes and their human-readable meaning.
///
/// OBD-II (SAE J2012) packs a DTC into two bytes: the top two bits select the
/// category (P/C/B/U), the next two bits the first digit, and the remaining
/// three nibbles the last three digits. UDS (ISO 14229-1) uses a three-byte
/// DTC plus a status byte; the first two bytes follow the same J2012 layout and
/// the third byte is rendered as a failure-type suffix.
enum DTCDecoder {

    private static let categories = ["P", "C", "B", "U"]

    /// Decode a two-byte OBD-II DTC, e.g. `0x01 0x33` → `"P0133"`.
    static func code(_ a: UInt8, _ b: UInt8) -> String {
        let category = Self.categories[Int(a >> 6)]
        let firstDigit = (a >> 4) & 0x03
        let secondDigit = a & 0x0F
        let thirdDigit = b >> 4
        let fourthDigit = b & 0x0F
        return String(format: "%@%X%X%X%X", category, firstDigit, secondDigit, thirdDigit, fourthDigit)
    }

    /// Decode a three-byte UDS DTC, e.g. `0x01 0x33 0x00` → `"P0133-00"`.
    static func code(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> String {
        "\(Self.code(a, b))-\(String(format: "%02X", c))"
    }

    /// Human description for a well-known generic code, or nil when unknown.
    static func description(for code: String) -> String? {
        Self.descriptions[code]
    }

    /// Render a decoded code with its description appended when available.
    static func describe(_ code: String) -> String {
        guard let description = Self.description(for: code) else { return code }
        return "\(code) — \(description)"
    }

    /// Expand a UDS DTC status byte (ISO 14229-1 Annex D) into short labels.
    static func statusFlags(_ status: UInt8) -> [String] {
        var flags: [String] = []
        if status & 0x01 != 0 { flags.append("testFailed") }
        if status & 0x02 != 0 { flags.append("testFailedThisCycle") }
        if status & 0x04 != 0 { flags.append("pending") }
        if status & 0x08 != 0 { flags.append("confirmed") }
        if status & 0x10 != 0 { flags.append("testNotCompletedSinceClear") }
        if status & 0x20 != 0 { flags.append("testFailedSinceClear") }
        if status & 0x40 != 0 { flags.append("testNotCompletedThisCycle") }
        if status & 0x80 != 0 { flags.append("warningIndicatorRequested") }
        return flags
    }

    /// Starter set of common generic (SAE J2012) descriptions. Manufacturer
    /// "P1xxx"/"Cxxxx" codes are intentionally absent; unknown codes simply
    /// render without a description. Grow this table as needed.
    private static let descriptions: [String: String] = [
        "P0010": "\"A\" Camshaft Position Actuator Circuit (Bank 1)",
        "P0011": "\"A\" Camshaft Position - Timing Over-Advanced (Bank 1)",
        "P0014": "\"B\" Camshaft Position - Timing Over-Advanced (Bank 1)",
        "P0016": "Crankshaft/Camshaft Position Correlation (Bank 1 Sensor A)",
        "P0030": "HO2S Heater Control Circuit (Bank 1 Sensor 1)",
        "P0100": "Mass or Volume Air Flow Circuit Malfunction",
        "P0101": "Mass or Volume Air Flow Circuit Range/Performance",
        "P0102": "Mass or Volume Air Flow Circuit Low Input",
        "P0103": "Mass or Volume Air Flow Circuit High Input",
        "P0105": "Manifold Absolute Pressure/Barometric Pressure Circuit",
        "P0106": "Manifold Absolute Pressure Range/Performance",
        "P0110": "Intake Air Temperature Circuit Malfunction",
        "P0111": "Intake Air Temperature Circuit Range/Performance",
        "P0112": "Intake Air Temperature Circuit Low Input",
        "P0113": "Intake Air Temperature Circuit High Input",
        "P0115": "Engine Coolant Temperature Circuit Malfunction",
        "P0116": "Engine Coolant Temperature Circuit Range/Performance",
        "P0117": "Engine Coolant Temperature Circuit Low Input",
        "P0118": "Engine Coolant Temperature Circuit High Input",
        "P0120": "Throttle/Pedal Position Sensor \"A\" Circuit Malfunction",
        "P0121": "Throttle/Pedal Position Sensor \"A\" Range/Performance",
        "P0122": "Throttle/Pedal Position Sensor \"A\" Circuit Low Input",
        "P0123": "Throttle/Pedal Position Sensor \"A\" Circuit High Input",
        "P0125": "Insufficient Coolant Temperature for Closed Loop Fuel Control",
        "P0128": "Coolant Thermostat Below Regulating Temperature",
        "P0130": "O2 Sensor Circuit Malfunction (Bank 1, Sensor 1)",
        "P0131": "O2 Sensor Circuit Low Voltage (Bank 1, Sensor 1)",
        "P0132": "O2 Sensor Circuit High Voltage (Bank 1, Sensor 1)",
        "P0133": "O2 Sensor Circuit Slow Response (Bank 1, Sensor 1)",
        "P0134": "O2 Sensor Circuit No Activity Detected (Bank 1, Sensor 1)",
        "P0135": "O2 Sensor Heater Circuit Malfunction (Bank 1, Sensor 1)",
        "P0136": "O2 Sensor Circuit Malfunction (Bank 1, Sensor 2)",
        "P0137": "O2 Sensor Circuit Low Voltage (Bank 1, Sensor 2)",
        "P0138": "O2 Sensor Circuit High Voltage (Bank 1, Sensor 2)",
        "P0140": "O2 Sensor Circuit No Activity Detected (Bank 1, Sensor 2)",
        "P0141": "O2 Sensor Heater Circuit Malfunction (Bank 1, Sensor 2)",
        "P0150": "O2 Sensor Circuit Malfunction (Bank 2, Sensor 1)",
        "P0171": "System Too Lean (Bank 1)",
        "P0172": "System Too Rich (Bank 1)",
        "P0174": "System Too Lean (Bank 2)",
        "P0175": "System Too Rich (Bank 2)",
        "P0200": "Injector Circuit Malfunction",
        "P0201": "Injector Circuit Malfunction - Cylinder 1",
        "P0220": "Throttle/Pedal Position Sensor \"B\" Circuit Malfunction",
        "P0300": "Random/Multiple Cylinder Misfire Detected",
        "P0301": "Cylinder 1 Misfire Detected",
        "P0302": "Cylinder 2 Misfire Detected",
        "P0303": "Cylinder 3 Misfire Detected",
        "P0304": "Cylinder 4 Misfire Detected",
        "P0305": "Cylinder 5 Misfire Detected",
        "P0306": "Cylinder 6 Misfire Detected",
        "P0325": "Knock Sensor 1 Circuit Malfunction (Bank 1)",
        "P0327": "Knock Sensor 1 Circuit Low Input (Bank 1)",
        "P0335": "Crankshaft Position Sensor \"A\" Circuit Malfunction",
        "P0336": "Crankshaft Position Sensor \"A\" Range/Performance",
        "P0340": "Camshaft Position Sensor \"A\" Circuit Malfunction (Bank 1)",
        "P0341": "Camshaft Position Sensor \"A\" Range/Performance (Bank 1)",
        "P0401": "Exhaust Gas Recirculation Flow Insufficient Detected",
        "P0402": "Exhaust Gas Recirculation Flow Excessive Detected",
        "P0420": "Catalyst System Efficiency Below Threshold (Bank 1)",
        "P0430": "Catalyst System Efficiency Below Threshold (Bank 2)",
        "P0440": "Evaporative Emission Control System Malfunction",
        "P0442": "Evaporative Emission Control System Leak Detected (small leak)",
        "P0446": "Evaporative Emission Control System Vent Control Circuit",
        "P0455": "Evaporative Emission Control System Leak Detected (gross leak)",
        "P0500": "Vehicle Speed Sensor Malfunction",
        "P0505": "Idle Control System Malfunction",
        "P0506": "Idle Control System RPM Lower Than Expected",
        "P0507": "Idle Control System RPM Higher Than Expected",
        "P0600": "Serial Communication Link Malfunction",
        "P0606": "PCM Processor Fault",
        "P0700": "Transmission Control System Malfunction",
        "P0705": "Transmission Range Sensor Circuit Malfunction (PRNDL Input)",
        "U0100": "Lost Communication With ECM/PCM \"A\"",
        "U0101": "Lost Communication With TCM",
        "U0121": "Lost Communication With ABS Control Module",
        "U0140": "Lost Communication With Body Control Module",
        "U0155": "Lost Communication With Instrument Panel Cluster",
        "C0035": "Left Front Wheel Speed Sensor Circuit",
        "C0040": "Right Front Wheel Speed Sensor Circuit",
        "B0001": "Driver Frontal Stage 1 Deployment Control",
    ]
}

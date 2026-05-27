import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

enum ColorTheme: String, CaseIterable, Codable, ExpressibleByArgument {

    case light
    case dark

    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

struct ColorPalette {
    let outgoing: String
    let incoming: String
    let status: String
    let annotationOutgoing: String
    let annotationIncoming: String
    let hexdump: String
    let error: String

    static let reset = "\u{001B}[0m"

    static func palette(for theme: ColorTheme) -> ColorPalette {
        switch theme {
            case .light:
                return ColorPalette(
                    outgoing: "\u{001B}[38;5;19m",          // deep navy
                    incoming: "\u{001B}[38;5;28m",         // dark green
                    status: "\u{001B}[38;5;130m",          // burnt amber
                    annotationOutgoing: "\u{001B}[38;5;24m",
                    annotationIncoming: "\u{001B}[38;5;58m",
                    hexdump: "\u{001B}[38;5;94m",
                    error: "\u{001B}[38;5;124m"
                )
            case .dark:
                return ColorPalette(
                    outgoing: "\u{001B}[38;5;117m",        // bright cyan
                    incoming: "\u{001B}[38;5;156m",        // pale green
                    status: "\u{001B}[38;5;222m",          // warm yellow
                    annotationOutgoing: "\u{001B}[38;5;153m",
                    annotationIncoming: "\u{001B}[38;5;186m",
                    hexdump: "\u{001B}[38;5;244m",
                    error: "\u{001B}[38;5;203m"
                )
        }
    }
}

struct UserPreferences: Codable {
    var theme: ColorTheme?
    var historyPath: String?
    var historyDepth: Int?

    static let empty = UserPreferences(theme: nil, historyPath: nil, historyDepth: nil)
}

/// Configuration that describes the REPL environment.
struct TerminalConfiguration {
    let prompt: String
    let terminator: CommandTerminator
    let historyURL: URL?
    let historyDepth: Int
    let hexdump: Bool
    let timestamps: Bool
    let annotationIndent: Int
    let colorPalette: ColorPalette
    let logFileURL: URL?
    let useTUI: Bool
}

/// Supported command terminators for the REPL.
enum CommandTerminator: ExpressibleByArgument {

    case carriageReturn
    case lineFeed
    case crlf
    case none
    case literal(String)
    case hex(Data)

    init?(argument: String) {

        let lowered = argument.lowercased()
        switch lowered {
            case "cr", "\\r", "carriage-return":
                self = .carriageReturn
            case "lf", "\\n", "line-feed":
                self = .lineFeed
            case "crlf", "\\r\\n":
                self = .crlf
            case "none":
                self = .none
            default:
                if lowered.hasPrefix("hex:") {
                    let hexPayload = String(argument.dropFirst(4))
                    guard let data = Data(hexString: hexPayload) else { return nil }
                    self = .hex(data)
                } else {
                    self = .literal(argument)
                }
        }
    }

    var bytes: [UInt8] {

        switch self {
            case .carriageReturn:
                return [0x0D]
            case .lineFeed:
                return [0x0A]
            case .crlf:
                return [0x0D, 0x0A]
            case .none:
                return []
            case .literal(let string):
                return Array(string.utf8)
            case .hex(let data):
                return Array(data)
        }
    }

    var description: String {
        switch self {
            case .carriageReturn: return "CR"
            case .lineFeed: return "LF"
            case .crlf: return "CRLF"
            case .none: return "no terminator"
            case .literal(let string): return "\"\(string)\""
            case .hex(let data): return data.hexDescription
        }
    }
}

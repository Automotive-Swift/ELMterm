import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

enum MetaCommand {

    enum LogAction {
        case status
        case start(path: String)
        case stop
    }

    case help
    case history(limit: Int?)
    case clear
    case analyzer(Bool?)
    case log(LogAction)
    case every(arguments: [String])
    case quit
    case saveHistory

    init?(_ line: String) {
        guard line.hasPrefix(":") else { return nil }
        let rawComponents = line
            .dropFirst()
            .split(separator: " ", omittingEmptySubsequences: true)
        let components = rawComponents.map { $0.lowercased() }
        guard let keyword = components.first else { return nil }
        switch keyword {
            case "help":
                self = .help
            case "history":
                let limit = components.dropFirst().first.flatMap { Int($0) }
                self = .history(limit: limit)
            case "clear":
                self = .clear
            case "analyzer":
                if let arg = components.dropFirst().first {
                    switch arg {
                        case "on", "1", "true":
                            self = .analyzer(true)
                        case "off", "0", "false":
                            self = .analyzer(false)
                        default:
                            self = .analyzer(nil)
                    }
                } else {
                    self = .analyzer(nil)
                }
            case "log":
                if let arg = components.dropFirst().first {
                    switch arg {
                        case "off", "stop":
                            self = .log(.stop)
                        default:
                            let path = String(rawComponents.dropFirst().first!)
                            self = .log(.start(path: path))
                    }
                } else {
                    self = .log(.status)
                }
            case "every", "periodic":
                self = .every(arguments: rawComponents.dropFirst().map(String.init))
            case "quit", "exit":
                self = .quit
            case "save":
                self = .saveHistory
            default:
                return nil
        }
    }

    static func completions(for buffer: String) -> [String] {
        guard buffer.hasPrefix(":") else { return [] }
        let options = [
            ":help",
            ":history",
            ":clear",
            ":analyzer",
            ":log",
            ":every",
            ":save",
            ":quit",
        ]
        return options.filter { $0.hasPrefix(buffer.lowercased()) }
    }
}

import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

final class CommunicationLogger {

    enum Direction: String {
        case tx = "TX"
        case rx = "RX"
    }

    let url: URL
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "ELMterm.logger")
    private lazy var timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(url: URL) {
        self.url = url
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        self.fileHandle = try? FileHandle(forWritingTo: url)
        self.fileHandle?.seekToEndOfFile()
    }

    deinit {
        try? self.fileHandle?.close()
    }

    func log(direction: Direction, message: String) {
        self.queue.async { [weak self] in
            guard let self, let handle = self.fileHandle else { return }
            let timestamp = self.timestampFormatter.string(from: Date())
            let line = "[\(timestamp)] \(direction.rawValue): \(message)\n"
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }
}

extension CommunicationLogger: @unchecked Sendable {}

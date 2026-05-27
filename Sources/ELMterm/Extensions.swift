import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

extension String {

    var trimmed: String {
        self.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func appendingTerminator(_ terminator: [UInt8]) -> Data {
        var data = Data(self.utf8)
        data.append(contentsOf: terminator)
        return data
    }
}

extension Data {

    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        self.init()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let pair = cleaned[index..<next]
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            self.append(byte)
            index = next
        }
    }

    var hexDescription: String {
        self.map { String(format: "%02X", $0) }.joined()
    }

    func hexdump(prefix: String = "", width: Int = 16) -> String {

        guard !self.isEmpty else { return "" }
        var lines: [String] = []
        var offset = 0
        while offset < self.count {
            let upper = Swift.min(offset + width, self.count)
            let chunk = self.subdata(in: offset..<upper)
            let hexPart = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let targetWidth = width * 3 - 1
            let paddedHex = hexPart.padding(toLength: targetWidth, withPad: " ", startingAt: 0)
            var asciiString = ""
            for byte in chunk {
                if (0x20...0x7E).contains(Int(byte)),
                   let scalar = UnicodeScalar(UInt32(byte)) {
                    asciiString.append(Character(scalar))
                } else {
                    asciiString.append(".")
                }
            }
            let line = "\(prefix)\(String(format: "%04X", offset))  \(paddedHex)  \(asciiString)"
            lines.append(line)
            offset += width
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

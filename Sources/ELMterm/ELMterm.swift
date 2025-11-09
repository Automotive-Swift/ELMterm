import ArgumentParser
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

@main
struct ELMterm: AsyncParsableCommand {

    static let configuration: CommandConfiguration = .init(
        commandName: "ELMterm",
        abstract: "A transport-agnostic terminal for ELM-compatible OBD-II adapters."
    )

    @Argument(help: "CornucopiaStreams URL, e.g. tcp://192.168.0.10:35000 or tty:///dev/tty.usbserial-XXXX.")
    var urlString: String

    @Option(name: [.customShort("t"), .long], help: "Connection timeout in seconds.")
    var timeout: Double = 12

    @Option(name: [.customShort("p"), .long], help: "Prompt shown in the REPL.")
    var prompt: String = "> "

    @Option(name: .long, help: "Terminator appended to every command (cr, lf, crlf, none, hex:0d0a, literal text).")
    var terminator: CommandTerminator = .carriageReturn

    @Option(name: .long, help: "Persist history at the provided path (default: ~/.elmterm.history when omitted).")
    var history: String?

    @Option(name: .long, help: "Maximum number of commands kept in history.")
    var historyDepth: Int = 500

    @Option(name: .long, help: "Path to a JSON config file (default: ~/.elmterm.json when present).")
    var config: String?

    @Option(name: .long, help: "Color theme preset (light or dark).")
    var theme: ColorTheme?

    @Flag(name: .long, help: "Print incoming frames as ASCII + hexdump.")
    var hexdump: Bool = false

    @Flag(name: .long, help: "Disable the OBD-II analyzer/annotation pipeline.")
    var plain: Bool = false

    @Flag(name: .long, help: "Show a timestamp prefix for every RX/TX line.")
    var timestamps: Bool = false

    mutating func run() async throws {

        guard let endpoint = URL(string: self.urlString) else {
            throw ValidationError("Invalid URL: \(self.urlString)")
        }

        signal(SIGPIPE, SIG_IGN)

        let preferences = self.loadPreferences()
        let effectiveTheme = self.theme ?? preferences.theme ?? .light
        let palette = ColorPalette.palette(for: effectiveTheme)
        let historyURL = Self.makeHistoryURL(from: self.history ?? preferences.historyPath)
        let historyDepth = preferences.historyDepth ?? self.historyDepth

        let configuration = TerminalConfiguration(
            prompt: self.prompt,
            terminator: self.terminator,
            historyURL: historyURL,
            historyDepth: historyDepth,
            hexdump: self.hexdump,
            timestamps: self.timestamps,
            annotationIndent: 2,
            colorPalette: palette
        )

        let controller = TerminalController(configuration: configuration, analyzer: self.plain ? nil : OBD2Analyzer())
        let runLoopStopper = RunLoopStopper()
        let signalHandler = SignalForwarder {
            controller.requestStop(reason: "Interrupted")
        }
        signalHandler.activate()
        let connectTimeout = self.timeout

        let replTask = Task.detached(priority: .userInitiated) {
            do {
                try await controller.start(url: endpoint, timeout: connectTimeout)
            } catch {
                controller.report(error: error)
                throw error
            }
            runLoopStopper.stop()
        }

        runLoopStopper.run()

        switch await replTask.result {
            case .success:
                return
            case .failure(let error):
                throw error
        }
    }

    private func loadPreferences() -> UserPreferences {
        guard let configURL = self.resolveConfigURL() else { return .empty }
        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(UserPreferences.self, from: data)
        } catch {
            fputs("Warning: Unable to load config at \(configURL.path): \(error.localizedDescription)\n", stderr)
            return .empty
        }
    }

    private func resolveConfigURL() -> URL? {
        if let explicit = self.config?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            let expanded = Self.expandPath(explicit)
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        let defaultPath = Self.expandPath("~/.elmterm.json")
        guard FileManager.default.fileExists(atPath: defaultPath) else { return nil }
        return URL(fileURLWithPath: defaultPath).standardizedFileURL
    }

    private static func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func makeHistoryURL(from path: String?) -> URL? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        if let trimmed, !trimmed.isEmpty {
            resolvedPath = Self.expandPath(trimmed)
        } else {
            resolvedPath = Self.expandPath("~/.elmterm.history")
        }
        return URL(fileURLWithPath: resolvedPath).standardizedFileURL
    }
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

/// Coordinates stream handling, REPL input and analyzer output.
final class TerminalController: NSObject {

    private let configuration: TerminalConfiguration
    private let colorPalette: ColorPalette
    private var analyzer: OBD2Analyzer?
    private var keepRunning = true
    private var annotationEnabled: Bool

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var incomingBuffer = Data()
    private lazy var timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withFractionalSeconds]
        return formatter
    }()

    private var history: [String] = []
    private let outputQueue = DispatchQueue(label: "ELMterm.output")
    private let promptStateQueue = DispatchQueue(label: "ELMterm.prompt.state", attributes: .concurrent)
    private var lineEditingActive = false
    private var activeInputBuffer = ""
    private let transmitLock = NSLock()
    private var pendingWriteBuffer = Data()
    private let echoLock = NSLock()
    private var lastSentCommand: String?

    private var pendingShutdown = false

    init(configuration: TerminalConfiguration, analyzer: OBD2Analyzer?) {
        self.configuration = configuration
        self.colorPalette = configuration.colorPalette
        self.analyzer = analyzer
        self.annotationEnabled = analyzer != nil
        super.init()
    }

    private func beginLineEditing() {
        self.promptStateQueue.sync(flags: .barrier) {
            self.lineEditingActive = true
            self.activeInputBuffer = ""
        }
    }

    private func endLineEditing() {
        self.promptStateQueue.sync(flags: .barrier) {
            self.lineEditingActive = false
            self.activeInputBuffer = ""
        }
    }

    private func updateActiveInputBuffer(_ buffer: String) {
        self.promptStateQueue.sync(flags: .barrier) {
            self.activeInputBuffer = buffer
        }
    }

    private func snapshotPromptState() -> (Bool, String) {
        self.promptStateQueue.sync { (self.lineEditingActive, self.activeInputBuffer) }
    }

    private func emitLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        self.outputQueue.async {
            let (active, buffer) = self.snapshotPromptState()
            if active {
                // Clear the current line (active editing)
                fputs("\r\u{001B}[K", stdout)
            }
            for line in lines {
                fputs(line, stdout)
                fputs("\n", stdout)
            }
            if active {
                // Restore the prompt and user's input buffer
                fputs("\(self.configuration.prompt)\(buffer)", stdout)
            }
            fflush(stdout)
        }
    }

    private func emitLine(_ line: String) {
        self.emitLines([line])
    }

    private func emitTextBlock(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        self.emitLines(lines)
    }

    func start(url: URL, timeout: TimeInterval) async throws {

        try self.prepareHistory()
        self.printStatus("Connecting to \(url.absoluteString)…")

        let (input, output) = try await Cornucopia.Streams.connect(url: url, timeout: timeout)
        self.inputStream = input
        self.outputStream = output

        self.configureStreams()
        self.printStatus("Connected – stream open, type :help for assistance.")

        do {
            try await self.replLoop()
        } catch {
            self.cleanupStreams()
            throw error
        }

        self.cleanupStreams()
        self.printStatus("Disconnected.")
    }

    func requestStop(reason: String? = nil) {
        guard !self.pendingShutdown else { return }
        self.pendingShutdown = true
        if let reason {
            self.printStatus("Stopping: \(reason)")
        }
        self.keepRunning = false
        self.cleanupStreams()
    }

    func report(error: Error) {
        let color = self.colorPalette.error
        self.emitLine("\(color)Error: \(error.localizedDescription)\(ColorPalette.reset)")
    }

    private func readUserInput() throws -> String {
        self.outputQueue.sync {
            fflush(stdout)
        }
        self.beginLineEditing()
        defer { self.endLineEditing() }

        return try self.readLineWithHistory(prompt: self.configuration.prompt)
    }

    private func readLineWithHistory(prompt: String) throws -> String {
        var buffer = ""
        var cursorPos = 0
        var historyIndex: Int? = nil

        // Set terminal to raw mode
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~(UInt(ECHO | ICANON))
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        }

        // Display prompt
        fputs(prompt, stdout)
        fflush(stdout)

        var escapeSequence: [UInt8] = []

        while true {
            var char: UInt8 = 0
            let bytesRead = read(STDIN_FILENO, &char, 1)

            guard bytesRead > 0 else {
                throw SimpleReadLineError.eof
            }

            // Handle escape sequences
            if !escapeSequence.isEmpty {
                escapeSequence.append(char)

                if escapeSequence.count == 3 && escapeSequence[0] == 27 && escapeSequence[1] == 91 {
                    // Arrow keys: ESC [ A/B/C/D
                    switch escapeSequence[2] {
                    case 65: // Up arrow
                        if historyIndex == nil {
                            historyIndex = self.history.count
                        }
                        if let idx = historyIndex, idx > 0 {
                            historyIndex = idx - 1
                            let historyLine = self.history[idx - 1]
                            self.replaceLineBuffer(&buffer, &cursorPos, with: historyLine, prompt: prompt)
                        }
                    case 66: // Down arrow
                        if let idx = historyIndex {
                            if idx < self.history.count - 1 {
                                historyIndex = idx + 1
                                let historyLine = self.history[idx + 1]
                                self.replaceLineBuffer(&buffer, &cursorPos, with: historyLine, prompt: prompt)
                            } else {
                                historyIndex = nil
                                self.replaceLineBuffer(&buffer, &cursorPos, with: "", prompt: prompt)
                            }
                        }
                    case 67: // Right arrow
                        if cursorPos < buffer.count {
                            fputs("\u{001B}[C", stdout)
                            fflush(stdout)
                            cursorPos += 1
                        }
                    case 68: // Left arrow
                        if cursorPos > 0 {
                            fputs("\u{001B}[D", stdout)
                            fflush(stdout)
                            cursorPos -= 1
                        }
                    default:
                        break
                    }
                    escapeSequence.removeAll()
                }
                continue
            }

            if char == 27 { // ESC
                escapeSequence.append(char)
                continue
            }

            if char == 127 || char == 8 { // Backspace or DEL
                if cursorPos > 0 {
                    let index = buffer.index(buffer.startIndex, offsetBy: cursorPos - 1)
                    buffer.remove(at: index)
                    cursorPos -= 1
                    self.redrawLine(buffer: buffer, cursorPos: cursorPos, prompt: prompt)
                }
                continue
            }

            if char == 13 || char == 10 { // CR or LF
                fputs("\n", stdout)
                fflush(stdout)
                return buffer
            }

            if char == 3 { // Ctrl-C
                fputs("^C\n", stdout)
                fflush(stdout)
                return ""
            }

            if char == 4 { // Ctrl-D (EOF)
                if buffer.isEmpty {
                    throw SimpleReadLineError.eof
                }
                continue
            }

            // Regular character
            if char >= 32 && char < 127 {
                let charStr = String(UnicodeScalar(char))
                if cursorPos == buffer.count {
                    buffer.append(charStr)
                    fputs(charStr, stdout)
                    fflush(stdout)
                } else {
                    let index = buffer.index(buffer.startIndex, offsetBy: cursorPos)
                    buffer.insert(contentsOf: charStr, at: index)
                    self.redrawLine(buffer: buffer, cursorPos: cursorPos, prompt: prompt)
                }
                cursorPos += 1
            }
        }
    }

    private func replaceLineBuffer(_ buffer: inout String, _ cursorPos: inout Int, with newContent: String, prompt: String) {
        buffer = newContent
        cursorPos = newContent.count
        self.redrawLine(buffer: buffer, cursorPos: cursorPos, prompt: prompt)
    }

    private func redrawLine(buffer: String, cursorPos: Int, prompt: String) {
        // Clear line and redraw
        fputs("\r\u{001B}[K", stdout)
        fputs(prompt, stdout)
        fputs(buffer, stdout)

        // Move cursor to correct position
        let distanceFromEnd = buffer.count - cursorPos
        if distanceFromEnd > 0 {
            fputs("\u{001B}[\(distanceFromEnd)D", stdout)
        }
        fflush(stdout)
    }

    enum SimpleReadLineError: Error {
        case eof
    }

    private func prepareHistory() throws {

        self.history.removeAll()
        if let historyURL = self.configuration.historyURL {
            let path = historyURL.path
            guard FileManager.default.fileExists(atPath: path) else { return }
            do {
                let fileContent = try String(contentsOf: historyURL, encoding: .utf8)
                self.history = fileContent
                    .split(separator: "\n")
                    .map { String($0) }
                    .suffix(self.configuration.historyDepth)
                    .map { String($0) }
            } catch {
                self.printStatus("Unable to load history (\(path)): \(error.localizedDescription)")
            }
        }
    }

    private func persistHistory() {

        guard let historyURL = self.configuration.historyURL else { return }
        let directory = historyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let content = self.history.suffix(self.configuration.historyDepth).joined(separator: "\n")
            try content.write(to: historyURL, atomically: true, encoding: .utf8)
        } catch {
            self.printStatus("Unable to persist history: \(error.localizedDescription)")
        }
    }

    private func configureStreams() {

        guard let inputStream, let outputStream else { return }
        inputStream.delegate = self
        outputStream.delegate = self
        let runLoop = RunLoop.main
        inputStream.schedule(in: runLoop, forMode: .common)
        inputStream.open()
        outputStream.schedule(in: runLoop, forMode: .common)
        outputStream.open()
    }

    private func cleanupStreams() {

        guard let inputStream, let outputStream else { return }
        inputStream.close()
        outputStream.close()
        inputStream.remove(from: .main, forMode: .common)
        outputStream.remove(from: .main, forMode: .common)
    }

    private func replLoop() async throws {

        while self.keepRunning {
            let line: String
            do {
                line = try self.readUserInput()
            } catch SimpleReadLineError.eof {
                self.printStatus("EOF – leaving.")
                break
            } catch {
                throw error
            }

            // Filter out any stray CR characters and then trim whitespace.
            let filtered = line.replacingOccurrences(of: "\r", with: "")
            let trimmed = filtered.trimmed
            guard !trimmed.isEmpty else { continue }

            if trimmed == "quit" || trimmed == "exit" {
                break
            }

            if trimmed.hasPrefix(":") {
                try self.handle(metaCommand: trimmed)
                continue
            }

            self.history.append(trimmed)
            self.persistHistory()
            try self.sendToAdapter(trimmed)
        }

        self.persistHistory()
        self.keepRunning = false
    }

    private func handle(metaCommand: String) throws {

        guard let command = MetaCommand(metaCommand) else {
            let color = self.colorPalette.error
            self.emitLine("\(color)Unknown command: \(metaCommand)\(ColorPalette.reset)")
            return
        }

        switch command {
            case .help:
                self.printMetaHelp()
            case .history(let limit):
                self.printHistory(limit: limit)
            case .clear:
                fputs("\u{001B}[2J\u{001B}[H", stdout)  // Clear screen and move to home
                fflush(stdout)
            case .analyzer(let toggle):
                if let toggle {
                    self.annotationEnabled = toggle
                } else {
                    self.annotationEnabled.toggle()
                }
                let state = self.annotationEnabled ? "enabled" : "disabled"
                self.printStatus("Analyzer \(state).")
            case .quit:
                self.keepRunning = false
            case .saveHistory:
                self.persistHistory()
                self.printStatus("History saved.")
        }
    }

    private func printMetaHelp() {
        let text = """
        :help              Show this help
        :history [n]       Print the last n commands (default 20)
        :clear             Clear the screen
        :analyzer [on|off] Toggle or force analyzer output
        :save              Persist the in-memory history
        :quit              Exit ELMterm
        """
        self.emitTextBlock(text)
    }

    private func printHistory(limit: Int?) {

        let count = limit ?? 20
        let slice = self.history.suffix(count)
        guard !slice.isEmpty else {
            self.printStatus("History empty.")
            return
        }
        let lines = slice.enumerated().map { index, entry in
            String(format: "[%02d] %@", index, entry)
        }
        self.emitLines(lines)
    }

    private func sendToAdapter(_ line: String) throws {

        self.echoLock.lock()
        self.lastSentCommand = line
        self.echoLock.unlock()

        let payload = line.appendingTerminator(self.configuration.terminator.bytes)
        self.printOutgoing(line)
        if self.annotationEnabled, let annotation = self.analyzer?.annotateOutgoing(line) {
            self.printAnnotation(annotation, direction: .outgoing)
        }

        self.transmitLock.lock()
        self.pendingWriteBuffer.append(payload)
        self.transmitLock.unlock()

        DispatchQueue.main.async {
            self.flushPendingWritesSafely()
        }
    }

    private enum OutputDirection {
        case outgoing
        case incoming
        case status
    }

    private func printOutgoing(_ line: String) {
        self.printDirectional(direction: .outgoing, body: line)
    }

    private func printIncoming(_ line: String) {
        self.printDirectional(direction: .incoming, body: line)
    }

    private func printStatus(_ line: String) {
        self.printDirectional(direction: .status, body: line)
    }

    private func printDirectional(direction: OutputDirection, body: String) {
        var components: [String] = []
        if self.configuration.timestamps {
            components.append("[\(self.timestampFormatter.string(from: Date()))]")
        }
        components.append(body)
        let line = components.isEmpty ? body : components.joined(separator: " ")
        let color = self.color(for: direction)
        self.emitLine("\(color)\(line)\(ColorPalette.reset)")
    }

    private func printAnnotation(_ annotation: AnalyzerOutput, direction: AdapterMessage.Direction) {

        guard self.annotationEnabled else { return }
        let indent = String(repeating: " ", count: self.configuration.annotationIndent)
        let color = self.annotationColor(for: direction)
        var lines = ["\(color)→ \(annotation.headline)\(ColorPalette.reset)"]
        for line in annotation.details {
            lines.append("\(color)\(indent)  \(line)\(ColorPalette.reset)")
        }
        self.emitLines(lines)
    }

    private func color(for direction: OutputDirection) -> String {
        switch direction {
            case .outgoing: return self.colorPalette.outgoing
            case .incoming: return self.colorPalette.incoming
            case .status: return self.colorPalette.status
        }
    }

    private func annotationColor(for direction: AdapterMessage.Direction) -> String {
        switch direction {
            case .incoming:
                return self.colorPalette.annotationIncoming
            case .outgoing:
                return self.colorPalette.annotationOutgoing
        }
    }

    private func flushPendingWritesSafely() {
        do {
            try self.flushPendingWrites()
        } catch {
            self.requestStop(reason: "Write error: \(error.localizedDescription)")
        }
    }

    private func flushPendingWrites() throws {

        guard let outputStream else { return }
        self.transmitLock.lock()
        defer { self.transmitLock.unlock() }

        while !self.pendingWriteBuffer.isEmpty {
            let wrote = self.pendingWriteBuffer.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return outputStream.write(base, maxLength: rawBuffer.count)
            }

            if wrote < 0 {
                throw outputStream.streamError ?? NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
            }

            if wrote == 0 {
                break
            }

            self.pendingWriteBuffer.removeFirst(wrote)
        }
    }

    private func handleIncomingData() {

        guard let inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while inputStream.hasBytesAvailable {
            let read = inputStream.read(&buffer, maxLength: buffer.count)
            if read > 0 {
                self.incomingBuffer.append(buffer, count: read)
            } else if read == 0 {
                self.requestStop(reason: "Remote closed connection.")
                return
            } else {
                self.requestStop(reason: inputStream.streamError?.localizedDescription ?? "Unknown read error")
                return
            }
        }

        self.processIncomingBuffer()
    }

    private func processIncomingBuffer() {

        let promptByte: UInt8 = 0x3E // ">"
        let cr: UInt8 = 0x0D
        let lf: UInt8 = 0x0A

        while !self.incomingBuffer.isEmpty {
            // The ELM327 prompt indicates end of a response. Swallow all leading prompt characters.
            while !self.incomingBuffer.isEmpty && self.incomingBuffer.first == promptByte {
                self.incomingBuffer.removeFirst()
            }

            guard !self.incomingBuffer.isEmpty else { break }

            // Look for the next CR or LF
            guard let index = self.incomingBuffer.firstIndex(where: { $0 == lf || $0 == cr }) else {
                // No newline found, wait for more data
                break
            }

            let lineData = self.incomingBuffer.prefix(upTo: index)
            var lineEnd = index

            // Consume ALL consecutive CR and LF characters (handles CRLF, LFCR, CRCR, LFLF, and any combinations)
            while lineEnd < self.incomingBuffer.endIndex && (self.incomingBuffer[lineEnd] == cr || self.incomingBuffer[lineEnd] == lf) {
                lineEnd = self.incomingBuffer.index(after: lineEnd)
            }

            self.incomingBuffer.removeSubrange(..<lineEnd)

            if !lineData.isEmpty {
                self.emitLine(from: lineData)
            }
        }
    }

    private func emitLine(from dataSlice: Data.SubSequence) {

        let data = Data(dataSlice)
        guard let line = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else {
            if self.configuration.hexdump {
                let color = self.colorPalette.hexdump
                let hexLines = data.hexdump().split(separator: "\n").map {
                    "\(color)\($0)\(ColorPalette.reset)"
                }
                self.emitLines(hexLines)
            }
            return
        }

        self.echoLock.lock()
        if let lastCommand = self.lastSentCommand {
            let cleanedLine = line.trimmed.uppercased()
            let cleanedCommand = lastCommand.trimmed.uppercased()
            if cleanedLine == cleanedCommand {
                self.lastSentCommand = nil
                self.echoLock.unlock()
                return // Swallow the echo
            }
        }
        self.echoLock.unlock()

        // Filter out CR characters and clean up the line
        let filteredLine = line.replacingOccurrences(of: "\r", with: "")
        let trimmed = filteredLine.trimmed
        guard !trimmed.isEmpty else { return }

        self.printIncoming(trimmed)

        // Show ASCII representation for long hex-looking lines
        if trimmed.count > 30 && self.looksLikeHex(trimmed) {
            if let bytes = self.parseHexBytes(from: trimmed) {
                let ascii = bytes.map { byte in
                    (0x20...0x7E).contains(Int(byte)) ? String(UnicodeScalar(byte)) : "."
                }.joined()
                let color = self.colorPalette.hexdump
                self.emitLine("\(color)    ASCII: \(ascii)\(ColorPalette.reset)")
            }
        }

        if self.configuration.hexdump, let asciiData = trimmed.data(using: .utf8) {
            let color = self.colorPalette.hexdump
            let hexLines = asciiData.hexdump().split(separator: "\n").map {
                "\(color)\($0)\(ColorPalette.reset)"
            }
            self.emitLines(hexLines)
        }

        if self.annotationEnabled, let annotation = self.analyzer?.annotateIncoming(trimmed) {
            self.printAnnotation(annotation, direction: .incoming)
        }
    }

    private func looksLikeHex(_ string: String) -> Bool {
        let hexChars = CharacterSet(charactersIn: "0123456789ABCDEFabcdef ")
        return string.unicodeScalars.allSatisfy { hexChars.contains($0) }
    }

    private func parseHexBytes(from string: String) -> [UInt8]? {
        let cleaned = string.replacingOccurrences(of: " ", with: "")

        // Parse from the end, taking pairs of hex digits
        // This works regardless of variable-length CAN header at the start
        var bytes: [UInt8] = []
        var index = cleaned.endIndex

        while index > cleaned.startIndex {
            let remaining = cleaned.distance(from: cleaned.startIndex, to: index)
            if remaining >= 2 {
                let start = cleaned.index(index, offsetBy: -2)
                let byteString = cleaned[start..<index]
                guard let byte = UInt8(byteString, radix: 16) else { return nil }
                bytes.insert(byte, at: 0)  // Insert at beginning to maintain order
                index = start
            } else {
                // Odd number of hex digits remaining (likely the CAN header)
                break
            }
        }

        return bytes.isEmpty ? nil : bytes
    }
}

extension TerminalController: StreamDelegate {

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {

        switch eventCode {
            case .openCompleted:
                return
            case .hasBytesAvailable:
                self.handleIncomingData()
            case .hasSpaceAvailable:
                self.flushPendingWritesSafely()
            case .errorOccurred:
                self.requestStop(reason: aStream.streamError?.localizedDescription ?? "Stream error")
            case .endEncountered:
                self.requestStop(reason: "Stream ended")
            default:
                break
        }
    }
}

extension TerminalController: @unchecked Sendable {}

private enum MetaCommand {

    case help
    case history(limit: Int?)
    case clear
    case analyzer(Bool?)
    case quit
    case saveHistory

    init?(_ line: String) {
        guard line.hasPrefix(":") else { return nil }
        let components = line
            .dropFirst()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
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
            ":save",
            ":quit",
        ]
        return options.filter { $0.hasPrefix(buffer.lowercased()) }
    }
}

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

    private struct ISOTPReassembly {
        var totalLength: Int
        var buffer: [UInt8]
        var nextSequence: UInt8
    }

    private var isotpState: ISOTPReassembly?

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
        "STMFR": "Monitor for receiver",
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
        0x05: .init(description: "Engine coolant temperature", formatter: { bytes in
            guard let a = bytes.first else { return nil }
            let value = Int(a) - 40
            return "\(value) °C"
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
        0x0F: .init(description: "Intake air temperature", formatter: { bytes in
            guard let a = bytes.first else { return nil }
            return "\(Int(a) - 40) °C"
        }),
        0x11: .init(description: "Throttle position", formatter: { bytes in
            guard let a = bytes.first else { return nil }
            let percent = Double(a) * 100.0 / 255.0
            return String(format: "%.1f %%", percent)
        }),
        0x2F: .init(description: "Fuel level", formatter: { bytes in
            guard let a = bytes.first else { return nil }
            let percent = Double(a) * 100.0 / 255.0
            return String(format: "%.1f %%", percent)
        }),
    ]

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

    func annotateOutgoing(_ line: String) -> AnalyzerOutput? {

        let upper = line.uppercased()
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

        var details: [String] = []
        let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        details.append("Hex: \(hexBytes)")

        let isOBD2 = mode <= 0x0F
        let protocolName = isOBD2 ? "OBD-II" : "UDS/KWP"
        let modeDescriptions = isOBD2 ? self.obd2ModeDescriptions : self.udsModeDescriptions

        if let description = modeDescriptions[mode] {
            details.append(description)
        }

        if isOBD2 && bytes.count > 1 {
            let pid = bytes[1]
            if let info = self.pidDatabase[pid] {
                details.append("PID \(String(format: "%02X", pid)): \(info.description)")
            } else {
                details.append("PID \(String(format: "%02X", pid))")
            }
        }

        guard !details.isEmpty else { return nil }
        return AnalyzerOutput(headline: "\(protocolName) request (mode \(String(format: "%02X", mode)))", details: details)
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

        if let description = modeDescriptions[mode] {
            details.append("Mode \(String(format: "%02X", mode)): \(description)")
        }

        return AnalyzerOutput(headline: "✅ ISO-TP: \(protocolName) Complete Message", details: details)
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

        guard let bytes = Self.bytes(fromResponse: upper), bytes.count >= 2 else {
            return nil
        }

        // Check for negative response (7F xx yy)
        if bytes[0] == 0x7F && bytes.count >= 3 {
            let serviceId = bytes[1]
            let nrcCode = bytes[2]
            let nrcDescription = Self.nrcDescription(for: nrcCode)

            let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = Self.asciiRepresentation(from: bytes)

            return AnalyzerOutput(
                headline: "❌ Negative Response (NRC 0x\(String(format: "%02X", nrcCode)))",
                details: [
                    "Service 0x\(String(format: "%02X", serviceId)) failed",
                    nrcDescription,
                    "Hex: \(hexBytes)",
                    "ASCII: \(ascii)"
                ]
            )
        }

        // Check for ISO-TP frames
        let frameType = bytes[0] >> 4

        // First Frame (0x10-0x1F)
        if frameType == 0x1 && bytes.count >= 2 {
            let lengthHigh = Int(bytes[0] & 0x0F)
            let lengthLow = Int(bytes[1])
            let totalLength = (lengthHigh << 8) | lengthLow
            let dataBytes = Array(bytes.dropFirst(2))

            self.isotpState = ISOTPReassembly(
                totalLength: totalLength,
                buffer: dataBytes,
                nextSequence: 1
            )

            let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            return AnalyzerOutput(
                headline: "📦 ISO-TP First Frame (1/\(totalLength) bytes)",
                details: [
                    "Hex: \(hexBytes)",
                    "Multi-frame message started, waiting for consecutive frames..."
                ]
            )
        }

        // Consecutive Frame (0x20-0x2F)
        if frameType == 0x2 {
            let sequence = bytes[0] & 0x0F
            let dataBytes = Array(bytes.dropFirst(1))

            guard var state = self.isotpState else {
                let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                return AnalyzerOutput(
                    headline: "⚠️ ISO-TP Consecutive Frame (orphaned)",
                    details: [
                        "Hex: \(hexBytes)",
                        "Received consecutive frame without first frame"
                    ]
                )
            }

            guard sequence == state.nextSequence else {
                self.isotpState = nil
                let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                return AnalyzerOutput(
                    headline: "⚠️ ISO-TP Sequence Error",
                    details: [
                        "Hex: \(hexBytes)",
                        "Expected sequence \(state.nextSequence), got \(sequence)"
                    ]
                )
            }

            state.buffer.append(contentsOf: dataBytes)
            state.nextSequence = (state.nextSequence + 1) & 0x0F

            if state.buffer.count >= state.totalLength {
                let completeMessage = Array(state.buffer.prefix(state.totalLength))
                self.isotpState = nil
                return self.decodeCompleteISOTPMessage(completeMessage)
            } else {
                self.isotpState = state
                let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                let progress = "\(state.buffer.count)/\(state.totalLength)"
                return AnalyzerOutput(
                    headline: "📦 ISO-TP Consecutive Frame (\(progress) bytes)",
                    details: [
                        "Hex: \(hexBytes)",
                        "Sequence \(sequence), waiting for more frames..."
                    ]
                )
            }
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
        details.append("Hex: \(hexBytes)")
        details.append("ASCII: \(ascii)")

        if isOBD2, let info = self.pidDatabase[pid], let formatted = info.formatter(payload) {
            let headline = "\(protocolName) response (mode \(String(format: "%02X", mode)))"
            details.append("\(info.description): \(formatted)")
            return AnalyzerOutput(headline: headline, details: details)
        }

        if let description = modeDescriptions[mode] {
            details.append("Mode \(String(format: "%02X", mode)): \(description)")
            return AnalyzerOutput(headline: "\(protocolName) response", details: details)
        }

        return AnalyzerOutput(headline: "\(protocolName) response", details: details)
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

    private static func bytes(fromResponse text: String) -> [UInt8]? {
        let cleaned = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")

        // Try to detect and skip common CAN headers
        var dataStart = cleaned.startIndex
        let length = cleaned.count

        // Check for standard 11-bit CAN IDs (3 hex digits: 7E8, 7E9, 7DF, etc.)
        if length >= 3 {
            let maybeHeader = cleaned.prefix(3)
            // Common OBD-II CAN IDs start with 7 (e.g., 7E8-7EF, 7DF)
            if maybeHeader.first == "7" {
                dataStart = cleaned.index(cleaned.startIndex, offsetBy: 3)
            }
        }

        // Check for extended 29-bit CAN IDs (8 hex digits)
        if dataStart == cleaned.startIndex && length >= 8 {
            let maybeExtended = cleaned.prefix(8)
            // Extended CAN typically starts with patterns like 18DA, 18DB
            if maybeExtended.hasPrefix("18") {
                dataStart = cleaned.index(cleaned.startIndex, offsetBy: 8)
            }
        }

        // Parse data bytes from the remaining string
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

        return bytes.isEmpty ? nil : bytes
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

// MARK: - Helpers

final class RunLoopStopper {

    private let runLoop = RunLoop.main

    func run() {
        self.runLoop.run()
    }

    func stop() {
        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
}

extension RunLoopStopper: @unchecked Sendable {}

final class SignalForwarder {

    private let handler: () -> Void
    private var source: DispatchSourceSignal?

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func activate() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        self.source = source
    }
}

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

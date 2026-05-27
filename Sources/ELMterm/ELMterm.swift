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

    @Flag(name: .long, help: "Disable the bottom-anchored TUI (use a scrolling line-by-line REPL instead).")
    var noTui: Bool = false

    @Option(name: .long, help: "Write communication log to the specified file.")
    var log: String?

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

        let logFileURL: URL? = self.log.map { path in
            URL(fileURLWithPath: Self.expandPath(path)).standardizedFileURL
        }

        let configuration = TerminalConfiguration(
            prompt: self.prompt,
            terminator: self.terminator,
            historyURL: historyURL,
            historyDepth: historyDepth,
            hexdump: self.hexdump,
            timestamps: self.timestamps,
            annotationIndent: 2,
            colorPalette: palette,
            logFileURL: logFileURL,
            useTUI: !self.noTui
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
    private var activeCursorPos = 0
    private let transmitLock = NSLock()
    private var pendingWriteBuffer = Data()
    private let echoLock = NSLock()
    private var lastSentCommand: String?

    /// Periodic commands quietly skip a tick while an interactive command was
    /// issued within this window, so background polling yields the half-duplex
    /// link rather than stacking onto an in-flight request/response exchange.
    private static let periodicInteractiveGrace: TimeInterval = 1.0
    private let activityLock = NSLock()
    private var lastInteractiveSend = Date.distantPast
    private lazy var periodicScheduler = PeriodicScheduler(
        send: { [weak self] command in self?.enqueueCommand(command, interactive: false) },
        shouldFire: { [weak self] in self?.mayFirePeriodicCommand() ?? false }
    )

    /// Half-duplex command pump: one command in flight, the rest queued until
    /// the adapter's `>` prompt releases the next. Guards every field below.
    private static let commandWatchdogTimeout: TimeInterval = 5.0
    private let commandLock = NSLock()
    private var commandQueue: [(command: String, interactive: Bool)] = []
    private var inFlightCommand: String?
    private var commandWatchdog: DispatchSourceTimer?
    private let commandWatchdogQueue = DispatchQueue(label: "ELMterm.command.watchdog")

    private var pendingShutdown = false
    private var streamsScheduledOnRunLoop = false

    private var communicationLogger: CommunicationLogger?

    private var tui: TerminalUI?
    private var winchSource: DispatchSourceSignal?

    init(configuration: TerminalConfiguration, analyzer: OBD2Analyzer?) {
        self.configuration = configuration
        self.colorPalette = configuration.colorPalette
        self.analyzer = analyzer
        self.annotationEnabled = analyzer != nil
        super.init()
        if let logURL = configuration.logFileURL {
            self.communicationLogger = CommunicationLogger(url: logURL)
        }
    }

    private func beginLineEditing() {
        self.promptStateQueue.sync(flags: .barrier) {
            self.lineEditingActive = true
            self.activeInputBuffer = ""
            self.activeCursorPos = 0
        }
    }

    private func endLineEditing() {
        self.promptStateQueue.sync(flags: .barrier) {
            self.lineEditingActive = false
            self.activeInputBuffer = ""
            self.activeCursorPos = 0
        }
    }

    private func snapshotPromptState() -> (active: Bool, buffer: String, cursor: Int) {
        self.promptStateQueue.sync {
            (self.lineEditingActive, self.activeInputBuffer, self.activeCursorPos)
        }
    }

    private func emitLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        self.outputQueue.async {
            let state = self.snapshotPromptState()
            if let tui = self.tui, tui.enabled {
                for line in lines {
                    tui.writeLine(line)
                }
                if state.active {
                    tui.drawPrompt(
                        prompt: self.configuration.prompt,
                        buffer: state.buffer,
                        cursorPos: state.cursor
                    )
                }
                fflush(stdout)
                return
            }
            if state.active {
                fputs("\r\u{001B}[K", stdout)
            }
            for line in lines {
                fputs(line, stdout)
                fputs("\n", stdout)
            }
            if state.active {
                fputs("\(self.configuration.prompt)\(state.buffer)", stdout)
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

        self.activateTUIIfPossible()
        defer { self.deactivateTUI() }

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

    private func activateTUIIfPossible() {
        guard self.configuration.useTUI else { return }
        let tui = TerminalUI()
        self.outputQueue.sync {
            if tui.enter() {
                self.tui = tui
            }
        }
        guard self.tui != nil else { return }
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: self.outputQueue)
        source.setEventHandler { [weak self] in
            guard let self, let tui = self.tui else { return }
            tui.handleResize()
            let state = self.snapshotPromptState()
            if state.active {
                tui.drawPrompt(
                    prompt: self.configuration.prompt,
                    buffer: state.buffer,
                    cursorPos: state.cursor
                )
                fflush(stdout)
            }
        }
        source.resume()
        self.winchSource = source
    }

    private func deactivateTUI() {
        self.winchSource?.cancel()
        self.winchSource = nil
        guard let tui = self.tui else { return }
        self.outputQueue.sync {
            tui.leave()
        }
        self.tui = nil
    }

    func requestStop(reason: String? = nil) {
        guard !self.pendingShutdown else { return }
        self.pendingShutdown = true
        if let reason {
            self.printStatus("Stopping: \(reason)")
        }
        self.keepRunning = false
        self.periodicScheduler.removeAll()
        self.clearCommandQueue()
        self.cleanupStreams()
    }

    func report(error: Error) {
        let color = self.colorPalette.error
        self.emitLine("\(color)Error: \(error.localizedDescription)\(ColorPalette.reset)")
    }

    private func readUserInput() throws -> String {
        _ = self.outputQueue.sync {
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
        let pollInterval: TimeInterval = 0.1

        // Set terminal to raw mode
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~(UInt(ECHO | ICANON))
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        }

        self.renderPromptLine(buffer: buffer, cursorPos: cursorPos, prompt: prompt)

        var escapeSequence: [UInt8] = []

        while true {
            if !self.keepRunning || self.pendingShutdown {
                return ""
            }

            guard let char = try self.readChar(timeout: pollInterval) else {
                continue
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
                            cursorPos += 1
                            self.moveCursorRelative(by: 1, buffer: buffer, cursor: cursorPos)
                        }
                    case 68: // Left arrow
                        if cursorPos > 0 {
                            cursorPos -= 1
                            self.moveCursorRelative(by: -1, buffer: buffer, cursor: cursorPos)
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
                self.commitPromptLine()
                return buffer
            }

            if char == 3 { // Ctrl-C
                self.emitLine("^C")
                self.requestStop(reason: "Interrupted")
                return ""
            }

            if char == 4 { // Ctrl-D (EOF)
                if buffer.isEmpty {
                    throw SimpleReadLineError.eof
                }
                continue
            }

            if char == 9 { // Tab – complete meta commands
                self.completeMetaCommand(buffer: &buffer, cursorPos: &cursorPos, prompt: prompt)
                continue
            }

            // Regular character
            if char >= 32 && char < 127 {
                let charStr = String(UnicodeScalar(char))
                if cursorPos == buffer.count {
                    buffer.append(charStr)
                    cursorPos += 1
                    self.appendCharToPromptLine(charStr, buffer: buffer, cursor: cursorPos)
                } else {
                    let index = buffer.index(buffer.startIndex, offsetBy: cursorPos)
                    buffer.insert(contentsOf: charStr, at: index)
                    cursorPos += 1
                    self.redrawLine(buffer: buffer, cursorPos: cursorPos, prompt: prompt)
                }
            }
        }
    }

    /// Tab completion for meta commands. Only the leading `:` keyword is
    /// completed (we have no argument vocabulary): a single match is filled in
    /// with a trailing space, several matches extend the shared prefix, and an
    /// ambiguous prefix prints the candidates.
    private func completeMetaCommand(buffer: inout String, cursorPos: inout Int, prompt: String) {
        guard cursorPos == buffer.count, buffer.hasPrefix(":"), !buffer.contains(" ") else { return }

        let matches = MetaCommand.completions(for: buffer)
        guard !matches.isEmpty else { return }

        if matches.count == 1 {
            self.replaceLineBuffer(&buffer, &cursorPos, with: matches[0] + " ", prompt: prompt)
            return
        }

        let shared = Self.longestCommonPrefix(of: matches)
        if shared.count > buffer.count {
            self.replaceLineBuffer(&buffer, &cursorPos, with: shared, prompt: prompt)
        } else {
            self.emitLine(matches.joined(separator: "   "))
        }
    }

    private static func longestCommonPrefix(of strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for string in strings.dropFirst() {
            while !string.hasPrefix(prefix) {
                prefix.removeLast()
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    private func readChar(timeout: TimeInterval) throws -> UInt8? {
        let timeoutMs = Int32(timeout * 1000)
        var readFD = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let result = poll(&readFD, 1, timeoutMs)

        if result == 0 {
            return nil
        }
        if result < 0 {
            if errno == EINTR {
                return nil
            }
            throw SimpleReadLineError.eof
        }

        var char: UInt8 = 0
        let bytesRead = read(STDIN_FILENO, &char, 1)
        if bytesRead > 0 {
            return char
        }
        if bytesRead == 0 {
            throw SimpleReadLineError.eof
        }
        if errno == EINTR {
            return nil
        }
        throw SimpleReadLineError.eof
    }

    private func replaceLineBuffer(_ buffer: inout String, _ cursorPos: inout Int, with newContent: String, prompt: String) {
        buffer = newContent
        cursorPos = newContent.count
        self.redrawLine(buffer: buffer, cursorPos: cursorPos, prompt: prompt)
    }

    private func renderPromptLine(buffer: String, cursorPos: Int, prompt: String) {
        self.outputQueue.sync {
            self.updateActiveInputLocked(buffer: buffer, cursor: cursorPos)
            self.drawPromptLocked(buffer: buffer, cursorPos: cursorPos, prompt: prompt, fullRedraw: false)
        }
    }

    private func redrawLine(buffer: String, cursorPos: Int, prompt: String) {
        self.outputQueue.sync {
            self.updateActiveInputLocked(buffer: buffer, cursor: cursorPos)
            self.drawPromptLocked(buffer: buffer, cursorPos: cursorPos, prompt: prompt, fullRedraw: true)
        }
    }

    private func appendCharToPromptLine(_ charStr: String, buffer: String, cursor: Int) {
        self.outputQueue.sync {
            self.updateActiveInputLocked(buffer: buffer, cursor: cursor)
            fputs(charStr, stdout)
            fflush(stdout)
        }
    }

    private func moveCursorRelative(by delta: Int, buffer: String, cursor: Int) {
        guard delta != 0 else { return }
        self.outputQueue.sync {
            self.updateActiveInputLocked(buffer: buffer, cursor: cursor)
            let seq = delta > 0 ? "\u{001B}[\(delta)C" : "\u{001B}[\(-delta)D"
            fputs(seq, stdout)
            fflush(stdout)
        }
    }

    /// State update + stdout write must be atomic w.r.t. emitLines, otherwise
    /// an asynchronous log can fire mid-keystroke and redraw with stale buffer.
    /// All callers run inside `outputQueue.sync`, so the prompt-state queue is
    /// the only thing we need to gate here.
    private func updateActiveInputLocked(buffer: String, cursor: Int) {
        self.promptStateQueue.sync(flags: .barrier) {
            self.activeInputBuffer = buffer
            self.activeCursorPos = cursor
        }
    }

    private func drawPromptLocked(buffer: String, cursorPos: Int, prompt: String, fullRedraw: Bool) {
        if let tui = self.tui, tui.enabled {
            tui.drawPrompt(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
            fflush(stdout)
            return
        }
        if fullRedraw {
            fputs("\r\u{001B}[K", stdout)
        }
        fputs(prompt, stdout)
        fputs(buffer, stdout)
        let distanceFromEnd = buffer.count - cursorPos
        if distanceFromEnd > 0 {
            fputs("\u{001B}[\(distanceFromEnd)D", stdout)
        }
        fflush(stdout)
    }

    private func commitPromptLine() {
        self.outputQueue.sync {
            if let tui = self.tui, tui.enabled {
                // Cantalk's pattern: blank the prompt on Enter and let
                // printOutgoing render the actual command into the scroll area.
                tui.drawPrompt(prompt: self.configuration.prompt, buffer: "", cursorPos: 0)
                fflush(stdout)
                return
            }
            fputs("\n", stdout)
            fflush(stdout)
        }
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
        guard !self.streamsScheduledOnRunLoop else { return }
        inputStream.delegate = self
        outputStream.delegate = self
        let runLoop = RunLoop.main
        inputStream.schedule(in: runLoop, forMode: .common)
        inputStream.open()
        outputStream.schedule(in: runLoop, forMode: .common)
        outputStream.open()
        self.streamsScheduledOnRunLoop = true
    }

    private func cleanupStreams() {

        guard let inputStream, let outputStream else { return }
        inputStream.close()
        outputStream.close()
        if self.streamsScheduledOnRunLoop {
            inputStream.remove(from: .main, forMode: .common)
            outputStream.remove(from: .main, forMode: .common)
            self.streamsScheduledOnRunLoop = false
        }
        self.inputStream = nil
        self.outputStream = nil
        self.pendingWriteBuffer.removeAll()
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
            if !self.keepRunning {
                break
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
            self.enqueueCommand(trimmed, interactive: true)
        }

        self.periodicScheduler.removeAll()
        self.clearCommandQueue()
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
                self.outputQueue.sync {
                    if let tui = self.tui, tui.enabled {
                        tui.clearScrollArea()
                        let state = self.snapshotPromptState()
                        tui.drawPrompt(
                            prompt: self.configuration.prompt,
                            buffer: state.buffer,
                            cursorPos: state.cursor
                        )
                    } else {
                        fputs("\u{001B}[2J\u{001B}[H", stdout)
                    }
                    fflush(stdout)
                }
            case .analyzer(let toggle):
                if let toggle {
                    self.annotationEnabled = toggle
                } else {
                    self.annotationEnabled.toggle()
                }
                let state = self.annotationEnabled ? "enabled" : "disabled"
                self.printStatus("Analyzer \(state).")
            case .log(let action):
                self.handleLogCommand(action)
            case .every(let arguments):
                self.handlePeriodicCommand(arguments)
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
        :log [path|off]    Start/stop logging or show status
        :every             List active periodic tasks
        :every <ival> <cmd> Send <cmd> repeatedly (e.g. :every 2s 0902)
        :every off [id]    Stop one or all periodic tasks
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

    private func handleLogCommand(_ action: MetaCommand.LogAction) {
        switch action {
            case .status:
                if let logger = self.communicationLogger {
                    self.printStatus("Logging to \(logger.url.path)")
                } else {
                    self.printStatus("Logging is off.")
                }
            case .start(let path):
                let expandedPath = (path as NSString).expandingTildeInPath
                let url = URL(fileURLWithPath: expandedPath).standardizedFileURL
                self.communicationLogger = CommunicationLogger(url: url)
                self.printStatus("Logging to \(url.path)")
            case .stop:
                self.communicationLogger = nil
                self.printStatus("Logging stopped.")
        }
    }

    /// Queue a command for transmission. The ELM link is half-duplex: only one
    /// command may be in flight at a time, so commands are serialized and the
    /// next one is released only once the adapter's `>` prompt confirms the
    /// previous response is complete (see `notePromptReceived`). A watchdog
    /// keeps the pump alive should a prompt never arrive.
    private func enqueueCommand(_ line: String, interactive: Bool) {
        if interactive {
            self.activityLock.lock()
            self.lastInteractiveSend = Date()
            self.activityLock.unlock()
        }

        self.commandLock.lock()
        // Coalesce periodic ticks: never stack a second copy of the same
        // request on the bus while an earlier one is still queued or in flight.
        if !interactive,
           self.inFlightCommand == line || self.commandQueue.contains(where: { $0.command == line }) {
            self.commandLock.unlock()
            return
        }
        self.commandQueue.append((command: line, interactive: interactive))
        self.commandLock.unlock()

        self.pumpNextCommand()
    }

    private func pumpNextCommand() {
        self.commandLock.lock()
        guard self.inFlightCommand == nil, !self.commandQueue.isEmpty else {
            self.commandLock.unlock()
            return
        }
        guard !self.pendingShutdown, self.outputStream?.streamStatus == .open else {
            self.commandQueue.removeAll()
            self.commandLock.unlock()
            return
        }
        let next = self.commandQueue.removeFirst()
        self.inFlightCommand = next.command
        self.startCommandWatchdogLocked()
        self.commandLock.unlock()

        self.writeCommand(next.command)
    }

    /// Called when the adapter emits its `>` prompt, signalling that the
    /// current command's response is complete and the next may be released.
    private func notePromptReceived() {
        self.commandLock.lock()
        let wasInFlight = self.inFlightCommand != nil
        self.inFlightCommand = nil
        self.cancelCommandWatchdogLocked()
        self.commandLock.unlock()
        guard wasInFlight else { return }
        self.pumpNextCommand()
    }

    private func clearCommandQueue() {
        self.commandLock.lock()
        self.commandQueue.removeAll()
        self.inFlightCommand = nil
        self.cancelCommandWatchdogLocked()
        self.commandLock.unlock()
    }

    /// Drop queued periodic commands so a stopped task can't fire once more.
    private func purgePeriodicCommands() {
        self.commandLock.lock()
        self.commandQueue.removeAll { !$0.interactive }
        self.commandLock.unlock()
    }

    private func startCommandWatchdogLocked() {
        self.cancelCommandWatchdogLocked()
        let timer = DispatchSource.makeTimerSource(queue: self.commandWatchdogQueue)
        timer.schedule(deadline: .now() + Self.commandWatchdogTimeout)
        timer.setEventHandler { [weak self] in
            self?.handleCommandWatchdog()
        }
        self.commandWatchdog = timer
        timer.resume()
    }

    private func cancelCommandWatchdogLocked() {
        self.commandWatchdog?.cancel()
        self.commandWatchdog = nil
    }

    private func handleCommandWatchdog() {
        self.commandLock.lock()
        self.inFlightCommand = nil
        self.cancelCommandWatchdogLocked()
        self.commandLock.unlock()
        self.pumpNextCommand()
    }

    private func writeCommand(_ line: String) {
        guard !self.pendingShutdown, self.outputStream?.streamStatus == .open else { return }

        self.echoLock.lock()
        self.lastSentCommand = line
        self.echoLock.unlock()

        let payload = line.appendingTerminator(self.configuration.terminator.bytes)
        self.printOutgoing(line)
        self.communicationLogger?.log(direction: .tx, message: line)
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

    private func mayFirePeriodicCommand() -> Bool {
        guard self.keepRunning,
              !self.pendingShutdown,
              self.outputStream?.streamStatus == .open else { return false }
        self.activityLock.lock()
        let last = self.lastInteractiveSend
        self.activityLock.unlock()
        return Date().timeIntervalSince(last) >= Self.periodicInteractiveGrace
    }

    private func handlePeriodicCommand(_ arguments: [String]) {

        guard let first = arguments.first else {
            self.printActivePeriodicTasks()
            return
        }

        let keyword = first.lowercased()
        if keyword == "off" || keyword == "stop" {
            guard let idArgument = arguments.dropFirst().first else {
                self.periodicScheduler.removeAll()
                self.purgePeriodicCommands()
                self.printStatus("Stopped all periodic tasks.")
                return
            }
            guard let id = Int(idArgument) else {
                self.emitError("Invalid task id: \(idArgument)")
                return
            }
            if self.periodicScheduler.remove(id: id) {
                self.printStatus("Stopped periodic task #\(id).")
            } else {
                self.printStatus("No periodic task #\(id).")
            }
            return
        }

        guard let interval = PeriodicScheduler.parseInterval(first) else {
            self.emitError("Invalid interval '\(first)'. Use e.g. 2s, 500ms, 1m.")
            return
        }
        guard interval >= PeriodicScheduler.minimumInterval else {
            self.emitError("Interval too short (minimum \(PeriodicScheduler.describe(PeriodicScheduler.minimumInterval))).")
            return
        }
        let command = arguments.dropFirst().joined(separator: " ").trimmed
        guard !command.isEmpty else {
            self.emitError("Provide a command to send, e.g. :every 2s 0902")
            return
        }

        let entry = self.periodicScheduler.add(interval: interval, command: command)
        self.printStatus("Periodic task #\(entry.id): sending '\(command)' every \(PeriodicScheduler.describe(interval)).")
    }

    private func printActivePeriodicTasks() {
        let entries = self.periodicScheduler.activeEntries
        guard !entries.isEmpty else {
            self.printStatus("No active periodic tasks.")
            return
        }
        let lines = entries.map { entry in
            "[\(entry.id)] every \(PeriodicScheduler.describe(entry.interval))  →  \(entry.command)"
        }
        self.emitLines(lines)
    }

    private func emitError(_ message: String) {
        self.emitLine("\(self.colorPalette.error)\(message)\(ColorPalette.reset)")
    }

    private func flushPendingWritesSafely() {
        do {
            try self.flushPendingWrites()
        } catch {
            self.requestStop(reason: "Write error: \(error.localizedDescription)")
        }
    }

    private func flushPendingWrites() throws {

        self.transmitLock.lock()
        defer { self.transmitLock.unlock() }
        guard !self.pendingShutdown,
              let outputStream,
              outputStream.streamStatus == .open else {
            self.pendingWriteBuffer.removeAll()
            return
        }

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
        var sawPrompt = false

        while !self.incomingBuffer.isEmpty {
            // The ELM327 prompt indicates end of a response. Swallow all leading prompt characters.
            while !self.incomingBuffer.isEmpty && self.incomingBuffer.first == promptByte {
                self.incomingBuffer.removeFirst()
                sawPrompt = true
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

        // Releasing the next queued command only after the prompt keeps the
        // half-duplex link clean and lets each response be fully processed.
        if sawPrompt {
            self.notePromptReceived()
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
        self.communicationLogger?.log(direction: .rx, message: trimmed)

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

// MARK: - Helpers

/// Bottom-anchored TUI: pins a 3-row prompt strip (top ruler, input line,
/// bottom ruler) to the last rows while a DECSTBM scroll region above it
/// receives all log output. Mirrors cantalk's approach — log lines are
/// printed at the bottom of the region so the terminal scrolls them up
/// naturally, which also feeds the host terminal's own scrollback.
/// All writes must be funnelled through the controller's output queue.
final class TerminalUI {

    private(set) var rows: Int = 24
    private(set) var cols: Int = 80
    /// 3 rows reserved at the bottom: top ruler, input line, bottom ruler.
    let promptHeight: Int = 3
    private(set) var enabled: Bool = false
    private let dim = "\u{001B}[2m"
    private let cyan = "\u{001B}[36m"
    private let bold = "\u{001B}[1m"
    private let reset = "\u{001B}[0m"

    /// Try to enter bottom-anchored mode. Returns false if stdin/stdout aren't
    /// TTYs or TERM is missing/dumb — caller should keep the plain REPL.
    @discardableResult
    func enter() -> Bool {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return false }
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        if term.isEmpty || term == "dumb" { return false }

        self.refreshSize()
        fputs("\u{001B}[?25l", stdout)
        self.installScrollRegion()
        // Park the cursor at the bottom of the scroll region so the first
        // writeLine accumulates downward before scrolling kicks in.
        fputs("\u{001B}[\(self.scrollBottom());1H", stdout)
        self.drawRulersInternal(prompt: "", buffer: "", cursorPos: 0)
        fputs("\u{001B}[?25h", stdout)
        fflush(stdout)
        self.enabled = true
        return true
    }

    func leave() {
        guard self.enabled else { return }
        // Reset DECSTBM, drop a fresh line below the transcript so the user's
        // shell prompt doesn't overwrite our last output.
        fputs("\u{001B}[r", stdout)
        fputs("\u{001B}[\(max(1, self.rows - self.promptHeight + 1));1H", stdout)
        fputs("\u{001B}[J", stdout)
        fputs("\u{001B}[?25h", stdout)
        fflush(stdout)
        self.enabled = false
    }

    func handleResize() {
        guard self.enabled else { return }
        self.refreshSize()
        self.installScrollRegion()
        self.drawRulersInternal(prompt: "", buffer: "", cursorPos: 0)
        fflush(stdout)
    }

    /// Paint the two horizontal rulers framing the input row.
    private func drawRulersInternal(prompt: String, buffer: String, cursorPos: Int) {
        let topRow = self.rows - 2
        let bottomRow = self.rows
        fputs("\u{001B}[\(topRow);1H\u{001B}[2K\(self.ruleLine(self.topSegments(prompt: prompt, buffer: buffer, cursorPos: cursorPos)))", stdout)
        fputs("\u{001B}[\(bottomRow);1H\u{001B}[2K\(self.ruleLine(self.hintSegments()))", stdout)
    }

    func writeLine(_ line: String) {
        guard self.enabled else {
            fputs(line, stdout)
            fputs("\n", stdout)
            return
        }
        let bottom = self.scrollBottom()
        // DECSC (ESC 7) survives DECSTBM better than CSI cursor save (CSI s).
        fputs("\u{001B}[?25l\u{001B}\u{0037}", stdout)
        for fragment in line.split(separator: "\n", omittingEmptySubsequences: false) {
            fputs("\u{001B}[\(bottom);1H", stdout)
            fputs(Self.clippedVisible(String(fragment), to: self.cols), stdout)
            // \n at the bottom row of the scroll region scrolls the region
            // up by one without disturbing the prompt strip below it.
            fputs("\n", stdout)
        }
        fputs("\u{001B}\u{0038}\u{001B}[?25h", stdout)
    }

    func drawPrompt(prompt: String, buffer: String, cursorPos: Int) {
        guard self.enabled else { return }
        let inputRow = max(1, self.rows - 1)
        let promptLen = Self.visibleLength(of: prompt)
        let col = max(1, 1 + promptLen + cursorPos)
        fputs("\u{001B}[?25l", stdout)
        self.drawRulersInternal(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
        fputs("\u{001B}[\(inputRow);1H\u{001B}[2K", stdout)
        fputs(prompt, stdout)
        fputs(buffer, stdout)
        fputs("\u{001B}[\(inputRow);\(col)H", stdout)
        fputs("\u{001B}[?25h", stdout)
    }

    func clearScrollArea() {
        guard self.enabled else { return }
        let bottom = self.scrollBottom()
        fputs("\u{001B}[?25l", stdout)
        for row in 1...bottom {
            fputs("\u{001B}[\(row);1H\u{001B}[2K", stdout)
        }
        fputs("\u{001B}[\(bottom);1H", stdout)
        fputs("\u{001B}[?25h", stdout)
    }

    private func scrollBottom() -> Int {
        max(1, self.rows - self.promptHeight)
    }

    private func installScrollRegion() {
        let bottom = self.scrollBottom()
        // Clear the scroll area so leftover content from before we set DECSTBM
        // doesn't end up frozen above the new region.
        for row in 1...bottom {
            fputs("\u{001B}[\(row);1H\u{001B}[2K", stdout)
        }
        fputs("\u{001B}[1;\(bottom)r", stdout)
    }

    private func refreshSize() {
        guard let (rows, cols) = Self.queryWindowSize() else { return }
        self.rows = max(self.promptHeight + 2, rows)
        self.cols = max(20, cols)
    }

    private func ruleLine(_ segments: [String]) -> String {
        let separator = "\(self.dim) · \(self.reset)"
        let body = "  " + segments.joined(separator: separator) + "  "
        let visible = Self.visibleLength(of: body)
        let targetWidth = max(1, self.cols)
        let prefix = "\(self.dim)──\(self.reset)"
        if visible + 2 >= targetWidth {
            return Self.clippedVisible(prefix + body + self.reset, to: targetWidth)
        }
        let right = max(0, targetWidth - visible - 2)
        let line = "\(prefix)\(body)\(self.dim)\(String(repeating: "─", count: right))\(self.reset)"
        return Self.clippedVisible(line, to: targetWidth)
    }

    private func topSegments(prompt: String, buffer: String, cursorPos: Int) -> [String] {
        let visiblePrompt = Self.stripANSI(from: prompt)
        let cursor = "\(cursorPos)/\(buffer.count)"
        return [
            "\(self.bold)ELMterm\(self.reset)",
            "\(self.dim)prompt \(visiblePrompt.isEmpty ? ">" : visiblePrompt.trimmed)\(self.reset)",
            "\(self.dim)cursor \(cursor)\(self.reset)",
        ]
    }

    private func hintSegments() -> [String] {
        [
            "\(self.cyan):help\(self.reset)",
            "\(self.cyan)⇥\(self.reset)\(self.dim) complete\(self.reset)",
            "\(self.cyan)↑↓\(self.reset)\(self.dim) history\(self.reset)",
            "\(self.cyan)Ctrl-C\(self.reset)\(self.dim) exit\(self.reset)",
        ]
    }

    /// Ask the kernel for the window size via TIOCGWINSZ. Routed through a C
    /// shim because ioctl(2) is variadic and the Apple arm64 ABI uses
    /// different calling conventions for variadic vs. non-variadic functions
    /// — calling it via `@_silgen_name` produces garbage on arm64.
    private static func queryWindowSize() -> (Int, Int)? {
        // Try stdout, stderr, stdin in turn — any of them might be the TTY.
        for fd in [STDOUT_FILENO, STDERR_FILENO, STDIN_FILENO] {
            var rows: UInt16 = 0
            var cols: UInt16 = 0
            if elmterm_get_winsize(fd, &rows, &cols) == 0, rows > 0, cols > 0 {
                return (Int(rows), Int(cols))
            }
        }
        return nil
    }

    /// Visible length, ignoring CSI escape sequences so coloured prompts
    /// position the cursor correctly.
    private static func visibleLength(of text: String) -> Int {
        var result = 0
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{001B}" {
                Self.consumeANSISequence(from: &iterator)
            } else {
                result += 1
            }
        }
        return result
    }

    private static func stripANSI(from text: String) -> String {
        var scalars: [UnicodeScalar] = []
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{001B}" {
                Self.consumeANSISequence(from: &iterator)
            } else {
                scalars.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func clippedVisible(_ text: String, to maxVisibleLength: Int) -> String {
        guard maxVisibleLength > 0 else { return "" }
        var result = String()
        var visible = 0
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{001B}" {
                result.unicodeScalars.append(scalar)
                Self.consumeANSISequence(from: &iterator) { result.unicodeScalars.append($0) }
                continue
            }
            guard visible < maxVisibleLength else { break }
            result.unicodeScalars.append(scalar)
            visible += 1
        }
        return result
    }

    private static func consumeANSISequence(
        from iterator: inout String.UnicodeScalarView.Iterator,
        append: ((UnicodeScalar) -> Void)? = nil
    ) {
        guard let first = iterator.next() else { return }
        append?(first)
        if first == "[" {
            while let next = iterator.next() {
                append?(next)
                if (0x40...0x7E).contains(next.value) {
                    break
                }
            }
        }
    }
}

extension TerminalUI: @unchecked Sendable {}

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

extension SignalForwarder: @unchecked Sendable {}

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

// MARK: - Communication Logger

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

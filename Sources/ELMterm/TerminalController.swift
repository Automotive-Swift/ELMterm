import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

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
            self.finalizeReassembly()
            self.notePromptReceived()
        }
    }

    /// The prompt marks the end of a response, which is the only completion
    /// signal legacy (non-CAN) multi-line replies carry — flush them now.
    private func finalizeReassembly() {
        guard self.annotationEnabled, let analyzer = self.analyzer else { return }
        for annotation in analyzer.finalizeReassembly() {
            self.printAnnotation(annotation, direction: .incoming)
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

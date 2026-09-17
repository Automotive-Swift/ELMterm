import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

@main
struct ELMterm: AsyncParsableCommand {

    static let configuration: CommandConfiguration = .init(
        commandName: "ELMterm",
        abstract: "A transport-agnostic terminal for ELM-compatible OBD-II adapters.",
        version: "1.2.0"
    )

    @Argument(help: "CornucopiaStreams URL, e.g. tcp://192.168.0.10:35000 or tty:///dev/tty.usbserial-XXXX.")
    var urlString: String

    @Option(name: [.customShort("t"), .long], help: "Connection timeout in seconds.")
    var timeout: Double = 12

    @Option(name: .long, help: "Maximum seconds to wait for an adapter response.")
    var responseTimeout: Double = 5

    @Flag(name: .long, help: "Disable ANSI colors.")
    var noColor: Bool = false

    @Option(name: [.customShort("p"), .long], help: "Prompt shown in the REPL.")
    var prompt: String = "> "

    @Option(name: .long, help: "Terminator appended to every command (cr, lf, crlf, none, hex:0d0a, literal text).")
    var terminator: CommandTerminator = .carriageReturn

    @Option(name: .long, help: "Persist history at the provided path (default: ~/.elmterm.history when omitted).")
    var history: String?

    @Option(name: .long, help: "Maximum number of commands kept in history (default: 500).")
    var historyDepth: Int?

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

    @Option(name: .customLong("init"), help: "Send commands from this file right after connecting (one per line, # for comments).")
    var initFile: String?

    @Option(name: .long, help: "Send a command, then exit once its response arrives. Repeatable; implies non-interactive mode.")
    var exec: [String] = []

    mutating func validate() throws {
        guard self.timeout.isFinite, self.timeout > 0, self.timeout <= 86400 else {
            throw ValidationError("--timeout must be greater than zero and at most 86400 seconds.")
        }
        guard self.responseTimeout.isFinite, self.responseTimeout > 0, self.responseTimeout <= 86400 else {
            throw ValidationError("--response-timeout must be greater than zero and at most 86400 seconds.")
        }
        if let historyDepth = self.historyDepth, historyDepth < 0 {
            throw ValidationError("--history-depth must be zero or greater.")
        }
        guard self.exec.allSatisfy({ !$0.trimmed.isEmpty && !$0.contains("\r") && !$0.contains("\n") }) else {
            throw ValidationError("Each --exec must contain one non-empty command without line breaks.")
        }
    }

    mutating func run() async throws {

        guard let endpoint = URL(string: self.urlString) else {
            throw ValidationError("Invalid URL: \(self.urlString)")
        }

        signal(SIGPIPE, SIG_IGN)

        let preferences = self.loadPreferences()
        let effectiveTheme = self.theme ?? preferences.theme ?? .light
        // Colour only when stdout is a real terminal, so piped or redirected
        // output stays clean text.
        let environment = ProcessInfo.processInfo.environment
        let useColor = isatty(STDOUT_FILENO) != 0 && !self.noColor
            && (environment["NO_COLOR"] ?? "").isEmpty && environment["TERM"] != "dumb"
        let palette = useColor ? ColorPalette.palette(for: effectiveTheme) : .plain
        let historyURL = Self.makeHistoryURL(from: self.history ?? preferences.historyPath)
        let historyDepth = self.historyDepth ?? preferences.historyDepth ?? 500
        guard historyDepth >= 0 else {
            throw ValidationError("Configured historyDepth must be zero or greater.")
        }

        let logFileURL: URL? = self.log.map { path in
            URL(fileURLWithPath: Self.expandPath(path)).standardizedFileURL
        }

        let initCommands = try self.initFile.map { try Self.loadCommandFile($0) } ?? []
        let isOneShot = !self.exec.isEmpty

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
            useTUI: !self.noTui && !isOneShot,
            initCommands: initCommands,
            responseTimeout: self.responseTimeout
        )

        let controller = TerminalController(configuration: configuration, analyzer: self.plain ? nil : OBD2Analyzer())
        let signalHandler = SignalForwarder {
            controller.requestStop(reason: "Interrupted")
        }
        signalHandler.activate()
        defer { withExtendedLifetime(signalHandler) {} }
        let connectTimeout = self.timeout
        let execCommands = self.exec

        // The line editor performs blocking reads. Keep it off the main queue,
        // which the async runtime uses to deliver Foundation stream events.
        let replTask = Task.detached(priority: .userInitiated) {
            if isOneShot {
                try await controller.runBatch(url: endpoint, timeout: connectTimeout, commands: execCommands)
            } else {
                try await controller.start(url: endpoint, timeout: connectTimeout)
            }
        }

        switch await replTask.result {
            case .success:
                return
            case .failure(let error):
                throw error
        }
    }

    /// Read a command file: one command per line, blank lines and `#` comments
    /// ignored. Used by `--init`.
    private static func loadCommandFile(_ path: String) throws -> [String] {
        let expanded = Self.expandPath(path)
        let content: String
        do {
            content = try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw ValidationError("Unable to read command file \(expanded): \(error.localizedDescription)")
        }
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
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

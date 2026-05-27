import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

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

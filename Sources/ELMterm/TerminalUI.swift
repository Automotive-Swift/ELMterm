import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

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

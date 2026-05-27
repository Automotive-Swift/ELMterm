# Repository Guidelines

## Project Structure & Module Organization
SwiftPM drives the layout: `Package.swift` defines the executable target plus `CornucopiaStreams` and `swift-argument-parser`. Runtime code lives in `Sources/ELMterm/`, one type per file: `ELMterm.swift` (the `@main` CLI entry point), `TerminalController.swift` (REPL, line editor, half-duplex command pump, stream handling), `OBD2Analyzer.swift` (OBD-II/UDS/KWP annotation, ISO-TP and legacy multi-line reassembly), `TerminalUI.swift` (bottom-anchored TUI), `PeriodicScheduler.swift` (timer-driven `:every` commands), `MetaCommand.swift`, `Configuration.swift`, `CommunicationLogger.swift`, `Extensions.swift`, and `Support.swift`. A small C shim in `Sources/CELMtermShim/` exposes `TIOCGWINSZ`. Build products land under `.build/`; keep it untracked. Keep new types in their own file and mirror folders under `Sources/` or `Tests/` so protocol decoders, transports, and UI helpers stay isolated.

## Build, Test, and Development Commands
- `swift build` — debug build; binary at `.build/debug/ELMterm`.
- `swift build -c release` — optimized artifact for in-vehicle validation.
- `swift run ELMterm tty:///dev/cu.usbserial-XXXX` — launch against serial (swap `tcp://` for network bridges).
- `swift test` — runs XCTest once suites exist; add `--enable-code-coverage` for analyzer-heavy changes.
- `swift package resolve` — update dependencies after touching `Package.swift`.

## Coding Style & Naming Conventions
Follow Swift 6 defaults: four-space indentation, same-line braces, `camelCase` members, `PascalCase` types. Mirror the current file by marking helpers `private`, declaring `final` where inheritance adds no value, and letting exhaustive `switch` blocks fail loudly rather than using `default`. Split reusable helpers into focused extensions (e.g., `Data+Hex.swift`) and document non-obvious logic with succinct `///` comments.

## Testing Guidelines
Add `Tests/ELMtermTests` with XCTest. Name files after the type under test (e.g., `OBD2AnalyzerTests.swift`) and methods `test_<behavior>_<result>()`. Store long CAN/ISO-TP transcripts under `Tests/Fixtures/` and load them via `Bundle.module`. Aim for branch coverage on new decoders and transports, and assert both success and error paths so annotations stay trustworthy.

## Commit & Pull Request Guidelines
History shows short, imperative summaries (`First version`), so keep subject lines focused (optionally `Analyzer: decode VIN frames`). Run `swift build && swift test` before committing and mention manual repro steps (serial device, mock server) in the body. PRs should state the problem, highlight design choices, attach screenshots or terminal captures for user-visible changes, and link issues (`Fixes #123`). Use draft PRs while validating with hardware.

## Security & Configuration Tips
Never hard-code adapter URLs, VINs, or credentials—pass them via CLI arguments or wrapper scripts. The REPL can persist history at `~/.elmterm.history`, so keep that path in `.gitignore`. When expanding protocol handlers, validate every frame and fail with descriptive `guard` messages; noisy aftermarket adapters routinely emit malformed payloads.

# Release review: 1.2.0

Reviewed on 2026-09-17, starting at e01482d. `git pull --ff-only` was already
current; the working tree was clean. The last source/Homebrew tag was 1.1.0,
while the latest GitHub Release entry was still 1.0.2. No open issues, open PRs,
or workflow runs were returned by GitHub at review time.

## Findings addressed for this release

- **Release blocker for scripting:** `--exec` returned success on missing prompts,
  disconnects, and interrupts. A throwing batch continuation now propagates
  transport failures; a timeout drops the remaining batch. Regression tests run
  the actual executable against a local TCP adapter.
- **Lifecycle:** explicitly stopping the main CFRunLoop could terminate the async
  process before errors reached ArgumentParser. Removed the manual run-loop
  driver and await the terminal task; stream events still arrive through the
  runtime's main queue. Error output is no longer duplicated on stdout.
- **Startup scripts:** splitting a Swift String on LF did not split CRLF grapheme
  clusters; a leading comment could swallow a whole Windows-format script.
  Parse newline components and trim whitespace instead.
- **Usability:** configurable response deadline, program version, standard color
  controls, CLI-over-config history depth, and finite/range-checked intervals.
- **Annotations:** mode-01 PID formatters were applied to other OBD modes with
  different payload layouts. Restrict them to mode 01 and retain fractional RPM.

## Cross-check with related projects

- [python-OBD](https://github.com/brendan-w/python-OBD) provides typed sensor values,
  unit conversion, automatic connection setup, and a larger sensor catalogue.
  Its [adapter implementation](https://github.com/brendan-w/python-OBD/blob/master/obd/elm327.py)
  explicitly handles initialization, timeouts, and prompt completion. For ELMterm,
  reliable batch completion is the immediate priority; named PID queries and
  supported-PID discovery would be useful next additions.
- [ELM327-emulator](https://github.com/Ircama/ELM327-emulator) offers TCP/PTY
  interfaces, multi-ECU scenarios, adjustable delays, and prompt controls. It is
  a good candidate for broader interoperability tests. The new stdlib TCP tests
  cover transport failure paths deterministically; they do not claim full
  compatibility testing against that emulator.

## Follow-up opportunities

1. Add macOS CI for Swift tests and TCP regression tests (no workflow currently
   exists). Exercise the minimum supported Swift toolchain as well as current.
2. Add supported-PID bitmaps, readiness status, and dedicated mode-02 freeze-frame
   decoding; mode 02 remains annotated without invented live-data values.
3. Extend transcript coverage for interleaved ECUs, ISO-TP sequence wraparound,
   truncated DTC payloads, and late prompts after an interactive watchdog timeout.
4. Consolidate stream/analyzer state isolation: the controller still uses
   `@unchecked Sendable` and several locks/queues. This release guards watchdog
   identity but does not claim a complete concurrency audit or migration.
5. Automate version synchronization, GitHub Release creation, and Homebrew
   verification in the release target. Existing `make release` only tags and
   updates the formula; GitHub Releases need a separate publishing step.

## Validation scope

Swift unit tests plus real-process local TCP tests, optimized build, CLI checks,
and Homebrew installation/test. No physical serial adapter or vehicle validation
was performed. Diagnostic ECU replies such as NRCs and NO DATA intentionally do
not cause process failure if the adapter prompt completes the exchange.

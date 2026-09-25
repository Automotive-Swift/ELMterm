# Changelog

## Unreleased

- Annotate requests with the inferred CAN frame the adapter transmits (header, PCI, payload; no padding), based on tracked protocol, header, priority, auto-formatting and extended-address settings. Omitted whenever the protocol is not known to be ISO 15765-4 or the request needs more than one frame.
- Keep tracking adapter state while annotations are toggled off with `:analyzer off`.
- Fix batch commands being released one step early when the adapter prints a prompt on connect (or any other stale `>`), which shifted every response onto the following command and could reorder analyzer state.

## 1.2.0 — 2026-09-17

- Run startup command files with `--init` and one-shot command sequences with repeated `--exec` options.
- Decode stored, pending, and permanent OBD-II trouble codes and UDS ReadDTCInformation records, including status flags and common generic descriptions.
- Decode more mode-01 live-data PIDs into engineering units; retain quarter-RPM precision and avoid applying mode-01 layouts to other services.
- Return a failing exit status for batch response timeouts, interrupted sessions, and premature disconnects. Stop sending remaining batch commands after a timeout.
- Add `--response-timeout` (default: 5 seconds) for slower adapters and protocol searches.
- Correct startup-file parsing for CRLF line endings.
- Add `--version` and `--no-color`; respect `NO_COLOR` and `TERM=dumb`.
- Give explicit `--history-depth` values precedence over configuration and validate timeout, history, batch-command, and periodic-interval inputs.
- Keep redirected status messages on stderr and let the async runtime finish error handling before process exit.
- Add real-process TCP regression tests for successful batches and transport failures.

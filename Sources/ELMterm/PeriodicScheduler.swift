import Foundation

/// Drives commands that should be re-sent at a fixed cadence (e.g. polling
/// `0902` every two seconds). Each registered command gets its own dispatch
/// timer, yet all timers share one serial queue so their sends never overlap
/// on the half-duplex adapter link.
final class PeriodicScheduler {

    struct Entry {
        let id: Int
        let interval: TimeInterval
        let command: String
    }

    static let minimumInterval: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "ELMterm.periodic")
    private let lock = NSLock()
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var entries: [Int: Entry] = [:]
    private var nextID = 1

    private let send: (String) -> Void
    /// Consulted on every tick; a `false` result skips the send so the periodic
    /// stream yields the bus to an in-flight interactive command.
    private let shouldFire: () -> Bool

    init(send: @escaping (String) -> Void, shouldFire: @escaping () -> Bool) {
        self.send = send
        self.shouldFire = shouldFire
    }

    @discardableResult
    func add(interval: TimeInterval, command: String) -> Entry {
        self.lock.lock()
        let id = self.nextID
        self.nextID += 1
        let entry = Entry(id: id, interval: interval, command: command)
        self.entries[id] = entry
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, self.shouldFire() else { return }
            self.send(command)
        }
        self.timers[id] = timer
        self.lock.unlock()
        timer.resume()
        return entry
    }

    @discardableResult
    func remove(id: Int) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let timer = self.timers.removeValue(forKey: id) else { return false }
        timer.cancel()
        self.entries.removeValue(forKey: id)
        return true
    }

    func removeAll() {
        self.lock.lock()
        let cancelled = Array(self.timers.values)
        self.timers.removeAll()
        self.entries.removeAll()
        self.lock.unlock()
        cancelled.forEach { $0.cancel() }
    }

    var activeEntries: [Entry] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries.values.sorted { $0.id < $1.id }
    }

    /// Parse a human interval: `2s`, `500ms`, `1m`, or a bare number (seconds).
    static func parseInterval(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("ms") {
            return Double(trimmed.dropLast(2)).map { $0 / 1000.0 }
        }
        if trimmed.hasSuffix("s") {
            return Double(trimmed.dropLast())
        }
        if trimmed.hasSuffix("m") {
            return Double(trimmed.dropLast()).map { $0 * 60.0 }
        }
        return Double(trimmed)
    }

    static func describe(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return "\(Int((interval * 1000).rounded()))ms"
        }
        if interval == interval.rounded() {
            return "\(Int(interval))s"
        }
        return String(format: "%.1fs", interval)
    }
}

extension PeriodicScheduler: @unchecked Sendable {}

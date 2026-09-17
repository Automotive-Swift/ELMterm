import ArgumentParser
import CELMtermShim
import CornucopiaStreams
import Foundation

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

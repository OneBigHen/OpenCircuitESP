// The signals that end a run early: Ctrl-C (SIGINT), `kill` (SIGTERM) and a closed terminal
// (SIGHUP). Their default action kills the process at once, which could leave a find or buzz
// running on the wearer's wrist (the strap's own stop is not established: ZEPP_PROTOCOL.md §11.4).
// Each one is handled the same way instead: `finish()` sends the stop, then exits with 128 + signal.

import Foundation

enum StopSignals {
    static let all: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    static func reason(_ signal: Int32) -> String {
        switch signal {
        case SIGINT: return "interrupted"
        case SIGTERM: return "terminated (SIGTERM)"
        case SIGHUP: return "hung up (SIGHUP)"
        default: return "signal \(signal)"
        }
    }

    /// The shell convention: 130 for SIGINT, 143 for SIGTERM, 129 for SIGHUP.
    static func exitCode(_ signal: Int32) -> Int32 { 128 + signal }

    /// SIGPIPE ignored (review-223 N2): with stdout piped to a reader that has gone away (a `| tee`
    /// whose terminal closed), a log line printed before the stop would otherwise kill the process
    /// with SIGPIPE, and the find stop would never go out. Ignored, the write just fails and the run
    /// carries on to send the stop. Call once, first thing at startup.
    static func ignoreBrokenPipe() {
        signal(SIGPIPE, SIG_IGN)
    }

    /// Ignores each signal's default action and calls `handler` on the main queue instead. Keep the
    /// returned sources alive for the whole run.
    static func install(_ handler: @escaping (Int32) -> Void) -> [DispatchSourceSignal] {
        all.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { handler(number) }
            source.resume()
            return source
        }
    }
}

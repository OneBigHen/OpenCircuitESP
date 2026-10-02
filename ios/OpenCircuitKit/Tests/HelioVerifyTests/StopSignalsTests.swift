// #221 review S2: only SIGINT was handled, so `kill` or closing the terminal during `--find` killed
// HelioVerify before it sent the stop. All three now reach the same handler (finish()).

import XCTest
@testable import HelioVerify

final class StopSignalsTests: XCTestCase {

    func testExitCodesAndReasons() {
        XCTAssertEqual(StopSignals.all, [SIGINT, SIGTERM, SIGHUP])
        XCTAssertEqual(StopSignals.all.map(StopSignals.exitCode), [130, 143, 129])
        XCTAssertEqual(StopSignals.reason(SIGINT), "interrupted")
        XCTAssertEqual(StopSignals.reason(SIGTERM), "terminated (SIGTERM)")
        XCTAssertEqual(StopSignals.reason(SIGHUP), "hung up (SIGHUP)")
    }

    /// Sends each signal to this test process. Without the handler, SIGTERM or SIGHUP would kill it.
    func testTermHupAndIntReachTheHandlerInsteadOfKillingTheProcess() {
        let expected: [Int32] = [SIGINT, SIGTERM, SIGHUP]
        var previous: [Int32: sigaction] = [:]
        for number in expected {
            var action = sigaction()
            sigaction(number, nil, &action)
            previous[number] = action
        }
        var received = Set<Int32>()
        let sources = StopSignals.install { received.insert($0) }
        defer {
            sources.forEach { $0.cancel() }
            for (number, action) in previous {
                var restore = action
                sigaction(number, &restore, nil)
            }
        }
        // A source registers asynchronously after resume(), and an ignored signal that arrives
        // before that is dropped, so resend until each one is seen.
        let deadline = Date().addingTimeInterval(10)
        while received.count < expected.count, Date() < deadline {
            for number in expected where !received.contains(number) { kill(getpid(), number) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(received, Set(expected))
    }

    /// review-223 N2: a write to a pipe whose reader is gone must fail with EPIPE, not kill the run
    /// before the find stop goes out. (Without `ignoreBrokenPipe()`, this test process would die.)
    func testABrokenPipeFailsTheWriteInsteadOfKillingTheProcess() {
        var previous = sigaction()
        sigaction(SIGPIPE, nil, &previous)
        defer { sigaction(SIGPIPE, &previous, nil) }

        StopSignals.ignoreBrokenPipe()
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        XCTAssertEqual(unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self),
                       unsafeBitCast(SIG_IGN, to: Int.self))

        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        close(fds[0])                      // the reader went away (the terminal behind `| tee` closed)
        defer { close(fds[1]) }
        let line = Array("find device: STOP before exiting\n".utf8)
        let written = line.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        XCTAssertEqual(written, -1)
        XCTAssertEqual(errno, EPIPE)
    }
}

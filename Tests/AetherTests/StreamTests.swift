import Darwin
import Foundation
import Testing
import SwiftTerm

private struct StreamFailure: Error, CustomStringConvertible {
    var description: String
}

/// Captures PTY output so we can tell whether it arrived while the child was still running.
private final class StreamProbe: LocalProcessDelegate, @unchecked Sendable {
    var process: LocalProcess!
    private let lock = NSLock()
    private var firstChunk: Date?
    private var exitDate: Date?
    private var text = ""
    private var finished = false
    var onDone: ((Result<Void, Error>) -> Void)?

    init(queue: DispatchQueue) {
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        lock.lock()
        if firstChunk == nil { firstChunk = Date() }
        text += String(bytes: slice, encoding: .utf8) ?? ""
        let first = firstChunk
        let ended = exitDate
        let body = text
        lock.unlock()
        consider(first: first, ended: ended, text: body)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.lock()
        exitDate = Date()
        let first = firstChunk
        let ended = exitDate
        let body = text
        lock.unlock()
        consider(first: first, ended: ended, text: body)
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }

    func fail(_ message: String) {
        complete(.failure(StreamFailure(description: message)))
    }

    private func consider(first: Date?, ended: Date?, text: String) {
        guard let first, let ended else { return }
        if text.contains("one"), ended.timeIntervalSince(first) >= 0.2 {
            complete(.success(()))
        } else {
            complete(.failure(StreamFailure(description: "output waited for exit (\(ended.timeIntervalSince(first))s): \(text)")))
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        process.terminate()
        onDone?(result)
    }
}

@Test func slowOutputArrivesBeforeTheProcessExits() async throws {
    let queue = DispatchQueue(label: "aether.stream-test")
    let probe = StreamProbe(queue: queue)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        probe.onDone = { result in
            cont.resume(with: result)
        }
        queue.asyncAfter(deadline: .now() + 5) {
            probe.fail("timed out waiting for streamed output")
        }
        probe.process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf 'one\\n'; sleep 0.4; printf 'two\\n'"],
            environment: ["TERM=xterm", "PATH=/bin:/usr/bin", "HOME=/tmp"],
            currentDirectory: "/tmp"
        )
    }
}

import AppKit
import Darwin
import Foundation
import Testing
import SwiftTerm
@testable import AetherKit

private struct StreamFailure: Error, CustomStringConvertible {
    var description: String
}

/// Captures PTY output so we can tell whether it arrived while the child was still running.
private final class StreamProbe: LocalProcessDelegate, @unchecked Sendable {
    var process: LocalProcess!
    private let lock = NSLock()
    private var needleDate: Date?
    private var exitDate: Date?
    private var text = ""
    private var finished = false
    private var events: [(Date, String)] = []
    var needle = "one"
    var minGap: TimeInterval = 0.2
    var onOutput: ((String) -> Void)?
    var onDone: ((Result<Void, Error>) -> Void)?

    init(queue: DispatchQueue) {
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    func snapshot() -> (text: String, events: [(Date, String)], first: Date?, ended: Date?) {
        lock.lock()
        defer { lock.unlock() }
        return (text, events, needleDate, exitDate)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        let piece = String(bytes: slice, encoding: .utf8) ?? ""
        lock.lock()
        text += piece
        if needleDate == nil, text.contains(needle) { needleDate = Date() }
        events.append((Date(), "data:\(piece.debugDescription)"))
        let first = needleDate
        let ended = exitDate
        let body = text
        let callback = onOutput
        lock.unlock()
        callback?(body)
        consider(first: first, ended: ended, text: body)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.lock()
        exitDate = Date()
        events.append((Date(), "exit:\(exitCode as Any)"))
        let first = needleDate
        let ended = exitDate
        let body = text
        lock.unlock()
        consider(first: first, ended: ended, text: body)
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }

    func fail(_ message: String) {
        let snap = snapshot()
        complete(.failure(StreamFailure(description: "\(message) events=\(snap.events.map(\.1)) text=\(snap.text.debugDescription)")))
    }

    private func consider(first: Date?, ended: Date?, text: String) {
        guard let first, let ended else { return }
        let gap = ended.timeIntervalSince(first)
        if text.contains(needle), gap >= minGap {
            complete(.success(()))
        } else {
            complete(.failure(StreamFailure(description: "wanted \(needle) with \(minGap)s gap, got \(gap)s: \(text.debugDescription)")))
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

private func runProbe(
    timeout: TimeInterval = 6,
    needle: String = "one",
    minGap: TimeInterval = 0.2,
    queueLabel: String,
    start: (StreamProbe) -> Void
) async throws {
    let queue = DispatchQueue(label: queueLabel)
    let probe = StreamProbe(queue: queue)
    probe.needle = needle
    probe.minGap = minGap
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        probe.onDone = { result in
            cont.resume(with: result)
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            probe.fail("timed out")
        }
        start(probe)
    }
}

@Test func aShortCommandStillDeliversThenEnds() async throws {
    try await runProbe(timeout: 4, needle: "bye", minGap: 0, queueLabel: "aether.stream-test.short") { probe in
        probe.process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf 'bye\\n'"],
            environment: ["TERM=xterm", "PATH=/bin:/usr/bin", "HOME=/tmp"],
            currentDirectory: "/tmp"
        )
    }
}

@Test func slowOutputArrivesBeforeTheProcessExits() async throws {
    try await runProbe(queueLabel: "aether.stream-test") { probe in
        probe.process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf 'one\\n'; sleep 0.4; printf 'two\\n'"],
            environment: ["TERM=xterm", "PATH=/bin:/usr/bin", "HOME=/tmp"],
            currentDirectory: "/tmp"
        )
    }
}

/// `arp -a` is typed into a live shell. Sending the command through the PTY
/// (DispatchIO.write) is the path the app actually uses.
@Test func aTypedSlowCommandStreamsBeforeItExits() async throws {
    let queue = DispatchQueue(label: "aether.stream-test.typed")
    let probe = StreamProbe(queue: queue)
    probe.needle = "one"
    probe.minGap = 0.25
    var sent = false
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        probe.onDone = { result in
            cont.resume(with: result)
        }
        probe.onOutput = { text in
            guard !sent, text.contains("ready") else { return }
            sent = true
            probe.process.send(data: Array("go\n".utf8)[...])
        }
        queue.asyncAfter(deadline: .now() + 6) {
            probe.fail("typed slow command never streamed")
        }
        probe.process.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf 'ready\\n'; read _; printf 'one\\n'; sleep 0.45; printf 'two\\n'"],
            environment: ["TERM=xterm", "PATH=/bin:/usr/bin:/usr/sbin", "HOME=/tmp"],
            currentDirectory: "/tmp"
        )
    }
}

/// libc line-buffers on a TTY. A program like `arp` uses printf without
/// fflush; if the child is not a TTY, every line sits until exit.
@Test func stdioLinesShowUpBeforeExit() async throws {
    let source = """
    #include <stdio.h>
    #include <unistd.h>
    int main(void) {
        printf("tty=%d\\n", isatty(1));
        for (int i = 0; i < 3; i++) {
            printf("tick%d\\n", i);
            usleep(250000);
        }
        return 0;
    }
    """
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-stdio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cFile = dir.appendingPathComponent("slow.c")
    let binary = dir.appendingPathComponent("slow")
    try source.write(to: cFile, atomically: true, encoding: .utf8)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compile.arguments = [cFile.path, "-o", binary.path]
    try compile.run()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
        throw StreamFailure(description: "cc failed")
    }

    let queue = DispatchQueue(label: "aether.stream-test.stdio")
    let probe = StreamProbe(queue: queue)
    probe.needle = "tick0"
    probe.minGap = 0.4
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        probe.onDone = { result in
            cont.resume(with: result)
        }
        queue.asyncAfter(deadline: .now() + 6) {
            probe.fail("stdio ticks never streamed")
        }
        probe.process.startProcess(
            executable: binary.path,
            args: [],
            environment: ["TERM=xterm", "PATH=/bin:/usr/bin", "HOME=/tmp"],
            currentDirectory: "/tmp"
        )
    }
}

/// Each flushed tick must arrive as its own event, not as one dump at hangup.
@Test func pingRepliesArriveBeforeTheCommandExits() async throws {
    try await runProbe(timeout: 6, needle: "bytes from", minGap: 0.4, queueLabel: "aether.stream-test.ping") { probe in
        probe.process.startProcess(
            executable: "/sbin/ping",
            args: ["-c", "2", "127.0.0.1"],
            environment: ["TERM=xterm", "PATH=/bin:/usr/bin:/sbin", "HOME=/tmp"],
            currentDirectory: "/tmp"
        )
    }
}

@Test func flushedTicksArriveWhileTheCommandIsStillRunning() async throws {
    let queue = DispatchQueue(label: "aether.stream-test.ticks")
    let probe = StreamProbe(queue: queue)
    probe.needle = "tick0"
    probe.minGap = 0.5
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        probe.onDone = { result in
            cont.resume(with: result)
        }
        queue.asyncAfter(deadline: .now() + 6) {
            probe.fail("flushed ticks never streamed")
        }
        probe.process.startProcess(
            executable: "/usr/bin/python3",
            args: ["-c", "import sys,time\nfor i in range(3):\n sys.stdout.write('tick%d\\n'%i)\n sys.stdout.flush()\n time.sleep(0.3)\n"],
            environment: ["TERM=xterm", "PATH=/bin:/usr/bin", "HOME=/tmp", "PYTHONUNBUFFERED=1"],
            currentDirectory: "/tmp"
        )
    }
}

/// The app delivers PTY bytes on the main queue. Custom-queue tests skip that path.
@MainActor
@Test func slowOutputOnTheMainQueueArrivesBeforeExit() async throws {
    let probe = StreamProbe(queue: .main)
    probe.needle = "tick0"
    probe.minGap = 0.4
    var result: Result<Void, Error>?
    probe.onDone = { result = $0 }
    probe.process.startProcess(
        executable: "/usr/bin/python3",
        args: ["-c", "import sys,time\nfor i in range(3):\n sys.stdout.write('tick%d\\n'%i)\n sys.stdout.flush()\n time.sleep(0.3)\n"],
        environment: ["TERM=xterm", "PATH=/bin:/usr/bin", "HOME=/tmp", "PYTHONUNBUFFERED=1"],
        currentDirectory: "/tmp"
    )
    let deadline = Date().addingTimeInterval(6)
    while result == nil, Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    switch result {
    case .success: return
    case .failure(let error): throw error
    case nil: throw StreamFailure(description: "main-queue drain never finished: \(probe.snapshot().text.debugDescription)")
    }
}

/// Same path as a pane: LocalProcessTerminalView on the main queue, then the buffer.
@MainActor
@Test func aPaneBufferShowsSlowOutputBeforeExit() async throws {
    _ = NSApplication.shared
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let chrome = PaneChrome(paneID: "stream", font: font)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = chrome
    window.setFrame(NSRect(x: 0, y: 0, width: 720, height: 420), display: true)
    chrome.frame = window.contentView?.bounds ?? chrome.frame
    chrome.layoutSubtreeIfNeeded()
    var settings = Settings()
    settings.glass = .regular
    settings.focusRest = .blur
    chrome.setFocused(true, settings: settings)

    chrome.terminal.startProcess(
        executable: "/usr/bin/python3",
        args: ["-c", "import sys,time\nfor i in range(3):\n sys.stdout.write('tick%d\\n'%i)\n sys.stdout.flush()\n time.sleep(0.35)\n"],
        environment: ["TERM=xterm", "PATH=/bin:/usr/bin", "HOME=/tmp", "PYTHONUNBUFFERED=1"],
        currentDirectory: "/tmp"
    )

    var sawTickWhileRunning = false
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        try await Task.sleep(for: .milliseconds(30))
        let text = String(data: chrome.terminal.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
        if text.contains("tick0"), chrome.terminal.process.running {
            sawTickWhileRunning = true
            break
        }
        if !chrome.terminal.process.running { break }
    }
    let text = String(data: chrome.terminal.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
    chrome.terminal.terminate()
    guard sawTickWhileRunning else {
        throw StreamFailure(description: "pane buffer waited for exit: \(text.debugDescription)")
    }
}

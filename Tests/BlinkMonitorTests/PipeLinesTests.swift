import Foundation
import Testing
import BlinkCore
@testable import BlinkMonitor

/// Reading the training helper's output. The first version never noticed the end of a
/// pipe, and kept a processor core busy per pipe after each training (`PipeLines`).
@MainActor
@Suite("Reading another process's output")
struct PipeLinesTests {

    /// Waits up to two seconds for `done`.
    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test("Lines arrive whole, whatever the pieces they were written in, and reading stops at the end")
    func linesThenEnd() async throws {
        let lines = Locked<[String]>([])
        let reader = PipeLines { line in lines.withLock { $0.append(line) } }
        let writer = reader.pipe.fileHandleForWriting
        try writer.write(contentsOf: Data("one\ntw".utf8))
        try writer.write(contentsOf: Data("o\nthree".utf8))
        #expect(reader.isReading)
        try writer.close()
        try await wait { !reader.isReading }
        #expect(!reader.isReading)
        // The last line had no line break: it is not lost.
        #expect(lines.withLock { $0 } == ["one", "two", "three"])
    }

    @Test("A helper that ends leaves nothing reading its pipes")
    func helperEnds() async throws {
        var reports: [TrainingProgress] = []
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("blink-pipe-\(UUID().uuidString)")
        // A program that ignores its arguments and ends at once, saying nothing.
        let job = TrainingJob(way: .helper(URL(fileURLWithPath: "/usr/bin/true")), sessions: staging, staging: staging) {
            reports.append($0)
        }
        job.start()
        try await wait {
            if case .failed = reports.last { return true }
            return false
        }
        guard case .failed(let reason) = reports.last else {
            Issue.record("The job did not end: \(reports)")
            return
        }
        #expect(reason.contains("stopped before the end"))
        #expect(!job.isReading)
    }
}

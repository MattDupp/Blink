import Foundation
import Testing
@testable import BlinkCore

/// What a process cost: the readings the replay and the performance log are built on.
///
/// The counters themselves were checked by hand against loads of known size (the numbers
/// are in `ProcessCost`). These tests hold what the code does with them.
@Suite("What a process costs")
struct ProcessCostTests {

    /// Whether this Mac counts instructions at all. A virtual Mac does not: on GitHub's
    /// runners every reading says 0 (CI, 24 and 26 November 2026). By the time a test runs,
    /// the process has carried out thousands of millions of them on a real one.
    static let countsInstructions = (ProcessCost.now()?.instructions ?? 0) > 0

    /// What a busy loop of 20 million rounds cost the process.
    private func costOfALoop() throws -> ProcessCost {
        @inline(never) func work(_ rounds: Int) -> Double {
            var x = 1.0
            for i in 0..<rounds { x = x * 1.000_000_1 + Double(i & 7) * 0.1 }
            return x
        }
        let start = try #require(ProcessCost.now())
        #expect(work(20_000_000) > 0)
        return try #require(ProcessCost.now()) - start
    }

    // (The counters are the whole process's, and other tests run in it at the same
    // time: only "more than this loop alone" can be asked.)

    @Test("Work shows: a busy loop adds processor time")
    func workShows() throws {
        let spent = try costOfALoop()
        #expect(spent.cpuSeconds > 0 && spent.cpuJoules >= 0)
        #expect(spent.performanceCoreSeconds <= spent.cpuSeconds + 0.001)
    }

    @Test("Work shows in the instructions: a busy loop adds more than one per round",
          .enabled(if: countsInstructions, "this Mac counts no instructions: a virtual Mac, like CI's"))
    func workShowsInInstructions() throws {
        let spent = try costOfALoop()
        #expect(spent.instructions > 20_000_000)
    }

    @Test("A process that does not exist has no cost, and a count that went down is not a negative time")
    func whatIsNotKnown() {
        #expect(ProcessCost.now(pid: 99_999_999) == nil)

        let before = ProcessCost(cpuSeconds: 1, cpuJoules: 2, gpuSeconds: 0.5)
        let after = ProcessCost(cpuSeconds: 3, cpuJoules: 5, gpuSeconds: 0.2)       // its connection was closed
        let spent = after - before
        #expect(spent.cpuSeconds == 2 && spent.cpuJoules == 3)
        #expect(spent.gpuSeconds == nil)
        #expect((ProcessCost(gpuSeconds: 0.75) - ProcessCost(gpuSeconds: 0.5)).gpuSeconds == 0.25)
        #expect((ProcessCost(gpuSeconds: 0.75) - ProcessCost()).gpuSeconds == nil)
    }
}

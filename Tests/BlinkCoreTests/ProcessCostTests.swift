import Foundation
import Testing
@testable import BlinkCore

/// What a process cost: the readings the replay and the performance log are built on.
///
/// The counters themselves were checked by hand against loads of known size (the numbers
/// are in `ProcessCost`). These tests hold what the code does with them.
@Suite("What a process costs")
struct ProcessCostTests {

    @Test("Work shows: a busy loop adds processor time and instructions")
    func workShows() throws {
        @inline(never) func work(_ rounds: Int) -> Double {
            var x = 1.0
            for i in 0..<rounds { x = x * 1.000_000_1 + Double(i & 7) * 0.1 }
            return x
        }
        let start = try #require(ProcessCost.now())
        #expect(work(20_000_000) > 0)
        let spent = try #require(ProcessCost.now()) - start

        // (The counters are the whole process's, and other tests run in it at the same
        // time: only "more than this loop alone" can be asked.)
        #expect(spent.cpuSeconds > 0 && spent.cpuJoules >= 0)
        #expect(spent.instructions > 20_000_000)
        #expect(spent.performanceCoreSeconds <= spent.cpuSeconds + 0.001)
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

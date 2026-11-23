import Foundation
import Darwin
import IOKit

/// What a process has used since it started: processor time, the energy the processor
/// spent on it, and time on the graphics processor.
///
/// Two readings a while apart, subtracted, say what that while cost. None of this needs
/// an administrator: a process may ask about itself, and about the user's other processes.
///
/// EACH COUNTER WAS CHECKED AGAINST A LOAD OF KNOWN SIZE before it was trusted
/// (2026-11-23, MacBook Pro M5 Pro, macOS 27):
///
///   - Processor time: one thread kept busy for 2.00 s reads 1.999 s, two threads 3.998 s,
///     a sleeping program 0.000 s.
///   - Instructions: the same loop, run four times on different cores, reads 3.201,
///     3.201, 3.202 and 3.206 thousand million; half the loop reads 1.601. Its processor
///     TIME went from 0.46 s on a performance core to 1.57 s on an efficiency core. So
///     time says how long a core was held, and depends on which core macOS chose that
///     time; instructions say how much work was done, and are what two runs agree on.
///   - Energy: 0.001 J asleep, 5.4 J for one busy thread during 2 s (2.7 W for a
///     performance core). It is the kernel's estimate for the PROCESSOR alone: the same
///     figure did not move with the graphics processor's load.
///   - Graphics processor: a program that blurs a large picture back to back reads 1.30 s
///     over 3.1 s, while the whole Mac's "device utilization" went from 11% to 46%; the
///     same blur with pauses reads in proportion to the pictures made; no picture, 0.000 s.
///
/// One counter was tried and dropped: `task_info` with `TASK_POWER_INFO_V2` has a field
/// for graphics time, and it stayed at zero under that same load.
///
/// What is not here, because nothing unprivileged reports it: the energy of the graphics
/// processor, of the camera and of the Neural Engine.
public struct ProcessCost: Equatable {

    /// Seconds of processor time, over all its cores and threads.
    public var cpuSeconds = 0.0
    /// The part of those seconds spent on performance cores (the rest: efficiency cores).
    public var performanceCoreSeconds = 0.0
    /// Instructions the processor carried out: the amount of work, whichever core did it.
    public var instructions = 0.0
    /// Joules spent by the processor on this process, as the kernel estimates them.
    public var cpuJoules = 0.0
    /// Seconds of the graphics processor's time. Nil when its driver does not say
    /// (it does on Apple's own graphics processors).
    public var gpuSeconds: Double?

    public init(cpuSeconds: Double = 0, performanceCoreSeconds: Double = 0, instructions: Double = 0,
                cpuJoules: Double = 0, gpuSeconds: Double? = nil) {
        self.cpuSeconds = cpuSeconds
        self.performanceCoreSeconds = performanceCoreSeconds
        self.instructions = instructions
        self.cpuJoules = cpuJoules
        self.gpuSeconds = gpuSeconds
    }

    /// What `pid` has used so far. Nil when the system does not answer: the process is
    /// gone, or it is another user's.
    public static func now(pid: pid_t = getpid()) -> ProcessCost? {
        var info = rusage_info_v6()
        let answered = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard answered == 0 else { return nil }
        return ProcessCost(cpuSeconds: seconds(fromTicks: info.ri_user_time + info.ri_system_time),
                           performanceCoreSeconds: seconds(fromTicks: info.ri_user_ptime + info.ri_system_ptime),
                           instructions: Double(info.ri_instructions),
                           cpuJoules: Double(info.ri_energy_nj) / 1_000_000_000,
                           gpuSeconds: gpuSeconds(pid: pid))
    }

    /// What was used between two readings: `later - earlier`.
    public static func - (later: ProcessCost, earlier: ProcessCost) -> ProcessCost {
        var gpu: Double?
        if let after = later.gpuSeconds, let before = earlier.gpuSeconds {
            // A program that closes its connection to the graphics processor takes its
            // count away with it: the sum can go down. That is "not known", not a negative time.
            gpu = after >= before ? after - before : nil
        }
        return ProcessCost(cpuSeconds: later.cpuSeconds - earlier.cpuSeconds,
                           performanceCoreSeconds: later.performanceCoreSeconds - earlier.performanceCoreSeconds,
                           instructions: later.instructions - earlier.instructions,
                           cpuJoules: later.cpuJoules - earlier.cpuJoules, gpuSeconds: gpu)
    }

    /// The kernel counts processor time in its own ticks: 125/3 nanoseconds each on
    /// Apple's processors, one nanosecond on Intel's. Read as nanoseconds, a busy second
    /// would look like 0.024 s.
    private static func seconds(fromTicks ticks: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.denom != 0 else { return 0 }
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// The graphics driver keeps, for each program connected to it, the time its work
    /// took ("accumulatedGPUTime", in nanoseconds), and shows it in the IO registry:
    /// what `ioreg -r -c IOAccelerator -l` prints. This adds up the connections of `pid`.
    private static func gpuSeconds(pid: pid_t) -> Double? {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(accelerators) }

        var total: Double?
        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            total = (total ?? 0) + gpuSeconds(pid: pid, under: accelerator)
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(accelerators)
        }
        return total
    }

    private static func gpuSeconds(pid: pid_t, under accelerator: io_registry_entry_t) -> Double {
        var clients: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &clients) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(clients) }

        var seconds = 0.0
        var client = IOIteratorNext(clients)
        while client != 0 {
            // "pid 1234, BlinkMonitor": who opened this connection.
            let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if let creator, creator.hasPrefix("pid \(pid),") {
                let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]]
                for entry in usage ?? [] {
                    seconds += ((entry["accumulatedGPUTime"] as? NSNumber)?.doubleValue ?? 0) / 1_000_000_000
                }
            }
            IOObjectRelease(client)
            client = IOIteratorNext(clients)
        }
        return seconds
    }
}

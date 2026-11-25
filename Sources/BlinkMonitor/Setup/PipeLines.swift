import Foundation
import BlinkCore

/// Reads what another process writes into a pipe, one line at a time, until that process
/// closes its end.
///
/// THE END OF THE PIPE MUST BE NOTICED. A pipe's `readabilityHandler` is called whenever
/// there is something to read, and a pipe whose writer has gone always has something to
/// read: the end, as empty data. A handler that only returns on empty data is called again
/// at once, and again, for as long as the app runs. Measured on 2026-11-25 with the code
/// `TrainingJob` had then: 2.3 million calls in two seconds, and about one processor core
/// per pipe, from the end of the first training until the app quit. So at the end the
/// handler takes itself off.
final class PipeLines: @unchecked Sendable {

    /// The pipe to give the other process (`Process.standardOutput`, `standardError`).
    let pipe = Pipe()

    private let unread = Locked(Data())
    private let open = Locked(true)

    /// `line` is called on a background queue, for each line without its line break, and
    /// once more for what is left at the end without one.
    init(_ line: @escaping @Sendable (String) -> Void) {
        let unread = unread, open = open
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let lines: [String] = unread.withLock { buffer in
                buffer.append(data)
                var lines: [String] = []
                while let end = buffer.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...end)
                }
                if data.isEmpty, !buffer.isEmpty {
                    lines.append(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll()
                }
                return lines
            }
            lines.forEach(line)
            if data.isEmpty {
                // The writer is gone: nothing more will come, and the handler stops here.
                handle.readabilityHandler = nil
                open.withLock { $0 = false }
            }
        }
    }

    /// The other side has not closed the pipe yet, and `stop` was not called.
    var isReading: Bool { open.withLock { $0 } }

    /// Stops reading now, whatever the other side does.
    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        open.withLock { $0 = false }
    }
}

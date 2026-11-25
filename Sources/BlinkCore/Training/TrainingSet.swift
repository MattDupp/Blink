import CoreGraphics
import CoreVideo
import Foundation

/// The recorded eye pictures, ready for training: what `training/data.py` does in Python.
///
/// A session's manifest.csv lists its pictures with their label. They are few (two
/// sessions are about 1,900 pictures, 30 MB as numbers), so all of them are read once
/// into one array of brightness values.
public struct TrainingSet {

    public struct Entry: Equatable {
        public let file: URL
        public let session: String
        /// The label: true for a picture recorded while the eyes were held closed.
        public let closed: Bool
    }

    public private(set) var entries: [Entry] = []
    /// 4,096 brightness values (0...1) per entry, one picture after the other.
    public private(set) var gray: [Float] = []

    public var count: Int { entries.count }
    public var labels: [Float] { entries.map { $0.closed ? 1 : 0 } }
    public var closedCount: Int { entries.filter(\.closed).count }
    public var sessions: [String] { Array(Set(entries.map(\.session))).sorted() }

    // MARK: Listing

    /// A manifest names its pictures inside its own session: "open/<name>" or "closed/<name>",
    /// as `SessionWriter` and training/label_captures.py write them. Anything else, a path that
    /// climbs out with ".." or one that starts at "/", is skipped: a manifest edited by hand
    /// must not make a training read files from elsewhere. (data.py has the same rule.)
    static func isOwnPicture(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && EyeLabel(rawValue: String(parts[0])) != nil && !["", ".", ".."].contains(parts[1])
    }

    /// Every usable picture of every session under `root`, in the order of the manifests.
    ///
    /// Two kinds of lines are left out, as in data.py: a picture that is no longer on disk,
    /// and the far eye of a head turned to one side (`LocatedEyes.maxYawForBothEyes`: it
    /// hides behind the nose, and its square shows the nose).
    public static func list(root: URL, sessions wanted: Set<String>? = nil) -> [Entry] {
        var entries: [Entry] = []
        for session in SessionStore.sessions(in: root) where wanted?.contains(session.name) ?? true {
            guard let text = try? String(contentsOf: session.folder.appendingPathComponent("manifest.csv"), encoding: .utf8) else { continue }
            let lines = text.split(whereSeparator: \.isNewline)
            guard let header = lines.first?.split(separator: ",", omittingEmptySubsequences: false).map(String.init),
                  let label = header.firstIndex(of: "label"), let file = header.firstIndex(of: "file") else { continue }
            let side = header.firstIndex(of: "side"), yaw = header.firstIndex(of: "yaw")
            for line in lines.dropFirst() {
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count > max(label, file) else { continue }
                if let side, let yaw, fields.count > max(side, yaw), let turn = Double(fields[yaw]),
                   isFarEye(side: String(fields[side]), yaw: turn) { continue }
                guard isOwnPicture(String(fields[file])) else { continue }
                let url = session.folder.appendingPathComponent(String(fields[file]))
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                entries.append(Entry(file: url, session: session.name, closed: fields[label] == EyeLabel.closed.rawValue))
            }
        }
        return entries
    }

    /// True for the eye hidden behind the nose when the head is turned far to one side.
    static func isFarEye(side: String, yaw: Double) -> Bool {
        (yaw > LocatedEyes.maxYawForBothEyes && side == EyeRegion.Side.imageRight.rawValue)
            || (yaw < -LocatedEyes.maxYawForBothEyes && side == EyeRegion.Side.imageLeft.rawValue)
    }

    // MARK: Reading

    /// Reads the pictures on all cores. `progress` is called now and then with how many
    /// have been read. A picture that cannot be read is left out.
    public static func load(_ entries: [Entry], progress: ((Int) -> Void)? = nil) -> TrainingSet {
        let pixels = EyeNetwork.pixels
        var gray = [Float](repeating: 0, count: entries.count * pixels)
        var readable = [Bool](repeating: false, count: entries.count)
        let chunk = 256
        gray.withUnsafeMutableBufferPointer { buffer in
            readable.withUnsafeMutableBufferPointer { flags in
                let target = SharedPointer(buffer.baseAddress!), ok = SharedPointer(flags.baseAddress!)
                for start in stride(from: 0, to: entries.count, by: chunk) {
                    let size = min(chunk, entries.count - start)
                    DispatchQueue.concurrentPerform(iterations: size) { offset in
                        let index = start + offset
                        guard let picture = Self.gray(contentsOf: entries[index].file) else { return }
                        picture.withUnsafeBufferPointer {
                            (target.pointer + index * pixels).update(from: $0.baseAddress!, count: pixels)
                        }
                        ok.pointer[index] = true
                    }
                    progress?(start + size)
                }
            }
        }

        var set = TrainingSet()
        if readable.allSatisfy({ $0 }) {
            set.entries = entries
            set.gray = gray
        } else {
            for index in entries.indices where readable[index] {
                set.entries.append(entries[index])
                set.gray += gray[index * pixels..<(index + 1) * pixels]
            }
        }
        return set
    }

    /// One eye picture as the model's own input: 4,096 brightness values, 0...1.
    ///
    /// It is made the way a camera frame's crop is read when the model runs: the picture's
    /// numbers as they are stored, laid out blue-green-red as in the camera's buffers, then
    /// `EyeNetwork.gray`. What the model learns from is made exactly like what it will be
    /// asked about (a test holds the two to the same numbers).
    ///
    /// The numbers are drawn into plain memory. The first version made a pixel buffer for
    /// each picture, as `EyeCropper.buffer` does; with the graphics processor busy
    /// elsewhere, macOS refused most of them (11,441 of 11,833, measured 2026-11-21) and
    /// the pictures came back missing. Reading a file must not depend on the graphics card.
    public static func gray(contentsOf file: URL) -> [Float]? {
        autoreleasepool {
            PNGFile.read(file).flatMap(gray(of:))
        }
    }

    public static func gray(of image: CGImage) -> [Float]? {
        let side = EyeNetwork.side
        guard image.width == side, image.height == side else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        // Drawing in the picture's OWN colour space means "copy the numbers as they are".
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // "Little-endian 32-bit, alpha first": blue, green, red, alpha in memory.
        let layout = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space, bitmapInfo: layout) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var gray = [Float](repeating: 0, count: EyeNetwork.pixels)
        EyeNetwork.gray(fromBGRA: bytes, bytesPerRow: side * 4, into: &gray)
        return gray
    }

    public static func gray(of buffer: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetWidth(buffer) == EyeNetwork.side, CVPixelBufferGetHeight(buffer) == EyeNetwork.side,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var gray = [Float](repeating: 0, count: EyeNetwork.pixels)
        EyeNetwork.gray(fromBGRA: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), into: &gray)
        return gray
    }

    /// A picture of brightness values as an image, to show it (the training screen shows
    /// your pictures as the model is shown them: altered).
    public static func image(fromGray gray: UnsafePointer<Float>) -> CGImage? {
        let side = EyeNetwork.side
        var bytes = [UInt8](repeating: 0, count: side * side)
        for i in 0..<side * side { bytes[i] = UInt8(min(max(gray[i], 0), 1) * 255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

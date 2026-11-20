import CoreGraphics
import Foundation
import ImageIO

/// Eye pictures as numbers: 64x64 brightness values, 0..1.
enum Pictures {
    static let side = 64
    static let pixels = side * side

    /// One PNG as the model's own grey: 0.299 R + 0.587 G + 0.114 B, each 0..1.
    /// The bytes are read as they are stored (drawn in the picture's own colour space),
    /// as Python's PIL does, so both routes start from the same numbers.
    static func gray(at path: String) -> [Float]? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == side, image.height == side else { return nil }
        var bytes = [UInt8](repeating: 0, count: pixels * 4)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var gray = [Float](repeating: 0, count: pixels)
        for i in 0..<pixels {
            let r = Float(bytes[4 * i]), g = Float(bytes[4 * i + 1]), b = Float(bytes[4 * i + 2])
            gray[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        return gray
    }

    /// Every picture of the list, one after the other in one array, read on all cores.
    static func load(_ paths: [String]) -> [Float] {
        var all = [Float](repeating: 0, count: paths.count * pixels)
        let failed = Counter()
        all.withUnsafeMutableBufferPointer { buffer in
            let base = UnsafeMutablePointerBox(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                guard let gray = gray(at: paths[i]) else { failed.add(); return }
                gray.withUnsafeBufferPointer { source in
                    (base.pointer + i * pixels).update(from: source.baseAddress!, count: pixels)
                }
            }
        }
        if failed.value > 0 { FileHandle.standardError.write("\(failed.value) pictures could not be read\n".data(using: .utf8)!) }
        return all
    }
}

/// A pointer several threads write through, each to its own part.
struct UnsafeMutablePointerBox: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
    init(_ pointer: UnsafeMutablePointer<Float>) { self.pointer = pointer }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

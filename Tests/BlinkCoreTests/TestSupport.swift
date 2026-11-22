import CoreGraphics
import CoreVideo
import Foundation
@testable import BlinkCore

/// Helpers shared by the tests. Nothing here needs a camera or a face: the tests work on
/// pictures painted in memory, where the right answer is known.
enum Fixture {

    /// The project folder (two levels above this file's folder).
    static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Where the private recordings and models are: in the project folder, unless
    /// BLINK_DATA and BLINK_MODELS name other places (`make test DATA=... MODELS=...`),
    /// as for the Python tools. They are never in the repository, so the tests that need
    /// them skip themselves where they are missing.
    static let dataHome: URL = ProcessInfo.processInfo.environment["BLINK_DATA"]
        .map { URL(fileURLWithPath: $0, isDirectory: true).deletingLastPathComponent() } ?? projectRoot
    static let models: URL = ProcessInfo.processInfo.environment["BLINK_MODELS"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? projectRoot.appendingPathComponent("models", isDirectory: true)

    /// The trainer needs a graphics processor, and is slow to trust on a machine never
    /// tried: GitHub's virtual Macs are skipped (their graphics are emulated, and whether
    /// MPSGraph trains there has not been checked).
    static let canTrain = EyeTrainer.isAvailable && ProcessInfo.processInfo.environment["CI"] == nil

    /// A session of painted eyes, written the way a recorded one is: `pictures` of each
    /// kind. Returns its folder.
    @discardableResult
    static func paintedSession(in root: URL, name: String, pictures: Int, seed: UInt64 = 1) throws -> URL {
        let writer = try SessionWriter(root: root, session: name, condition: "painted")
        var random = SeededRandom(seed: seed)
        let square = CGRect(x: 800, y: 400, width: 128, height: 128)
        let eye = EyeRegion(side: .imageLeft, cropRect: square, center: CGPoint(x: square.midX, y: square.midY))
        let other = EyeRegion(side: .imageRight, cropRect: square.offsetBy(dx: 260, dy: 0), center: CGPoint(x: square.midX + 260, y: square.midY))
        let located = LocatedEyes(faceRect: .zero, left: eye, right: other, interocularDistance: 260, roll: 0, yaw: nil)
        for index in 0..<pictures * 2 {
            let open = index % 2 == 0
            guard let image = PaintedEye.random(open: open, using: &random).image() else { continue }
            writer.save(EyeSample(image: image, label: open ? .open : .closed, variant: "painted", phaseIndex: open ? 0 : 1,
                                  frameIndex: index, time: Double(index) / 30, eye: eye, located: located,
                                  frameSize: CGSize(width: 1920, height: 1080)))
        }
        return writer.folder
    }

    /// A new empty folder, removed by the caller.
    static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("blink-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A BGRA frame: mid grey, with `target` painted red (top half) and blue (bottom half).
    /// With `noise`, every pixel is pseudo-random instead (the same picture at every run):
    /// detail at every scale, to compare two ways of resizing.
    static func frame(width: Int = 1920, height: Int = 1080, target: CGRect = .zero, noise: Bool = false) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        let buffer = created!

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)

        // Memory row 0 is the TOP row of the picture; each pixel is blue, green, red, alpha.
        for y in 0..<height {
            for x in 0..<width {
                let p = y * rowBytes + x * 4
                var (b, g, r): (UInt8, UInt8, UInt8) = (128, 128, 128)
                if noise {
                    let v = UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663))
                    (b, g, r) = (UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255))
                } else if target.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    if CGFloat(y) < target.midY { (b, g, r) = (0, 0, 255) } else { (b, g, r) = (255, 0, 0) }
                }
                bytes[p] = b
                bytes[p + 1] = g
                bytes[p + 2] = r
                bytes[p + 3] = 255
            }
        }
        return buffer
    }

    /// The colour of one pixel of an image, (x, y) counted from the top-left.
    static func pixel(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let p = (y * width + x) * 4
        return (Int(data[p]), Int(data[p + 1]), Int(data[p + 2]))
    }

    /// A stream of model answers at 30 frames a second, run through a new detector.
    static func events(_ stream: [Double?], settings: BlinkDetector.Settings = .init()) -> [BlinkDetector.Event] {
        var detector = BlinkDetector(settings: settings)
        return stream.enumerated().compactMap { frame, probability in
            detector.update(time: Double(frame) / 30, closed: probability)
        }
    }

    static func blinkCount(_ stream: [Double?]) -> Int {
        events(stream).filter { if case .blink = $0 { return true } else { return false } }.count
    }

    static func frames(_ value: Double?, _ count: Int) -> [Double?] {
        Array(repeating: value, count: count)
    }
}

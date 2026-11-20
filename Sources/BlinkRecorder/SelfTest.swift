import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import BlinkCore

/// Checks every part of the pipeline that does not need the camera or a face.
///
/// The camera part can only be checked by you, in front of it. Everything else - the
/// arithmetic of the squares, which way up a crop comes out, the files written - is
/// checked here on a picture we paint ourselves, where the right answer is known.
enum SelfTest {

    static func run() -> Bool {
        var allPassed = true
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            print((passed ? "PASS  " : "FAIL  ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
            if !passed { allPassed = false }
        }

        // 1. The squares: side = 0.7 x the distance between the eyes, centred on each eye.
        let rects = EyeLocator.cropRects(leftCenter: CGPoint(x: 800, y: 500), rightCenter: CGPoint(x: 900, y: 500))
        check("squares: side is 0.7 x the eye distance",
              rects.distance == 100 && rects.left.width == 70 && rects.left.height == 70 && rects.right.width == 70,
              "distance \(rects.distance), side \(rects.left.width)")
        check("squares: centred on each eye",
              rects.left.midX == 800 && rects.left.midY == 500 && rects.right.midX == 900 && rects.right.midY == 500)

        // 1b. Head turned far to one side: only the near eye is kept.
        func usableSides(yaw: Double?) -> String {
            let a = EyeRegion(side: .imageLeft, cropRect: rects.left, center: CGPoint(x: 800, y: 500))
            let b = EyeRegion(side: .imageRight, cropRect: rects.right, center: CGPoint(x: 900, y: 500))
            return LocatedEyes(faceRect: .zero, left: a, right: b, interocularDistance: 100, roll: nil, yaw: yaw)
                .usableEyes.map { $0.side.rawValue }.joined()
        }
        check("head straight, or angle unknown: both eyes are used",
              usableSides(yaw: 0) == "LR" && usableSides(yaw: nil) == "LR")
        check("head turned 45 degrees: only the near eye is used",
              usableSides(yaw: 0.785) == "L" && usableSides(yaw: -0.785) == "R",
              "+0.785 -> \(usableSides(yaw: 0.785)), -0.785 -> \(usableSides(yaw: -0.785))")

        // 2. A painted 1920x1080 frame: grey, with one square whose TOP half is red and
        //    BOTTOM half is blue. If the crop comes out upside down, or from the wrong
        //    place (the classic top-left / bottom-left mix-up), the colours give it away.
        let target = CGRect(x: 1000, y: 200, width: 128, height: 128)
        guard let frame = paintedFrame(width: 1920, height: 1080, target: target) else {
            check("painted frame created", false)
            return false
        }

        let cropper = EyeCropper()
        if let crop = cropper.crop(frame, rect: target) {
            check("crop: comes out \(EyeCropper.outputSize) x \(EyeCropper.outputSize)",
                  crop.width == EyeCropper.outputSize && crop.height == EyeCropper.outputSize,
                  "\(crop.width) x \(crop.height)")
            let top = pixel(of: crop, x: 32, y: 8)
            let bottom = pixel(of: crop, x: 32, y: 56)
            check("crop: the top of the square is at the top (red)", top.r > 200 && top.b < 60, "rgb \(top)")
            check("crop: the bottom of the square is at the bottom (blue)", bottom.b > 200 && bottom.r < 60, "rgb \(bottom)")
        } else {
            check("crop: produced", false)
        }
        check("crop: a square partly outside the frame is refused",
              cropper.crop(frame, rect: CGRect(x: 1900, y: 10, width: 64, height: 64)) == nil)
        if let preview = cropper.preview(frame, maxWidth: 960) {
            check("preview: 960 x 540", preview.width == 960 && preview.height == 540, "\(preview.width) x \(preview.height)")
        } else {
            check("preview: produced", false)
        }

        // 3. Vision runs on this Mac, and finds no face in a picture that has none.
        do {
            let found = try EyeLocator().locate(in: frame)
            check("Vision: runs, and finds no face in the painted frame", found == nil)
        } catch {
            check("Vision: runs", false, "\(error)")
        }

        // 4. A session on disk: folders, a readable PNG, one manifest line per picture.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blink-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let writer = try SessionWriter(root: root, session: "test", condition: "lamp, \"glasses\"")
            let phase = Phase(label: .closed, variant: "gentle", instruction: "")
            let eye = EyeRegion(side: .imageLeft, cropRect: target, center: CGPoint(x: target.midX, y: target.midY))
            let other = EyeRegion(side: .imageRight, cropRect: target.offsetBy(dx: 200, dy: 0),
                                  center: CGPoint(x: target.midX + 200, y: target.midY))
            let located = LocatedEyes(faceRect: .zero, left: eye, right: other, interocularDistance: 200, roll: 0.05, yaw: nil)
            guard let image = cropper.crop(frame, rect: target) else {
                check("writer: picture to save", false)
                return false
            }
            let saved = writer.save(Sample(image: image, phaseIndex: 1, phase: phase, frameIndex: 42, time: 1.5,
                                           eye: eye, located: located, frameSize: CGSize(width: 1920, height: 1080)))
            check("writer: picture saved", saved)

            let file = root.appendingPathComponent("test/closed/p01_f000042_L.png")
            var readBack: CGImage?
            if let source = CGImageSourceCreateWithURL(file as CFURL, nil) {
                readBack = CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            check("writer: the PNG reads back as 64 x 64", readBack?.width == 64 && readBack?.height == 64)

            let manifest = (try? String(contentsOf: root.appendingPathComponent("test/manifest.csv"), encoding: .utf8)) ?? ""
            let lines = manifest.split(separator: "\n").map(String.init)
            let columns = SessionWriter.header.split(separator: ",").count
            check("manifest: a header and one line", lines.count == 2 && lines.first == SessionWriter.header)
            check("manifest: the line has the header's \(columns) columns (commas in the condition removed)",
                  lines.count == 2 && lines[1].split(separator: ",", omittingEmptySubsequences: false).count == columns,
                  lines.last ?? "")

            let stats = DatasetStats.scan(root)
            check("dataset count: 1 session, 0 open, 1 closed", stats == DatasetStats(sessions: 1, open: 0, closed: 1))

            // 5. Discarding a session: the latest one goes, whole, and the older one stays.
            _ = try SessionWriter(root: root, session: "test-later", condition: "")
            check("sessions: the latest is the last by name",
                  SessionStore.latest(in: root)?.lastPathComponent == "test-later")
            try SessionStore.discard(root.appendingPathComponent("test-later"), toTrash: false)
            check("discard: the session's folder is gone",
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent("test-later").path))
            check("discard: the older session and its picture are kept",
                  SessionStore.latest(in: root)?.lastPathComponent == "test"
                  && DatasetStats.scan(root) == DatasetStats(sessions: 1, open: 0, closed: 1))
        } catch {
            check("writer: session created", false, "\(error)")
        }

        print(allPassed ? "RESULT: all checks passed" : "RESULT: FAILED")
        return allPassed
    }

    /// A BGRA frame: mid grey, with `target` painted red (top half) and blue (bottom half).
    private static func paintedFrame(width: Int, height: Int, target: CGRect) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // Memory row 0 is the TOP row of the picture; each pixel is blue, green, red, alpha.
        for y in 0..<height {
            for x in 0..<width {
                let p = y * rowBytes + x * 4
                var (b, g, r): (UInt8, UInt8, UInt8) = (128, 128, 128)
                if target.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
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
    private static func pixel(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (-1, -1, -1) }
        let p = (y * width + x) * 4
        return (Int(data[p]), Int(data[p + 1]), Int(data[p + 2]))
    }
}

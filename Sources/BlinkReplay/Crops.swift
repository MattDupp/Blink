import Foundation
import CoreVideo
import BlinkCore

/// How far the eye pictures cut on the processor are from the ones Core Image cuts:
///
///     BlinkReplay <folder> --crops
///
/// The model learned from pictures Core Image made, so a new way of cutting them is
/// judged on one question: are they the same pictures? Every eye of every stored frame
/// is cut both ways. The two pictures are compared number by number (64 x 64 points,
/// three colours each, 0...255), and the model is asked about both.
///
/// A capture only holds the squares its person's face made. The second part cuts squares
/// of every size out of one stored frame, so that each of Core Image's ways of shrinking
/// (`DirectCrop`) is covered whoever sat in front of the camera.
enum Crops {

    /// How many values are the same, one level apart, further apart: the three colours
    /// of each point. (The fourth number of a point says how opaque it is; a picture
    /// where it differs is counted in `opacity`.)
    struct Gap {
        var same = 0, oneApart = 0, further = 0, opacity = 0
        var total: Int { same + oneApart + further }

        mutating func add(_ a: CVPixelBuffer, _ b: CVPixelBuffer) {
            CVPixelBufferLockBaseAddress(a, .readOnly)
            CVPixelBufferLockBaseAddress(b, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(a, .readOnly)
                CVPixelBufferUnlockBaseAddress(b, .readOnly)
            }
            guard let first = CVPixelBufferGetBaseAddress(a)?.assumingMemoryBound(to: UInt8.self),
                  let second = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self) else { return }
            let rowA = CVPixelBufferGetBytesPerRow(a), rowB = CVPixelBufferGetBytesPerRow(b)
            for y in 0..<EyeCropper.outputSize {
                for x in 0..<EyeCropper.outputSize {
                    if first[y * rowA + x * 4 + 3] != second[y * rowB + x * 4 + 3] { opacity += 1 }
                    for channel in 0..<3 {       // blue, green, red
                        switch abs(Int(first[y * rowA + x * 4 + channel]) - Int(second[y * rowB + x * 4 + channel])) {
                        case 0: same += 1
                        case 1: oneApart += 1
                        default: further += 1
                        }
                    }
                }
            }
        }

        var text: String {
            let all = Double(max(total, 1))
            return String(format: "%.2f%% of the values the same, %.2f%% one level apart, %.3f%% further (%d)",
                          Double(same) / all * 100, Double(oneApart) / all * 100, Double(further) / all * 100, further)
                + (opacity > 0 ? ", \(opacity) points not as opaque" : "")
        }
    }

    static func run(captures: [RecordedCapture], classifier: EyeJudging, judge: String) async throws {
        let direct = EyeCropper(way: .direct), reference = EyeCropper(way: .coreImage)
        var gap = Gap()
        var pictures = 0, refused = 0
        var answerGap = 0.0, largest = 0.0, otherSide = 0
        var sizes: [Int: Int] = [:]
        var sample: CVPixelBuffer?

        for capture in captures {
            let frames = try await WholeFrameReader(folder: capture.folder)
            let locator = EyeLocator(strategy: .wholeFrame)
            var number = 0
            while true {
                let more: Bool = try autoreleasepool {
                    guard let frame = try frames.next() else { return false }
                    number += 1
                    if number == 300 && sample == nil { sample = frame.pixels }
                    guard let eyes = try locator.locate(in: frame.pixels) else { return true }
                    for eye in eyes.usableEyes {
                        let a = direct.cropBuffer(frame.pixels, rect: eye.cropRect)
                        let b = reference.cropBuffer(frame.pixels, rect: eye.cropRect)
                        guard let a, let b else {
                            if (a == nil) != (b == nil) { refused += 1 }
                            continue
                        }
                        pictures += 1
                        sizes[EyeCropper.halvings(forSquare: eye.cropRect.width), default: 0] += 1
                        gap.add(a, b)
                        let first = try classifier.closedProbability(of: a), second = try classifier.closedProbability(of: b)
                        answerGap += abs(first - second)
                        largest = max(largest, abs(first - second))
                        if (first > 0.5) != (second > 0.5) { otherSide += 1 }
                    }
                    return true
                }
                if !more { break }
            }
        }
        print("\n\(pictures) eye pictures of \(captures.count) captures, each cut on the processor and by Core Image:")
        print("  " + gap.text)
        print("  squares shrunk in one go: \(sizes[0] ?? 0); halved first: \(sizes[1] ?? 0); "
              + "halved twice or more (left to Core Image): \(sizes.filter { $0.key > 1 }.values.reduce(0, +))")
        print(String(format: "  the model (%@) asked about both: answers %.4f%% apart on average, %.2f%% at most; "
                     + "%d of %d on the other side of 50%%", judge, answerGap / Double(max(pictures, 1)) * 100,
                     largest * 100, otherSide, pictures))
        if refused > 0 { print("  \(refused) squares were cut by one way and refused by the other") }

        // Squares of every size, out of one stored frame.
        guard let sample else { return }
        print("\nSquares of every size, cut out of one stored frame both ways:")
        let width = CVPixelBufferGetWidth(sample), height = CVPixelBufferGetHeight(sample)
        var random = SeededRandom(seed: 7)
        for (title, range) in [("up to 147 pixels (shrunk in one go, or enlarged)", 30...147),
                               ("148 to 294 pixels (halved first)", 148...294),
                               ("295 to 588 pixels (halved twice: left to Core Image, so the same by construction)", 295...588)] {
            var gap = Gap()
            for _ in 0..<150 {
                func pick(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(random.next() % UInt64(range.count)) }
                let side = pick(range)
                let rect = CGRect(x: pick(2...(width - side - 2)), y: pick(2...(height - side - 2)), width: side, height: side)
                guard let a = direct.cropBuffer(sample, rect: rect), let b = reference.cropBuffer(sample, rect: rect) else { continue }
                gap.add(a, b)
            }
            print("  \(title): " + gap.text)
        }

        // What one picture costs each way: the same square of that frame, cut again and again.
        print("\nThe work of one picture (instructions, the same square cut 2,000 times):")
        for side in [90, 120, 200, 400] {
            let rect = CGRect(x: 701, y: 303, width: side, height: side)
            func work(_ cropper: EyeCropper) -> Double {
                guard let before = ProcessCost.now() else { return 0 }
                for _ in 0..<2000 { autoreleasepool { _ = cropper.cropBuffer(sample, rect: rect) } }
                return ((ProcessCost.now()?.instructions ?? 0) - before.instructions) / 2000
            }
            print(String(format: "  a square of %d pixels: %.0f thousand on the processor, %.0f thousand by Core Image",
                         side, work(direct) / 1000, work(reference) / 1000))
        }
    }
}

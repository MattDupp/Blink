import Foundation

/// A small seeded random generator (SplitMix64): the same seed gives the same run again,
/// and each picture can have its own, so the work can be spread over all cores.
public struct SeededRandom {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<1.
    public mutating func uniform() -> Float { Float(next() >> 40) * (1.0 / 16_777_216.0) }
    public mutating func uniform(_ low: Float, _ high: Float) -> Float { low + (high - low) * uniform() }
    public mutating func below(_ count: Int) -> Int { Int(next() % UInt64(count)) }

    /// Two numbers from the bell curve (Box-Muller).
    mutating func normalPair() -> (Float, Float) {
        let u = max(uniform(), 1e-7), v = uniform()
        let radius = (-2 * logf(u)).squareRoot()
        return (radius * cosf(2 * .pi * v), radius * sinf(2 * .pi * v))
    }
}

/// What training does to a picture each time it shows it ("augmentation"): mirror it,
/// turn / zoom / shift it, lose some detail, bend its brightness, add a little noise.
///
/// WHY. A few thousand pictures taken in two sittings all look alike: same light, same
/// distance, the head upright. Shown as they are, the network would learn those accidents.
/// Altered another way at every pass, the only thing that stays the same is the eyelid.
///
/// The ranges and the order are those of `training/learning.py`. Two differences, both
/// measured as part of the whole (2026-11-20: 936 of 936 blinks, like Python): it works on
/// the grey picture (Python alters the three colours, then the model makes them grey), and
/// the size used to lose detail is drawn per picture (Python draws one per batch).
public enum PictureAlteration {

    static let side = EyeNetwork.side
    static let maxRotation: Float = 35 * .pi / 180

    /// Writes an altered copy of `source` (4,096 brightness values, 0...1) into `target`.
    public static func apply(_ source: UnsafePointer<Float>, into target: UnsafeMutablePointer<Float>,
                             random: inout SeededRandom) {
        let n = side, last = Float(n - 1)

        // 1 + 2. Mirror half of the pictures, then rotate, zoom and shift: one pass that
        // asks, for every pixel of the result, where it comes from in the original.
        let mirror = random.uniform() < 0.5
        let angle = random.uniform(-maxRotation, maxRotation)
        let zoom = random.uniform(0.85, 1.15)
        let shiftX = random.uniform(-0.2, 0.2), shiftY = random.uniform(-0.2, 0.2)
        let c = cosf(angle) / zoom, s = sinf(angle) / zoom
        for y in 0..<n {
            let yo = (2 * Float(y) + 1) / Float(n) - 1
            for x in 0..<n {
                let xo = (2 * Float(x) + 1) / Float(n) - 1
                let xs = c * xo - s * yo + shiftX
                let ys = s * xo + c * yo + shiftY
                // Outside the picture, repeat its edge.
                let px = min(max(((xs + 1) * Float(n) - 1) / 2, 0), last)
                let py = min(max(((ys + 1) * Float(n) - 1) / 2, 0), last)
                let x0 = Int(px), y0 = Int(py)
                let x1 = min(x0 + 1, n - 1), y1 = min(y0 + 1, n - 1)
                let fx = px - Float(x0), fy = py - Float(y0)
                let a0 = mirror ? n - 1 - x0 : x0, a1 = mirror ? n - 1 - x1 : x1
                let top = source[y0 * n + a0] * (1 - fx) + source[y0 * n + a1] * fx
                let bottom = source[y1 * n + a0] * (1 - fx) + source[y1 * n + a1] * fx
                target[y * n + x] = top * (1 - fy) + bottom * fy
            }
        }

        // 3. Lose detail in a third of the pictures: shrink to 24...48 pixels, enlarge back.
        // (A face far from the camera gives exactly such a picture.)
        if random.uniform() < 0.33 {
            let small = 24 + random.below(25)
            var reduced = [Float](repeating: 0, count: small * small)
            reduced.withUnsafeMutableBufferPointer { resize(target, n, into: $0.baseAddress!, small) }
            reduced.withUnsafeBufferPointer { resize($0.baseAddress!, small, into: target, n) }
        }

        // 4. Bend the brightness curve, add a little sensor noise.
        let gamma = expf(random.uniform(-0.4, 0.4))
        let noise = random.uniform(0, 0.03)
        var i = 0
        while i < n * n {
            let (a, b) = random.normalPair()
            target[i] = min(max(powf(max(target[i], 1e-4), gamma) + noise * a, 0), 1)
            target[i + 1] = min(max(powf(max(target[i + 1], 1e-4), gamma) + noise * b, 0), 1)
            i += 2
        }
    }

    /// Resizes a square picture, each new pixel a mix of the four nearest old ones.
    private static func resize(_ source: UnsafePointer<Float>, _ from: Int, into target: UnsafeMutablePointer<Float>, _ to: Int) {
        let scale = Float(from) / Float(to)
        for y in 0..<to {
            let py = max((Float(y) + 0.5) * scale - 0.5, 0)
            let y0 = min(Int(py), from - 1), y1 = min(y0 + 1, from - 1)
            let fy = py - Float(y0)
            for x in 0..<to {
                let px = max((Float(x) + 0.5) * scale - 0.5, 0)
                let x0 = min(Int(px), from - 1), x1 = min(x0 + 1, from - 1)
                let fx = px - Float(x0)
                let top = source[y0 * from + x0] * (1 - fx) + source[y0 * from + x1] * fx
                let bottom = source[y1 * from + x0] * (1 - fx) + source[y1 * from + x1] * fx
                target[y * to + x] = top * (1 - fy) + bottom * fy
            }
        }
    }
}

/// A pointer several threads read or write through, each its own part.
struct SharedPointer<Pointee>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Pointee>
    init(_ pointer: UnsafeMutablePointer<Pointee>) { self.pointer = pointer }
    init(_ pointer: UnsafePointer<Pointee>) { self.pointer = UnsafeMutablePointer(mutating: pointer) }
}

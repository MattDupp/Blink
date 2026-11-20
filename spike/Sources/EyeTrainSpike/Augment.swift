import Foundation

/// A small seeded random generator (SplitMix64): the same seed gives the same run again,
/// and each picture can have its own, so the work can be spread over all cores.
struct Random {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<1.
    mutating func uniform() -> Float { Float(next() >> 40) * (1.0 / 16_777_216.0) }
    mutating func uniform(_ low: Float, _ high: Float) -> Float { low + (high - low) * uniform() }
    mutating func below(_ count: Int) -> Int { Int(next() % UInt64(count)) }

    /// Two numbers from the bell curve (Box-Muller).
    mutating func normalPair() -> (Float, Float) {
        let u = max(uniform(), 1e-7), v = uniform()
        let radius = (-2 * logf(u)).squareRoot()
        return (radius * cosf(2 * .pi * v), radius * sinf(2 * .pi * v))
    }
}

/// The alterations `training/learning.py` applies to a picture each time it is shown:
/// mirror, rotate / zoom / shift, lose detail, bend the brightness curve, add noise.
/// Same ranges, same order. Two differences, both on purpose and both measured by the
/// spike as a whole: it works on the grey picture (Python alters the three colours, then
/// the model makes them grey), and the size used to lose detail is drawn per picture
/// (Python draws one per batch).
enum Augment {
    static let side = Pictures.side
    static let maxRotation: Float = 35 * .pi / 180

    static func apply(_ source: UnsafePointer<Float>, into target: UnsafeMutablePointer<Float>, random: inout Random) {
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
                // Outside the picture, repeat its edge ("border" in PyTorch).
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

        // 3. Lose detail in a third of the pictures: shrink to 24..48 pixels, enlarge back.
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

    /// Bilinear resize of a square picture, pixel centres aligned (PyTorch's
    /// `interpolate(mode="bilinear", align_corners=False)`).
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

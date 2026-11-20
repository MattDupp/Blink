// Draws the app icon:   swift scripts/make-icon.swift App/AppIcon.iconset     (or: make icon)
//
// An .icns file is a set of PNGs of the same picture at ten sizes; `iconutil` packs the
// folder this script fills. Drawing the icon in code keeps the project free of binary
// design files: the icon is reproducible, and changing it is changing a few numbers.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: swift scripts/make-icon.swift <folder.iconset>")
    exit(1)
}
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

/// One icon, `pixels` wide: a rounded square in a blue-to-teal gradient, a white eye.
func icon(pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons leave a margin: the rounded square fills about 80% of the canvas.
    let plate = CGRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    let platePath = CGPath(roundedRect: plate, cornerWidth: plate.width * 0.225, cornerHeight: plate.width * 0.225, transform: nil)

    // A soft shadow under the plate.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                      color: CGColor(gray: 0, alpha: 0.28))
    context.addPath(platePath)
    context.setFillColor(CGColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // The gradient, top-left to bottom-right.
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let colors = [CGColor(red: 0.16, green: 0.42, blue: 0.96, alpha: 1), CGColor(red: 0.10, green: 0.72, blue: 0.80, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY),
                               end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    context.restoreGState()

    // The eye: an almond (two arcs meeting at the corners), white.
    let centre = CGPoint(x: size / 2, y: size / 2)
    let halfWidth = plate.width * 0.36
    let lift = plate.width * 0.235
    let eye = CGMutablePath()
    eye.move(to: CGPoint(x: centre.x - halfWidth, y: centre.y))
    eye.addQuadCurve(to: CGPoint(x: centre.x + halfWidth, y: centre.y), control: CGPoint(x: centre.x, y: centre.y + lift * 2))
    eye.addQuadCurve(to: CGPoint(x: centre.x - halfWidth, y: centre.y), control: CGPoint(x: centre.x, y: centre.y - lift * 2))
    eye.closeSubpath()
    context.addPath(eye)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()

    // The iris, in the plate's own blue, with a white glint.
    let iris = plate.width * 0.165
    context.setFillColor(CGColor(red: 0.11, green: 0.36, blue: 0.86, alpha: 1))
    context.fillEllipse(in: CGRect(x: centre.x - iris, y: centre.y - iris, width: iris * 2, height: iris * 2))
    let pupil = iris * 0.5
    context.setFillColor(CGColor(red: 0.05, green: 0.14, blue: 0.36, alpha: 1))
    context.fillEllipse(in: CGRect(x: centre.x - pupil, y: centre.y - pupil, width: pupil * 2, height: pupil * 2))
    let glint = iris * 0.26
    context.setFillColor(CGColor(gray: 1, alpha: 0.95))
    context.fillEllipse(in: CGRect(x: centre.x + iris * 0.22, y: centre.y + iris * 0.24, width: glint * 2, height: glint * 2))

    return context.makeImage()!
}

// The ten files iconutil expects: five sizes, each at 1x and 2x.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let bitmap = NSBitmapImageRep(cgImage: icon(pixels: points * scale))
        guard let png = bitmap.representation(using: .png, properties: [:]) else { continue }
        try png.write(to: folder.appendingPathComponent(name))
    }
}
print("Wrote 10 icon sizes to \(folder.path)")

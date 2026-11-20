// Draws the picture behind the icons of the installer's window:
//
//     swift scripts/make-dmg-background.swift <folder> [--notarized]
//
// It writes background.png (one pixel per point) and background@2x.png (two, for Retina
// screens) into the folder; scripts/dmg.sh hands them to dmgbuild, which packs both into
// one file. Like the icon, the picture is drawn by code: nothing binary to keep in git,
// and moving an icon is changing a number here and in scripts/dmg-settings.py.
//
// WHAT FINDER DRAWS, AND WHAT THIS DRAWS. Finder draws the two icons and their names. This
// picture is only what is behind them: a sentence, an arrow from one icon to the other,
// and, for an app Apple has not checked, the two steps macOS will ask for.
//
// THE COLOUR IS A MIDDLE GREY-BLUE ON PURPOSE. Finder writes the icons' names in black in
// light mode and in white in dark mode, whatever is behind them. A light picture hides
// the white names, a dark one hides the black names; this one is readable under both.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard let folderPath = arguments.first(where: { !$0.hasPrefix("--") }) else {
    print("usage: swift scripts/make-dmg-background.swift <folder> [--notarized]")
    exit(1)
}
/// A notarized app opens with one ordinary question: there is nothing to warn about.
let notarized = arguments.contains("--notarized")
let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

// The window's content, in points. These numbers are also in scripts/dmg-settings.py.
// The picture is drawn taller than the window: a window that turns out a little higher
// than planned (the title bar's height changes between macOS versions) shows more of the
// same colour, not a white strip.
let width = 600.0
let visibleHeight = 400.0
let height = 460.0
let iconY = 185.0               // the icons' centre, from the top
let appX = 150.0
let applicationsX = 450.0

func background(scale: Int) -> CGImage {
    let context = CGContext(data: nil, width: Int(width) * scale, height: Int(height) * scale,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    // From here on, distances are in points, and `fromTop` turns "this far under the
    // top edge" into Core Graphics' own direction (y grows upwards).
    func fromTop(_ y: Double) -> Double { height - y }

    // The ground: grey-blue, a little lighter at the top.
    let colors = [CGColor(red: 0.45, green: 0.51, blue: 0.60, alpha: 1),
                  CGColor(red: 0.38, green: 0.43, blue: 0.52, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: height - visibleHeight),
                               options: [.drawsAfterEndLocation])

    // Text is drawn by AppKit, which needs to be told which canvas is the current one.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    func write(_ text: String, size: Double, weight: NSFont.Weight, alpha: Double, centredAt y: Double) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
            .paragraphStyle: paragraph,
        ])
        let lineHeight = string.size().height
        string.draw(in: CGRect(x: 20, y: fromTop(y) - lineHeight / 2, width: width - 40, height: lineHeight))
    }

    write("Drag Blink Monitor onto Applications", size: 21, weight: .semibold, alpha: 1, centredAt: 62)

    // The arrow, from the app towards the folder, between the two icons.
    let arrow = CGMutablePath()
    let (tail, tip, y) = (appX + 92, applicationsX - 92, fromTop(iconY))
    arrow.move(to: CGPoint(x: tail, y: y))
    arrow.addLine(to: CGPoint(x: tip, y: y))
    arrow.move(to: CGPoint(x: tip - 16, y: y + 14))
    arrow.addLine(to: CGPoint(x: tip, y: y))
    arrow.addLine(to: CGPoint(x: tip - 16, y: y - 14))
    context.addPath(arrow)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
    context.setLineWidth(5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    if notarized {
        write("Then open it from your Applications folder.", size: 13, weight: .regular, alpha: 0.92, centredAt: 330)
    } else {
        // Said here because this is where the person is when it happens. The README has
        // the same steps with more words.
        write("Then open it from Applications. The first time, macOS stops it:", size: 13, weight: .regular,
              alpha: 0.92, centredAt: 318)
        write("System Settings > Privacy & Security > Open Anyway", size: 13, weight: .semibold,
              alpha: 1, centredAt: 340)
        write("Apple has not checked this free app. Its code is public.", size: 11.5, weight: .regular,
              alpha: 0.8, centredAt: 364)
    }
    NSGraphicsContext.current = nil
    return context.makeImage()!
}

for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(cgImage: background(scale: scale))
    // The size in POINTS is what makes the second file "the same picture, twice as fine"
    // and not "a picture twice as big".
    bitmap.size = NSSize(width: width, height: height)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        print("The background could not be encoded.")
        exit(1)
    }
    try png.write(to: folder.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
}

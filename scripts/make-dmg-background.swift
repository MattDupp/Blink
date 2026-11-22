// Draws the picture behind the icons of the installer's window:
//
//     swift scripts/make-dmg-background.swift <folder> [--notarized]
//     swift scripts/make-dmg-background.swift <folder> --mock      a picture to LOOK at (below)
//
// It writes background.png (one pixel per point) and background@2x.png (two, for Retina
// screens) into the folder; scripts/dmg.sh hands them to dmgbuild, which packs both into
// one file. Like the icon, the picture is drawn by code: nothing binary to keep in git,
// and moving an icon is changing a number here and in scripts/dmg-settings.py.
//
// WHAT FINDER DRAWS, AND WHAT THIS DRAWS. Finder draws the two icons and their names. This
// picture is only what is behind them: a title, a card under each icon, three chevrons
// from one to the other, and, for an app Apple has not checked, the step macOS will ask for.
//
// THE PICTURE IS LIGHT ON PURPOSE. Over a background picture, Finder writes the icons'
// names in black, in light mode and in dark mode alike (seen on macOS 27 in dark mode: the
// first version was grey-blue, to be safe under white names that never came). Black names
// need a light ground, so each icon sits on a white card.
//
// --mock adds stand-ins for what Finder draws (the two icons and their names) and writes
// mock@2x.png only: the design can be looked at without building and opening an image.
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard let folderPath = arguments.first(where: { !$0.hasPrefix("--") }) else {
    print("usage: swift scripts/make-dmg-background.swift <folder> [--notarized] [--mock]")
    exit(1)
}
/// A notarized app opens with one ordinary question: there is nothing to warn about.
let notarized = arguments.contains("--notarized")
let mock = arguments.contains("--mock")
let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

// The window's content, in points. The icons' places are also in scripts/dmg-settings.py.
// The picture is drawn taller than the window shows (about 396 points on macOS 27, where
// the title bar takes 32 of the window's 428): a window that turns out a little higher
// shows more of the same ground, not a white strip.
let width = 600.0
let height = 460.0
let iconY = 180.0               // the icons' centre, from the top
let iconSize = 112.0
let appX = 150.0
let applicationsX = 450.0

// The app icon's two colours, and the two greys of the text.
let blue = (red: 0.16, green: 0.42, blue: 0.96)
let teal = (red: 0.10, green: 0.72, blue: 0.80)
let ink = NSColor(srgbRed: 0.09, green: 0.11, blue: 0.17, alpha: 1)
let softInk = NSColor(srgbRed: 0.36, green: 0.40, blue: 0.47, alpha: 1)

func font(_ size: Double, _ weight: NSFont.Weight, rounded: Bool = false) -> NSFont {
    let plain = NSFont.systemFont(ofSize: size, weight: weight)
    guard rounded, let descriptor = plain.fontDescriptor.withDesign(.rounded) else { return plain }
    return NSFont(descriptor: descriptor, size: size) ?? plain
}

func background(scale: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: Int(width) * scale, height: Int(height) * scale,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    // From here on, distances are in points. Core Graphics counts y upwards from the
    // bottom; a window is read from the top. These two turn "this far under the top
    // edge" into Core Graphics' direction.
    func fromTop(_ y: Double) -> Double { height - y }
    func box(x: Double, top: Double, width: Double, height boxHeight: Double) -> CGRect {
        CGRect(x: x, y: fromTop(top) - boxHeight, width: width, height: boxHeight)
    }
    func color(_ rgb: (red: Double, green: Double, blue: Double), _ alpha: Double) -> CGColor {
        CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    // The ground: almost white, a little cooler at the bottom.
    let ground = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.965, green: 0.975, blue: 0.995, alpha: 1),
                                                         CGColor(srgbRed: 0.925, green: 0.945, blue: 0.975, alpha: 1)] as CFArray,
                            locations: [0, 1])!
    context.drawLinearGradient(ground, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    // Two soft glows in the icon's colours, one in each far corner: the same blue and
    // teal as the app, very faint, so the window belongs to the app without shouting.
    func glow(_ rgb: (red: Double, green: Double, blue: Double), x: Double, top: Double, radius: Double, strength: Double) {
        let gradient = CGGradient(colorsSpace: space, colors: [color(rgb, strength), color(rgb, 0)] as CFArray, locations: [0, 1])!
        let centre = CGPoint(x: x, y: fromTop(top))
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
    }
    glow(blue, x: 40, top: 10, radius: 330, strength: 0.26)
    glow(teal, x: 580, top: 370, radius: 340, strength: 0.24)

    // A white card under each icon and its name.
    for x in [appX, applicationsX] {
        let card = box(x: x - 86, top: 96, width: 172, height: 192)
        let shape = CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil)
        // The shadow first, kept OUTSIDE the card: under a see-through card it would
        // show through and turn the card grey. (A shadow's size ignores the scale set
        // above, so it is multiplied by hand.)
        context.saveGState()
        context.addRect(CGRect(x: 0, y: 0, width: width, height: height))
        context.addPath(shape)
        context.clip(using: .evenOdd)
        context.setShadow(offset: CGSize(width: 0, height: -10 * Double(scale)), blur: 28 * Double(scale),
                          color: CGColor(srgbRed: 0.10, green: 0.20, blue: 0.40, alpha: 0.20))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.addPath(shape)
        context.setFillColor(CGColor(gray: 1, alpha: 0.80))
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1)
        context.strokePath()
    }

    // Three chevrons from the app towards the folder, fading in: blue to teal.
    context.setLineWidth(3.6)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for (index, alpha) in [0.30, 0.62, 1.0].enumerated() {
        let x = 300.0 + Double(index - 1) * 17
        let y = fromTop(iconY)
        let mix = Double(index) / 2
        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: x - 4.5, y: y + 10))
        chevron.addLine(to: CGPoint(x: x + 4.5, y: y))
        chevron.addLine(to: CGPoint(x: x - 4.5, y: y - 10))
        context.addPath(chevron)
        context.setStrokeColor(CGColor(srgbRed: blue.red + (teal.red - blue.red) * mix, green: blue.green + (teal.green - blue.green) * mix,
                                       blue: blue.blue + (teal.blue - blue.blue) * mix, alpha: alpha))
        context.strokePath()
    }

    // Text is drawn by AppKit, which needs to be told which canvas is the current one.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    func write(_ string: NSAttributedString, centredAt y: Double, around x: Double = width / 2) {
        let size = string.size()
        string.draw(at: CGPoint(x: x - size.width / 2, y: fromTop(y) - size.height / 2))
    }
    func text(_ words: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: color])
    }

    write(text("Install Blink Monitor", font(25, .bold, rounded: true), ink), centredAt: 42)
    write(text("Drag the app onto the Applications folder", font(13.5, .regular), softInk), centredAt: 70)

    if notarized {
        write(text("Then open it from your Applications folder.", font(12.5, .regular), softInk), centredAt: 336)
    } else {
        // Said here because this is where the person is when it happens. The README has
        // the same steps with more words. A pill of its own: it is a notice, not a title.
        let pill = box(x: 78, top: 312, width: 444, height: 58)
        let shape = CGPath(roundedRect: pill, cornerWidth: 18, cornerHeight: 18, transform: nil)
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 1, alpha: 0.62))
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(1)
        context.strokePath()

        write(text("The first time, macOS stops it: Apple has not checked this free app.", font(12, .regular), softInk),
              centredAt: 331)
        let way = NSMutableAttributedString()
        way.append(text("Allow it in  ", font(12, .regular), softInk))
        way.append(text("System Settings  ›  Privacy & Security  ›  Open Anyway", font(12, .semibold), ink))
        write(way, centredAt: 351)
    }

    if mock {
        // Stand-ins for what Finder adds: the two icons, and their names in black.
        let icons = [(appX, NSImage(contentsOfFile: "App/AppIcon.icns"), "Blink Monitor"),
                     (applicationsX, Optional(NSWorkspace.shared.icon(forFile: "/Applications")), "Applications")]
        for (x, icon, name) in icons {
            icon?.draw(in: CGRect(x: x - iconSize / 2, y: fromTop(iconY) - iconSize / 2, width: iconSize, height: iconSize))
            write(text(name, font(13, .regular), .black), centredAt: iconY + 75, around: x)
        }
    }
    NSGraphicsContext.current = nil
    return context.makeImage()!
}

for scale in [1, 2] {
    if mock && scale == 1 { continue }
    let bitmap = NSBitmapImageRep(cgImage: background(scale: scale))
    // The size in POINTS is what makes the second file "the same picture, twice as fine"
    // and not "a picture twice as big".
    bitmap.size = NSSize(width: width, height: height)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        print("The background could not be encoded.")
        exit(1)
    }
    let name = mock ? "mock@2x.png" : (scale == 1 ? "background.png" : "background@2x.png")
    try png.write(to: folder.appendingPathComponent(name))
}

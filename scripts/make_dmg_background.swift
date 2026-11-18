// make_dmg_background.swift — draws the background of the Waverly disk image window:
// the sunset of the app icon (indigo #1F2752 → plum #7A3E6E → ember #E9895A), a few
// stars, the icon's warm glow on the horizon and a subtle arrow from the app to the
// Applications folder.
//
//   swift scripts/make_dmg_background.swift <out-dir>     -> background.png (640×400) + background@2x.png
//
// The icon labels sit on an even rose band (#A2637D, relative luminance 0.18), so
// Finder's label text reads in both black (light appearance) and white (dark
// appearance) at better than 4.5:1.
// Layout constants must match scripts/make_dmg.sh (window 640×400, icons at
// (170, 175) and (470, 175), icon size 128).

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width = 640.0, height = 400.0
let appIcon = CGPoint(x: 170, y: 175), appsIcon = CGPoint(x: 470, y: 175)   // icon centres, from the top
let labelY = 175.0 + 64 + 18                                                  // centre of the label text

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat) -> CGImage {
    let w = Int(width * Double(scale)), h = Int(height * Double(scale))
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // work top-down like Finder's coordinates
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // sky: the icon's indigo overhead, through plum to the rose horizon at the labels,
    // then down into the icon's ember
    let sky: [(Double, UInt32)] = [
        (0.00, 0x1F2752), (0.26, 0x29295A), (0.42, 0x3A2C61), (0.50, 0x553368), (0.56, 0x7A3E6E),
        (0.625, 0xA2637D), (0.69, 0xA2637D), (0.77, 0xB66D71), (0.88, 0xCF7B62), (1.00, 0xE9895A),
    ]
    let g = CGGradient(colorsSpace: cs, colors: sky.map { rgb($0.1) } as CFArray, locations: sky.map { CGFloat($0.0) })!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: height), options: [])

    // the icon's warm glow rising behind the horizon, between the two icons
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFB27A, 0.34), rgb(0xE9895A, 0.16), rgb(0xE9895A, 0)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.saveGState()
    ctx.translateBy(x: width / 2, y: labelY - 30)
    ctx.scaleBy(x: 2.4, y: 0.8)
    ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 150, options: [])
    ctx.restoreGState()

    // an even band under the labels so both label colours keep their contrast
    let band = CGGradient(colorsSpace: cs, colors: [rgb(0xA2637D, 0), rgb(0xA2637D, 1), rgb(0xA2637D, 1), rgb(0xA2637D, 0)] as CFArray,
                          locations: [0, 0.3, 0.7, 1])!
    ctx.drawLinearGradient(band, start: CGPoint(x: 0, y: labelY - 34), end: CGPoint(x: 0, y: labelY + 30), options: [])

    // stars
    var seed: UInt64 = 0x5EED_4D75
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
    for _ in 0..<38 {
        let p = CGPoint(x: rnd() * width, y: rnd() * height * 0.42)
        let r = 0.45 + rnd() * 0.75
        let a = 0.18 + rnd() * 0.45 * (1 - p.y / (height * 0.42))
        ctx.setFillColor(rgb(0xFFFFFF, a))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    // the arrow: a soft line with a rounded chevron, from the app to Applications
    let x0 = appIcon.x + 84, x1 = appsIcon.x - 84, y = appIcon.y
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let shaft = CGGradient(colorsSpace: cs, colors: [rgb(0xFFF9F1, 0.1), rgb(0xFFD9A8, 0.7)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: x0, y: y))
    ctx.addLine(to: CGPoint(x: x1 - 2, y: y))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(shaft, start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0xFFD9A8, 0.75))
    ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: x1 - 13, y: y - 12))
    ctx.addLine(to: CGPoint(x: x1, y: y))
    ctx.addLine(to: CGPoint(x: x1 - 13, y: y + 12))
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ img: CGImage, _ url: URL, dpi: Double) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
write(render(scale: 1), out.appendingPathComponent("background.png"), dpi: 72)
write(render(scale: 2), out.appendingPathComponent("background@2x.png"), dpi: 144)
print("wrote \(out.path)/background.png and background@2x.png")

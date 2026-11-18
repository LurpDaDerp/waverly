// Palette.swift — the ten label colours shared with hud-core and the page
// (spec §3). Python and the page use the same ids; they draw the `dark` / `light`
// tones, the Swift settings UI draws the `swatch` tone.

import AppKit
import SwiftUI

struct PaletteColor: Identifiable, Hashable {
    let id: String
    let swatch: NSColor
    /// For VoiceOver and tooltips ("Blue").
    var name: String { id.prefix(1).uppercased() + id.dropFirst() }
    var color: Color { Color(nsColor: swatch) }
}

enum Palette {
    static let all: [PaletteColor] = [
        ("blue", 0x5B8DEF), ("amber", 0xF0954A), ("teal", 0x2BB3A3), ("rose", 0xE5679A), ("violet", 0x9670EE),
        ("green", 0x63B84A), ("gold", 0xE3B93A), ("coral", 0xEE6B5A), ("cyan", 0x3BAEE3), ("slate", 0x8A94A6),
    ].map { PaletteColor(id: $0.0, swatch: NSColor(hex: $0.1)) }

    static func color(_ id: String?) -> PaletteColor? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func isValid(_ id: String?) -> Bool { color(id) != nil }

    /// A small round swatch for menu items (SwiftUI and AppKit menus only draw
    /// images), with a little room before the title.
    static func dotImage(_ id: String?, size: CGFloat = 10) -> NSImage {
        let fill = color(id)?.swatch ?? NSColor(white: 1, alpha: 0.3)
        let img = NSImage(size: NSSize(width: size + 3, height: size), flipped: false) { _ in
            fill.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1)).fill()
            return true
        }
        img.accessibilityDescription = color(id)?.name
        return img
    }

    /// The colour used by the fewest of `used` (ties: palette order), as hud-core
    /// picks automatic source colours.
    static func leastUsed(_ used: [String]) -> String {
        var counts: [String: Int] = [:]
        for u in used { counts[u, default: 0] += 1 }
        return all.min { counts[$0.id, default: 0] < counts[$1.id, default: 0] }!.id
    }
}

extension NSColor {
    /// An sRGB colour from 0xRRGGBB.
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

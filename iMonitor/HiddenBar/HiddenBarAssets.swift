//
//  HiddenBarAssets.swift
//  iMonitor
//
//  Ported from dwarvesf/hidden (MIT License, © Dwarves Foundation), with the
//  bitmap assets replaced by SF Symbols.
//  https://github.com/dwarvesf/hidden
//

import Cocoa

enum HiddenBarAssets {

    /// The `|` separator the user ⌘-drags left of the icons to hide. Drawn as a
    /// crisp vertical rule rather than an SF Symbol so its 1pt-ish weight reads
    /// like the system item separators.
    static let separatorImage: NSImage = {
        let scale: CGFloat = 2
        let image = NSImage(size: NSSize(width: 2, height: 14))
        image.addRepresentation(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(2 * scale), pixelsHigh: Int(14 * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!)
        image.lockFocus()
        NSColor(white: 0.5, alpha: 0.6).setFill()
        NSRect(x: 0.5, y: 2, width: 0.5, height: 10).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()

    /// Shown while the hidden zone is already hidden: clicking expands it.
    static let expandImage = symbol("chevron.left")

    /// Shown while the hidden zone is visible: clicking hides it again.
    static let collapseImage = symbol("chevron.right")

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: name)
        image?.isTemplate = true
        return image
    }
}

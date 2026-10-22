//
//  OverflowRowView.swift
//  iMonitor
//
//  A row of the Notch Overflow menu, drawn as a custom item view instead of a
//  plain NSMenuItem title. Three things need the real view: the app icon,
//  which NSMenuItem.image renders garbled for the lazily-drawn images macOS
//  returns from NSRunningApplication; the shown/not-shown eye marker; and
//  ⌘-drag delivery, which plain menu items never hand to their owner.
//

import Cocoa

final class OverflowRowView: NSView {

    /// Where this row sits in the menu's flat reorderable list. Handed to the
    /// drag session so it can name the dragged row without hunting for its
    /// Accessibility element (one app can own several identical status items).
    let rowIndex: Int
    let info: MenuBarExtraInfo
    let isHiddenRow: Bool

    /// ⌘-click: begin a rearrangement drag. The handler tears the menu down.
    var onCommandDrag: ((OverflowRowView) -> Void)?
    /// Plain click inside the row: activate the real menu-bar item.
    var onActivate: ((MenuBarExtraInfo) -> Void)?

    static let rowHeight: CGFloat = 24
    /// Native menu-bar icon size. App icons are scaled down to this slot;
    /// symbols keep their natural proportions (a 2:1 battery must not be
    /// stretched into a square).
    static let iconSize: CGFloat = 18
    /// Width of the shown/not-shown eye slot every row reserves (see `drawRow`).
    static let eyeSize: CGFloat = 13
    static let horizontalPadding: CGFloat = 8
    static let iconEyeSpacing: CGFloat = 6
    static let eyeTextSpacing: CGFloat = 6

    /// Width one row needs for `title`, so a build can give every row the same
    /// width and the menu sizes itself like a normal one.
    static func preferredWidth(forTitle title: String, hidden: Bool) -> CGFloat {
        let textWidth = (title as NSString)
            .size(withAttributes: [.font: font(hidden: hidden)]).width
        return horizontalPadding + iconSize + iconEyeSpacing + eyeSize + eyeTextSpacing + textWidth
            + horizontalPadding
    }

    /// Title for the Accessibility tree. The eye marker says shown/not-shown on
    /// screen, but Assistive clients cannot see it (nor is bold weight alone an
    /// accessible signal), so hidden rows spell the state out in words.
    static func accessibilityTitle(title: String, hidden: Bool) -> String {
        hidden ? "\(title) (hidden)" : title
    }

    private static func font(hidden: Bool) -> NSFont {
        hidden ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
    }

    /// SF Symbols for the eye marker. Drawn as templates, so the current color
    /// applies; a crossed-out eye marks the rows the bar is not showing.
    private static let eyeImage = eyeSymbol("eye")
    private static let eyeSlashImage = eyeSymbol("eye.slash")

    private static func eyeSymbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: eyeSize - 1, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    init(rowIndex: Int, info: MenuBarExtraInfo, hidden: Bool, width: CGFloat) {
        self.rowIndex = rowIndex
        self.info = info
        self.isHiddenRow = hidden
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
    }

    required init?(coder: NSCoder) {
        fatalError("OverflowRowView is created in code only")
    }

    private var title: String {
        info.displayName
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Self.drawRow(
            icon: info.displayIcon, title: title, hidden: isHiddenRow,
            highlighted: enclosingMenuItem?.isHighlighted == true,
            in: bounds)
    }

    /// Shared by the menu rows and the drag session's replica, so a row looks
    /// identical in both. `rect` is one row tall; content is centred in it and
    /// drawing works in flipped and unflipped contexts alike.
    static func drawRow(
        icon: NSImage?, title: String, hidden: Bool, highlighted: Bool, in rect: NSRect
    ) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
        }

        let iconRect = NSRect(
            x: rect.minX + horizontalPadding,
            y: rect.midY - iconSize / 2,
            width: iconSize, height: iconSize)
        if let icon = icon {
            // Template glyphs take the row's text color so a system symbol stays
            // visible in Dark Mode; app icons keep their own colors.
            let iconColor =
                highlighted
                ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
            // Aspect-fit, never upscale: app icons come back from
            // NSRunningApplication at 32 pt and shrink to the slot; a system
            // symbol keeps its own (often non-square) proportions instead of
            // being stretched to fill it.
            Self.draw(
                icon, in: Self.aspectFit(icon, in: iconRect), color: iconColor,
                fraction: hidden ? 0.6 : 1.0)
        }

        // Shown/not-shown marker: an eye in a fixed-width slot after the app
        // icon, so every title starts at the same x. A crossed-out eye marks
        // the rows the bar is not showing (they can still be activated here);
        // the muted color matches their dimmed app icon.
        let eyeRect = NSRect(
            x: iconRect.maxX + iconEyeSpacing,
            y: rect.midY - eyeSize / 2,
            width: eyeSize, height: eyeSize)
        if let eye = hidden ? eyeSlashImage : eyeImage {
            let eyeColor: NSColor =
                highlighted
                ? .selectedMenuItemTextColor : (hidden ? .secondaryLabelColor : .labelColor)
            Self.draw(eye, in: eyeRect, color: eyeColor)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(hidden: hidden),
            .foregroundColor: highlighted
                ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
        ]
        let textX = eyeRect.maxX + eyeTextSpacing
        let text = fitted(
            title,
            attributes: attributes,
            maxWidth: rect.maxX - horizontalPadding - textX)
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: textX, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    /// Draws an image at its original colors, or tints a template image with
    /// `color` (an SF Symbol drawn manually does not pick up the current
    /// NSColor by itself, and would stay black in Dark Mode).
    private static func draw(
        _ image: NSImage, in rect: NSRect, color: NSColor, fraction: CGFloat = 1.0
    ) {
        let source = image.isTemplate ? tinted(image, with: color) : image
        source.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: fraction,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    /// A copy of `image` whose opaque pixels are `color`. The handler runs at
    /// draw time, so the tint follows the row's current appearance.
    private static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(rect: rect).fill()
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private static func aspectFit(_ image: NSImage, in rect: NSRect) -> NSRect {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height, 1)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(
            x: rect.midX - width / 2, y: rect.midY - height / 2,
            width: width, height: height)
    }

    private static func fitted(
        _ text: String, attributes: [NSAttributedString.Key: Any], maxWidth: CGFloat
    ) -> String {
        guard (text as NSString).size(withAttributes: attributes).width > maxWidth else {
            return text
        }
        var kept = ""
        for character in text {
            let candidate = kept + String(character) + "\u{2026}"
            if (candidate as NSString).size(withAttributes: attributes).width > maxWidth { break }
            kept.append(character)
        }
        return kept + "\u{2026}"
    }

    // MARK: - Mouse

    // Plain menu items never see mouse events; a custom item view does, which is
    // the whole point: it is how ⌘-drag is told apart from a click. The menu's
    // own tracking loop still highlights rows and handles keyboard navigation.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onCommandDrag?(self)
        }
        // Plain click: leave it to mouse-up, exactly like a menu item.
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), menu.highlightedItem === item {
            // View-based rows do not run the item action for clicks, so close
            // the menu and activate explicitly.
            menu.cancelTracking()
            onActivate?(info)
            return
        }
        // Released over another row: plain rows are fired by the menu itself,
        // but a sibling custom row relies on the view that captured the drag.
        if let highlighted = menu.highlightedItem, highlighted.view is OverflowRowView {
            menu.performActionForItem(at: menu.index(of: highlighted))
        }
    }
}

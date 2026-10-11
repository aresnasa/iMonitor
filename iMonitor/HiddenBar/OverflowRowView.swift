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
    static let iconSize: CGFloat = 16
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
        (info.title?.isEmpty == false) ? info.title! : info.appName
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Self.drawRow(
            icon: info.appIcon, title: title, hidden: isHiddenRow,
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
            // Drawn straight from the original multi-representation image, so
            // AppKit picks the Retina-crisp one; see the header.
            icon.draw(
                in: iconRect, from: .zero, operation: .sourceOver,
                fraction: hidden ? 0.6 : 1.0, respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue])
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
            eyeColor.set()
            eye.draw(
                in: eyeRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue])
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

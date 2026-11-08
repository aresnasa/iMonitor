import Cocoa

class StatusBarIconView: NSView {

    private static let barWidth: CGFloat = 4
    private static let barSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 1

    var cpuUsage: Double = 0 { didSet { needsDisplay = true } }
    var memoryUsage: Double = 0 { didSet { needsDisplay = true } }
    var gpuUsage: Double = 0 { didSet { needsDisplay = true } }
    var totalInBytes: Int = 0 { didSet { needsDisplay = true } }
    var totalOutBytes: Int = 0 { didSet { needsDisplay = true } }

    var usedColor: NSColor = ColorThemePreset.default.colors.used.nsColor {
        didSet { needsDisplay = true }
    }
    var overloadedColor: NSColor = ColorThemePreset.default.colors.overloaded.nsColor {
        didSet { needsDisplay = true }
    }
    var freeColor: NSColor = ColorThemePreset.default.colors.free.nsColor {
        didSet { needsDisplay = true }
    }

    // Cache font — avoids creating NSFont on every draw call
    private let netFont: NSFont = {
        if #available(macOS 12.0, *) {
            return NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        } else {
            return NSFont.systemFont(ofSize: 10, weight: .medium)
        }
    }()

    // Cache text attributes — avoids dictionary creation on every draw call
    private lazy var textAttrs: [NSAttributedString.Key: Any] = {
        [.font: netFont, .foregroundColor: NSColor.labelColor] as [NSAttributedString.Key: Any]
    }()

    override var isFlipped: Bool { true }

    private static let barsWidth = barWidth * 3 + barSpacing * 2
    private static let barsTextGap: CGFloat = 4

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let h = bounds.height
        let bars: [Double] = [cpuUsage, memoryUsage, gpuUsage]

        let upStr = "↑" + formatBytesShort(totalOutBytes)
        let dnStr = "↓" + formatBytesShort(totalInBytes)
        let upAttrStr = NSAttributedString(string: upStr, attributes: textAttrs)
        let dnAttrStr = NSAttributedString(string: dnStr, attributes: textAttrs)
        let textWidth = ceil(max(upAttrStr.size().width, dnAttrStr.size().width))

        // Center the bars + text block in the slot. The slot width is a user
        // setting, so a wide one leaves balanced padding on both sides instead
        // of a gap on one side only.
        let contentWidth = Self.barsWidth + Self.barsTextGap + textWidth
        let contentX = max(0, floor((bounds.width - contentWidth) / 2))

        for (index, usage) in bars.enumerated() {
            let x = contentX + CGFloat(index) * (Self.barWidth + Self.barSpacing)
            let clamped = min(max(usage, 0), 1)

            let usedHeight = h * CGFloat(clamped)
            let usedRect = NSRect(x: x, y: 0, width: Self.barWidth, height: usedHeight)

            let color = clamped < ThemeModel.overloadedThreshold ? usedColor : overloadedColor
            context.setFillColor(color.cgColor)
            context.addPath(makeRoundedRectPath(usedRect))
            context.fillPath()

            let freeY = usedHeight
            let freeHeight = h - usedHeight
            if freeHeight > 0 {
                let freeRect = NSRect(x: x, y: freeY, width: Self.barWidth, height: freeHeight)
                context.setFillColor(freeColor.cgColor)
                context.addPath(makeRoundedRectPath(freeRect))
                context.fillPath()
            }
        }

        let netX = contentX + Self.barsWidth + Self.barsTextGap

        upAttrStr.draw(at: NSPoint(x: netX, y: 0))

        let dnSize = dnAttrStr.size()
        dnAttrStr.draw(at: NSPoint(x: netX, y: h - dnSize.height))
    }

    private func makeRoundedRectPath(_ rect: NSRect) -> CGPath {
        if #available(macOS 12.0, *) {
            return CGPath(
                roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil)
        } else {
            return CGPath(rect: rect, transform: nil)
        }
    }

    private func formatBytesShort(_ bytes: Int) -> String {
        if bytes <= 0 { return "0K" }
        let kb = Double(bytes) / 1024
        if kb < 1000 { return String(format: "%.0fK", kb) }
        let mb = kb / 1024
        if mb < 1000 { return String(format: "%.0fM", mb) }
        let gb = mb / 1024
        return String(format: "%.0fG", gb)
    }
}

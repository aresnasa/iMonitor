import Cocoa

class StatusBarIconView: NSView {

    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 1

    var cpuUsage: Double = 0 { didSet { needsDisplay = true } }
    var memoryUsage: Double = 0 { didSet { needsDisplay = true } }
    var gpuUsage: Double = 0 { didSet { needsDisplay = true } }
    var totalInBytes: Int = 0 { didSet { needsDisplay = true } }
    var totalOutBytes: Int = 0 { didSet { needsDisplay = true } }

    var usedColor: NSColor = ColorThemePreset.default.colors.used.nsColor { didSet { needsDisplay = true } }
    var overloadedColor: NSColor = ColorThemePreset.default.colors.overloaded.nsColor { didSet { needsDisplay = true } }
    var freeColor: NSColor = ColorThemePreset.default.colors.free.nsColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let h = bounds.height
        let bars: [Double] = [cpuUsage, memoryUsage, gpuUsage]

        for (index, usage) in bars.enumerated() {
            let x = CGFloat(index) * (barWidth + barSpacing)
            let clamped = min(max(usage, 0), 1)

            let usedHeight = h * CGFloat(clamped)
            let usedRect = NSRect(x: x, y: 0, width: barWidth, height: usedHeight)

            let color = clamped < ThemeModel.overloadedThreshold ? usedColor : overloadedColor
            context.setFillColor(color.cgColor)
            let usedPath = makeRoundedRectPath(usedRect)
            context.addPath(usedPath)
            context.fillPath()

            let freeY = usedHeight
            let freeHeight = h - usedHeight
            if freeHeight > 0 {
                let freeRect = NSRect(x: x, y: freeY, width: barWidth, height: freeHeight)
                context.setFillColor(freeColor.cgColor)
                let freePath = makeRoundedRectPath(freeRect)
                context.addPath(freePath)
                context.fillPath()
            }
        }

        let barsWidth = barWidth * 3 + barSpacing * 2
        let netX = barsWidth + 4

        let font = makeMonospacedFont(size: 10)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        let upStr = "↑" + formatBytesShort(totalOutBytes)
        let dnStr = "↓" + formatBytesShort(totalInBytes)

        let upAttrStr = NSAttributedString(string: upStr, attributes: attrs)
        upAttrStr.draw(at: NSPoint(x: netX, y: 0))

        let dnAttrStr = NSAttributedString(string: dnStr, attributes: attrs)
        let dnSize = dnAttrStr.size()
        dnAttrStr.draw(at: NSPoint(x: netX, y: h - dnSize.height))
    }

    /// CGPath(roundedRect:) is macOS 12+. Fall back to plain rect on older systems.
    private func makeRoundedRectPath(_ rect: NSRect) -> CGPath {
        if #available(macOS 12.0, *) {
            return CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        } else {
            return CGPath(rect: rect, transform: nil)
        }
    }

    /// NSFont.monospacedSystemFont(ofSize:weight:) is macOS 12+.
    /// Fall back to system font of medium weight on older macOS.
    private func makeMonospacedFont(size: CGFloat) -> NSFont {
        if #available(macOS 12.0, *) {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        } else {
            return NSFont.systemFont(ofSize: size, weight: .medium)
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

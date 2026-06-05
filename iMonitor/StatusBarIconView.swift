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

    // Flip coordinates so (0,0) is top-left
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let h = bounds.height
        let bars: [Double] = [cpuUsage, memoryUsage, gpuUsage]

        // Draw 3 bars, aligned to top of the view
        for (index, usage) in bars.enumerated() {
            let x = CGFloat(index) * (barWidth + barSpacing)
            let clamped = min(max(usage, 0), 1)

            // Used portion (top, from y=0 downward)
            let usedHeight = h * CGFloat(clamped)
            let usedRect = NSRect(x: x, y: 0, width: barWidth, height: usedHeight)

            let color: NSColor
            if clamped < 0.6 {
                color = NSColor.systemOrange.withAlphaComponent(0.85)
            } else if clamped < 0.85 {
                color = NSColor.systemYellow.withAlphaComponent(0.9)
            } else {
                color = NSColor.systemRed.withAlphaComponent(0.9)
            }
            context.setFillColor(color.cgColor)
            let usedPath = CGPath(roundedRect: usedRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(usedPath)
            context.fillPath()

            // Free portion (green, below used)
            let freeY = usedHeight
            let freeHeight = h - usedHeight
            if freeHeight > 0 {
                let freeRect = NSRect(x: x, y: freeY, width: barWidth, height: freeHeight)
                context.setFillColor(NSColor.systemGreen.withAlphaComponent(0.5).cgColor)
                let freePath = CGPath(roundedRect: freeRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                context.addPath(freePath)
                context.fillPath()
            }
        }

        // Network text on the right of bars
        let barsWidth = barWidth * 3 + barSpacing * 2
        let netX = barsWidth + 4

        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        let upStr = "↑" + formatBytesShort(totalOutBytes)
        let dnStr = "↓" + formatBytesShort(totalInBytes)

        // Upload - top half
        let upAttrStr = NSAttributedString(string: upStr, attributes: attrs)
        upAttrStr.draw(at: NSPoint(x: netX, y: 0))

        // Download - bottom half
        let dnAttrStr = NSAttributedString(string: dnStr, attributes: attrs)
        let dnSize = dnAttrStr.size()
        dnAttrStr.draw(at: NSPoint(x: netX, y: h - dnSize.height))
    }

    private func formatBytesShort(_ bytes: Int) -> String {
        if bytes <= 0 { return "0K" }
        let kb = Double(bytes) / 1024
        if kb < 1000 { return String(format: "%.0fK", kb) }
        let mb = kb / 1024
        if mb < 1000 { return String(format: "%.1fM", mb) }
        let gb = mb / 1024
        return String(format: "%.1fG", gb)
    }
}

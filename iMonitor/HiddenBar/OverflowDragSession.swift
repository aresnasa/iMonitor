//
//  OverflowDragSession.swift
//  iMonitor
//
//  The ⌘-drag reordering interaction for the Notch Overflow menu. NSMenu has no
//  reorder machinery, and the icons this popup exists for cannot be ⌘-dragged on
//  the real bar (they are the ones squeezed under the notch), so the popup has
//  to supply the interaction itself: tear the menu down, put a transparent
//  replica in its place, track the mouse, and on release let the controller
//  synthesise a real ⌘-drag on the bar (MenuBarItemMover) to apply the order.
//

import Cocoa

final class OverflowDragSession {

    /// One reorderable row of the popup, in menu order.
    struct Row {
        let info: MenuBarExtraInfo
        let title: String
        let isHiddenRow: Bool
    }

    private let rows: [Row]
    private let draggedIndex: Int
    private let menuFrame: NSRect
    /// The rows' exact screen rects, captured from the still-open menu, so the
    /// replica draws each row where it really sat and a cursor position maps to
    /// the same row the user saw.
    private let rowRects: [NSRect]
    /// Called with (dragged row index, insertion gap 0...rows.count). Set by the
    /// owner after init so the closures can identify this session by identity.
    var onFinish: ((Int, Int) -> Void)?
    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private weak var overlay: OverflowReplicaView?
    private var monitors: [Any] = []
    private var insertionGap: Int
    private var finished = false

    /// Vertical margin the panel adds above and below the menu's frame so the
    /// dragged row can travel a little past the list before the panel clips it.
    static let verticalMargin: CGFloat = 80

    init(rows: [Row], draggedIndex: Int, menuFrame: NSRect, rowRects: [NSRect]) {
        self.rows = rows
        self.draggedIndex = draggedIndex
        self.menuFrame = menuFrame
        self.rowRects = rowRects
        self.insertionGap = draggedIndex
    }

    deinit {
        removeMonitors()
    }

    // MARK: - Lifecycle

    /// Put up the replica and start tracking. Call from the main queue *after*
    /// the menu has been told to close, so the two never overlap.
    func start() {
        // A fast click can be released before the menu's tracking loop hands
        // control back - in that case the mouse-up was eaten by the menu and a
        // session would wait for a release that already happened.
        guard !finished, rows.indices.contains(draggedIndex),
            NSEvent.pressedMouseButtons & 0x1 != 0
        else {
            cancel()
            return
        }
        let frame = NSRect(
            x: menuFrame.minX, y: menuFrame.minY - Self.verticalMargin,
            width: menuFrame.width, height: menuFrame.height + Self.verticalMargin * 2)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Every event goes through the monitors; the panel must never intercept
        // the mouse, or the held button would break the drag.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // Menu-shaped backdrop exactly where the menu sat, so the list reads as
        // "the same menu, still open" while the row follows the cursor.
        let backdrop = NSVisualEffectView(
            frame: NSRect(
                x: 0, y: Self.verticalMargin, width: frame.width, height: menuFrame.height))
        backdrop.material = .menu
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.layer?.masksToBounds = true

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let overlay = OverflowReplicaView(
            frame: NSRect(origin: .zero, size: frame.size),
            band: NSRect(
                x: 0, y: Self.verticalMargin, width: frame.width, height: menuFrame.height),
            screenRowRects: rowRects)
        overlay.rows = rows
        overlay.draggedIndex = draggedIndex
        overlay.insertionGap = insertionGap
        content.addSubview(backdrop)
        content.addSubview(overlay)
        panel.contentView = content

        self.panel = panel
        self.overlay = overlay
        panel.orderFrontRegardless()

        // The pointer is already where the user pressed: over the row.
        update(atScreenPoint: NSEvent.mouseLocation)
        installMonitors()
    }

    private func installMonitors() {
        // Local covers events delivered to this app (the normal case while the
        // button that opened the menu is still held); global is the safety net
        // for releases that get routed elsewhere.
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }  // ESC cancels
                self.cancel()
                return nil
            }
            self.handle(event.type, atScreenPoint: NSEvent.mouseLocation)
            return event
        }
        if let local = local {
            monitors.append(local)
        }

        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self else { return }
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                // A fresh press with our release never seen: the up was lost.
                self.cancel()
            default:
                self.handle(event.type, atScreenPoint: NSEvent.mouseLocation)
            }
        }
        if let global = global {
            monitors.append(global)
        }
    }

    private func handle(_ type: NSEvent.EventType, atScreenPoint point: NSPoint) {
        guard !finished else { return }
        switch type {
        case .leftMouseDragged:
            update(atScreenPoint: point)
        case .leftMouseUp:
            finish(atScreenPoint: point)
        default:
            break
        }
    }

    private func update(atScreenPoint point: NSPoint) {
        guard let overlay = overlay else { return }
        overlay.cursor = overlay.viewPoint(fromScreen: point)
        insertionGap = overlay.insertionGap(forCursorY: overlay.cursor.y)
        overlay.insertionGap = insertionGap
        overlay.needsDisplay = true
    }

    private func finish(atScreenPoint point: NSPoint) {
        guard !finished else { return }
        finished = true
        update(atScreenPoint: point)
        let gap = insertionGap
        tearDown()
        onFinish?(draggedIndex, gap)
    }

    /// Ends the session without a move. Also used by the owner to clear a
    /// session whose mouse-up never arrived.
    func cancel() {
        guard !finished else { return }
        finished = true
        tearDown()
        onCancel?()
    }

    private func tearDown() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        overlay = nil
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }
}

// MARK: - Replica View

/// Draws the menu replica: every row where it sat, an empty slot where the
/// dragged row was, an insertion line at the drop gap, and the dragged row
/// itself following the cursor like a drag image.
final class OverflowReplicaView: NSView {

    var rows: [OverflowDragSession.Row] = []
    var draggedIndex = 0
    var insertionGap = 0
    var cursor: NSPoint = .zero

    /// Where the menu's list sat, in this view's flipped coordinates.
    private let band: NSRect
    /// The rows' screen rects as captured from the menu; used verbatim so the
    /// replica matches what the user saw, headers and separators included.
    private let screenRowRects: [NSRect]

    init(frame: NSRect, band: NSRect, screenRowRects: [NSRect]) {
        self.band = band
        self.screenRowRects = screenRowRects
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("OverflowReplicaView is created in code only")
    }

    override var isFlipped: Bool { true }

    /// Screen point (AppKit coordinates) → this view's coordinates.
    func viewPoint(fromScreen point: NSPoint) -> NSPoint {
        guard let frame = window?.frame else { return .zero }
        return NSPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }

    /// Row rects as drawn, top row first, matching the menu's order.
    func rowRects() -> [NSRect] {
        guard !rows.isEmpty else { return [] }
        if screenRowRects.count == rows.count, let frame = window?.frame {
            return screenRowRects.map { rect in
                NSRect(
                    x: rect.minX - frame.minX, y: frame.maxY - rect.maxY,
                    width: rect.width, height: rect.height)
            }
        }
        // Fallback for a menu that could not be measured (still matches the
        // view's coordinate space): centre the list in the band.
        let total = CGFloat(rows.count) * OverflowRowView.rowHeight
        let top = band.minY + max(0, (band.height - total) / 2)
        return (0..<rows.count).map { index in
            NSRect(
                x: band.minX + 8, y: top + CGFloat(index) * OverflowRowView.rowHeight,
                width: band.width - 16, height: OverflowRowView.rowHeight)
        }
    }

    /// Gap index (0...rows.count) for a cursor Y, with the dragged row's own
    /// slot counted in place — so dropping back onto it means "no change".
    func insertionGap(forCursorY y: CGFloat) -> Int {
        return rowRects().filter { $0.midY < y }.count
    }

    override func draw(_ dirtyRect: NSRect) {
        let rects = rowRects()
        guard !rects.isEmpty else { return }

        // The rows stay where they were, so the user keeps their bearings; the
        // dragged row leaves a hole.
        for (index, rect) in rects.enumerated() where index != draggedIndex {
            let row = rows[index]
            OverflowRowView.drawRow(
                icon: row.info.displayIcon, title: row.title, hidden: row.isHiddenRow,
                highlighted: false, in: rect)
        }

        let hole = rects[draggedIndex]
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: hole.insetBy(dx: 4, dy: 2), xRadius: 4, yRadius: 4).fill()

        drawInsertionLine(forGap: insertionGap, rows: rects)

        if let dragged = rows[safe: draggedIndex] {
            drawGhost(for: dragged)
        }
    }

    private func drawInsertionLine(forGap gap: Int, rows rects: [NSRect]) {
        let y: CGFloat
        if gap <= 0 {
            y = rects[0].minY - 3
        } else if gap >= rects.count {
            y = rects[rects.count - 1].maxY + 3
        } else {
            y = (rects[gap - 1].maxY + rects[gap].minY) / 2
        }
        let line = NSBezierPath()
        line.move(to: NSPoint(x: bounds.minX + 10, y: y))
        line.line(to: NSPoint(x: bounds.maxX - 10, y: y))
        line.lineWidth = 2
        line.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        line.stroke()
    }

    private func drawGhost(for row: OverflowDragSession.Row) {
        let size = NSSize(width: bounds.width - 24, height: OverflowRowView.rowHeight + 2)
        let x = min(max(cursor.x - 20, 8), bounds.width - size.width - 8)
        let y = min(max(cursor.y - size.height / 2, 2), bounds.height - size.height - 2)
        let ghost = NSRect(x: x, y: y, width: size.width, height: size.height)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: 2)
        shadow.set()
        NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: ghost, xRadius: 5, yRadius: 5).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: ghost, xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()

        OverflowRowView.drawRow(
            icon: row.info.displayIcon, title: row.title, hidden: row.isHiddenRow,
            highlighted: false, in: ghost.insetBy(dx: 0, dy: 1))
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

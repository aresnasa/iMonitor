//
//  MenuBarItemMover.swift
//  iMonitor
//
//  Moves a status item on the real menu bar. macOS offers no API for this; the
//  only supported way is the one the user has: ⌘-drag the icon. These events
//  synthesise that drag, which also makes the system play its normal live
//  rearrangement while it happens.
//

import ApplicationServices
import Cocoa

enum MenuBarItemMover {

    /// Move `source` so it takes `target`'s place on the bar — the same result
    /// as ⌘-dragging the source onto the target. Completion runs on the main
    /// queue; `true` means the bar accepted the move.
    ///
    /// - Parameters:
    ///   - allExtras: every item the popup listed; used to find a grab point
    ///     that only the source owns, since overlapped icons are exactly what
    ///     this feature exists for.
    static func move(
        source: MenuBarExtraInfo,
        target: MenuBarExtraInfo,
        allExtras: [MenuBarExtraInfo],
        completion: @escaping (Bool) -> Void
    ) {
        // Positions are read fresh: the popup's snapshot is from before the bar
        // expanded, and the drag must target the icons' live slots.
        let liveFrames: [(element: AXUIElement, frame: CGRect)] = allExtras.compactMap { info in
            guard let frame = liveFrame(of: info.element), frame.width > 0 else { return nil }
            return (info.element, frame)
        }
        guard
            let sourceFrame = liveFrames.first(where: { CFEqual($0.element, source.element) })?
                .frame,
            let targetFrame = liveFrames.first(where: { CFEqual($0.element, target.element) })?
                .frame
        else {
            AppLogger.warn("MenuBarItemMover: source or target has no readable frame")
            completion(false)
            return
        }

        let from = grabPoint(for: source.element, frame: sourceFrame, among: liveFrames)
        let to = CGPoint(x: targetFrame.midX, y: from.y)
        let returnCursor = currentCursorInCGCoordinates()
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let command: CGEventFlags = .maskCommand

        // A ⌘-drag as the system expects it: settle on the icon, press, glide
        // over, pause so the bar's live rearrangement catches up, then release.
        var steps: [(delay: TimeInterval, action: () -> Void)] = [
            (0.00, { _ = CGWarpMouseCursorPosition(from) }),
            (0.03, { post(.mouseMoved, at: from, flags: command, source: eventSource) }),
            (0.05, { post(.leftMouseDown, at: from, flags: command, source: eventSource) }),
        ]
        let glideSteps = 12
        for step in 1...glideSteps {
            let progress = CGFloat(step) / CGFloat(glideSteps)
            let point = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y)
            steps.append(
                (0.03, { post(.leftMouseDragged, at: point, flags: command, source: eventSource) }))
        }
        steps.append((0.12, { post(.leftMouseUp, at: to, flags: command, source: eventSource) }))
        steps.append((0.20, { _ = CGWarpMouseCursorPosition(returnCursor) }))
        steps.append(
            (
                0.05,
                {
                    // Report what actually happened instead of assuming success: when
                    // icons overlap, the bar may have grabbed a neighbour.
                    let landed =
                        liveFrame(of: source.element).map { frame in
                            abs(frame.midX - to.x) < max(24, frame.width)
                        } ?? false
                    if !landed {
                        AppLogger.warn(
                            "MenuBarItemMover: \(source.appName) did not land on the target; "
                                + "the bar may have grabbed an overlapping icon")
                    }
                    completion(landed)
                }
            ))
        run(steps)
    }

    // MARK: - Grab point

    /// Centre of the frame, or — when other icons overlap it — the first of its
    /// inner edges no other icon covers, so the bar's hit test picks the
    /// intended item.
    private static func grabPoint(
        for sourceElement: AXUIElement,
        frame: CGRect,
        among liveFrames: [(element: AXUIElement, frame: CGRect)]
    ) -> CGPoint {
        let covered = { (x: CGFloat) -> Bool in
            liveFrames.contains { other in
                !CFEqual(other.element, sourceElement)
                    && other.frame.contains(CGPoint(x: x, y: frame.midY))
            }
        }
        for candidate in [frame.midX, frame.minX + 5, frame.maxX - 5] where !covered(candidate) {
            return CGPoint(x: candidate, y: frame.midY)
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: - AX access

    private static func liveFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
                == .success,
            let positionValue = positionRef
        else { return nil }
        var position = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) else { return nil }

        var sizeRef: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
                == .success,
            let sizeValue = sizeRef
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }

        return CGRect(origin: position, size: size)
    }

    // MARK: - Event synthesis

    private static func post(
        _ type: CGEventType, at point: CGPoint, flags: CGEventFlags, source: CGEventSource?
    ) {
        guard
            let event = CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)
        else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    /// AX positions are already in the global display coordinates CGEvent uses
    /// (origin top-left of the primary display); NSEvent's are not.
    private static func currentCursorInCGCoordinates() -> CGPoint {
        let appKitPoint = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
    }

    private static func run(_ steps: [(delay: TimeInterval, action: () -> Void)]) {
        var remaining = steps
        func next() {
            guard !remaining.isEmpty else { return }
            let step = remaining.removeFirst()
            if step.delay <= 0 {
                step.action()
                next()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
                    step.action()
                    next()
                }
            }
        }
        next()
    }
}

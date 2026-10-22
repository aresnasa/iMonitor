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

        let from = grabPoint(for: source, frame: sourceFrame)
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
                    // Report what actually happened instead of assuming success. The
                    // tolerance must be tighter than the narrowest slot pitch, or a
                    // neighbouring item would look like a success.
                    let landed =
                        liveFrame(of: source.element).map { frame in
                            abs(frame.midX - to.x) < 12
                        } ?? false
                    if !landed {
                        AppLogger.warn(
                            "MenuBarItemMover: \(source.displayName) did not land on the target; "
                                + "the system ignored the synthetic drag or grabbed another icon")
                    }
                    completion(landed)
                }
            ))
        run(steps)
    }

    // MARK: - Grab point

    /// A pixel of `frame` that the system's own hit test attributes to the
    /// source, so the ⌘-drag grabs the intended icon (icons overlap by design in
    /// the pile this feature exists for). Items macOS no longer draws on the bar
    /// have no such pixel anywhere; the centre is returned then, and the
    /// caller's post-move check reports the failure.
    private static func grabPoint(for source: MenuBarExtraInfo, frame: CGRect) -> CGPoint {
        let systemWide = AXUIElementCreateSystemWide()
        var candidates: [CGFloat] = [frame.midX]
        var x = frame.minX + 2
        while x <= frame.maxX - 2 {
            candidates.append(x)
            x += 4
        }
        // Centre-out, so any accepted pixel stays as close to the centre as it
        // can.
        candidates.sort { abs($0 - frame.midX) < abs($1 - frame.midX) }

        for candidate in candidates {
            var hit: AXUIElement?
            guard
                AXUIElementCopyElementAtPosition(
                    systemWide, Float(candidate), Float(frame.midY), &hit)
                    == .success,
                let hit = hit, isSameItem(hit, as: source.element, frame: frame)
            else { continue }
            return CGPoint(x: candidate, y: frame.midY)
        }

        AppLogger.warn(
            "MenuBarItemMover: \(source.displayName) has no clickable pixel on the bar "
                + "(macOS is not drawing it); it cannot be dragged right now")
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The hit test hands back a freshly resolved element, often a child of the
    /// status item rather than the item itself, so both the element and its
    /// ancestors are checked. Equality is by identity, or by pid plus a frame
    /// that matches (or lies inside) the item's slot.
    private static func isSameItem(_ hit: AXUIElement, as known: AXUIElement, frame: CGRect) -> Bool
    {
        var knownPID: pid_t = 0
        AXUIElementGetPid(known, &knownPID)

        var element = hit
        for _ in 0..<4 {
            if CFEqual(element, known) { return true }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if pid == knownPID, let hitFrame = elementFrame(element) {
                if abs(hitFrame.origin.x - frame.origin.x) < 2
                    && abs(hitFrame.origin.y - frame.origin.y) < 2
                {
                    return true
                }
                if hitFrame.width > 0, hitFrame.height > 0,
                    frame.contains(CGPoint(x: hitFrame.midX, y: hitFrame.midY))
                {
                    return true
                }
            }
            guard let parent = parent(of: element) else { break }
            element = parent
        }
        return false
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
                == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    // MARK: - AX access

    private static func liveFrame(of element: AXUIElement) -> CGRect? {
        return elementFrame(element)
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
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

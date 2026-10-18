//
//  SystemItemClickForwarder.swift
//  iMonitor
//
//  macOS 27's native hiding runs the menu bar in the system's assessment
//  (exam-lockdown) mode. That mode does not only hide the apps' items: while
//  it is active, macOS's own items - the clock/calendar, Wi-Fi, Control Center -
//  stay visible but stop responding, and Notification Center does not open.
//  The restriction's only knob is an allow-list of apps and system items;
//  experiments show even a list containing the clock leaves it inert (the
//  lockdown is the point of the API), so the click has to be let through with
//  the restriction released.
//
//  This forwarder watches for a click on one of those system items while the
//  bar is collapsed, swallows it, releases the restriction for one interaction
//  (see HiddenBarController.beginTemporaryReveal), and replays the click after
//  the bar has relaid out. The bar re-hides once the system UI the click opened
//  (calendar, Wi-Fi menu, Control Center) has gone.
//
//  A session event tap is the only pre-dispatch hook available: a global
//  NSEvent monitor cannot swallow the click or act before the item sees it.
//

import Cocoa

final class SystemItemClickForwarder {

    private weak var controller: HiddenBarController?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // The mouse-up that belongs to a swallowed mouse-down must be swallowed
    // too, or the menu bar sees a release for a press it never got.
    private var swallowNextMouseUp = false

    // Marker carried by the replayed pair so the tap passes it through instead
    // of forwarding it again.
    static let replayMarker: Int64 = 0x694D_6F6E  // "iMon"

    /// True for the synthetic click this forwarder replays. iMonitor's own
    /// status-item actions ignore these: a forwarded system-item click must
    /// never open the panel or the hidden-icons list, whatever the layout does
    /// between the swallow and the replay.
    static func isReplayEvent(_ event: NSEvent?) -> Bool {
        guard let cgEvent = event?.cgEvent else { return false }
        return cgEvent.getIntegerValueField(.eventSourceUserData) == replayMarker
    }
    // Time for the native restriction to be released and the bar to relayout
    // before the replayed click is delivered. Measured: the click is still
    // lost at 0.15 s, consistently lands at 0.25 s.
    private static let replayDelay: TimeInterval = 0.25

    init(controller: HiddenBarController) {
        self.controller = controller
        installTap()
    }

    /// Accessibility may have been missing when this object was created (the app
    /// can launch before the user grants it). A collapse only succeeds once the
    /// permission is there, so retry from that path instead of needing a restart.
    func ensureInstalled() {
        guard tap == nil else { return }
        installTap()
    }

    func tearDown() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    deinit {
        tearDown()
    }

    // MARK: - Event tap

    private func installTap() {
        let mask =
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo = userInfo else {
                        return Unmanaged.passUnretained(event)
                    }
                    let forwarder = Unmanaged<SystemItemClickForwarder>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    return forwarder.handle(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // No Accessibility (or taps refused): the system items keep the
            // restriction's behaviour, which is what happened before this fix.
            AppLogger.info(
                "HiddenBar: system-item click forwarding unavailable (event tap refused)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Replays are ours: deliver them untouched.
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            return Unmanaged.passUnretained(event)
        }
        guard let controller = controller, controller.forwardsSystemItemClicks else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            let location = event.location
            guard controller.isSystemItemClick(at: location) else {
                return Unmanaged.passUnretained(event)
            }
            swallowNextMouseUp = true
            // The tap source runs on the main runloop, so the restriction is
            // lifted synchronously, before the replayed click below.
            controller.beginTemporaryRevealForSystemItemClick()
            guard let replayDown = event.copy(),
                let replayUp = CGEvent(
                    mouseEventSource: nil, mouseType: .leftMouseUp,
                    mouseCursorPosition: location, mouseButton: .left)
            else {
                return nil
            }
            replayDown.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            replayUp.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + Self.replayDelay
            ) {
                AppLogger.info("HiddenBar: replaying the system-item click")
                replayDown.post(tap: .cghidEventTap)
                usleep(40_000)
                replayUp.post(tap: .cghidEventTap)
            }
            return nil  // swallow the original press
        case .leftMouseUp:
            if swallowNextMouseUp {
                swallowNextMouseUp = false
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

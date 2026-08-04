import Cocoa
import ServiceManagement
import SwiftUI

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Shared instance. `@NSApplicationMain` wires `NSApp.delegate` to this
    /// instance on launch; this convenience lets SwiftUI views reach the
    /// update flow without walking `NSApp.delegate` casts.
    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    var statusBarItem: NSStatusItem!
    var statusBarIcon: StatusBarIconView!
    var panel: NSPanel!
    var contentView: ContentView!
    var network: Network!
    let updateManager = UpdateManager()
    @ObservedObject var globalModel = SharedStore.globalModel
    @ObservedObject var systemDataModel = SharedStore.systemDataModel
    @ObservedObject var statusDataModel = SharedStore.statusDataModel
    private var refreshTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?
    private var mouseExitWorkItem: DispatchWorkItem?

    static func quit() {
        AppLogger.info("iMonitor quitting")
        NSApplication.shared.terminate(self)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppLogger.installCrashHandlers()

        // Register as login item (auto-launch at startup)
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        } else {
            SMLoginItemSetEnabled("com.aresnasa.iMonitor" as CFString, true)
        }

        self.contentView = ContentView()
        self.network = SharedStore.network

        // Width: bars(4*3+2*2=16) + gap(4) + net text(~48)
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: 68)

        if let button = self.statusBarItem.button {
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            self.statusBarIcon = StatusBarIconView()
            statusBarIcon.frame = NSRect(
                x: 0, y: 0, width: 68, height: NSStatusBar.system.thickness)
            statusBarIcon.autoresizingMask = [.width, .height]

            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(statusBarIcon)
        }

        self.network.startListenNetwork()
        updateStatusBar()

        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: AppConfig.statusBarRefreshInterval, repeats: true
        ) { [weak self] _ in
            self?.updateStatusBar()
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift] && event.charactersIgnoringModifiers == "m" {
                DispatchQueue.main.async { self?.togglePanel(self) }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift] && event.charactersIgnoringModifiers == "m" {
                self?.togglePanel(self)
                return nil
            }
            return event
        }
    }

    private func updateStatusBar() {
        guard let icon = statusBarIcon else { return }

        let themeColors = SharedStore.themeModel.colors
        icon.usedColor = themeColors.used.nsColor
        icon.overloadedColor = themeColors.overloaded.nsColor
        icon.freeColor = themeColors.free.nsColor

        icon.cpuUsage = systemDataModel.cpuUsage
        icon.memoryUsage =
            systemDataModel.memoryTotal > 0
            ? Double(systemDataModel.memoryUsed) / Double(systemDataModel.memoryTotal) : 0
        icon.gpuUsage = systemDataModel.gpuUsage
        icon.totalInBytes = statusDataModel.totalInBytes
        icon.totalOutBytes = statusDataModel.totalOutBytes

        let cpuPct = Int(round(systemDataModel.cpuUsage * 100))
        let memPct =
            systemDataModel.memoryTotal > 0
            ? Int(
                round(
                    Double(systemDataModel.memoryUsed) / Double(systemDataModel.memoryTotal) * 100))
            : 0
        let gpuPct = Int(round(systemDataModel.gpuUsage * 100))
        let memUsed = formatBytes(Int(systemDataModel.memoryUsed))
        let memTotal = formatBytes(Int(systemDataModel.memoryTotal))
        let upStr = formatBytes(statusDataModel.totalOutBytes) + "/s"
        let dnStr = formatBytes(statusDataModel.totalInBytes) + "/s"

        statusBarItem.button?.toolTip = """
            CPU: \(cpuPct)%
            Memory: \(memUsed)/\(memTotal) (\(memPct)%)
            GPU: \(gpuPct)%
            ↑ Upload: \(upStr)
            ↓ Download: \(dnStr)
            """
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes <= 0 { return "0K" }
        let kb = Double(bytes) / 1024
        if kb < 1000 { return String(format: "%.0fK", kb) }
        let mb = kb / 1024
        if mb < 1000 { return String(format: "%.1fM", mb) }
        let gb = mb / 1024
        return String(format: "%.1fG", gb)
    }

    @objc func togglePanel(_ sender: AnyObject?) {
        // Right-click on the status bar item opens the gear menu instead of
        // toggling the panel. `sendAction(on: [.leftMouseUp, .rightMouseUp])`
        // is set on the button, so we inspect the current event type.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusBarMenu()
            return
        }

        updateStatusBar()

        if let panel = panel, panel.isVisible {
            closePanel()
            return
        }

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        globalModel.viewShowing = true

        if panel == nil {
            let hostingView = NSHostingView(rootView: contentView.withGlobalEnvironmentObjects())
            hostingView.frame.size = NSSize(width: 420, height: 460)

            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                styleMask: [.titled, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.contentView = hostingView
            panel.title = "iMonitor"
            panel.isReleasedWhenClosed = false
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.delegate = self
        }

        positionPanelTopRight()
        panel.orderFrontRegardless()
        panel.makeKey()
        startMouseMonitoring()
    }

    private func closePanel() {
        stopMouseMonitoring()
        panel.orderOut(self)
        globalModel.viewShowing = false
    }

    /// Build and pop up the status-bar context menu (gear menu).
    /// Shown on right-click of the status item. Mirrors the in-panel gear menu.
    private func showStatusBarMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let updateItem = NSMenuItem(
            title: updateManager.isUpdating ? "Updating…" : "Check for Updates…",
            action: #selector(performUpdateFromMenu(_:)),
            keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = !updateManager.isUpdating
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit iMonitor",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = statusBarItem.button {
            // Pop up below the status item. `popUp(positioning:at:in:)` expects
            // a view; the button itself is a valid coordinate space. We place
            // the menu just below the button's bottom edge.
            let loc = NSPoint(x: 0, y: button.bounds.maxY + 4)
            menu.popUp(positioning: nil, at: loc, in: button)
        }
    }

    @objc private func performUpdateFromMenu(_ sender: AnyObject?) {
        performUpdate()
    }

    @objc private func quitFromMenu(_ sender: AnyObject?) {
        AppDelegate.quit()
    }

    /// Run the Homebrew self-update flow and relaunch on success.
    /// Shows an alert on failure with an option to open Terminal for manual update.
    func performUpdate() {
        guard !updateManager.isUpdating else { return }

        // If the app isn't running from /Applications, warn early — the
        // upgrade would install to /Applications but this running copy
        // wouldn't be the one replaced, and the relaunch path would be wrong.
        if Bundle.main.bundlePath != UpdateManager.installedAppPath {
            presentAlert(
                title: "Self-update unavailable",
                message: UpdateManager.UpdateError.notInstalledViaBrew.errorDescription ?? "",
                buttons: ["OK"]
            )
            return
        }

        updateManager.performUpdate(
            onProgress: { [weak self] in
                self?.presentUpdatingSheet()
            },
            onComplete: { [weak self] result in
                self?.dismissUpdatingSheet()
                switch result {
                case .success:
                    // Relaunch is already scheduled by UpdateManager.
                    break
                case .failure(let error):
                    self?.presentUpdateFailure(error)
                }
            }
        )
    }

    // MARK: - Update UI helpers

    private var updatingAlert: NSAlert?

    private func presentUpdatingSheet() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Updating iMonitor…"
        alert.informativeText =
            "Running `brew update && brew upgrade --cask imonitor`.\nThe app will relaunch automatically when done."
        alert.addButton(withTitle: "Cancel")
        // Non-blocking: run modal-ish via a detached panel so brew keeps running.
        // We don't actually cancel the brew process — the button just dismisses
        // the alert; the update will still complete in the background.
        alert.buttons.first?.action = #selector(dismissUpdatingAlertFromButton(_:))
        alert.buttons.first?.target = self
        updatingAlert = alert
        if let panel = panel, panel.isVisible {
            alert.beginSheetModal(for: panel) { _ in }
        } else {
            // No panel visible — show as a standalone window so the user gets feedback.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func dismissUpdatingAlertFromButton(_ sender: AnyObject?) {
        dismissUpdatingSheet()
    }

    private func dismissUpdatingSheet() {
        guard let alert = updatingAlert else { return }
        updatingAlert = nil
        if let panel = panel, panel.isVisible, panel.sheetParent != nil,
            panel.attachedSheet === alert.window
        {
            panel.endSheet(alert.window)
        } else {
            NSApp.abortModal()
            alert.window.orderOut(nil)
        }
    }

    private func presentUpdateFailure(_ error: UpdateManager.UpdateError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update failed"
        alert.informativeText = error.errorDescription ?? "Unknown error."
        alert.addButton(withTitle: "Open in Terminal")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openTerminalForManualUpdate()
        }
    }

    /// Open Terminal with a pre-typed update command so the user can run it manually.
    private func openTerminalForManualUpdate() {
        let script = "brew update && brew upgrade --cask imonitor"
        let appleScript = """
            tell application \"Terminal\"
                activate
                do script \"\(script)\"
            end tell
            """
        if let script = NSAppleScript(source: appleScript) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }

    private func presentAlert(title: String, message: String, buttons: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func startMouseMonitoring() {
        stopMouseMonitoring()

        mouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]) { [weak self] _ in
            self?.handleMouseCheck()
        }
        mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]) { [weak self] event in
            self?.handleMouseCheck()
            return event
        }
    }

    private func stopMouseMonitoring() {
        if let monitor = mouseGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            mouseGlobalMonitor = nil
        }
        if let monitor = mouseLocalMonitor {
            NSEvent.removeMonitor(monitor)
            mouseLocalMonitor = nil
        }
        mouseExitWorkItem?.cancel()
        mouseExitWorkItem = nil
    }

    private func handleMouseCheck() {
        guard let panel = panel, panel.isVisible else {
            stopMouseMonitoring()
            return
        }

        let mouseLoc = NSEvent.mouseLocation
        let panelFrame = panel.frame

        // Check if mouse is over the status bar button
        if let button = statusBarItem.button {
            let buttonFrame =
                button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
            if buttonFrame.contains(mouseLoc) { return }
        }

        if panelFrame.contains(mouseLoc) {
            // Mouse is inside the panel — cancel any pending close
            mouseExitWorkItem?.cancel()
            mouseExitWorkItem = nil
        } else {
            // Mouse is outside — schedule close with a small delay to avoid flicker
            if mouseExitWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if let panel = self.panel, panel.isVisible {
                        let loc = NSEvent.mouseLocation
                        if !panel.frame.contains(loc) {
                            // Check status bar button too
                            if let button = self.statusBarItem.button {
                                let btnFrame =
                                    button.window?.convertToScreen(
                                        button.convert(button.bounds, to: nil)) ?? .zero
                                if btnFrame.contains(loc) { return }
                            }
                            self.closePanel()
                        }
                    }
                }
                mouseExitWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
            }
        }
    }

    private func positionPanelTopRight() {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let panelX = screenRect.maxX - 440
        let panelY = screenRect.maxY - 10
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
    }

    func applicationWillResignActive(_ aNotification: Notification) {
        self.globalModel.viewShowing = false
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        globalModel.viewShowing = false
    }
}

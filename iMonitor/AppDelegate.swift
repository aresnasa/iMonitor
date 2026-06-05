import Cocoa
import SwiftUI
import ServiceManagement

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    var statusBarItem: NSStatusItem!
    var statusBarIcon: StatusBarIconView!
    var panel: NSPanel!
    var contentView: ContentView!
    var network: Network!
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
        NSApplication.shared.terminate(self)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Register as login item (auto-launch at startup)
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        self.contentView = ContentView()
        self.network = Network()

        // Width: bars(4*3+2*2=16) + gap(4) + net text(~48)
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: 68)

        if let button = self.statusBarItem.button {
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            self.statusBarIcon = StatusBarIconView()
            statusBarIcon.frame = NSRect(x: 0, y: 0, width: 68, height: NSStatusBar.system.thickness)
            statusBarIcon.autoresizingMask = [.width, .height]

            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(statusBarIcon)
        }

        self.network.startListenNetwork()
        updateStatusBar()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.statusBarRefreshInterval, repeats: true) { [weak self] _ in
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
        icon.memoryUsage = systemDataModel.memoryTotal > 0
            ? Double(systemDataModel.memoryUsed) / Double(systemDataModel.memoryTotal) : 0
        icon.gpuUsage = systemDataModel.gpuUsage
        icon.totalInBytes = statusDataModel.totalInBytes
        icon.totalOutBytes = statusDataModel.totalOutBytes

        let cpuPct = Int(round(systemDataModel.cpuUsage * 100))
        let memPct = systemDataModel.memoryTotal > 0
            ? Int(round(Double(systemDataModel.memoryUsed) / Double(systemDataModel.memoryTotal) * 100)) : 0
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

    @objc func statusBarClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            togglePanel(sender)
        }
    }

    private func showContextMenu(_ button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit iMonitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        button.menu = menu
        button.performClick(nil)
        button.menu = nil
    }

    @objc func togglePanel(_ sender: AnyObject?) {
        updateStatusBar()

        if let panel = panel, panel.isVisible {
            closePanel()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        globalModel.viewShowing = true

        if panel == nil {
            let hostingView = NSHostingView(rootView: contentView.withGlobalEnvironmentObjects())
            hostingView.frame.size = NSSize(width: 420, height: 300)

            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
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

    private func startMouseMonitoring() {
        stopMouseMonitoring()

        mouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            self?.handleMouseCheck()
        }
        mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
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
            let buttonFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
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
                                let btnFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
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

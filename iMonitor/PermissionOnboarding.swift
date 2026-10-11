//
//  PermissionOnboarding.swift
//  iMonitor
//
//  The first-launch permission walkthrough. Managing menu-bar icons (hiding
//  them, keeping the ones behind the camera notch in reach) needs macOS
//  Accessibility access, and a denied app only ever gets silence back from the
//  Accessibility API. So instead of starting the features and letting them look
//  broken, the first launch explains what to grant, deep-links into System
//  Settings, watches for the grant, and starts the features the moment it
//  lands - no relaunch required.
//

import Cocoa
import Combine
import SwiftUI

/// Owns the walkthrough window. `AppDelegate` keeps one alive while the window
/// is open and drops it on `onFinished`.
final class PermissionOnboardingController: NSObject, NSWindowDelegate {

    /// The grant was detected while the window was still up. The menu-bar
    /// features can start now.
    var onGranted: (() -> Void)?
    /// The user is done - granted, postponed, or window closed. The window is
    /// already gone when this runs.
    var onFinished: (() -> Void)?

    private var window: NSWindow?
    private var didFinish = false

    func present() {
        if window == nil {
            window = makeWindow()
        }
        // Deferred one tick: on a first launch this runs from
        // applicationDidFinishLaunching, and both the activation request and
        // ordering the window front are reliably honored only once the launch
        // has settled.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            Self.activateApp()
            window.center()
            window.makeKeyAndOrderFront(nil)
            // macOS's own "grant access" prompt doubles as the way an app gets
            // listed in System Settings, so the user finds iMonitor there
            // instead of an empty list. Shown at most once per launch.
            AccessibilityPermission.request()
        }
    }

    private func makeWindow() -> NSWindow {
        let view = PermissionOnboardingView(
            onOpenSettings: { AccessibilityPermission.openSystemSettings() },
            onGranted: { [weak self] in self?.grantDetected() },
            onFinish: { [weak self] in self?.finish() }
        )
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "iMonitor Setup"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        return window
    }

    /// The grant usually lands while System Settings is frontmost; bring the
    /// walkthrough back so setup visibly completes instead of first looking
    /// like a no-op.
    private func grantDetected() {
        AccessibilityPermission.rememberGrantIfTrusted()
        Self.activateApp()
        window?.makeKeyAndOrderFront(nil)
        onGranted?()
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        AppConfig.permissionOnboardingCompleted = true
        window?.orderOut(nil)
        window = nil
        onFinished?()
    }

    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }
}

/// The walkthrough content: the permission it needs, the steps to enable it,
/// and a live status so the window flips to "done" the moment the TCC toggle
/// flips. The app keeps running while the user is in System Settings, so the
/// view polls instead of relying on an activation callback.
struct PermissionOnboardingView: View {

    let onOpenSettings: () -> Void
    let onGranted: () -> Void
    let onFinish: () -> Void

    @State private var granted = AccessibilityPermission.isGranted

    /// One second is fast enough to feel automatic and cheap enough to run for
    /// the lifetime of the window (`AXIsProcessTrusted` reads the TCC state).
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            permissionRow
            if granted {
                grantedNote
            } else {
                steps
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 440)
        .onReceive(poll) { _ in refresh() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: AccessibilityPermission.mayHaveChangedNotification)
        ) { _ in refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.shield.fill" : "menubar.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(granted ? "You're all set" : "Finish setting up iMonitor")
                    .font(.system(size: 15, weight: .semibold))
                Text(
                    granted
                        ? "Accessibility access is granted - the menu-bar features are starting."
                        : featureSummary
                )
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var featureSummary: String {
        if NotchDropdownItem.isSupported {
            return "iMonitor hides the menu-bar icons you choose and keeps the ones "
                + "behind the camera notch in reach. macOS needs Accessibility access "
                + "before any app may read and move other apps' menu-bar items."
        }
        return "iMonitor hides the menu-bar icons you choose. macOS needs "
            + "Accessibility access before any app may read and move other apps' "
            + "menu-bar items."
    }

    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(
                systemName: granted
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(granted ? Color.green : Color.orange)
            Text("Accessibility")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text(granted ? "Granted" : "Not granted")
                .font(.system(size: 11))
                .foregroundColor(granted ? .green : .orange)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            step(
                1,
                "Click \u{201C}Open System Settings\u{201D} below - iMonitor is already in the list."
            )
            step(
                2,
                "Turn on the switch next to iMonitor (unlock with Touch ID or your "
                    + "password if asked).")
            step(3, "Come back to this window - setup continues automatically.")
        }
        .padding(.leading, 2)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var grantedNote: some View {
        Text(
            "Hiding, the notch list, and icon rearranging now work; no restart needed. "
                + "The permission can be reviewed any time in Settings \u{203A} Menu Bar."
        )
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if granted {
                Button("Continue") { onFinish() }
                    .keyboardShortcut(.defaultAction)
                Spacer()
            } else {
                Button("Open System Settings") { onOpenSettings() }
                    .keyboardShortcut(.defaultAction)
                Button("Check Again") { refresh() }
                Spacer()
                Button("Not Now") { onFinish() }
                    .help(
                        "The menu-bar features stay off until Accessibility is granted. "
                            + "Setup can be resumed from the gear menu or Settings later."
                    )
            }
        }
    }

    // MARK: - Permission state

    /// Re-read the TCC state; a false-to-true flip is the moment setup can
    /// finish, so tell the controller.
    private func refresh() {
        let current = AccessibilityPermission.isGranted
        guard current != granted else { return }
        granted = current
        if current { onGranted() }
    }
}

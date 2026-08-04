import Cocoa
import Foundation

/// Manages Homebrew-based self-update for the running app.
///
/// Flow:
/// 1. Verify the app is installed via Homebrew (`/Applications/iMonitor.app`)
///    and that `brew` is reachable.
/// 2. Run `brew update && brew upgrade --cask imonitor` on a background queue.
/// 3. On success, schedule a relaunch (`open` after a short sleep) and terminate.
/// 4. On failure, surface the error to the caller (UI shows an alert).
///
/// Designed to be UI-agnostic: the caller drives presentation. A single
/// `UpdateManager` instance must not be reused for concurrent updates —
/// `isUpdating` guards against that.
final class UpdateManager {

    enum UpdateError: LocalizedError {
        case notInstalledViaBrew
        case brewNotFound
        case brewCommandFailed(output: String)

        var errorDescription: String? {
            switch self {
            case .notInstalledViaBrew:
                return """
                    iMonitor is not installed in /Applications. \
                    Self-update is only available for the Homebrew Cask install.
                    """
            case .brewNotFound:
                return "Homebrew (`brew`) was not found on this system."
            case .brewCommandFailed(let output):
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Homebrew update failed:\n\(trimmed)"
            }
        }
    }

    /// Path to the app bundle as installed by the Homebrew Cask.
    static let installedAppPath = "/Applications/iMonitor.app"

    /// Cask name — must match `Casks/imonitor.rb` in the homebrew-tap repo.
    static let caskName = "imonitor"

    /// Whether an update is currently in progress. UI should disable the
    /// trigger button while this is true.
    private(set) var isUpdating: Bool = false

    /// Resolved absolute path to `brew`, or nil if not found.
    /// Prefers `/opt/homebrew/bin/brew` (Apple Silicon), then `/usr/local/bin/brew`
    /// (Intel), then a `which` lookup as a last resort.
    private static func resolveBrewPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fall back to `which brew` — honours the user's shell PATH.
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["brew"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let resolved = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = resolved, !resolved.isEmpty,
            FileManager.default.isExecutableFile(atPath: resolved)
        else {
            return nil
        }
        return resolved
    }

    /// True if the running app appears to be the Homebrew Cask install.
    private static var isInstalledViaBrew: Bool {
        Bundle.main.bundlePath == installedAppPath
    }

    /// Run the update flow.
    ///
    /// - Parameters:
    ///   - onProgress: Called on the main thread when the update starts —
    ///     use this to show a spinner / disable buttons.
    ///   - onComplete: Called on the main thread with the result. On success
    ///     the app will be terminated shortly after this callback returns,
    ///     so any UI shown should be dismissable or informational only.
    func performUpdate(
        onProgress: @escaping () -> Void,
        onComplete: @escaping (Result<Void, UpdateError>) -> Void
    ) {
        guard !isUpdating else { return }
        isUpdating = true

        DispatchQueue.main.async { onProgress() }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runBrewUpdate() ?? .failure(.brewNotFound)
            DispatchQueue.main.async {
                self?.isUpdating = false
                onComplete(result)
                if case .success = result {
                    self?.scheduleRelaunchAndTerminate()
                }
            }
        }
    }

    /// Runs the actual brew commands synchronously. Returns nil on success.
    private func runBrewUpdate() -> Result<Void, UpdateError> {
        guard Self.isInstalledViaBrew else { return .failure(.notInstalledViaBrew) }
        guard let brewPath = Self.resolveBrewPath() else { return .failure(.brewNotFound) }

        // `brew update` then `brew upgrade --cask imonitor`.
        // We run them as a single shell invocation so `&&` short-circuits.
        let script =
            "\(shellQuote(brewPath)) update && \(shellQuote(brewPath)) upgrade --cask \(Self.caskName)"

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        // Give brew a sane environment — inherit the current process env and
        // ensure PATH includes the standard brew locations.
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(existingPath)"
        task.environment = env

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            return .failure(.brewCommandFailed(output: error.localizedDescription))
        }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard task.terminationStatus == 0 else {
            return .failure(.brewCommandFailed(output: output))
        }
        return .success(())
    }

    /// Spawn a detached shell that waits briefly for this process to exit,
    /// then reopens the freshly-updated app bundle. Then terminate self.
    private func scheduleRelaunchAndTerminate() {
        let appPath = Self.installedAppPath
        // `sleep 1` gives the OS time to fully tear down the old process
        // before `open` tries to launch the new one. If 1s proves too short
        // in practice, bump to 2 — but longer delays feel broken to users.
        let script = "sleep 1; open \(shellQuote(appPath))"
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        // Detach: stdout/stderr to /dev/null so the shell doesn't inherit
        // our pipes and keep them open.
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try task.run()
            // Don't waitUntilExit — we want this to outlive us.
        } catch {
            // Last resort: log and terminate anyway. User can reopen manually.
            NSLog("iMonitor: failed to schedule relaunch: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            AppDelegate.quit()
        }
    }

    /// Quote a path for safe inclusion in a shell command line.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

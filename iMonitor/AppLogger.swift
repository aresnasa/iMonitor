import Foundation

/// File-based logger for diagnostics and crash reporting.
/// Logs are written to ~/Library/Logs/iMonitor/ and rotated by size.
enum AppLogger {
    private static let queue = DispatchQueue(label: "app-logger", qos: .utility)
    private static let maxFileSize: UInt64 = 2 * 1024 * 1024 // 2 MB
    private static let maxFiles = 3

    private static let logDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/iMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let logFileURL = logDir.appendingPathComponent("imonitor.log")

    // MARK: - Public API

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        write(level: "INFO", message: message, file: file, line: line)
    }

    static func warn(_ message: String, file: String = #file, line: Int = #line) {
        write(level: "WARN", message: message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        write(level: "ERROR", message: message, file: file, line: line)
    }

    /// Log a caught error with context
    static func error(_ error: Error, context: String, file: String = #file, line: Int = #line) {
        write(level: "ERROR", message: "\(context): \(error.localizedDescription)", file: file, line: line)
    }

    /// Install signal handlers to log crashes before the app terminates
    static func installCrashHandlers() {
        signal(SIGABRT) { _ in AppLogger.writeCrashSignal("SIGABRT") }
        signal(SIGSEGV) { _ in AppLogger.writeCrashSignal("SIGSEGV") }
        signal(SIGBUS)  { _ in AppLogger.writeCrashSignal("SIGBUS") }
        signal(SIGFPE)  { _ in AppLogger.writeCrashSignal("SIGFPE") }
        signal(SIGTRAP) { _ in AppLogger.writeCrashSignal("SIGTRAP") }
        signal(SIGILL)  { _ in AppLogger.writeCrashSignal("SIGILL") }

        // Log unhandled exceptions via NSSetUncaughtExceptionHandler
        NSSetUncaughtExceptionHandler { exception in
            AppLogger.write(level: "FATAL", message: """
                Unhandled exception: \(exception.name.rawValue)
                Reason: \(exception.reason ?? "unknown")
                Stack: \(exception.callStackSymbols.joined(separator: "\n       "))
                """, file: "NSSetUncaughtExceptionHandler", line: 0)
        }

        info("iMonitor started — crash handlers installed")
    }

    // MARK: - Internal

    private static func write(level: String, message: String, file: String, line: Int) {
        let filename = URL(fileURLWithPath: file).lastPathComponent
        let timestamp = DateFormatter.iso8601Full.string(from: Date())
        let entry = "[\(timestamp)] [\(level)] [\(filename):\(line)] \(message)\n"

        queue.async {
            rotateIfNeeded()
            guard let data = entry.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }

    private static func writeCrashSignal(_ sig: String) {
        // Synchronous — called from signal handler, must be async-signal-safe
        let timestamp = Int(Date().timeIntervalSince1970)
        let entry = "[CRASH:\(timestamp)] Signal \(sig) — app will terminate\n"
        let path = logFileURL.path
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        entry.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
        Darwin.close(fd)
    }

    private static func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
        let size = (attrs?[.size] as? UInt64) ?? 0
        guard size > maxFileSize else { return }

        // Rotate: .2 → delete, .1 → .2, current → .1
        let base = logDir.appendingPathComponent("imonitor")
        for i in stride(from: maxFiles - 1, through: 1, by: -1) {
            let src = base.appendingPathExtension("log.\(i)")
            let dst = base.appendingPathExtension("log.\(i + 1)")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.moveItem(at: src, to: dst)
        }
        try? FileManager.default.moveItem(at: logFileURL, to: base.appendingPathExtension("log.1"))
    }
}

extension DateFormatter {
    static let iso8601Full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

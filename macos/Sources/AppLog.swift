// AppLog.swift — the app's own log: unified logging (Console.app, subsystem
// "app.waverly.Waverly") plus a size-capped file in ~/Library/Logs/Waverly/app.log,
// rotated like the Python helpers' logs (2 MB x 3), so the logs folder can
// never fill the disk and "Open logs" shows what the app did as well.

import Foundation
import os

enum AppLog {
    static let directory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Waverly", isDirectory: true)
    static let maxBytes: UInt64 = 2_000_000
    static let backups = 2

    private static let logger = Logger(subsystem: "app.waverly.Waverly", category: "app")
    private static let queue = DispatchQueue(label: "waverly.log", qos: .utility)
    private static var handle: FileHandle?
    private static var size: UInt64 = 0
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        return f
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        write("WARNING", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    private static var file: URL { directory.appendingPathComponent("app.log") }

    private static func write(_ level: String, _ message: String) {
        let now = Date()
        queue.async {
            let line = "\(stamp.string(from: now)) app: \(level) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil { open() }
            if size + UInt64(data.count) > maxBytes { rotate() }
            guard let h = handle else { return }
            do {
                try h.write(contentsOf: data)
                size += UInt64(data.count)
            } catch {
                try? h.close()
                handle = nil
            }
        }
    }

    private static func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        size = (try? h.seekToEnd()) ?? 0
        handle = h
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let base = file.path
        try? fm.removeItem(atPath: "\(base).\(backups)")
        if backups > 1 {
            for i in stride(from: backups - 1, through: 1, by: -1) {
                try? fm.moveItem(atPath: "\(base).\(i)", toPath: "\(base).\(i + 1)")
            }
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
        open()
    }
}

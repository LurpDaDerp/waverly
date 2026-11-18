// HelperChecks.swift — small pure checks behind the helper supervisor and the
// Python setup: which package versions the bundled setup script asks for, when a
// helper is crash-looping, and whether the HTTP port is free. Foundation only, so
// hud/tests/test_native_checks.py compiles this file on its own and tests it.

import CryptoKit
import Foundation

/// The exact package versions tools/setup_macos.sh installs (its PACKAGES lines
/// between "# requirements:begin" and "# requirements:end").
enum PythonRequirements {
    /// "name==version" for every pin in the script, in script order.
    static func pins(inScript text: String) -> [String] {
        guard let begin = text.range(of: "# requirements:begin"),
              let end = text.range(of: "# requirements:end", range: begin.upperBound..<text.endIndex) else { return [] }
        let block = String(text[begin.upperBound..<end.lowerBound])
        guard let re = try? NSRegularExpression(pattern: #""([A-Za-z0-9][A-Za-z0-9._-]*==[A-Za-z0-9.+!_-]+)""#) else { return [] }
        let ns = block as NSString
        return re.matches(in: block, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Stands for one set of pins: the same pins in any order or layout give the same
    /// value, any changed, added or removed pin a different one. Nil without pins.
    static func fingerprint(_ pins: [String]) -> String? {
        guard !pins.isEmpty else { return nil }
        let canonical = pins.map { $0.lowercased() }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Counts a helper's exits that come soon after its launch. A helper that can never
/// start (a broken environment, the port taken by another app) exits within seconds
/// every time: after `limit` such exits in a row it is crash-looping.
struct CrashLoopCounter {
    static let quickExit: TimeInterval = 10     // an exit this soon after launch counts
    static let limit = 3

    private(set) var quickExits = 0

    /// The helper exited after running `uptime` seconds. True exactly once per run of
    /// quick exits: when it reaches `limit`.
    mutating func exited(after uptime: TimeInterval) -> Bool {
        quickExits = uptime < Self.quickExit ? quickExits + 1 : 0
        return quickExits == Self.limit
    }

    /// The helper is healthy again.
    mutating func reset() { quickExits = 0 }

    var isLooping: Bool { quickExits >= Self.limit }
}

enum LocalPort {
    /// True if a server could listen on 127.0.0.1:`port` right now (nothing else is).
    /// SO_REUSEADDR, as servers set it: a socket of a server that just stopped
    /// (TIME_WAIT) does not count as taken.
    static func isFree(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }                 // can't tell: assume free
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }
}

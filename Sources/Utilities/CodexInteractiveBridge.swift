import AppKit
import Foundation

/// Best-effort focus bridge for Codex sessions when terminal PID metadata is unavailable.
enum CodexInteractiveBridge {
    struct ProcessInfo {
        let pid: Int
        let cwd: String?
        let tty: String?
    }

    /// Background replies are not supported via this bridge.
    static let supportsBackgroundReplies = false

    private static let codexProcessMatchers: [[String]] = [
        ["-x", "codex"],
        ["-x", "Codex"],
        ["-f", "codex_cli_rs"],
        ["-f", "Codex.app"],
        ["-f", "Codex Desktop"],
    ]

    static func focus(
        event: AgentEvent,
        processInfos: [ProcessInfo]? = nil,
        activator: ((Int) -> Bool)? = nil
    ) -> Bool {
        guard AgentSource(rawSource: event.source) == .codex else { return false }

        let infos = processInfos ?? runningCodexProcesses()
        guard let target = selectProcess(for: event, from: infos) else {
            return false
        }

        let activate = activator ?? defaultActivator
        let success = activate(target.pid)
        if success {
            print("[masko-desktop] Codex bridge focused pid=\(target.pid)")
        } else {
            print("[masko-desktop] Codex bridge failed to focus pid=\(target.pid)")
        }
        return success
    }

    static func selectProcess(for event: AgentEvent, from infos: [ProcessInfo]) -> ProcessInfo? {
        guard !infos.isEmpty else { return nil }

        if let cwd = normalized(path: event.cwd) {
            let matched = infos.filter { normalized(path: $0.cwd) == cwd }
            if matched.count == 1 {
                return matched.first
            }
            if matched.count > 1 {
                // Prefer newest process when multiple Codex sessions share the same cwd.
                return matched.max(by: { $0.pid < $1.pid })
            }
        }

        let ttyInfos = infos.filter { info in
            guard let tty = info.tty else { return false }
            return !tty.isEmpty
        }

        if ttyInfos.count == 1 {
            return ttyInfos.first
        }

        // Desktop sessions are frequently launched without a reliable cwd match.
        // Prefer the newest interactive TTY process so mascot "open terminal" still works.
        if event.assistantClientKind == .codexDesktop,
           let newestTTY = ttyInfos.max(by: { $0.pid < $1.pid }) {
            return newestTTY
        }

        // No cwd match: only safe fallback is a single visible Codex process.
        if infos.count == 1 {
            return infos.first
        }

        return nil
    }

    private static func runningCodexProcesses() -> [ProcessInfo] {
        let pids = Set(codexProcessMatchers.flatMap(pidsForMatcher))
        let sortedPids = pids.sorted()

        guard !sortedPids.isEmpty else { return [] }

        return sortedPids.map { pid in
            ProcessInfo(
                pid: pid,
                cwd: cwdForPid(pid),
                tty: ttyForPid(pid)
            )
        }
    }

    private static func pidsForMatcher(_ matcher: [String]) -> [Int] {
        runCommand("/usr/bin/pgrep", arguments: matcher)
            .split(separator: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func cwdForPid(_ pid: Int) -> String? {
        let output = runCommand("/usr/sbin/lsof", arguments: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        return output.split(separator: "\n")
            .first(where: { $0.hasPrefix("n") })
            .map { String($0.dropFirst()) }
    }

    private static func ttyForPid(_ pid: Int) -> String? {
        let output = runCommand("/usr/sbin/lsof", arguments: ["-a", "-p", "\(pid)", "-Fn"])
        return output.split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("n") else { return nil }
                let path = String(line.dropFirst())
                return path.hasPrefix("/dev/tty") || path.hasPrefix("/dev/ttys") ? path : nil
            }
            .first
    }

    private static func defaultActivator(pid: Int) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
        return app.activate()
    }

    private static func runCommand(_ launchPath: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func normalized(path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

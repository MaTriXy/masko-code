import Foundation

/// Best-effort bridge that sends mascot decisions back to an active Codex terminal session.
/// This path is only used for Codex-originated local permission requests.
enum CodexInteractiveBridge {
    struct ProcessInfo {
        let pid: Int
        let cwd: String?
        let tty: String?
    }

    static func submit(
        resolution: LocalPermissionResolution,
        event: ClaudeEvent,
        processInfos: [ProcessInfo]? = nil,
        writer: ((String, String) -> Bool)? = nil
    ) -> Bool {
        guard event.assistantClientKind != .claude else { return false }
        guard let input = inputText(for: resolution), !input.isEmpty else { return false }

        let infos = processInfos ?? runningCodexProcesses()
        guard let target = selectProcess(for: event, from: infos),
              let tty = target.tty, !tty.isEmpty else {
            return false
        }

        let write = writer ?? defaultTTYWriter
        let success = write(tty, input)
        if success {
            print("[masko-desktop] Codex bridge wrote resolution to \(tty) (pid=\(target.pid))")
        } else {
            print("[masko-desktop] Codex bridge failed to write resolution to \(tty) (pid=\(target.pid))")
        }
        return success
    }

    static func inputText(for resolution: LocalPermissionResolution) -> String? {
        switch resolution {
        case .decision(let decision):
            return decision == .allow ? "y\n" : "n\n"
        case .answers(let answers):
            let values = answers.keys.sorted().compactMap { answers[$0] }
            guard !values.isEmpty else { return nil }
            return values.joined(separator: "\n") + "\n"
        case .feedback(let feedback):
            let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed + "\n"
        case .permissionSuggestions:
            // Closest terminal equivalent: accept current prompt.
            return "y\n"
        }
    }

    static func selectProcess(for event: ClaudeEvent, from infos: [ProcessInfo]) -> ProcessInfo? {
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

        // No cwd match: only safe fallback is a single visible Codex process.
        if infos.count == 1 {
            return infos.first
        }

        return nil
    }

    private static func runningCodexProcesses() -> [ProcessInfo] {
        let pids = runCommand("/usr/bin/pgrep", arguments: ["-x", "codex"])
            .split(separator: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        guard !pids.isEmpty else { return [] }

        return pids.map { pid in
            ProcessInfo(
                pid: pid,
                cwd: cwdForPid(pid),
                tty: ttyForPid(pid)
            )
        }
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

    private static func defaultTTYWriter(path: String, text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return false }
        handle.write(data)
        handle.closeFile()
        return true
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

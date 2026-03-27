import Foundation

/// Diagnoses and repairs the connection between Masko Code and Claude Code/Codex.
@Observable
@MainActor
final class ConnectionDoctor {

    struct Check: Identifiable {
        enum Status { case ok, warning, error }
        let id: String
        let name: String
        var status: Status
        var message: String
        var canAutoFix: Bool
    }

    private(set) var checks: [Check] = []
    private(set) var isRunning = false
    private(set) var isRepairing = false

    private let localServer: LocalServer

    init(localServer: LocalServer) {
        self.localServer = localServer
    }

    // MARK: - Diagnostics

    func runDiagnostics() async {
        isRunning = true
        checks = []

        // 1. Server running
        checks.append(checkServerRunning())

        // 2. Hooks installed in settings.json
        checks.append(checkHooksInstalled())

        // 3. Hook script exists
        checks.append(checkHookScriptExists())

        // 4. Port match between script and server
        checks.append(checkPortMatch())

        // 5. Script version
        checks.append(checkScriptVersion())

        // 6. End-to-end health check
        let healthResult = await checkHealthEndpoint()
        checks.append(healthResult)

        isRunning = false
    }

    // MARK: - Individual Checks

    private func checkServerRunning() -> Check {
        if localServer.isRunning {
            return Check(
                id: "server_running",
                name: "Local Server",
                status: .ok,
                message: "Running on port \(localServer.port)",
                canAutoFix: true
            )
        }
        return Check(
            id: "server_running",
            name: "Local Server",
            status: .error,
            message: "Server is offline",
            canAutoFix: true
        )
    }

    private func checkHooksInstalled() -> Check {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return Check(
                id: "hooks_installed",
                name: "Claude Code Hooks",
                status: .error,
                message: "No hooks found in settings.json",
                canAutoFix: true
            )
        }

        let hookCommand = "~/.masko-desktop/hooks/hook-sender.sh"
        let expectedEvents = [
            "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "StopFailure",
            "Notification", "SessionStart", "SessionEnd", "TaskCompleted",
            "PermissionRequest", "UserPromptSubmit", "SubagentStart", "SubagentStop",
            "PreCompact", "PostCompact", "ConfigChange", "TeammateIdle",
            "WorktreeCreate", "WorktreeRemove",
        ]

        var missing = 0
        for event in expectedEvents {
            if let entries = hooks[event] as? [[String: Any]] {
                let hasHook = entries.contains { entry in
                    guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.contains { ($0["command"] as? String) == hookCommand }
                }
                if !hasHook { missing += 1 }
            } else {
                missing += 1
            }
        }

        if missing == 0 {
            return Check(
                id: "hooks_installed",
                name: "Claude Code Hooks",
                status: .ok,
                message: "All \(expectedEvents.count) hooks registered",
                canAutoFix: true
            )
        }

        return Check(
            id: "hooks_installed",
            name: "Claude Code Hooks",
            status: missing == expectedEvents.count ? .error : .warning,
            message: "Missing \(missing) of \(expectedEvents.count) hooks",
            canAutoFix: true
        )
    }

    private func checkHookScriptExists() -> Check {
        let scriptPath = NSHomeDirectory() + "/.masko-desktop/hooks/hook-sender.sh"
        let fm = FileManager.default

        guard fm.fileExists(atPath: scriptPath) else {
            return Check(
                id: "hook_script",
                name: "Hook Script",
                status: .error,
                message: "hook-sender.sh not found",
                canAutoFix: true
            )
        }

        guard fm.isExecutableFile(atPath: scriptPath) else {
            return Check(
                id: "hook_script",
                name: "Hook Script",
                status: .warning,
                message: "hook-sender.sh exists but is not executable",
                canAutoFix: true
            )
        }

        return Check(
            id: "hook_script",
            name: "Hook Script",
            status: .ok,
            message: "hook-sender.sh exists and is executable",
            canAutoFix: true
        )
    }

    private func checkPortMatch() -> Check {
        let scriptPath = NSHomeDirectory() + "/.masko-desktop/hooks/hook-sender.sh"
        guard let content = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            return Check(
                id: "port_match",
                name: "Port Configuration",
                status: .warning,
                message: "Cannot read hook script to verify port",
                canAutoFix: true
            )
        }

        // Extract port from: curl ... "http://localhost:XXXXX/health"
        let pattern = "http://localhost:(\\d+)/health"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let portRange = Range(match.range(at: 1), in: content),
              let scriptPort = UInt16(content[portRange]) else {
            return Check(
                id: "port_match",
                name: "Port Configuration",
                status: .warning,
                message: "Cannot parse port from hook script",
                canAutoFix: true
            )
        }

        let serverPort = localServer.port
        if scriptPort == serverPort {
            return Check(
                id: "port_match",
                name: "Port Configuration",
                status: .ok,
                message: "Script and server both on port \(serverPort)",
                canAutoFix: true
            )
        }

        return Check(
            id: "port_match",
            name: "Port Configuration",
            status: .error,
            message: "Port mismatch: script=\(scriptPort), server=\(serverPort)",
            canAutoFix: true
        )
    }

    private func checkScriptVersion() -> Check {
        let scriptPath = NSHomeDirectory() + "/.masko-desktop/hooks/hook-sender.sh"
        guard let content = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            return Check(
                id: "script_version",
                name: "Script Version",
                status: .warning,
                message: "Cannot read hook script",
                canAutoFix: true
            )
        }

        // Extract version from: # version: NN
        let pattern = "# version: (\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let versionRange = Range(match.range(at: 1), in: content),
              let version = Int(content[versionRange]) else {
            return Check(
                id: "script_version",
                name: "Script Version",
                status: .warning,
                message: "Cannot parse version from hook script",
                canAutoFix: true
            )
        }

        // HookInstaller embeds a version constant; reinstalling will update it
        return Check(
            id: "script_version",
            name: "Script Version",
            status: .ok,
            message: "Version \(version)",
            canAutoFix: true
        )
    }

    private func checkHealthEndpoint() async -> Check {
        let port = localServer.port
        let url = URL(string: "http://localhost:\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return Check(
                    id: "health_check",
                    name: "Health Check",
                    status: .ok,
                    message: "Server responding on port \(port)",
                    canAutoFix: false
                )
            }
            return Check(
                id: "health_check",
                name: "Health Check",
                status: .error,
                message: "Server returned non-200 status",
                canAutoFix: false
            )
        } catch {
            return Check(
                id: "health_check",
                name: "Health Check",
                status: .error,
                message: "Connection refused on port \(port)",
                canAutoFix: false
            )
        }
    }

    // MARK: - Repair

    func repairAll() async {
        isRepairing = true

        // 1. Restart server if not running
        if !localServer.isRunning {
            localServer.restart(port: localServer.port)
            // Give it a moment to bind
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // 2. Reinstall hooks + regenerate script (fixes hooks, script, port, version)
        try? HookInstaller.install()

        // 3. Re-run diagnostics to verify
        await runDiagnostics()

        isRepairing = false
    }

    // MARK: - Report Payload

    func buildReportPayload() -> [String: Any] {
        var checkPayloads: [[String: Any]] = []
        for check in checks {
            checkPayloads.append([
                "name": check.id,
                "status": statusString(check.status),
                "message": check.message,
            ])
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        return [
            "app_version": "\(appVersion) (\(buildNumber))",
            "os_version": osVersion,
            "checks": checkPayloads,
            "active_sessions": 0, // Could be wired to sessionStore if needed
        ]
    }

    /// Send diagnostic report to masko.ai and return the short code
    func sendReport() async -> String? {
        let payload = buildReportPayload()

        let urlString = Constants.maskoBaseURL + "/api/debug-reports"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let shortCode = json["short_code"] as? String {
                return shortCode
            }
            return nil
        } catch {
            print("[ConnectionDoctor] Failed to send report: \(error)")
            return nil
        }
    }

    private func statusString(_ status: Check.Status) -> String {
        switch status {
        case .ok: return "ok"
        case .warning: return "warning"
        case .error: return "error"
        }
    }
}

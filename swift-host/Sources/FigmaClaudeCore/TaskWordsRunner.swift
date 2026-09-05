import Foundation

/// The model that names the task: small and quick, one call per session.
public let taskWordsModel = "claude-haiku-4-5-20251001"

/// Asks Claude Code in print mode for the two words. Returns the raw answer, or nil when the
/// binary is missing, exits non-zero, or takes longer than `timeout` (a full minute: the call
/// pays Claude Code's startup, not only Haiku's answer) — the caller then falls back
/// to `fallbackTaskWords`. Blocking; run it off the main queue.
public func askTaskWords(prompt: String, claude: String, path: String, cwd: String? = nil,
                         environment extra: [String: String] = [:],
                         timeout: TimeInterval = 60) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: claude)
    // `--strict-mcp-config` without a config: no MCP server starts for a call that needs none.
    // Measured 22 s wall time for 4 s of CPU without it — the servers and hooks of a full session.
    process.arguments = ["-p", "--model", taskWordsModel, "--output-format", "text",
                         "--strict-mcp-config", taskWordsPrompt(for: prompt)]
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = path
    for (key, value) in extra { environment[key] = value }
    process.environment = environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    do { try process.run() } catch { return nil }

    // Read to EOF on another thread; `waitUntilExit` alone deadlocks once the pipe fills.
    var output = Data()
    let reader = DispatchQueue(label: "fc.taskwords.read")
    let done = DispatchSemaphore(value: 0)
    reader.async {
        output = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    let deadline = DispatchTime.now() + timeout
    if done.wait(timeout: deadline) == .timedOut {
        process.terminate()
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: output, encoding: .utf8)
}

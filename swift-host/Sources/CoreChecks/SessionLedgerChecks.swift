import Foundation
import FigmaClaudeCore

/// Two sources decide whether a name is free: Claude Code's registry of running sessions and the
/// host's own ledger of every name it ever handed out. Both are files somebody else may have
/// half-written, so the cases are about what happens when they are missing or broken.
enum SessionLedgerTests {
    static func run() {
        registry()
        ledger()
    }

    static func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "fc-ledger-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // testReadsTheNamesOfRunningSessionsAndIgnoresTheRest
    static func registry() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = #"{"pid":1,"sessionId":"aaaa-1","name":"fc-designdone-cli-lab","status":"idle","extra":{"x":1}}"#
        let b = #"{"pid":2,"sessionId":"bbbb-2","name":"port-pr-kiss-cleanup","status":"busy"}"#
        try? a.write(toFile: dir + "/1.json", atomically: true, encoding: .utf8)
        try? b.write(toFile: dir + "/2.json", atomically: true, encoding: .utf8)
        try? "{not json".write(toFile: dir + "/3.json", atomically: true, encoding: .utf8)
        try? "ignored".write(toFile: dir + "/4.key", atomically: true, encoding: .utf8)

        Checks.expect(liveSessionNames(registryDir: dir), ["fc-designdone-cli-lab", "port-pr-kiss-cleanup"])
        let mine = registryEntry(sessionId: "aaaa-1", registryDir: dir)
        Checks.expect(mine?.name, "fc-designdone-cli-lab")
        Checks.expect(mine?.status, "idle")
        Checks.expectNil(registryEntry(sessionId: "nope", registryDir: dir))
        Checks.expect(liveSessionNames(registryDir: dir + "/missing"), [])
    }

    // testRemembersEveryNameEverHandedOut
    static func ledger() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/session-names.json"

        Checks.expect(ledgerNames(path: path), [])
        recordName("fc-designdone-cli-lab", path: path)
        recordName("fc-feedback-triage", path: path)
        Checks.expect(ledgerNames(path: path), ["fc-designdone-cli-lab", "fc-feedback-triage"])
        // The same name twice is one entry, not a crash and not a duplicate.
        recordName("fc-feedback-triage", path: path)
        Checks.expect(ledgerNames(path: path).count, 2)

        // A broken ledger reads as empty and is replaced by the next record, not appended to.
        try? "[{".write(toFile: path, atomically: true, encoding: .utf8)
        Checks.expect(ledgerNames(path: path), [])
        recordName("fc-after-damage", path: path)
        Checks.expect(ledgerNames(path: path), ["fc-after-damage"])

        // The directory may not exist yet on a fresh machine.
        let fresh = dir + "/new/dir/session-names.json"
        recordName("fc-first", path: fresh)
        Checks.expect(ledgerNames(path: fresh), ["fc-first"])
    }
}

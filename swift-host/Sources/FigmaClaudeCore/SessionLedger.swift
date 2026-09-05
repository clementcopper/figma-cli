import Foundation

/// A session name is handed out once, ever. Two files decide whether one is free:
///
/// - Claude Code's registry of running sessions, `~/.claude/sessions/<pid>.json` — one file per
///   process, with `name`, `sessionId` and `status`. Read for the names that run right now and
///   for the host's own row (found by `sessionId`, never by pid).
/// - the host's ledger, `~/.figma-ds-cli/session-names.json` — every name this host ever minted.
///   Past sessions keep their names in the `/resume` picker, and Claude Code stores those only
///   inside the transcripts, which are too big to scan on every spawn.
///
/// Both are files somebody else may be writing; anything unreadable counts as "no names", never
/// as a reason to fail a spawn.

public struct RegistryEntry: Equatable {
    public var name: String
    public var status: String
}

private struct RegistryRow: Decodable {
    var name: String?
    var sessionId: String?
    var status: String?
}

public func defaultRegistryDir(home: String = NSHomeDirectory()) -> String {
    home + "/.claude/sessions"
}

public func defaultLedgerPath(home: String = NSHomeDirectory()) -> String {
    home + "/.figma-ds-cli/session-names.json"
}

private func registryRows(_ dir: String) -> [RegistryRow] {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    return files.filter { $0.hasSuffix(".json") }.compactMap { file in
        guard let data = FileManager.default.contents(atPath: dir + "/" + file) else { return nil }
        return try? JSONDecoder().decode(RegistryRow.self, from: data)
    }
}

/// The names of every session Claude Code has running.
public func liveSessionNames(registryDir: String = defaultRegistryDir()) -> Set<String> {
    Set(registryRows(registryDir).compactMap { row in
        guard let name = row.name, !name.isEmpty else { return nil }
        return name
    })
}

/// The host's own row: what Claude Code calls the session and whether it is busy or idle.
public func registryEntry(sessionId: String, registryDir: String = defaultRegistryDir()) -> RegistryEntry? {
    guard let row = registryRows(registryDir).first(where: { $0.sessionId == sessionId }) else { return nil }
    return RegistryEntry(name: row.name ?? "", status: row.status ?? "")
}

private struct LedgerRow: Codable {
    var name: String
    var at: String
}

private func ledgerRows(_ path: String) -> [LedgerRow] {
    guard let data = FileManager.default.contents(atPath: path),
          let rows = try? JSONDecoder().decode([LedgerRow].self, from: data) else { return [] }
    return rows
}

/// Every name this host ever handed out.
public func ledgerNames(path: String = defaultLedgerPath()) -> Set<String> {
    Set(ledgerRows(path).map(\.name))
}

/// Adds a name to the ledger — before `claude` starts, so the name is taken from that moment even
/// if the process never comes up. A broken ledger is replaced, not appended to. The write is
/// atomic (temp file + rename), so two tabs spawning at once cannot leave half a file.
public func recordName(_ name: String, path: String = defaultLedgerPath(), now: Date = Date()) {
    var rows = ledgerRows(path)
    if rows.contains(where: { $0.name == name }) { return }
    rows.append(LedgerRow(name: name, at: ISO8601DateFormatter().string(from: now)))
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(rows) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

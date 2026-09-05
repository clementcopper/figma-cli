import Foundation

/// The display name a panel tab starts Claude Code with (`claude -n <name>`), and the one it is
/// renamed to once the task is known.
///
/// Several Claudes run at once on this machine and the `/resume` picker shows them side by side,
/// so a name has to say "this one is the panel" and what it was doing. Claude Code names its own
/// sessions after the working directory first and after the task a few turns later; a name set
/// with `-n` is never touched again — which is why the old `fc-<file>-<uuid8>` stayed cryptic for
/// the life of a session. (The uuid was in the name so the `/resume` row pointed at its own
/// transcript. `--session-id` is still minted by the host; the name no longer carries it.)
///
/// Two stages now: `fc-<file>-<page>` at start, `fc-<word>-<word>` after the first prompt (see
/// `TaskWords.swift` and the renamer in the app). Every name is handed out once, ever — checked
/// against the running sessions and the host's ledger (`SessionLedger.swift`), a collision gets
/// `-2`, `-3`, …
///
/// `app/src/lib/session-name.ts` (the Electron host) deliberately stays on its old format; it is
/// not the app that runs.

/// Prefix every panel session carries.
public let sessionNamePrefix = "fc"

/// Long names are truncated in the prompt box anyway; this keeps each piece readable there.
private let maxSuffix = 40

/// The daemon reports the browser page title, which Figma suffixes with " – Figma". In a name
/// that is already about Figma, that word is noise. Port of `cleanFileName` in `figma-status.ts`.
public func cleanFileName(_ title: String?) -> String {
    guard let title else { return "" }
    let pattern = "\\s*[–—-]\\s*Figma\\s*$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return title }
    let range = NSRange(title.startIndex..., in: title)
    let stripped = regex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// One lowercase, hyphen-joined piece of a session name.
///
/// Folding the diacritics first is what keeps a German file name legible — "Übersicht" becomes
/// `ubersicht`, not `bersicht`. Anything the fold does not reduce to ASCII (CJK, emoji, the
/// zero-width characters that survive a copy out of Figma) drops out, which is why every caller
/// has to cope with an empty result.
public func sessionSlug(_ raw: String) -> String {
    // "ß" is no diacritic, so the fold drops it and "Größen" would break into "gro-en". The other
    // German vowels stay single letters — "ubersicht" reads fine, "uebersicht" does not.
    let sharpS = raw.replacingOccurrences(of: "ß", with: "ss")
        .replacingOccurrences(of: "ẞ", with: "ss")
    let folded = sharpS.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                locale: Locale(identifier: "en_US_POSIX")).lowercased()
    var out = ""
    var pendingSeparator = false
    for scalar in folded.unicodeScalars {
        let isKept = (scalar.value >= 97 && scalar.value <= 122)   // a-z
            || (scalar.value >= 48 && scalar.value <= 57)          // 0-9
        if isKept {
            if pendingSeparator, !out.isEmpty { out.append("-") }
            pendingSeparator = false
            out.unicodeScalars.append(scalar)
            if out.count >= maxSuffix { break }
        } else {
            pendingSeparator = true
        }
    }
    return out
}

/// The start name: the Figma file and the page it is on, the working directory when no file is
/// known yet, the bare prefix when nothing is. A page without a file says nothing on its own.
public func panelSessionName(file: String? = nil, page: String? = nil, cwd: String? = nil) -> String {
    var parts = [sessionNamePrefix]
    let fileSlug = sessionSlug(cleanFileName(file))
    if !fileSlug.isEmpty {
        parts.append(fileSlug)
        let pageSlug = sessionSlug(page ?? "")
        if !pageSlug.isEmpty { parts.append(pageSlug) }
    } else if let cwd {
        // `basename("/")` is "/" and `basename("")` is "" — neither says anything about the
        // session, and both slug to nothing anyway.
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)
        let dir = sessionSlug((trimmed as NSString).lastPathComponent)
        if !dir.isEmpty { parts.append(dir) }
    }
    return parts.joined(separator: "-")
}

/// `base` if nobody has it, else `base-2`, `base-3`, … — the first that is free.
public func uniqueName(_ base: String, taken: Set<String>) -> String {
    if !taken.contains(base) { return base }
    var n = 2
    while taken.contains("\(base)-\(n)") { n += 1 }
    return "\(base)-\(n)"
}

/// The name after the first prompt: the prefix and the two task words.
public func taskSessionName(words: String) -> String {
    "\(sessionNamePrefix)-\(sessionSlug(words))"
}

/// Whether a spawn starts a conversation of its own, and so deserves a fresh name and id.
///
/// `--resume` and `--continue` adopt an existing session. Passing `-n` alongside them renames
/// whatever the user picked — that is how one session on disk ended up carrying two names — and
/// `--session-id` would be claiming an id the conversation already has.
public func startsANewSession(extraArgs: [String]) -> Bool {
    let adopting: Set<String> = ["--resume", "-r", "--continue", "-c"]
    return !extraArgs.contains { adopting.contains($0) }
}

/// Seconds of silence on the keyboard before the host may type into the prompt.
public let injectionQuietSeconds: Double = 3

/// `/rename` is typed into the user's own terminal, so every reason to hold back wins: Claude
/// must be idle (Claude Code's registry says so), not showing a question of its own, and the
/// user must not have typed for a moment — otherwise the command lands inside their sentence.
public func shouldInject(status: String?, waiting: Bool, secondsSinceInput: Double) -> Bool {
    status == "idle" && !waiting && secondsSinceInput > injectionQuietSeconds
}

/// The keystrokes for a rename: the slash command and Enter.
public func renameCommand(_ name: String) -> String {
    "/rename \(name)\r"
}

import Foundation

/// The two words after `fc-`: found in the session's transcript (the first thing the user
/// typed), named by a small model, checked here, and — when that fails — picked from the prompt
/// itself. Everything in this file is pure; `TaskWordsRunner.swift` does the subprocess.

/// Where Claude Code writes the transcript: the working directory keyed with every character
/// outside `[A-Za-z0-9]` turned into a hyphen (`/Users/x/.claude` → `-Users-x--claude`).
public func transcriptPath(cwd: String, sessionId: String, home: String = NSHomeDirectory()) -> String {
    let key = String(cwd.unicodeScalars.map { scalar -> Character in
        let v = scalar.value
        let keep = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
        return keep ? Character(scalar) : "-"
    })
    return "\(home)/.claude/projects/\(key)/\(sessionId).jsonl"
}

/// Prompts longer than this are cut before they go to the model; the task is in the first lines.
public let maxPromptLength = 2000

private struct TranscriptRecord: Decodable {
    var type: String?
    var message: Message?
    struct Message: Decodable {
        var content: Content?
    }
    enum Content: Decodable {
        case text(String)
        case blocks([Block])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s); return }
            self = .blocks((try? c.decode([Block].self)) ?? [])
        }
    }
    struct Block: Decodable {
        var type: String?
        var text: String?
    }
}

/// Records Claude Code writes as "user" that the user never typed: slash commands, hook output,
/// the system reminders a hook injects.
private func isSyntheticUserText(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty
        || t.hasPrefix("<command-name>") || t.contains("<local-command-stdout>")
        || t.hasPrefix("<local-command-caveat>") || t.hasPrefix("<system-reminder>")
}

/// The first thing the user typed, or nil while there is none. Lines that do not parse — the one
/// Claude Code is still appending — are skipped, not fatal.
public func firstUserPrompt(transcript: String) -> String? {
    for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let data = line.data(using: .utf8),
              let record = try? JSONDecoder().decode(TranscriptRecord.self, from: data),
              record.type == "user", let content = record.message?.content else { continue }
        let text: String
        switch content {
        case .text(let s): text = s
        case .blocks(let blocks):
            guard let block = blocks.first(where: { $0.type == "text" }), let t = block.text else { continue }
            text = t
        }
        if isSyntheticUserText(text) { continue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxPromptLength))
    }
    return nil
}

/// The instruction for the model. Two words in the prompt's own language: a German prompt gets a
/// German name, the way Claude Code's own auto-names keep the language.
public func taskWordsPrompt(for prompt: String) -> String {
    "Name the task in this message with exactly two words, in the language of the message, " +
    "lowercase, ASCII letters only, joined by a hyphen (like feedback-triage or button-bindings). " +
    "Answer with the two words and nothing else.\n\nMessage:\n" + prompt
}

/// What the model answered, if it is two sluggable words — the last non-empty line, so a chatty
/// preface does not count against it. Anything else is nil and the caller falls back.
public func parseTaskWords(_ output: String) -> String? {
    guard let last = output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
        .last(where: { !$0.isEmpty }) else { return nil }
    let slug = sessionSlug(last)
    let parts = slug.split(separator: "-")
    guard parts.count == 2, parts.allSatisfy({ $0.count >= 2 }) else { return nil }
    return slug
}

/// Words that name nothing about a task, in the two languages the prompts come in.
private let stopWords: Set<String> = [
    "bitte", "mach", "mache", "kannst", "einmal", "dann", "noch", "eine", "einen", "einem", "eines",
    "diese", "dieses", "dieser", "nicht", "auch", "aber", "oder", "also", "hier", "jetzt", "mal",
    "please", "make", "could", "would", "should", "with", "from", "into", "that", "this", "them",
    "then", "just", "also", "here", "there", "what", "which", "about", "your", "have", "want",
    "claude", "hallo", "hello",
]

/// Two content words from the prompt: at least four letters, not a stop word. Only used when the
/// model gave nothing usable.
public func fallbackTaskWords(_ prompt: String) -> String? {
    let words = sessionSlug(prompt).split(separator: "-").map(String.init)
        .filter { $0.count >= 4 && !stopWords.contains($0) }
    guard words.count >= 2 else { return nil }
    return words[0] + "-" + words[1]
}

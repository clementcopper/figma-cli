import Foundation

/// Noticing that a tab is waiting for an answer.
///
/// Port of `app/src/host/promptDetector.ts`. This is the one place in the host that guesses at
/// somebody else's text, so it is written to be wrong in the cheap direction: a missed prompt
/// costs a dot that never appears, a false one puts a dot on a tab that is busy answering and
/// teaches the user to ignore it.
///
/// Three rules keep it honest, all inherited from the original:
///
/// - **Only after the output settles.** The check runs `showDelay` after the last byte, because
///   a pattern can match halfway through a frame that is still being drawn.
/// - **New output clears it.** If Claude starts writing again, it was not waiting.
/// - **A keystroke clears it and the buffer.** The user is already answering.

/// Strips ANSI escapes so a pattern is matched against text, not against colour codes.
public func stripAnsi(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{001B}(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
                              with: "", options: .regularExpression)
}

/// What "waiting for input" looks like in a terminal. Anchored at the end where the shape allows
/// it — a `(y/n)` in the middle of a paragraph Claude is quoting is not a question being asked.
public let defaultPromptPatterns: [String] = [
    // REPL prompts, at the end of the output
    "(?:^|\n|\r)>\\s*$",
    "(?:^|\n|\r)>>>\\s*$",
    "(?:^|\n|\r)\\w+>\\s*$",

    // Y/N confirmations
    "\\([Yy]/[Nn]\\)\\s*:?\\s*$",
    "\\[[Yy]/[Nn]\\]\\s*:?\\s*$",
    "\\(yes/no\\)\\s*:?\\s*$",

    // Question prompts, at the end
    "[Cc]onfirm\\??\\s*$",
    "[Aa]pply\\??\\s*$",
    "[Cc]ontinue\\??\\s*$",
    "[Pp]roceed\\??\\s*$",
    "[Aa]ccept\\??\\s*$",

    // Interactive menus — the selector arrow in front of a numbered choice
    "[❯›>]\\s*\\d+\\.",
    // Claude Code's plan file hint, which only appears during an interactive prompt
    "~/\\.claude/plans/.*\\.md",
    // Generic "Would you like to …" anywhere in the recent output
    "[Ww]ould you like to [^?]*\\?",
    "[Pp]ress enter to confirm",
    "esc to cancel"
]

/// A sliding window over the PTY stream. Only the tail can carry a prompt, and keeping the whole
/// session would mean matching against everything Claude ever printed.
public struct PromptBuffer {
    private var content = ""
    private let maxSize: Int

    public init(maxSize: Int = 500) {
        self.maxSize = maxSize
    }

    public mutating func append(_ data: String) {
        content += data
        if content.count > maxSize {
            content = String(content.suffix(maxSize))
        }
    }

    public var text: String { content }

    public mutating func clear() { content = "" }
}

/// Does this tail look like a question? The last 200 characters are enough for any prompt, and
/// short enough that a match cannot come from something scrolled far above.
public func looksLikePrompt(_ raw: String, patterns: [String] = defaultPromptPatterns) -> Bool {
    let tail = String(stripAnsi(raw).suffix(200))
    return patterns.contains { pattern in
        tail.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Per-tab state: buffer, pending check, and whether the dot is currently shown.
public final class PromptDetector {
    private var buffers: [String: PromptBuffer] = [:]
    private var waiting: Set<String> = []
    private var lastInput: [String: Date] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private let showDelay: TimeInterval
    private let patterns: [String]
    private let onChange: (String, Bool) -> Void

    public init(showDelay: TimeInterval = 0.6,
                patterns: [String] = defaultPromptPatterns,
                onChange: @escaping (String, Bool) -> Void) {
        self.showDelay = showDelay
        self.patterns = patterns
        self.onChange = onChange
    }

    public func isWaiting(_ tabId: String) -> Bool { waiting.contains(tabId) }

    public func onData(_ tabId: String, _ data: String) {
        buffers[tabId, default: PromptBuffer()].append(data)

        // More output arrived: whatever was pending is stale, and a tab that is writing is not
        // waiting.
        pending[tabId]?.cancel()
        set(tabId, waiting: false)

        let work = DispatchWorkItem { [weak self] in self?.check(tabId) }
        pending[tabId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    /// The user is already answering — clear the dot and the buffer, so the answer they type does
    /// not match a pattern on the next check.
    public func onUserInput(_ tabId: String) {
        pending[tabId]?.cancel()
        buffers[tabId]?.clear()
        lastInput[tabId] = Date()
        set(tabId, waiting: false)
    }

    /// How long the keyboard has been quiet on this tab — infinite if it never spoke. The renamer
    /// types into the prompt only after a pause, so its command cannot land inside a sentence.
    public func secondsSinceInput(_ tabId: String) -> Double {
        guard let at = lastInput[tabId] else { return .infinity }
        return Date().timeIntervalSince(at)
    }

    public func forget(_ tabId: String) {
        pending[tabId]?.cancel()
        pending.removeValue(forKey: tabId)
        buffers.removeValue(forKey: tabId)
        lastInput.removeValue(forKey: tabId)
        waiting.remove(tabId)
    }

    private func check(_ tabId: String) {
        guard let buffer = buffers[tabId] else { return }
        set(tabId, waiting: looksLikePrompt(buffer.text, patterns: patterns))
    }

    private func set(_ tabId: String, waiting isWaiting: Bool) {
        let was = waiting.contains(tabId)
        guard was != isWaiting else { return }
        if isWaiting { waiting.insert(tabId) } else { waiting.remove(tabId) }
        onChange(tabId, isWaiting)
    }
}

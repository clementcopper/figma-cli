import Foundation
import FigmaClaudeCore

/// The two words after `fc-` come from the first prompt: found in the transcript, named by a
/// Haiku call, or — when that fails — picked from the prompt itself.
enum TaskWordsTests {
    static func run() {
        transcript()
        firstPrompt()
        parse()
        fallback()
        instruction()
    }

    // Claude Code keys a project directory by the cwd with every non-alphanumeric character
    // replaced by a hyphen: `/Users/x/.claude` becomes `-Users-x--claude`.
    // testFindsTheTranscriptOfASession
    static func transcript() {
        Checks.expect(transcriptPath(cwd: "/Users/x/figma-cli", sessionId: "ab-1", home: "/Users/x"),
                      "/Users/x/.claude/projects/-Users-x-figma-cli/ab-1.jsonl")
        Checks.expect(transcriptPath(cwd: "/Users/x/.claude", sessionId: "s", home: "/Users/x"),
                      "/Users/x/.claude/projects/-Users-x--claude/s.jsonl")
        Checks.expect(transcriptPath(cwd: "/Users/x/Documents/DMA/Designdone/Design", sessionId: "s", home: "/Users/x"),
                      "/Users/x/.claude/projects/-Users-x-Documents-DMA-Designdone-Design/s.jsonl")
    }

    // The first user record is a `/clear` or a hook, not the prompt; the prompt is the first user
    // record with text of its own.
    // testSkipsCommandsAndHooksToReachThePrompt
    static func firstPrompt() {
        let lines = [
            #"{"type":"summary","summary":"x"}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<local-command-stdout></local-command-stdout>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<system-reminder>hook text</system-reminder>"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"Hey Claude, mach bitte /feedback-triage"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"second prompt"}}"#,
        ].joined(separator: "\n")
        Checks.expect(firstUserPrompt(transcript: lines), "Hey Claude, mach bitte /feedback-triage")

        // Content as an array of blocks: the first text block counts, a tool_result does not.
        let blocks = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"bind the button fills"}]}}"#,
        ].joined(separator: "\n")
        Checks.expect(firstUserPrompt(transcript: blocks), "bind the button fills")

        Checks.expectNil(firstUserPrompt(transcript: ""))
        Checks.expectNil(firstUserPrompt(transcript: #"{"type":"user","message":{"content":"<command-name>/x</command-name>"}}"#))
        // A half-written last line (Claude Code is still appending) does not break the rest.
        Checks.expect(firstUserPrompt(transcript: #"{"type":"user","message":{"content":"first"}}"# + "\n{\"type\":\"us"), "first")
        // Long prompts are cut before they go to Haiku.
        let long = #"{"type":"user","message":{"content":""# + String(repeating: "a", count: 5000) + #""}}"#
        Checks.expect(firstUserPrompt(transcript: long)?.count, 2000)
    }

    // Haiku is asked for two words; whatever comes back is checked, never trusted.
    // testAcceptsExactlyTwoSluggableWords
    static func parse() {
        Checks.expect(parseTaskWords("token-audit"), "token-audit")
        Checks.expect(parseTaskWords("Token Audit\n"), "token-audit")
        Checks.expect(parseTaskWords("Sure! Here you go:\nfeedback-triage"), "feedback-triage")
        Checks.expect(parseTaskWords("Größen-Übersicht"), "grossen-ubersicht")
        Checks.expectNil(parseTaskWords("audit"))
        Checks.expectNil(parseTaskWords("token binding audit"))
        Checks.expectNil(parseTaskWords(""))
        Checks.expectNil(parseTaskWords("I cannot name this task."))
        Checks.expectNil(parseTaskWords("a-b"))
    }

    // testPicksTwoContentWordsFromThePromptWhenHaikuIsUnavailable
    static func fallback() {
        Checks.expect(fallbackTaskWords("Hey Claude, mach bitte /feedback-triage"), "feedback-triage")
        Checks.expect(fallbackTaskWords("bind the button fills to Semantic"), "bind-button")
        Checks.expect(fallbackTaskWords("Zähl die Textstyles"), "zahl-textstyles")
        Checks.expectNil(fallbackTaskWords("ok"))
        Checks.expectNil(fallbackTaskWords(""))
    }

    // testAsksForTwoWordsInThePromptsLanguage
    static func instruction() {
        let p = taskWordsPrompt(for: "mach bitte /feedback-triage")
        Checks.expect(p.contains("two words"), true)
        Checks.expect(p.contains("mach bitte /feedback-triage"), true)
        Checks.expect(p.hasSuffix("\n"), false)
    }
}

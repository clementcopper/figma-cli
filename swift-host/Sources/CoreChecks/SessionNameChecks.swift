import Foundation
import FigmaClaudeCore

/// The name a panel tab hands to `claude -n`, and the one it renames itself to once the task is
/// known. The Electron host (`app/tests/session-name.test.js`) stays on its old format; these
/// cases no longer mirror the JS suite.
enum SessionNameTests {
    static func run() {
        startName()
        fallbacks()
        slugRules()
        uniqueness()
        taskName()
        spawns()
        injection()
    }

    // testNamesTheSessionAfterTheFileAndThePage
    static func startName() {
        Checks.expect(panelSessionName(file: "Designdone", page: "CLI Lab", cwd: "/Users/x/Design"),
                      "fc-designdone-cli-lab")
        Checks.expect(panelSessionName(file: "Website Redesign", page: "Components", cwd: "/x"),
                      "fc-website-redesign-components")
        // The daemon reports the browser page title, so the suffix comes along for the ride.
        Checks.expect(panelSessionName(file: "Icon Set – Figma", page: "Icons"), "fc-icon-set-icons")
        // No page yet (first tab before the first poll has answered with one).
        Checks.expect(panelSessionName(file: "Designdone", page: "", cwd: "/x"), "fc-designdone")
    }

    // The first tab after app start can spawn before the watcher's first poll returns.
    // testFallsBackToTheWorkingDirectory
    static func fallbacks() {
        Checks.expect(panelSessionName(file: "", page: "", cwd: "/Users/x/Documents/Business"),
                      "fc-business")
        Checks.expect(panelSessionName(cwd: "/Users/x/Documents/Business/"), "fc-business")
        // A page without a file says nothing on its own.
        Checks.expect(panelSessionName(file: "", page: "CLI Lab", cwd: "/Users/x/Design"), "fc-design")
        Checks.expect(panelSessionName(), sessionNamePrefix)
        Checks.expect(panelSessionName(file: nil, page: nil, cwd: nil), sessionNamePrefix)
        Checks.expect(panelSessionName(file: "   ", page: " ", cwd: ""), sessionNamePrefix)
        // testDoesNotNameASessionAfterTheFilesystemRoot
        Checks.expect(panelSessionName(cwd: "/"), sessionNamePrefix)
        Checks.expect(panelSessionName(cwd: "."), sessionNamePrefix)
        // Claude Code refuses a name that is empty once invisible characters are stripped.
        let invisible = "\u{200B}\u{200B}\u{FEFF}"
        Checks.expect(panelSessionName(file: invisible, cwd: "/Users/x/Business"), "fc-business")
        Checks.expect(panelSessionName(file: "設計 ✱", cwd: "/Users/x/Business"), "fc-business")
    }

    static func slugRules() {
        // A German file name has to stay readable: "Übersicht", not "bersicht".
        Checks.expect(panelSessionName(file: "Übersicht Größen", page: "Ränder"),
                      "fc-ubersicht-grossen-rander")
        Checks.expect(panelSessionName(file: "Design\u{0007} System"), "fc-design-system")
        Checks.expect(panelSessionName(file: "Design\n  System"), "fc-design-system")
        Checks.expect(sessionSlug("--Design---System--"), "design-system")
        // The cut must not leave a trailing hyphen.
        let long = String(repeating: "A", count: 80)
        Checks.expect(panelSessionName(file: long), "fc-" + String(repeating: "a", count: 40))
        let cutAtASpace = String(repeating: "a", count: 39) + " bbbb"
        Checks.expect(sessionSlug(cutAtASpace), String(repeating: "a", count: 39) + "-b")
    }

    // A name is handed out once, ever: against the sessions that run and the ones that ran.
    // testNeverHandsOutANameTwice
    static func uniqueness() {
        Checks.expect(uniqueName("fc-designdone-cli-lab", taken: []), "fc-designdone-cli-lab")
        Checks.expect(uniqueName("fc-designdone-cli-lab", taken: ["fc-designdone-cli-lab"]),
                      "fc-designdone-cli-lab-2")
        Checks.expect(uniqueName("fc-designdone-cli-lab",
                                 taken: ["fc-designdone-cli-lab", "fc-designdone-cli-lab-2"]),
                      "fc-designdone-cli-lab-3")
        // A base that already ends in a number gets its own counter, not a bump of that number.
        Checks.expect(uniqueName("fc-v2", taken: ["fc-v2"]), "fc-v2-2")
    }

    // testBuildsTheTaskNameFromTwoWords
    static func taskName() {
        Checks.expect(taskSessionName(words: "feedback-triage"), "fc-feedback-triage")
        Checks.expect(taskSessionName(words: "Button Bindings"), "fc-button-bindings")
    }

    // Only a real start gets a fresh name and id; the other two adopt a session that has both.
    // testKnowsWhichSpawnsStartANewSession
    static func spawns() {
        Checks.expect(startsANewSession(extraArgs: []), true)
        Checks.expect(startsANewSession(extraArgs: ["--resume"]), false)
        Checks.expect(startsANewSession(extraArgs: ["-r"]), false)
        Checks.expect(startsANewSession(extraArgs: ["--continue"]), false)
        Checks.expect(startsANewSession(extraArgs: ["-c"]), false)
    }

    // `/rename` is typed into the user's terminal, so every reason to hold back wins.
    // testTypesOnlyIntoAnIdleUnattendedPrompt
    static func injection() {
        Checks.expect(shouldInject(status: "idle", waiting: false, secondsSinceInput: 10), true)
        Checks.expect(shouldInject(status: "busy", waiting: false, secondsSinceInput: 10), false)
        Checks.expect(shouldInject(status: "idle", waiting: true, secondsSinceInput: 10), false)
        Checks.expect(shouldInject(status: "idle", waiting: false, secondsSinceInput: 1), false)
        Checks.expect(shouldInject(status: nil, waiting: false, secondsSinceInput: 10), false)
        Checks.expect(shouldInject(status: "idle", waiting: false, secondsSinceInput: .infinity), true)
        Checks.expect(renameCommand("fc-feedback-triage"), "/rename fc-feedback-triage\r")
    }
}

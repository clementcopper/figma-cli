# Figma Claude — the Swift host

Claude Code in a macOS window next to Figma, written in Swift and AppKit. This is the app that is
being developed; the Electron version it grew out of still sits in [`app/`](../app/README.md) and
is not.

It is a window around three things: a terminal running Claude Code, Claude's status line drawn as
rings instead of text, and a live view of what Figma has open and selected.

<p align="center">
  <img src="window.png" width="420" alt="The Figma Claude window: toolbar with the open Figma file, Claude Code below it, and the ring status bar">
</p>

## Building

Xcode's command line tools and nothing else — no Node, no `npm install`, no native module to
rebuild.

```bash
swift build -c release && bash Tools/make-app.sh
open "build/Figma Claude.app"
```

`make-app.sh` assembles the bundle around the release binary: `Info.plist`, the icon (taken from
`../app/build/icon.icns`, so both hosts wear the same one) and an ad-hoc signature, which
unsigned bundles need on Apple Silicon. There is no `xcodebuild` anywhere here and none is
needed — an `.app` is a directory with an `Info.plist`.

The bundle carries three numbers, all visible in **About Figma Claude**:

| | |
|---|---|
| `VERSION` | the version, set by hand |
| `CFBundleVersion` | the commit it was built from, suffixed `+` when the tree was dirty |
| `FCBuildDate` | that commit's date |

So the running app can always answer "which build is this?" — worth more than it sounds, because
a stale process that looks like the new one costs an afternoon of debugging something already
fixed.

## Checks

```bash
swift run CoreChecks     # every ported case, no window, no Figma
```

**XCTest needs a full Xcode**; with only the command line tools `swift test` stops at "XCTest not
available". The ported cases therefore run as a plain executable target instead. That is why
logic that decides something belongs in `Sources/FigmaClaudeCore/` — it can be checked there —
and the view keeps only the drawing.

CI runs both on every push to `master`: the CLI suite on Linux across Node 18/20/22, and a macOS
job that builds this package and runs `CoreChecks`.

## Layout

| Target | What it is |
|---|---|
| `Sources/FigmaClaudeCore/` | pure logic, **no AppKit**: session names, the status-line parser, ring geometry, the CLI invocation, shell PATH, exit recovery, tab state |
| `Sources/FigmaClaude/` | the app: window, toolbar, tab strip, ring status bar, terminal (SwiftTerm), menus, the probes |
| `Sources/CoreChecks/` | the cases, one file per Core area |

`swiftc` cannot be pointed at `FigmaClaudeCore` directly — SwiftPM leaves no library by that name
on disk, so a throwaway binary fails with `library not found`. Everything to be checked goes
through `CoreChecks`.

## Probes

The app can draw its own interface into a PNG, or answer in text, without a window on screen.

This exists because **`screencapture` is blind without Screen Recording permission** — it returns
the desktop picture with every window missing, and no error. `cacheDisplay` renders inside the
process, needs no permission, and shows exactly what the app draws.

```bash
B=".build/release/FigmaClaude"          # or the binary inside the bundle, see below

$B --render-chrome [tabs] [--width N] [--hover] [--selection]   # /tmp/chrome.png
$B --render-rings  [path] [--bar]                               # the ring bar at five widths
$B --render-about  [path]                                       # the About panel
$B --render-menurows                                            # the Figma menu's rows, /tmp/menurows.png

$B --print-menu                # the Figma menu as text, the same rows `fig-status` prints
$B --print-statusline [tabId]  # what the status row would draw, and what it was built from
$B --print-about               # the About panel as text, with the real CLI lookup

$B --probe-selection           # does the status band grow when a selection lands (real window)
$B --probe-late-label [width]  # the toolbar labels after the first poll arrives late

$B --appearance light|dark     # forces the palette on any of the render probes
```

Two things to know before trusting one:

- **`--render-about` and anything reading the bundle must run from inside the bundle**
  (`"build/Figma Claude.app/Contents/MacOS/FigmaClaude"`). Outside it there is no `Info.plist`,
  and the panel then has no version to show.
- **A probe that stubs its input proves nothing about that input.** `--render-about` passes a
  fixed CLI version so the image stays reproducible, which is exactly why the real lookup once
  shipped broken with every check green. `--print-about` exists to run the real path.

## Tools

| | |
|---|---|
| `Tools/make-app.sh` | assembles the bundle (above) |
| `Tools/display-check.sh` | what a terminal actually puts on screen: box drawing joining without gaps, wide emoji taking two cells, combining marks taking none, 256-colour against truecolour |
| `Tools/width-check.sh` | black-box width check — print, then ask the terminal where the cursor is (`ESC[6n`) and compare against what a correct one must answer |
| `Tools/repaint-bench.sh` | full-screen repaints in the shape Claude Code's streaming UI produces, which is not what `cat` of a file measures |

## Session names

A tab starts Claude Code as `claude -n fc-<file>-<page> --session-id <uuid>` — the bound Figma
file and the page it is on (`fc-designdone-cli-lab`), the working directory when no file is known
yet (`fc-design`), the bare `fc` when nothing is. Claude Code never touches a name set with `-n`,
so the host renames the session itself once the task is known: when the first prompt appears in
the transcript (`~/.claude/projects/<cwd key>/<uuid>.jsonl`), a Haiku call names it in two words
in the prompt's own language, and `/rename fc-<w1>-<w2>` is typed into the tab
(`SessionRenamer.swift`, rules in `SessionName.swift` and `TaskWords.swift`).

Typing into somebody's terminal has conditions, all four at once: Claude Code's registry row
(`~/.claude/sessions/<pid>.json`, found by `sessionId`) says `idle`, the prompt detector sees no
question, the keyboard has been quiet for 3 s, and the tab still runs that session. The registry
confirms the new name within 10 s; one retry, then the start name stays.

Every name is handed out once, ever: checked against the running sessions and the host's ledger
`~/.figma-ds-cli/session-names.json` (every name ever minted, written before `claude` starts); a
collision gets `-2`, `-3`, … `--resume` and `--continue` adopt a session that has a name and are
neither named nor renamed. The Electron host in `app/` stays on its old `figma-claude:<file>`.

## Reading further

- [`../CLAUDE.md`](../CLAUDE.md) — the repo's own guide, including what must survive an upstream merge
- [`../LEARNINGS.md`](../LEARNINGS.md) — the AppKit traps this app has already paid for: `cacheDisplay` not capturing the window's background, `NSImage.lockFocus` discarding the appearance context, SwiftTerm's closed key handling, symbols that need macOS 15
- [`../app/PORTED-FROM.md`](../app/PORTED-FROM.md) — which files came from `claude-terminal-panel`, and from which commit

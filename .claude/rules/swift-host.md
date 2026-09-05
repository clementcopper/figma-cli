---
paths:
  - "swift-host/**"
---

# Swift host (`swift-host/`, AppKit + SwiftTerm)

Distilled from `LEARNINGS.md` § Swift host. Stories and measurements there.

## Layout

- **Position the top-level bands by frame; Auto Layout only inside each band.** Pinning bands to the content view makes AppKit resolve the window to its *smallest* legal size (272 for a saved 380); `contentMinSize`, priorities, `==` constraints and intrinsic widths all failed.
- **Save the content rect, not `window.frame`,** or the window grows by the title bar (28 pt) on every launch.
- **`NSStackView` spaces by alignment rects, not frames.** Subclass with `alignmentRectInsets = NSEdgeInsets()` **when a view is created**, not when someone notices the gap; the ring bar hit the same trap months after the first fix.
- **A frame set by hand is discarded unless `translatesAutoresizingMaskIntoConstraints` is `true`.** Twice in one afternoon children drew at the same origin while the measurements printed the right rectangles (measured before the discard).
- **A wrapping view's height depends on the width it has not been given yet.** Override `setFrameSize`, invalidate on width change, propagate upwards; otherwise `intrinsicContentSize` answers the tallest case (212 pt = five stacked rows).
- **`NSButtonCell` cannot be talked into padding;** a button that needs icon and label with real padding lays them out itself in a stack.
- **A view that implements `draw(_:)` never gets `updateLayer`;** a background set there silently disappears.
- **Two SF Symbols need macOS 15** (`arrow.trianglehead.*`); `NSImage(systemSymbolName:)` returns nil for unknown names, so every name is asked for with a fallback.

## Colours, capture, appearance

- **`NSColor.textBackgroundColor.cgColor` freezes the appearance,** and SwiftTerm converts assigned colours immediately; resolve dynamic colours inside `effectiveAppearance.performAsCurrentDrawingAppearance`.
- **A `layer.backgroundColor` set once in `init` is frozen too.** Fixed-colour surfaces go through `TintedView`, which resolves in `updateLayer`; the effort chip stayed light after a switch to dark.
- **Anything shown per tab belongs in `show(_:)`.** Four paths bring a tab to the front and all go through it; the folder button, set only at launch and on picking, showed the same directory for every tab.
- **Finder caches an app's icon through LaunchServices.** `touch` the bundle and `lsregister -f` after building, or `build/` keeps the placeholder while the Dock shows the real one.
- **`cacheDisplay` gives the view, not the window:** everything outside the glyphs is transparent. `wantsLayer = true` plus a layer background set inside the drawing appearance puts the ground into the capture.
- **`NSImage.lockFocus` throws away the appearance context;** pin dynamic colours to concrete ones before locking focus, or don't route through an NSImage.
- **A blank render is a measurement, not a look.** `NSBitmapImageRep.colorAt` answered in one run what three guesses missed; hand-rolled PNG parsing does not count.

## Processes, sessions, terminal

- **SwiftTerm reports the raw `waitpid` status:** exit 1 arrives as 256. Decode with `WIFEXITED`/`WIFSIGNALED` before comparing; every `code == 1` branch was dead.
- **SwiftTerm's key handling is closed** (`public override`, not `open`); `send(source:data:)` is `open` and is where keystrokes leave for the PTY.
- **A `timeout` parameter nobody reads is a hang with a name.** `readOutput(_:from:timeout:)` in `ProcessOutput.swift` is the one place a child's deadline is enforced; `runCli` and `LoginShellPath.resolve` go through it.
- **Scan the transcript's bytes, never split it into lines.** `countCompactions` runs on every status line render: 1 320 ms at 17 MB as a String split, 14 ms as a `Data.range(of:)` scan.
- **⌘Q never sends `windowWillClose`.** Exit work lives in `applicationWillTerminate`; closing the window arrives there too.
- **A terminal exiting must not close the app;** write the exit description into the tab and leave it standing, as the Electron host does.
- **A spawn that adopts a conversation (`--resume`, `-r`, `--continue`, `-c`) passes neither `-n` nor `--session-id`,** or the picked session gets renamed. And Claude Code keeps a session's name in two places (transcript records **and** `custom-title.json` sidecar); sweep both.
- **A guard that carries two things drops both.** The status-line `--settings` hung off the same `!sessionName.isEmpty` guard as `-n`.
- **`folding(.diacriticInsensitive)` deletes "ß";** replace with `ss` first, umlauts fold fine.
- **`closeTab` takes the window down on the last tab;** in a replace, open the new one first. Check every caller that walks through an edge case on purpose.
- **Finding a command on PATH is not being able to run it.** The `figma-cli` shim does `exec node …`; hand the resolved PATH to every child (`runCli` in `FigmaActions.swift` does).
- **A probe that stubs the thing under test proves nothing.** `--render-about` passed a fixed version and shipped the dialog broken; every stubbed input needs a second, non-visual probe (`--print-about`) that runs the real path.
- **XCTest needs full Xcode;** with Command Line Tools only, the checks run as a plain executable target (`CoreChecks`).
- **Text into the user's terminal only when Claude is idle, shows no question, and the keyboard has been quiet for 3 s** (`shouldInject`, `SessionRenamer.swift`); the registry row `~/.claude/sessions/<pid>.json` says busy or idle, the host finds it by `sessionId`.
- **A session name is handed out once, ever:** registry ∪ ledger (`~/.figma-ds-cli/session-names.json`), written before `claude` starts; a collision gets `-2`.

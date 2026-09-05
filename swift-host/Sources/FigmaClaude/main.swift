// The app: a window around a terminal running Claude Code, the ring status bar, and the Figma
// toolbar. The pure logic lives in `FigmaClaudeCore`; this file wires it to AppKit.
//
//     .build/release/FigmaClaude                    the configured command, in the configured cwd
//     .build/release/FigmaClaude /bin/zsh -lc "…"   an explicit command, used by Tools/
//     .build/release/FigmaClaude --statusline       the status line producer (no window)
//     .build/release/FigmaClaude --render-…         the probes, see README

import AppKit
import SwiftTerm
import FigmaClaudeCore

/// What the app is called, read from the bundle rather than typed twice.
///
/// The bundle is `Figma Claude.app`; only the executable inside it stays `FigmaClaude`, because
/// `pgrep -x` addresses it by that name. Keeping the visible string in the Info.plist means the
/// rename happened in one place — the fallback is for `swift run`, which has no bundle at all.
let appDisplayName: String = {
    for key in ["CFBundleDisplayName", "CFBundleName"] {
        if let name = Bundle.main.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
            return name
        }
    }
    return "Figma Claude"
}()

/// The terminal of one tab, with the two hooks the panel needs around the PTY stream.
///
/// `dataReceived` is where `LocalProcess` hands the PTY output over — the only place the bytes
/// are visible before SwiftTerm swallows them; the delegate never sees the data.
///
/// `Unhandle selector noop:` on stdout comes from SwiftTerm's own `doCommand(by:)` default branch
/// and means AppKit had no binding for a chord. Control keys are not affected — `keyDown` handles
/// those before `interpretKeyEvents`. ⌘-chords reached `noop:` while there was no menu bar for
/// them to hit; there is one now.
///
/// Worth knowing either way: `keyDown`, `flagsChanged` and `doCommand` are all `public override`
/// rather than `open`, so none of SwiftTerm's key handling can be corrected from outside the
/// module. Anything that needs changing there means forking the package.
final class PanelTerminalView: LocalProcessTerminalView {
    var sawOutput = false
    /// Called with everything the process writes, so the prompt detector can watch the tail.
    var onOutput: ((String) -> Void)?
    /// Called when the user types, so the dot clears before the next check runs.
    var onInput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        sawOutput = true
        if let onOutput {
            let text = String(decoding: slice, as: UTF8.self)
            DispatchQueue.main.async { onOutput(text) }
        }
        super.dataReceived(slice: slice)
    }

    /// `send` rather than `keyDown`: SwiftTerm marks its key handling `public override` rather
    /// than `open`, so it cannot be overridden from outside the module — but `send` is where
    /// every keystroke leaves for the PTY, and it is `open`.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?()
        super.send(source: source, data: data)
    }
}

/// The column the terminal sits in: padding around it, and the column painted in the terminal's
/// own colour.
///
/// Both halves are needed. The inset alone only revealed the window's grey underneath — the same
/// grey that showed as a strip beside the tabs when the terminal did not quite fill its column.
/// And the inset is applied here rather than at the call site because `show(_:)` can run before
/// the column has a size, where `insetBy` on an empty rect yields a negative one.
final class TerminalColumn: NSView {
    static let padding: CGFloat = 8

    /// Drawn, not stored as a `CGColor` on the layer. `NSColor.textBackgroundColor.cgColor`
    /// resolves against whatever appearance is current at the moment it is read, so a column
    /// painted once stayed light after the system went dark. Drawing asks the colour again on
    /// every pass, which is what makes it dynamic.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    /// The terminal fills the same colour for everything outside its cells, and it holds an
    /// `NSColor`, so it follows the appearance on its own — but only if it is told again when
    /// the appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for view in subviews {
            if let terminal = view as? TerminalView {
                Self.matchBackground(terminal, in: self)
            }
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        for view in subviews {
            view.frame = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        }
    }

    /// Everything the terminal paints outside its cells — the strip below the last row, the
    /// area behind a hidden scroller — uses `nativeBackgroundColor`. On a fresh view that reads
    /// black while the cells are drawn white, which put a black bar under the terminal the
    /// moment the padding revealed it. Setting it makes the leftover match the column.
    /// SwiftTerm converts the colour to its own representation the moment it is assigned
    /// (`nativeBackgroundColor`'s setter calls `getTerminalColor()`), which freezes whichever
    /// appearance happened to be current. Resolving inside the view's own appearance is what
    /// makes a dark window get a dark terminal instead of a white rectangle.
    static func matchBackground(_ terminal: TerminalView, in view: NSView) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            terminal.nativeBackgroundColor = .textBackgroundColor
            terminal.nativeForegroundColor = .textColor
        }
    }

    /// SwiftTerm keeps an `NSScroller` at its trailing edge. Its style is `.overlay`, which is
    /// meant to auto-hide, but the slot stays drawn — a grey box between the terminal and the tab
    /// strip. The panel scrolls with the wheel and with Claude's own keys, so the control has
    /// nothing to add.
    func hideScroller(in terminal: NSView) {
        for view in terminal.subviews where view is NSScroller {
            view.isHidden = true
        }
    }
}

/// The four bands of the window, laid out by frame.
///
/// Deliberately not Auto Layout at this level. Pinning the bands to the content view's edges
/// makes AppKit derive the *window's* size from the layout — the stack trace named
/// `_changeWindowFrameFromConstraintsIfNecessary` — and that resolution takes the smallest legal
/// size, not the saved one. Measured: 380 asked, 272 given with a 240-point floor on the
/// terminal, 117 without it. `contentMinSize`, a low-priority width, an `==` on the column, an
/// intrinsic width and re-asserting the size after the first pass all still gave 272.
///
/// Positioning by frame takes the window out of that conversation: the window owns its size, and
/// Auto Layout is left to do what it is good at — the inside of each band.
final class PanelContentView: NSView {
    var toolbar: NSView?
    var strip: NSView?
    var terminal: NSView?
    var statusLine: NSView?

    /// One point each, drawn rather than laid out — three views with a colour would be three
    /// more things to keep in step with the bands they divide.
    private let lineWidth: CGFloat = 1

    /// The status bar's top edge is the exception: it has to run the full window width, and
    /// `draw(_:)` happens *under* the subviews, so the tab strip painted over it — measured, the
    /// line stopped dead at the strip's edge. A view added last sits on top of the strip.
    let topEdge = Hairline()

    override var isFlipped: Bool { false }

    /// The strip runs from under the toolbar to the bottom edge, so the status line ends at it
    /// rather than passing underneath. One place for the split, read by `layout` and `draw`.
    private var bandWidths: (strip: CGFloat, left: CGFloat) {
        let strip = min(TabStripView.stripWidth, bounds.width)
        return (strip, max(0, bounds.width - strip - lineWidth))
    }

    override func layout() {
        super.layout()
        guard let toolbar, let strip, let terminal, let statusLine else { return }

        let width = bounds.width
        let (stripWidth, leftWidth) = bandWidths

        // Width first, then ask how tall it needs to be. Asked the other way round the status
        // line answers for a zero-width column, where its text wraps — measured a 1387-point
        // window for a 700-point one.
        statusLine.setFrameSize(NSSize(width: leftWidth, height: statusLine.frame.height))
        statusLine.layoutSubtreeIfNeeded()
        let statusHeight = min(statusLine.fittingSize.height, bounds.height / 2)

        toolbar.frame = NSRect(x: 0, y: bounds.height - ToolbarView.barHeight,
                               width: width, height: ToolbarView.barHeight)
        strip.frame = NSRect(x: width - stripWidth, y: 0, width: stripWidth,
                             height: max(0, bounds.height - ToolbarView.barHeight - lineWidth))
        statusLine.frame = NSRect(x: 0, y: 0, width: leftWidth, height: statusHeight)

        let middleTop = bounds.height - ToolbarView.barHeight - lineWidth
        terminal.frame = NSRect(x: 0, y: statusHeight + lineWidth, width: leftWidth,
                                height: max(0, middleTop - statusHeight - lineWidth))

        if topEdge.superview !== self { addSubview(topEdge) }
        topEdge.frame = NSRect(x: 0, y: statusHeight, width: width, height: lineWidth)
    }

    /// Two of the three separators. The third — the status bar's top edge — is `topEdge`, a
    /// subview: drawn here it ran only as far as the strip and in the system colour, measured
    /// 0.851 against the 0.896 of the hairline inside the bar.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        // Under the toolbar, across the whole width.
        bounds.divided(atDistance: ToolbarView.barHeight + lineWidth, from: .maxYEdge)
            .slice.divided(atDistance: lineWidth, from: .minYEdge).slice.fill()
        // Left of the strip, from the toolbar down to the bottom edge.
        NSRect(x: bandWidths.left, y: 0, width: lineWidth,
               height: bounds.height - ToolbarView.barHeight - lineWidth).fill()
    }
}

/// One tab: its terminal, its name, and where it started.
final class TerminalTab {
    let view: PanelTerminalView
    let name: String
    let cwd: String
    /// What the status line producer names its file after. Not the display name: that changes
    /// with the counter, and a file left behind would reappear under a later tab.
    let id: String
    let spawnedAt = Date()
    /// The `--session-id` this tab's conversation runs under; empty for `--resume`/`--continue`,
    /// which adopt a session the host did not mint.
    let sessionId: String
    /// What Claude Code calls the session: the start name, then the task name once renamed.
    var sessionName: String

    /// `id` is carried over when a tab is respawned: the status line is keyed on it, and a new
    /// one would point the row at a tab that no longer exists.
    init(view: PanelTerminalView, name: String, cwd: String, id: String? = nil,
         sessionId: String = "", sessionName: String = "") {
        self.view = view
        self.name = name
        self.cwd = cwd
        self.id = id ?? "tab-\(UUID().uuidString.prefix(8))"
        self.sessionId = sessionId
        self.sessionName = sessionName
    }
}

final class PanelWindowController: NSObject, LocalProcessTerminalViewDelegate, NSWindowDelegate {
    let window: NSWindow
    private let tabStrip = TabStripView()
    private let toolbar = ToolbarView()
    /// What to start instead when a tab exits with code 1 — see `ExitRecovery`.
    private var exitRecovery = ExitRecovery()

    private let statusLine = StatusRingLineView()
    /// Draws whatever Claude Code last wrote for the active tab, and toasts once per crossing of
    /// the clear marker — not on every poll: the ring's colour already tells the story, the toast
    /// is the nudge. Reset when the fill dips back under the marker.
    private lazy var statusWatcher = StatusLineWatcher { [weak self] tabId, snapshot in
        guard let self, self.state.active?.id == tabId else { return }
        self.statusLine.render(snapshot)
        let marker = self.statusLine.contextThreshold
        let danger = contextFillLevel(snapshot.usedPercent, marker: marker) == .danger
        if danger && !self.markerDangerToasted {
            self.markerDangerToasted = true
            self.toolbar.toast("Context \(Int(snapshot.usedPercent.rounded()))% — /clear")
        } else if !danger && self.markerDangerToasted {
            self.markerDangerToasted = false
        }
    }
    private lazy var prompts = PromptDetector { [weak self] _, _ in self?.refreshTabBar() }
    /// Types `/rename fc-<task>` into a fresh tab once its first prompt is known — see
    /// `SessionRenamer.swift`. Built lazily: it needs `prompts` and the PATH of a panel shell.
    private lazy var renamer: SessionRenamer = {
        let config = PanelConfig.load()
        let environment = panelEnvironment(config: config)
        let path = environment["PATH"] ?? ""
        return SessionRenamer(
            prompts: prompts, claude: whichOnPath(config.command, path: path), path: path,
            environment: environment,
            tabFor: { [weak self] tabId, sessionId in
                guard let tab = self?.state.tabs.first(where: { $0.id == tabId }),
                      tab.sessionId == sessionId else { return nil }
                return tab.view
            },
            onRenamed: { [weak self] tabId, name in
                self?.state.tabs.first(where: { $0.id == tabId })?.sessionName = name
            })
    }()
    /// An action that touches the daemon or Figma is running; the menu is read-only until it ends.
    private var figmaBusy = false
    /// Whether the "should clear" toast has already fired for the current crossing of the
    /// marker. Reset when the fill dips back under it, so a re-crossing toasts again.
    private var markerDangerToasted = false
    private lazy var cli = resolveCli(appRoot: Bundle.main.bundlePath, configured: PanelConfig.load().figmaCli)
    private let container = TerminalColumn()
    private var state = TabState<TerminalTab>()
    /// `NSWorkspace` answers "is Figma running" from a list the system already keeps — no process
    /// start every 2.5 seconds, which is what `pgrep -x Figma` would cost now that the toolbar
    /// wants this on every poll rather than only when the menu opens.
    private let watcher = FigmaWatcher(probes: FigmaProbes(figmaRunning: {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.figma.Desktop" }
    }))

    /// An explicit command from the command line, used by the probes in `Tools/`. It applies to
    /// the first tab only — every tab after it is a real panel tab.
    private let commandOverride = Array(CommandLine.arguments.dropFirst())

    override init() {
        // Where the window was last time, pulled back onto an attached screen if the monitor it
        // was parked on is gone.
        let screens = NSScreen.screens.map {
            WorkArea(x: $0.visibleFrame.origin.x, y: $0.visibleFrame.origin.y,
                     width: $0.visibleFrame.width, height: $0.visibleFrame.height)
        }
        let saved = clampBounds(loadBounds(), workAreas: screens)

        let frame = NSRect(x: saved.x ?? 0, y: saved.y ?? 0, width: saved.width, height: saved.height)

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()

        watcher.onChange = { [weak self] snapshot in
            self?.toolbar.render(snapshot)
            self?.statusLine.renderSelection(snapshot.selection)
        }
        watcher.start()

        let config = PanelConfig.load()
        applyTheme(ThemeSetting(rawValue: config.theme) ?? .system)
        window.title = appDisplayName
        window.delegate = self
        // An explicit floor, so the answer to "how narrow may this be" is a decision rather than
        // whatever the longest label happened to be.
        window.contentMinSize = NSSize(width: 320, height: 240)

        let content = PanelContentView(frame: NSRect(origin: .zero, size: frame.size))
        content.toolbar = toolbar
        content.strip = tabStrip
        content.terminal = container
        content.statusLine = statusLine
        for band in [toolbar, tabStrip, container, statusLine] as [NSView] {
            band.translatesAutoresizingMaskIntoConstraints = true
            content.addSubview(band)
        }
        window.contentView = content
        window.setContentSize(NSSize(width: saved.width, height: saved.height))

        // Full height at launch, and the height alone is not remembered: the panel stands beside
        // Figma for a whole session, and the useful height is always "as much as the screen has".
        // The width is the part worth keeping — that is what gets matched to the Figma window.
        //
        // Set as a *frame*, not a content size. The title bar is part of the frame, so asking for
        // a content height of the full visible area produces a window 28 points too tall and
        // AppKit clamps it — measured 1415 asked, 1387 given.
        //
        // `visibleFrame`, not `frame`: the menu bar and the Dock are not ours to cover, and a
        // window that starts underneath them cannot be dragged back out.
        let home = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: saved.x ?? 0, y: saved.y ?? 0))
        } ?? NSScreen.main
        if let area = home?.visibleFrame {
            window.setFrame(NSRect(x: min(max(saved.x ?? area.minX, area.minX),
                                          area.maxX - saved.width),
                                   y: area.minY, width: saved.width, height: area.height),
                            display: false)
        }

        tabStrip.onSelect = { [weak self] in self?.activate($0) }
        tabStrip.onClose = { [weak self] in self?.closeTab(at: $0) }
        tabStrip.onNewTab = { [weak self] in self?.newTab() }
        toolbar.onPickDirectory = { [weak self] in self?.pickDirectory() }
        toolbar.onFigmaMenu = { [weak self] button in self?.showFigmaMenu(from: button) }
        toolbar.onResume = { [weak self] in
            guard let self else { return }
            // Registered before the respawn, because the process it protects starts inside it:
            // `--resume` kills the running session to make room for the picker, and cancelling
            // the picker then leaves nothing to go back to.
            if let id = self.state.active?.id {
                self.exitRecovery.register(resumeRecoveryPlan(), for: id)
            }
            self.respawnActive(["--resume"])
        }
        toolbar.onContinue = { [weak self] in
            guard let self else { return }
            if let id = self.state.active?.id { self.exitRecovery.clear(for: id) }
            self.respawnActive(["--continue"])
        }
        toolbar.onRestart = { [weak self] in
            guard let self else { return }
            if let id = self.state.active?.id { self.exitRecovery.clear(for: id) }
            self.respawnActive([])
        }
        statusLine.onSelectionClick = { [weak self] in self?.insertSelection() }
        // Still the same stored value, still `contextMarker` in panel.json — only the way it is
        // set changed. The ring design has no handle to drag, so it is a number now.
        statusLine.contextThreshold = config.contextMarker
        statusLine.onThresholdChange = { [weak self] value in
            guard let self, updatePanelConfig(["contextMarker": value]) else { return }
            self.toolbar.toast("Clear threshold \(Int(value.rounded()))%")
        }
        // ESC is what interrupts a turn in Claude Code. Sent to the active tab, because the
        // status line always describes that one.
        statusLine.onStop = { [weak self] in
            guard let tab = self?.state.active else { return }
            tab.view.send(txt: "\u{1b}")
        }
        statusWatcher.start()
        toolbar.setDirectory(config.resolvedCwd() ?? NSHomeDirectory())

        if saved.x == nil { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// This same binary, invoked as Claude Code's status line command. Nothing else has to be
    /// installed and nothing on the user's PATH is involved.
    static var statusLineCommand: String {
        shellPath(Bundle.main.executablePath ?? CommandLine.arguments[0]) + " --statusline"
    }

    // MARK: - Tabs

    func newTab() {
        let config = PanelConfig.load()
        let cwd = config.resolvedCwd() ?? NSHomeDirectory()

        // The Figma file makes the better half of the session name; the working directory is the
        // fallback while the daemon is unreachable. Waiting for the first poll is what stops the
        // first tab from always being named after the folder — the Electron host learned that the
        // hard way, and the fix has to be ported along with the feature.
        watcher.waitForFirstPoll()
        let snapshot = watcher.snapshot
        let file = snapshot.file.isEmpty ? config.figmaFile : snapshot.file
        // The id is minted here rather than left to Claude: it is how the host finds the
        // session's transcript and its registry row later, for the rename after the first prompt.
        let sessionId = UUID().uuidString.lowercased()
        let sessionName = mintSessionName(file: file, page: snapshot.page, cwd: cwd)
        let name = state.nextName()
        let tab = TerminalTab(view: makeTerminalView(), name: name, cwd: cwd,
                              sessionId: sessionId, sessionName: sessionName)
        let view = tab.view
        let environment = panelEnvironment(config: config, tabId: tab.id)
        view.onOutput = { [weak self] text in self?.prompts.onData(tab.id, text) }
        view.onInput = { [weak self] in self?.prompts.onUserInput(tab.id) }

        let executable: String?
        let args: [String]
        if state.count == 0, !commandOverride.isEmpty {
            executable = commandOverride[0]
            args = Array(commandOverride.dropFirst())
        } else {
            executable = whichOnPath(config.command, path: environment["PATH"] ?? "")
            args = panelArguments(config: config, sessionName: sessionName,
                                  sessionId: sessionId,
                                  statusLineCommand: Self.statusLineCommand)
        }

        state.append(tab)
        show(tab)
        start(view, executable: executable, args: args, environment: environment, cwd: cwd,
              command: config.command)
        renamer.watch(tabId: tab.id, sessionId: sessionId, cwd: cwd)
        refreshTabBar()
    }

    /// A start name nobody has had: `fc-<file>-<page>`, made unique against the running sessions
    /// and the ledger, and written to the ledger before `claude` starts.
    private func mintSessionName(file: String, page: String, cwd: String) -> String {
        let base = panelSessionName(file: file, page: page, cwd: cwd)
        let name = uniqueName(base, taken: liveSessionNames().union(ledgerNames()))
        recordName(name)
        return name
    }

    /// Starts the tab's process — or, when the command is nowhere on the PATH, says so in the
    /// tab and leaves it standing, so the window opens with something to read rather than empty.
    private func start(_ view: PanelTerminalView, executable: String?, args: [String],
                       environment: [String: String], cwd: String, command: String) {
        guard let executable else {
            view.feed(text: missingCommandNote(command: command))
            return
        }
        view.startProcess(executable: executable, args: args,
                          environment: environment.map { "\($0.key)=\($0.value)" },
                          currentDirectory: cwd)
    }

    private func show(_ tab: TerminalTab) {
        container.subviews.forEach { $0.removeFromSuperview() }
        // `textBackgroundColor`, not the terminal's `nativeBackgroundColor`: that property reads
        // black on an unconfigured view while the grid is drawn white, so painting the column
        // from it framed the terminal in black.
        TerminalColumn.matchBackground(tab.view, in: container)
        container.addSubview(tab.view)
        container.hideScroller(in: tab.view)
        container.needsLayout = true
        window.makeFirstResponder(tab.view)
        // Both bars, here rather than at each call site: four places bring a tab to the front, and
        // anything redrawn in only some of them shows the previous tab's state in the others. The
        // folder button was exactly that — set at launch and when picking a directory, never on a
        // tab switch, so every tab wore the last directory chosen anywhere.
        //
        // The fallback is what a respawned tab lives on: Claude Code writes no snapshot until it
        // renders, and after `--continue` its first one carries no rate limits at all.
        statusLine.render(statusWatcher.snapshot(for: tab.id)
            ?? statusWatcher.initialSnapshot(cwd: tab.cwd))
        toolbar.setDirectory(tab.cwd)
    }

    func activate(_ index: Int) {
        state.activate(index)
        if let tab = state.active { show(tab) }
        refreshTabBar()
    }

    func closeTab(at index: Int) {
        guard let removed = state.close(index) else { return }
        statusWatcher.forget(removed.id)
        prompts.forget(removed.id)
        renamer.forget(removed.id)
        removed.view.terminate()
        removed.view.removeFromSuperview()

        if let tab = state.active {
            show(tab)
            refreshTabBar()
        } else {
            // The last tab closing takes the window with it — a panel with no terminal is an
            // empty rectangle nobody asked for.
            window.close()
        }
    }

    func closeActiveTab() {
        guard let index = state.activeIndex else { return }
        closeTab(at: index)
    }

    func cycleTab(by offset: Int) {
        state.cycle(by: offset)
        if let tab = state.active { show(tab) }
        refreshTabBar()
    }

    /// A terminal view the way every tab wants it. `onOutput`/`onInput` are set by the caller,
    /// because they carry the tab id.
    private func makeTerminalView() -> PanelTerminalView {
        let view = PanelTerminalView(frame: container.bounds)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.processDelegate = self
        return view
    }

    private func refreshTabBar() {
        let waiting = Set(state.tabs.enumerated()
            .filter { prompts.isWaiting($0.element.id) }
            .map(\.offset))
        tabStrip.render(titles: state.tabs.map(\.name),
                        tooltips: state.tabs.map { "\($0.name) — \(shortenPath($0.cwd))" },
                        activeIndex: state.activeIndex,
                        waiting: waiting)
    }

    // MARK: - The four things a plain terminal cannot do

    /// Connecting is the panel's job, never Claude's — the project rules say so, and the CLI's
    /// own `connect` is the one command that can quit a running Figma if it gets it wrong.
    ///
    /// The CLI never quits a running Figma, so when the debug port is missing the panel asks and
    /// does the quitting itself; `connect` then takes its start-fresh path and brings Figma back
    /// with the flag set. Port of `runConnect` (`app/src/main.ts:561`).
    private func connect() {
        let mode = FigmaMode(rawValue: PanelConfig.load().figmaMode) ?? .yolo
        var restartFigma = false

        // From the poll, like the menu: the two answers are at most 2.5 s old, and asking again
        // here would spawn `pgrep` and wait on a socket on the main thread.
        let snapshot = watcher.snapshot
        if mode == .yolo, !snapshot.cdpOk, snapshot.figmaRunning {
            let ask = NSAlert()
            ask.messageText = "Restart Figma to open the debug port?"
            ask.informativeText =
                "Figma is running without --remote-debugging-port, which is what the CLI talks to. "
                + "Save your work first: Figma will be quit and started again."
            ask.addButton(withTitle: "Restart Figma")
            ask.addButton(withTitle: "Cancel")
            guard ask.runModal() == .alertFirstButtonReturn else { return }
            restartFigma = true
        }

        runInBackground(title: "Connect") {
            if restartFigma {
                quitFigma()
                // Figma takes a moment to let go of its window and its lock file; `connect`
                // arriving before that finds a half-dead app.
                Thread.sleep(forTimeInterval: 2)
            }
            return runCli(self.cli, connectArguments(mode: mode), timeout: 120)
        }
    }

    /// Restarts the daemon, pinned to the bound file when there is one. `FIGMA_FILE` is the only
    /// way to say which — the CLI has no flag for it.
    private func restartDaemon() {
        let pin = PanelConfig.load().figmaFile
        runInBackground(title: "Restart daemon") {
            let result = runCli(self.cli, ["daemon", "restart"],
                                env: pin.isEmpty ? nil : ["FIGMA_FILE": pin], timeout: 30)
            // /health needs a moment before it answers; without the wait the menu reads stale.
            Thread.sleep(forTimeInterval: 1.5)
            guard result.ok else { return result }
            return CliResult(ok: true, output: pin.isEmpty ? "Daemon restarted" : "Daemon bound to \(pin)")
        }
    }

    private func stopDaemon() {
        runInBackground(title: "Stop daemon") {
            let result = runCli(self.cli, ["daemon", "stop"], timeout: 15)
            return result.ok ? CliResult(ok: true, output: "Daemon stopped") : result
        }
    }

    /// Binds the daemon to one open file and keeps Claude's terminals on the same one.
    private func bindFile(_ title: String) {
        guard updatePanelConfig(["figmaFile": title]) else { return reportConfigWriteFailed() }
        restartDaemon()
    }

    /// A mode is only real once the connection has been made in it, so this connects afterwards —
    /// same order as `setFigmaMode` (`app/src/main.ts:618`).
    private func setMode(_ mode: FigmaMode) {
        guard updatePanelConfig(["figmaMode": mode.rawValue]) else { return reportConfigWriteFailed() }
        connect()
    }

    /// `init-agent` in the directory Claude actually runs in — the active tab's, not the repo's.
    private func prepareWorkingDirectory() {
        guard let cwd = state.active?.cwd, !cwd.isEmpty else { return pickDirectory() }
        runInBackground(title: "Prepare this folder") {
            // `claude`, not `both`: Claude Code reads .claude/rules/, never AGENTS.md.
            // `--no-setup` drops the "run connect once per session" line — connecting is a
            // menu item here.
            let result = runCli(self.cli, ["init-agent", "--tool", "claude", "--no-setup"],
                                cwd: cwd, timeout: 15)
            guard result.ok else { return result }
            let folder = prepareOutputFolder(cwd: cwd)
            return CliResult(ok: true, output: "Rules written to \(rulesFile)\n\(folder)")
        }
    }

    /// Writes the selection into the active terminal's input without a newline: sending it stays
    /// the user's decision. Ids, not just names — those are what `get`, `set` and
    /// `render --parent` take.
    private func insertSelection() {
        guard let text = selectionPromptText(watcher.snapshot.selection),
              let tab = state.active else { return }
        // Bracketed paste, so a multi-line selection arrives as one paste rather than as
        // newlines the prompt would submit on.
        tab.view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        window.makeFirstResponder(tab.view)
    }

    private func undoRender() {
        runInBackground(title: "Undo last render") { CliResult(ok: true, output: undoLastRender()) }
    }

    /// Which palette the window wears, and the setting written back for the other host.
    func setTheme(_ setting: ThemeSetting) {
        guard updatePanelConfig(["theme": setting.rawValue]) else { return reportConfigWriteFailed() }
        applyTheme(setting)
    }

    /// `system` deliberately assigns *nothing*.
    ///
    /// A window with no appearance of its own follows macOS, so the "follow the system" case is
    /// handled by AppKit rather than by an observer this app would have to keep in step — and
    /// switching Light/Dark in System Settings arrives without a single line of code here.
    private func applyTheme(_ setting: ThemeSetting) {
        switch setting {
        case .system: window.appearance = nil
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        }

        // Only the terminal in the hierarchy hears `viewDidChangeEffectiveAppearance`; the other
        // tabs' views are out of it while they are not shown, and SwiftTerm freezes the colour it
        // was last handed. Without this a background tab comes back white on a dark window.
        for tab in state.tabs {
            TerminalColumn.matchBackground(tab.view, in: container)
        }
        container.needsDisplay = true
    }

    /// The one failure the actions share: panel.json exists but is not JSON, so nothing was
    /// written. Saying so beats a menu that silently ignores the click.
    private func reportConfigWriteFailed() {
        let alert = NSAlert()
        alert.messageText = "Could not write panel.json"
        alert.informativeText =
            "\(PanelConfig.path) is not valid JSON, so it was left untouched. Fix or delete it."
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    /// Claude Code keeps its session history per directory, so moving a tab means restarting it —
    /// the process cannot be moved, only replaced.
    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Working directory for Claude"
        panel.message = "Claude Code keeps its session history per directory."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        if let current = PanelConfig.load().resolvedCwd() {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        guard panel.runModal() == .OK, let chosen = panel.url?.path else { return }

        guard updatePanelConfig(["cwd": chosen]) else { return reportConfigWriteFailed() }

        // The button is not set here: `newTab()` below brings its tab to the front and `show`
        // labels it from that tab's own directory. Two sources for one label is how it came to
        // show the same folder for every tab.
        // Replace the active tab so the new directory actually applies — new one first, old one
        // second. The other way round the panel disappeared: with a single tab open, which is the
        // normal case, `closeTab` found no active tab left, took the window with it, and
        // `applicationShouldTerminateAfterLastWindowClosed` ended the app before this line was
        // reached. With two tabs open it worked, which is why it went unnoticed.
        let previous = state.activeIndex
        newTab()
        if let previous { closeTab(at: previous) }
    }


    /// Runs a CLI action off the main thread and reports it. `connect` can take seconds — doing it
    /// inline would freeze the terminal the panel exists to serve.
    ///
    /// One action at a time, like `withBusy` (`app/src/main.ts:539`): each of them restarts the
    /// daemon or Figma underneath, and two at once fight each other.
    ///
    /// Success lands as a toast in the toolbar, failure as a sheet. The menu closes on the click,
    /// so there is nowhere else for either to go — and a dialog for every "Daemon restarted" is
    /// one dismissal too many, while a message that only flashes for a failure is one too few.
    private func runInBackground(title: String, _ work: @escaping () -> CliResult) {
        guard !figmaBusy else { return }
        figmaBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.figmaBusy = false
                self.watcher.refresh()
                guard result.ok else { return self.reportFailure(title: title, result.output) }
                self.toolbar.toast(result.output.isEmpty ? "\(title) — done" : result.output)
            }
        }
    }

    /// Patching Figma needs macOS's "App Management" right, and the CLI can only report that as a
    /// line of text. The sheet turns it into the one thing that helps: the settings pane itself.
    private func reportFailure(title: String, _ output: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = output.isEmpty ? "Failed." : output
        alert.alertStyle = .warning

        let permission = output.range(of: "App Management|permission", options: [.regularExpression,
                                                                                .caseInsensitive])
        if permission != nil {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
        }
        alert.beginSheetModal(for: window) { response in
            guard permission != nil, response == .alertFirstButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security"
                                + "?Privacy_AppBundles") else { return }
            NSWorkspace.shared.open(url)
        }
    }


    /// Kills the active tab's process and starts it again **in the tab's own directory**.
    ///
    /// Port of `respawnActive` in `app/src/main.ts`. Without that cwd the new PTY falls back
    /// elsewhere, which silently changes which session history applies — the whole point of the
    /// three buttons is that they act on *this* conversation.
    ///
    /// The tab keeps its place and its id: the status line is keyed on that id, and a new one
    /// would point the row at a tab that no longer exists.
    private func respawnActive(_ extraArgs: [String]) {
        guard let index = state.activeIndex else { return }
        respawn(at: index, extraArgs: extraArgs)
    }

    /// The same for a named tab rather than the active one. A cancelled session picker can land
    /// on a tab the user has since switched away from; respawning "the active tab" would then
    /// restart the wrong conversation.
    private func respawn(at index: Int, extraArgs: [String]) {
        guard index < state.tabs.count else { return }
        let old = state.tabs[index]

        let config = PanelConfig.load()
        let environment = panelEnvironment(config: config, tabId: old.id)
        let executable = whichOnPath(config.command, path: environment["PATH"] ?? "")

        let snapshot = watcher.snapshot
        let file = snapshot.file.isEmpty ? config.figmaFile : snapshot.file
        // Restart begins a conversation of its own and gets a name and an id; `--resume` and
        // `--continue` adopt one that already has both, and naming it would rename it. That also
        // covers the recovery steps in `resumeRecoveryPlan()`, which come through here.
        let fresh = startsANewSession(extraArgs: extraArgs)
        let sessionId = fresh ? UUID().uuidString.lowercased() : ""
        let sessionName = fresh ? mintSessionName(file: file, page: snapshot.page, cwd: old.cwd) : ""
        var args = panelArguments(config: config, sessionName: sessionName,
                                  sessionId: sessionId,
                                  statusLineCommand: Self.statusLineCommand)
        args.append(contentsOf: extraArgs)

        // The old process's exit arrives later, on the main queue — by then `state` no longer
        // holds its view and `processTerminated` finds no tab for it, so it is not reported.
        old.view.terminate()
        old.view.removeFromSuperview()
        prompts.forget(old.id)
        renamer.forget(old.id)

        let view = makeTerminalView()
        view.onOutput = { [weak self] text in self?.prompts.onData(old.id, text) }
        view.onInput = { [weak self] in self?.prompts.onUserInput(old.id) }

        let replacement = TerminalTab(view: view, name: old.name, cwd: old.cwd, id: old.id,
                                      sessionId: sessionId, sessionName: sessionName)
        state.replace(at: index, with: replacement)
        show(replacement)
        start(view, executable: executable, args: args, environment: environment, cwd: old.cwd,
              command: config.command)
        if fresh { renamer.watch(tabId: old.id, sessionId: sessionId, cwd: old.cwd) }
        refreshTabBar()
    }

    /// The status readout and the actions behind it, as a menu rather than the popover the web
    /// UI builds. The rows are what `bin/fig-status` prints, so the two cannot drift apart; every
    /// section below them comes from `figmaMenuSections`, which is where the rules are checked.
    private func showFigmaMenu(from button: NSButton) {
        let snapshot = watcher.snapshot
        let config = PanelConfig.load()
        let cwd = state.active?.cwd ?? ""
        let menu = NSMenu()
        // AppKit would otherwise ask a validator whether each item is enabled and grey out every
        // one of them — the model has already decided.
        menu.autoenablesItems = false

        // From the poll, not asked again here: the toolbar already draws these three, and two
        // probes at the moment the menu opens are two chances for it to differ from the button.
        let cdpOk = snapshot.cdpOk
        for row in statusRows(figmaRunning: snapshot.figmaRunning, cdpOk: cdpOk,
                              cdpPort: cdpPort, health: snapshot.health) {
            // A view of its own rather than a title: these three report, they do not act, so they
            // must neither grey out nor light up under the pointer. See `MenuStatusRowView`.
            let item = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
            let view = MenuStatusRowView(row)
            view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
            item.view = view
        }

        let input = FigmaMenuInput(
            figma: snapshot.status.figma,
            figmaRunning: snapshot.figmaRunning,
            cdpOk: cdpOk,
            // Over CDP directly, not `figma-cli files`: a menu is built while the user waits for
            // it to open, and a Node start there is a visible pause. Asked only when the port
            // answers — in Safe Mode there is none, and the request would be a dead wait.
            files: cdpOk ? listOpenFiles() : [],
            configuredFile: config.figmaFile,
            snapshotFile: snapshot.file,
            mode: FigmaMode(rawValue: config.figmaMode) ?? .yolo,
            theme: ThemeSetting(rawValue: config.theme) ?? .system,
            undoNodes: parseLastRender(try? String(contentsOfFile: lastRenderFile, encoding: .utf8)),
            cwd: cwd,
            agentsReady: hasAgentRules(cwd: cwd),
            cliFound: cli.isUsable,
            busy: figmaBusy)

        for section in figmaMenuSections(input) {
            menu.addItem(.separator())
            menu.addItem(heading(section.heading))
            for model in section.items { menu.addItem(menuItem(model)) }
        }

        if let note = missingCliNote(cliFound: cli.isUsable) {
            menu.addItem(.separator())
            let item = menu.addItem(withTitle: note, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// A section title: the same small capitals the Electron popover uses.
    private func heading(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: text.uppercased(),
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .kern: 0.6])
        item.isEnabled = false
        return item
    }

    private func menuItem(_ model: MenuItem) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = model.title
        item.isEnabled = model.enabled
        item.toolTip = model.hint
        // The system's own tick, which is what a Mac menu uses for "this setting is on".
        item.state = model.marker == .check ? .on : .off
        if let action = model.action, model.enabled {
            item.action = #selector(menuAction(_:))
            item.target = self
            item.representedObject = action
        }
        return item
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        switch action {
        case .connect: connect()
        case .daemonRestart: restartDaemon()
        case .daemonStop: stopDaemon()
        case .bindFile(let title): bindFile(title)
        case .undo: undoRender()
        case .initAgent: prepareWorkingDirectory()
        case .setMode(let mode): setMode(mode)
        case .setTheme(let setting): setTheme(setting)
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window.title = title.isEmpty ? appDisplayName : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// A process that ended writes its epitaph **into its own tab**, and the tab stays.
    ///
    /// The first version closed the tab here and, when it was the last one, the window with it —
    /// so anything that ended Claude Code took the whole app down. The Electron host never did
    /// that (`app/src/main.ts:738`): it posts the line into the terminal and leaves everything
    /// standing, which is what lets you read why it exited and press Restart.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // A view no longer in `state` was replaced or closed on purpose; its exit is not news.
        guard let index = state.tabs.firstIndex(where: { $0.view === source }) else { return }

        let tab = state.tabs[index]
        // SwiftTerm hands the raw waitpid status through, so an exit of 1 arrives as 256. That is
        // the number the panel used to print, and the reason the code-1 branch below never fired.
        let status = exitStatus(waitStatus: exitCode ?? 0)

        if let step = exitRecovery.next(for: tab.id, exitCode: status.code) {
            tab.view.feed(text: "\r\n" + step.note + "\r\n")
            // Out of the exit callback before spawning the replacement, the way the Electron host
            // defers it — restarting a process from inside its own termination is asking for it.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let now = self.state.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                self.respawn(at: now, extraArgs: step.args)
            }
            return
        }

        tab.view.feed(text: describePtyExit(
            code: status.code,
            msSinceSpawn: Date().timeIntervalSince(tab.spawnedAt) * 1000,
            sawOutput: tab.view.sawOutput))
    }

    /// A window position is only worth remembering if it is written down before the app dies.
    ///
    /// Called from `applicationWillTerminate`, not from `windowWillClose`: ⌘Q goes through
    /// `NSApplication.terminate` and never closes the window, so a save hung on the close
    /// delegate was skipped on the most common way out. Closing the window ends the app too
    /// (`applicationShouldTerminateAfterLastWindowClosed`), so both paths arrive here.
    func saveWindowBounds() {
        // The *content* rect, not the frame: the frame carries the title bar, and handing that
        // back to `NSWindow(contentRect:)` on the next launch made the window 28 points taller
        // every time it was opened. It looked like it settled only because it was hitting the
        // top of the screen.
        let f = window.contentRect(forFrameRect: window.frame)
        saveBounds(Bounds(x: window.frame.origin.x, y: window.frame.origin.y,
                          width: f.width, height: f.height))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var controller: PanelWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let controller = PanelWindowController()
        self.controller = controller
        controller.newTab()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Without a menu every ⌘-chord falls through the responder chain to `noop:`, which SwiftTerm
    /// drops with a line on stdout. The menu is what gives them somewhere to go.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Figma Claude", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let tabItem = NSMenuItem()
        let tabMenu = NSMenu(title: "Tabs")
        tabMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t").target = self
        tabMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w").target = self
        tabMenu.addItem(.separator())
        let next = tabMenu.addItem(withTitle: "Next Tab", action: #selector(nextTab), keyEquivalent: "\u{0009}")
        next.keyEquivalentModifierMask = [.control]
        next.target = self
        let prev = tabMenu.addItem(withTitle: "Previous Tab", action: #selector(previousTab), keyEquivalent: "\u{0009}")
        prev.keyEquivalentModifierMask = [.control, .shift]
        prev.target = self
        tabItem.submenu = tabMenu
        main.addItem(tabItem)

        // The same switch as in the Figma menu, reachable without opening it — and where a Mac
        // user looks for a window setting first.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let appearance = NSMenu(title: "Appearance")
        appearance.delegate = self
        for choice in appearanceChoices {
            let item = appearance.addItem(withTitle: choice.label,
                                          action: #selector(pickAppearance(_:)), keyEquivalent: "")
            item.representedObject = choice.setting
            item.target = self
        }
        let appearanceItem = viewMenu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    /// The tick is read from the config each time the submenu opens: the Figma menu writes the
    /// same key, and a state cached at build time would show the setting from launch.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = ThemeSetting(rawValue: PanelConfig.load().theme) ?? .system
        for item in menu.items {
            item.state = (item.representedObject as? ThemeSetting) == current ? .on : .off
        }
    }

    @objc private func pickAppearance(_ sender: NSMenuItem) {
        guard let setting = sender.representedObject as? ThemeSetting else { return }
        controller?.setTheme(setting)
    }

    @objc private func newTab() { controller?.newTab() }
    @objc private func closeTab() { controller?.closeActiveTab() }
    @objc private func nextTab() { controller?.cycleTab(by: 1) }
    @objc private func previousTab() { controller?.cycleTab(by: -1) }

    /// Apple's own About panel rather than an `NSAlert`: it draws the app icon, the name and
    /// "Version <short> (<build>)" from the bundle itself, so the numbers cannot drift from what
    /// LaunchServices thinks is installed. Only the credits below them are ours.
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: aboutPanelOptions(cliVersion: figmaCliVersion()))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.saveWindowBounds()
    }
}

// Claude Code invokes this same binary as its `statusLine` command and pushes the session data
// in on stdin. No window, no AppKit — read, write the snapshot, leave. Printing nothing is part
// of the contract: the window draws the row, so any output here would show up twice.
if CommandLine.arguments.contains("--statusline") {
    runStatusLineProducer()
    exit(0)
}

/// The CLI's own version, for the About panel — the last line that looks like a version, so a
/// shell error never appears as a number.
///
/// Through `runCli`, not a `Process` of its own. The hand-rolled spawn this replaces found
/// `figma-cli` on the login PATH but started it with the app's own environment, and the installed
/// `figma-cli` is a shim that runs `exec node …`: launched from the Dock, where PATH is
/// `/usr/bin:/bin:/usr/sbin:/sbin`, the child died with "exec: node: not found" and the dialog
/// said "figma-cli —". `runCli` hands the resolved PATH to the child, and `resolveCli` also finds
/// a checkout when nothing is installed globally.
///
/// Free function rather than a method on the delegate so `--print-about` exercises this exact
/// path. While it was private the probe passed a fixed version instead — and the dialog shipped
/// broken with every check green.
func figmaCliVersion() -> String? {
    let cli = resolveCli(appRoot: Bundle.main.bundlePath, configured: PanelConfig.load().figmaCli)
    let result = runCli(cli, ["--version"], timeout: 10)
    guard result.ok else { return nil }
    return parseCliVersion(result.output)
}

/// What the About panel is opened with — one place, so `--render-about` shows the real dialog
/// rather than a rebuilt lookalike.
///
/// The version and the build come from the bundle, not from a constant compiled in: they are what
/// LaunchServices reads, so the panel cannot claim a version the installed bundle does not have.
/// Outside a bundle (`swift run`) there is no plist and the panel says "—".
func aboutPanelOptions(cliVersion: String?) -> [NSApplication.AboutPanelOptionKey: Any] {
    let info = Bundle.main.infoDictionary
    let credits = aboutCredits(cliVersion: cliVersion, buildDate: info?["FCBuildDate"] as? String)
    var options: [NSApplication.AboutPanelOptionKey: Any] = [
        .applicationName: "Figma Claude",
        .applicationVersion: info?["CFBundleShortVersionString"] as? String ?? "—",
        .credits: NSAttributedString(
            string: credits,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
    ]
    // `.version` is what lands in the parentheses. Left out entirely when there is no commit, so
    // the panel shows "Version 0.9.0" rather than empty brackets.
    let build = aboutBuild(commit: info?["CFBundleVersion"] as? String)
    if !build.isEmpty { options[.version] = build }
    return options
}

/// `--appearance light|dark` forces the palette the probes draw in.
///
/// A shell run inherits whatever the system is set to, so "it looks right in dark mode" could
/// only ever be checked by switching System Settings by hand. With this both PNGs come out of
/// one command and the two can be compared.
func applyProbeAppearance() {
    guard let index = CommandLine.arguments.firstIndex(of: "--appearance"),
          CommandLine.arguments.count > index + 1 else { return }
    switch CommandLine.arguments[index + 1] {
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    default: break
    }
}

// What the status row would draw for a tab, and what it was built from — the raw snapshot, the
// remembered pieces, and the two lines as text. `--print-statusline [tabId]`, newest tab if none.
if let index = CommandLine.arguments.firstIndex(of: "--print-statusline") {
    let dir = statusLineDir()
    let named = CommandLine.arguments.count > index + 1
        && !CommandLine.arguments[index + 1].hasPrefix("--")
        ? CommandLine.arguments[index + 1] : nil
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
        .filter { $0.hasSuffix(".json") } ?? []
    let newest = files.max { left, right in
        let date: (String) -> Date = { name in
            ((try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(name)"))?[.modificationDate]
                as? Date) ?? .distantPast
        }
        return date(left) < date(right)
    }
    guard let tabId = named ?? newest.map({ String($0.dropLast(5)) }),
          let written = readSnapshot(dir: dir, tabId: tabId) else {
        print("no snapshot in \(dir)")
        exit(1)
    }

    let merged = resolvedSnapshot(written, dir: dir)
    print("tab \(tabId)")
    print("written  session=\(written.sessionPercent.map { "\($0)" } ?? "—") "
          + "resetsAt=\(written.sessionResetsAt.map { "\($0)" } ?? "—") "
          + "week=\(written.weekPercent.map { "\($0)" } ?? "—") total=\(written.totalTokens)")
    if let limits = readRememberedLimits(dir: dir) {
        print("remembered session=\(limits.sessionPercent.map { "\($0)" } ?? "—") "
              + "resetsAt=\(limits.sessionResetsAt.map { "\($0)" } ?? "—") "
              + "week=\(limits.weekPercent.map { "\($0)" } ?? "—")")
    } else {
        print("remembered —")
    }
    print("merged   session=\(merged.sessionPercent.map { "\($0)" } ?? "—") "
          + "inMin=\(merged.sessionResetsInMin.map { "\($0)" } ?? "—") "
          + "resetsAt=\(merged.sessionResetsAt.map { "\($0)" } ?? "—")")
    if let rows = secondaryRowText(merged) {
        print("row      \"\(rows.left)\"  \"\(rows.compacted)\"  \"\(rows.week)\"")
    } else {
        print("row      —")
    }
    exit(0)
}

// Does the status band make room for a Figma selection? Needs a real window, so it cannot live
// with the offscreen probes.
if CommandLine.arguments.contains("--probe-selection") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    RenderProbe.selectionGrowth()
    exit(0)
}

// The menu as text, for a shell that cannot open one. It asks the same sources the window does —
// the debug port, the daemon, panel.json — so a wrong row here is a wrong row there.
if CommandLine.arguments.contains("--print-menu") {
    _ = NSApplication.shared
    let config = PanelConfig.load()
    let cli = resolveCli(appRoot: Bundle.main.bundlePath, configured: config.figmaCli)
    let snapshot = pollFigma()
    let cdpOk = snapshot.cdpOk
    for row in statusRows(figmaRunning: snapshot.figmaRunning, cdpOk: cdpOk, cdpPort: cdpPort,
                          health: snapshot.health) {
        print("\(row.state.rawValue.uppercased())  \(row.label): \(row.value)")
    }
    let cwd = config.resolvedCwd() ?? ""
    let sections = figmaMenuSections(FigmaMenuInput(
        figma: snapshot.status.figma,
        figmaRunning: snapshot.figmaRunning,
        cdpOk: cdpOk,
        files: cdpOk ? listOpenFiles() : [],
        configuredFile: config.figmaFile,
        snapshotFile: snapshot.file,
        mode: FigmaMode(rawValue: config.figmaMode) ?? .yolo,
        theme: ThemeSetting(rawValue: config.theme) ?? .system,
        undoNodes: parseLastRender(try? String(contentsOfFile: lastRenderFile, encoding: .utf8)),
        cwd: cwd,
        agentsReady: hasAgentRules(cwd: cwd),
        cliFound: cli.isUsable))
    for section in sections {
        print("\n\(section.heading.uppercased())")
        for item in section.items {
            let mark = item.marker == .check ? "✓" : " "
            print("  \(mark) \(item.enabled ? " " : "·")\(item.title)")
        }
    }
    if let note = missingCliNote(cliFound: cli.isUsable) { print("\n\(note)") }
    exit(0)
}

// Draw the status line into a PNG and exit — the only way to look at the layout from a shell
// that has no Screen Recording permission.
if let index = CommandLine.arguments.firstIndex(of: "--render-chrome") {
    _ = NSApplication.shared
    applyProbeAppearance()
    let tabs = CommandLine.arguments.count > index + 1
        ? Int(CommandLine.arguments[index + 1]) ?? 4 : 4
    // `--width` so the row can be measured across the range the window actually has, instead of
    // dragging the real one and guessing at what happened.
    let width = CommandLine.arguments.firstIndex(of: "--width")
        .flatMap { CommandLine.arguments.count > $0 + 1 ? Double(CommandLine.arguments[$0 + 1]) : nil }
        ?? 546
    RenderProbe.chrome(width: width, tabs: tabs, to: "/tmp/chrome.png")
    exit(0)
}

// What the About panel would say, as text, with the real CLI lookup — the one thing the PNG
// probe cannot show, because it passes a fixed version so the render stays reproducible.
if CommandLine.arguments.contains("--print-about") {
    _ = NSApplication.shared
    let path = LoginShellPath.resolve() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
    let cli = resolveCli(appRoot: Bundle.main.bundlePath, configured: PanelConfig.load().figmaCli)
    let version = figmaCliVersion()
    print("PATH      \(path)")
    print("figma-cli \(cli.isUsable ? ([cli.file] + cli.args).joined(separator: " ") : "not found")")
    print("version   \(version ?? "nil")")
    let info = Bundle.main.infoDictionary
    print("bundle    \(info?["CFBundleShortVersionString"] as? String ?? "—") " +
          "(\(aboutBuild(commit: info?["CFBundleVersion"] as? String))) " +
          "\(info?["FCBuildDate"] as? String ?? "—")")
    print("---")
    print(aboutCredits(cliVersion: version, buildDate: info?["FCBuildDate"] as? String))
    exit(0)
}

// The About panel, drawn to a PNG. It is an AppKit window like any other, so `cacheDisplay`
// reaches it without Screen Recording permission — but only when this binary runs from inside the
// bundle, since everything in the panel except the credits comes from Info.plist:
//   "build/Figma Claude.app/Contents/MacOS/FigmaClaude" --render-about /tmp/about.png
if let index = CommandLine.arguments.firstIndex(of: "--render-about") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    applyProbeAppearance()
    let path = CommandLine.arguments.count > index + 1
        && !CommandLine.arguments[index + 1].hasPrefix("--")
        ? CommandLine.arguments[index + 1] : NSTemporaryDirectory() + "figmaclaude-about.png"
    RenderProbe.about(to: path)
    exit(0)
}

if CommandLine.arguments.contains("--render-menurows") {
    _ = NSApplication.shared
    applyProbeAppearance()
    RenderProbe.menuRows(to: "/tmp/menurows.png")
    exit(0)
}

if CommandLine.arguments.contains("--probe-late-label") {
    _ = NSApplication.shared
    applyProbeAppearance()
    let width = CommandLine.arguments.count > 1
        ? Double(CommandLine.arguments.last!) ?? 546 : 546
    RenderProbe.lateLabelBudget(width: width)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-rings") {
    _ = NSApplication.shared
    applyProbeAppearance()
    let path = CommandLine.arguments.count > index + 1 && !CommandLine.arguments[index + 1].hasPrefix("--")
        ? CommandLine.arguments[index + 1] : NSTemporaryDirectory() + "figmaclaude-rings.png"
    if CommandLine.arguments.contains("--bar") {
        RingProbe.bar(to: path)
    } else {
        RingProbe.run(to: path)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

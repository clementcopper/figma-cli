import Foundation
import FigmaClaudeCore

/// Renames a fresh session after its task once the first prompt is known.
///
/// A tab starts as `fc-<file>-<page>`. When the user's first prompt lands in the transcript, a
/// Haiku call names it in two words (`TaskWords.swift`), the name is taken in the ledger, and
/// `/rename fc-<w1>-<w2>` is typed into the tab — only while Claude is idle, shows no question of
/// its own, and the keyboard has been quiet (`shouldInject`). The registry confirms the rename;
/// one retry, then the start name stays (it is unique too, nothing is lost).
final class SessionRenamer {
    private enum Phase { case waitingForPrompt, naming, readyToRename, confirming(since: Date), done }

    private final class Job {
        let tabId: String
        let sessionId: String
        let cwd: String
        let startedAt = Date()
        var phase: Phase = .waitingForPrompt
        var target = ""
        var attempts = 0
        init(tabId: String, sessionId: String, cwd: String) {
            self.tabId = tabId; self.sessionId = sessionId; self.cwd = cwd
        }
    }

    /// The tab to type into, or nil once it is gone or respawned under another session.
    typealias TabLookup = (_ tabId: String, _ sessionId: String) -> PanelTerminalView?
    typealias Renamed = (_ tabId: String, _ name: String) -> Void

    private var jobs: [String: Job] = [:]
    private var timer: DispatchSourceTimer?
    private let prompts: PromptDetector
    private let tabFor: TabLookup
    private let onRenamed: Renamed
    private let claude: String?
    private let path: String
    private let environment: [String: String]
    private let interval: TimeInterval = 2
    private let giveUpAfter: TimeInterval = 30 * 60
    private let confirmWithin: TimeInterval = 10
    private let work = DispatchQueue(label: "fc.renamer", qos: .utility)

    init(prompts: PromptDetector, claude: String?, path: String, environment: [String: String],
         tabFor: @escaping TabLookup, onRenamed: @escaping Renamed) {
        self.prompts = prompts
        self.claude = claude
        self.path = path
        self.environment = environment
        self.tabFor = tabFor
        self.onRenamed = onRenamed
    }

    func watch(tabId: String, sessionId: String, cwd: String) {
        jobs[tabId] = Job(tabId: tabId, sessionId: sessionId, cwd: cwd)
        startTimer()
    }

    func forget(_ tabId: String) {
        jobs.removeValue(forKey: tabId)
        if jobs.isEmpty { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        for job in Array(jobs.values) { step(job) }
        if jobs.isEmpty { stopTimer() }
    }

    private func step(_ job: Job) {
        guard tabFor(job.tabId, job.sessionId) != nil else { forget(job.tabId); return }
        if Date().timeIntervalSince(job.startedAt) > giveUpAfter { forget(job.tabId); return }

        switch job.phase {
        case .waitingForPrompt:
            let transcript = transcriptPath(cwd: job.cwd, sessionId: job.sessionId)
            guard let data = FileManager.default.contents(atPath: transcript),
                  let text = String(data: data, encoding: .utf8),
                  let prompt = firstUserPrompt(transcript: text) else { return }
            job.phase = .naming
            name(job, prompt: prompt)

        case .naming:
            return

        case .readyToRename:
            let entry = registryEntry(sessionId: job.sessionId)
            guard shouldInject(status: entry?.status, waiting: prompts.isWaiting(job.tabId),
                               secondsSinceInput: prompts.secondsSinceInput(job.tabId)),
                  let view = tabFor(job.tabId, job.sessionId) else { return }
            job.attempts += 1
            view.send(txt: renameCommand(job.target))
            job.phase = .confirming(since: Date())

        case .confirming(let since):
            if registryEntry(sessionId: job.sessionId)?.name == job.target {
                onRenamed(job.tabId, job.target)
                forget(job.tabId)
            } else if Date().timeIntervalSince(since) > confirmWithin {
                job.phase = job.attempts < 2 ? .readyToRename : .done
                if case .done = job.phase { forget(job.tabId) }
            }

        case .done:
            forget(job.tabId)
        }
    }

    /// Haiku on the utility queue; the ledger and the phase change back on main.
    private func name(_ job: Job, prompt: String) {
        let claude = self.claude, path = self.path, env = self.environment, cwd = job.cwd
        work.async { [weak self] in
            var words: String?
            if let claude {
                words = askTaskWords(prompt: prompt, claude: claude, path: path, cwd: cwd,
                                     environment: env).flatMap(parseTaskWords)
            }
            if words == nil { words = fallbackTaskWords(prompt) }
            DispatchQueue.main.async {
                guard let self, self.jobs[job.tabId] === job else { return }
                guard let words else { self.forget(job.tabId); return }
                let taken = liveSessionNames().union(ledgerNames())
                job.target = uniqueName(taskSessionName(words: words), taken: taken)
                recordName(job.target)
                job.phase = .readyToRename
            }
        }
    }
}

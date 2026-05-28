import Foundation
import BrainProcess  // BackoffPolicy module from Task 5

/// Owns the brain child process: spawn, async readiness via `READY\n` stdout
/// signal, and respawn-with-backoff on unexpected exit.
///
/// Threading: callbacks fire on the main queue so AppDelegate handlers can
/// update UI without further dispatching.
final class BrainProcessManager {
    enum State: Equatable {
        case notStarted
        case starting
        case ready
        case reconnecting   // after exit, before next start
        case exhausted      // backoff attempts exhausted
    }

    let binPath: String
    let configPath: String
    let socketPath: String
    let repoRoot: String

    private(set) var state: State = .notStarted
    private var process: Process?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private let bufferLock = NSLock()
    private let readyMarker = "READY\n"

    private var backoff: BackoffState
    private var startedAt: Date?

    /// Fires (on main queue) when the brain transitions to `.ready`.
    var onReady: (() -> Void)?
    /// Fires (on main queue) when the brain exits unexpectedly. The Bool is
    /// true if a respawn is queued; false if backoff is exhausted.
    var onExit: ((_ willRespawn: Bool) -> Void)?
    /// Fires (on main queue) after backoff exhaustion — terminal state.
    var onExhausted: (() -> Void)?

    init(
        binPath: String,
        configPath: String,
        socketPath: String,
        repoRoot: String,
        policy: BackoffPolicy = .default
    ) {
        self.binPath = binPath
        self.configPath = configPath
        self.socketPath = socketPath
        self.repoRoot = repoRoot
        self.backoff = BackoffState(policy: policy)
    }

    func start() {
        guard state == .notStarted || state == .reconnecting else { return }
        state = .starting
        spawn()
    }

    func terminate() {
        process?.terminationHandler = nil  // suppress respawn on intentional shutdown
        process?.terminate()
        process = nil
        state = .notStarted
    }

    // MARK: - Internals

    private func spawn() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binPath)
        p.arguments = ["--config", configPath, "--socket", socketPath]

        var env = ProcessInfo.processInfo.environment
        env["REPO_ROOT"] = repoRoot
        p.environment = env
        let apiKeyLen = (env["ANTHROPIC_API_KEY"] ?? "").count
        NSLog("[screen-grab][brain] spawn env: ANTHROPIC_API_KEY len=\(apiKeyLen) PATH=\(env["PATH"] != nil ? "set" : "UNSET") bin=\(binPath)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        p.terminationHandler = { [weak self] proc in
            self?.handleExit(proc)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self = self else { return }
            let data = h.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                self.appendStdout(s)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self = self else { return }
            let data = h.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                self.bufferLock.lock()
                self.stderrBuffer.append(s)
                self.bufferLock.unlock()
                NSLog("[brain stderr] %@", s.trimmingCharacters(in: .newlines))
            }
        }

        do {
            try p.run()
            self.process = p
            self.startedAt = Date()
            self.backoff.recordStart(at: Date())
        } catch {
            NSLog("[brain] failed to spawn: %@", String(describing: error))
            // We're already on main here (start() runs on main, so spawn-from-start
            // is on main; respawn-from-exit hops to main via handleExit). Funnel
            // anyway for safety.
            DispatchQueue.main.async { [weak self] in
                self?.scheduleNextOrExhaust()
            }
        }
    }

    private func appendStdout(_ s: String) {
        bufferLock.lock()
        stdoutBuffer.append(s)
        let hit = stdoutBuffer.contains(readyMarker)
        bufferLock.unlock()
        guard hit else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.state == .starting else { return }
            self.state = .ready
            self.onReady?()
        }
    }

    private func handleExit(_ proc: Process) {
        // Ignore stale terminations (after we've moved on).
        guard self.process === proc else { return }
        self.process = nil
        DispatchQueue.main.async { [weak self] in
            self?.scheduleNextOrExhaust()
        }
    }

    /// Decides whether to schedule a respawn or transition to `.exhausted`.
    /// Must be called on the main queue — it mutates `state` and fires
    /// callbacks synchronously, so all reads in `start()`/`terminate()`
    /// (also main-queue) see a consistent view.
    private func scheduleNextOrExhaust() {
        // BackoffState.recordExit folds in the most recent startedAt to
        // decide whether the prior run counted as healthy; no separate
        // recordHealthy call is needed here.
        let next = backoff.recordExit(at: Date())
        if let delay = next {
            state = .reconnecting
            onExit?(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                // If terminate() was called while we were waiting, don't respawn.
                guard self.state == .reconnecting else { return }
                self.state = .starting
                self.spawn()
            }
        } else {
            state = .exhausted
            onExit?(false)
            onExhausted?()
        }
    }
}

import AppKit
import NoBeachballsCore
import Combine
import Darwin

struct ThrottleEvent: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
    let isAuto: Bool
}

/// Owns sampling, health evaluation and auto-throttle. Sampling runs on a background queue;
/// results are published on the main thread.
@MainActor
final class Monitor: ObservableObject {
    struct Snapshot {
        var system: SystemSample?
        var report: HealthReport = .ok
        var groups: [ProcessGroup] = []
        var unattributedCPU = 0.0
        var cpuHistory: [Double] = []
        var memHistory: [Double] = []
        var swapHistory: [Double] = []
        var latencyMs = 0.0
        var autoPaused: [ThrottledJob] = []
        var deprioritized = Set<ProcessKey>()
    }

    /// Publish a complete tick once, so views never render partially updated samples.
    @Published private(set) var snapshot = Snapshot()
    var system: SystemSample? { snapshot.system }
    var report: HealthReport { snapshot.report }
    var groups: [ProcessGroup] { snapshot.groups }
    var unattributedCPU: Double { snapshot.unattributedCPU }
    var cpuHistory: [Double] { snapshot.cpuHistory }
    var memHistory: [Double] { snapshot.memHistory }
    var swapHistory: [Double] { snapshot.swapHistory }
    var latencyMs: Double { snapshot.latencyMs }
    var autoPaused: [ThrottledJob] { snapshot.autoPaused }
    var deprioritized: Set<ProcessKey> { snapshot.deprioritized }

    @Published private(set) var events: [ThrottleEvent] = []

    @Published var mode: ThrottleMode {
        didSet {
            guard controlsProcesses else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "throttleMode")
            let mode = mode
            queue.async { self.engine.config.mode = mode }
        }
    }

    @Published var protectedNames: [String] {
        didSet {
            UserDefaults.standard.set(protectedNames, forKey: "protectedNames")
            refreshRules()
        }
    }

    /// Faster sampling and full process publishing while the window is open.
    var isVisible = false {
        didSet { if isVisible != oldValue { reschedule() } }
    }

    private let queue = DispatchQueue(label: "nobeachballs.sampler", qos: .userInitiated)
    // Sampler, evaluator and engine are touched only on `queue`.
    private nonisolated(unsafe) let processSampler = ProcessSampler()
    private nonisolated(unsafe) let systemSampler = SystemSampler()
    private nonisolated(unsafe) let evaluator = HealthEvaluator()
    private let probe = ResponsivenessProbe()
    private nonisolated(unsafe) let engine: ThrottleEngine
    private var timer: DispatchSourceTimer?
    private let historyLength = 90

    /// Accessed only on `queue`.
    private nonisolated(unsafe) var rules = ProtectionRules()
    /// Processes the user paused by hand (tracked so quitting never leaves them frozen).
    private nonisolated(unsafe) var manualPauses = Set<ProcessKey>()
    private nonisolated(unsafe) var savedLedger = ThrottleLedger()

    /// When false (snapshot and test modes) the monitor only observes: it never signals,
    /// reprioritizes or touches the ledger, so it can't interfere with the running app.
    private let controlsProcesses: Bool

    init(controlsProcesses: Bool = true) {
        self.controlsProcesses = controlsProcesses
        let mode = ThrottleMode(rawValue: UserDefaults.standard.string(forKey: "throttleMode") ?? "") ?? .full
        self.mode = mode
        protectedNames = UserDefaults.standard.stringArray(forKey: "protectedNames") ?? []
        engine = ThrottleEngine(config: ThrottleConfig(mode: controlsProcesses ? mode : .off))

        // Undo anything a previous run left paused (crash, force quit).
        if controlsProcesses {
            let recovered = ThrottleLedger.releaseAll()
            if recovered > 0 { log("Resumed \(recovered) process(es) left paused by a previous run", auto: true) }
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRules() }
            }
        }
        refreshRules()
        // Launch/quit notifications can be missed (or arrive before NSWorkspace updates); re-sync now and then.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRules() }
        }
        probe.start()
        reschedule()
    }

    // MARK: - Sampling

    private func reschedule() {
        timer?.cancel()
        let interval = isVisible ? 1.0 : 2.0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        let publishProcesses = isVisible
        t.setEventHandler { [weak self] in self?.tick(publishProcesses: publishProcesses) }
        t.resume()
        timer = t
    }

    private nonisolated func tick(publishProcesses: Bool) {
        let system = systemSampler.sample()
        let processes = processSampler.sample()
        let latency = probe.latencyMs
        let report = evaluator.evaluate(HealthInputs(system: system, latencyMs: latency))
        let tree = ProcessTree(processes)
        let groups = Grouping.groups(processes, tree: tree, rules: rules)

        var messages: [String] = []
        if controlsProcesses {
            messages = engine.step(report: report, groups: groups, rules: rules).map(perform)
            var ledger = engine.ledger
            ledger.paused += manualPauses.filter(ProcessControl.isAlive)
            if ledger != savedLedger {
                ledger.save()
                savedLedger = ledger
            }
        }

        let readableCPU = processes.reduce(0) { $0 + ($1.isAccessible ? $1.cpu : 0) }
        let unattributed = max(0, system.cpuTotal * Double(system.coreCount) * 100 - readableCPU)
        let paused = engine.paused
        let deprioritized = Set(engine.deprioritized.keys)
        let visibleGroups = publishProcesses ? groups : []

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var next = self.snapshot
                next.system = system
                next.report = report
                next.latencyMs = latency
                next.autoPaused = paused
                next.deprioritized = deprioritized
                next.unattributedCPU = unattributed
                if publishProcesses { next.groups = visibleGroups }
                self.push(&next.cpuHistory, system.cpuTotal)
                self.push(&next.memHistory, 1 - Double(system.memAvailablePercent) / 100)
                self.push(&next.swapHistory, system.swapInRate + system.swapOutRate)
                self.snapshot = next
                for message in messages { self.log(message, auto: true) }
            }
        }
    }

    private nonisolated func perform(_ action: ThrottleAction) -> String {
        switch action {
        case .deprioritize(let key, let name):
            ProcessControl.setBackground(key, true)
            return "Deprioritized \(name) (\(key.pid))"
        case .restorePriority(let key, let name):
            ProcessControl.setBackground(key, false)
            return "Restored priority of \(name) (\(key.pid))"
        case .pause(let job):
            let n = ProcessControl.send(SIGSTOP, to: job.members)
            return "Paused \(job.name) — \(n) process(es); \(job.reason)"
        case .resume(let job):
            let n = ProcessControl.send(SIGCONT, to: job.members)
            return "Resumed \(job.name) — \(n) process(es)"
        }
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }

    private func refreshRules() {
        var appNames: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            guard let path = app.bundleURL?.path, path.hasSuffix(".app") else { continue }
            // Finder's name ("Visual Studio Code"), not the short process name ("Code").
            var name = FileManager.default.displayName(atPath: path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            appNames[path + "/"] = name
        }
        let bundles = Array(appNames.keys)
        let names = Set(protectedNames.map { $0.lowercased() })
        queue.async {
            self.rules.appBundlePaths = bundles
            self.rules.appNames = appNames
            self.rules.protectedNames = names
        }
    }

    // MARK: - User actions

    func pause(_ group: ProcessGroup) {
        let keys = group.members.map(\.key)
        queue.async {
            let n = ProcessControl.send(SIGSTOP, to: keys)
            self.manualPauses.formUnion(keys)
            self.logAsync("Paused \(group.name) — \(n) process(es)")
        }
    }

    func resume(_ group: ProcessGroup) {
        let keys = group.members.map(\.key)
        queue.async {
            self.engine.userResumed(groupID: group.id)
            let n = ProcessControl.send(SIGCONT, to: keys)
            self.manualPauses.subtract(keys)
            self.logAsync("Resumed \(group.name) — \(n) process(es)")
        }
    }

    func resume(_ job: ThrottledJob) {
        queue.async {
            self.engine.userResumed(groupID: job.id)
            let n = ProcessControl.send(SIGCONT, to: job.members)
            self.logAsync("Resumed \(job.name) — \(n) process(es)")
        }
    }

    func kill(_ group: ProcessGroup, force: Bool) {
        if case .app = group.kind, let app = NSRunningApplication(processIdentifier: group.root.pid) {
            _ = force ? app.forceTerminate() : app.terminate()
            log("\(force ? "Force quit" : "Quit") \(group.name)", auto: false)
            return
        }
        let keys = group.members.map(\.key)
        queue.async {
            // Stopped processes can't act on SIGTERM until continued.
            let n = ProcessControl.send(force ? SIGKILL : SIGTERM, to: keys)
            ProcessControl.send(SIGCONT, to: keys)
            self.manualPauses.subtract(keys)
            self.logAsync("\(force ? "Force killed" : "Terminated") \(group.name) — \(n) process(es)")
        }
    }

    func protect(_ group: ProcessGroup) {
        let name = group.name
        if !protectedNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            protectedNames.append(name)
        }
        resume(group)
    }

    func resumeEverything() {
        queue.async {
            let actions = self.engine.releaseAll()
            let messages = actions.map(self.perform)
            let manual = ProcessControl.send(SIGCONT, to: Array(self.manualPauses))
            self.manualPauses.removeAll()
            ThrottleLedger().save()
            self.savedLedger = ThrottleLedger()
            for m in messages { self.logAsync(m) }
            if manual > 0 { self.logAsync("Resumed \(manual) manually paused process(es)") }
        }
    }

    /// Called on quit: never leave anything frozen behind.
    nonisolated func releaseAllSync() {
        guard controlsProcesses else { return }
        queue.sync {
            for action in engine.releaseAll() { _ = perform(action) }
            ProcessControl.send(SIGCONT, to: Array(manualPauses))
            manualPauses.removeAll()
            ThrottleLedger().save()
            savedLedger = ThrottleLedger()
        }
    }

    private nonisolated func logAsync(_ text: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.log(text, auto: false) } }
    }

    private func log(_ text: String, auto: Bool) {
        events.insert(ThrottleEvent(date: Date(), text: text, isAuto: auto), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
    }
}

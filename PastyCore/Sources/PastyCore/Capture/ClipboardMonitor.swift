import AppKit

/// Watches a pasteboard for changes and turns them into `ClipDraft`s.
///
/// macOS has no clipboard-change notification, so this polls `changeCount` — a cheap integer
/// read — on a private utility queue. The interval adapts: brisk right after activity, relaxed
/// when idle. Data is only read once a change passes the privacy rules, and all reading,
/// hashing and thumbnailing happens off the main thread.
///
/// All mutable state is confined to `queue`, which is what makes the `@unchecked Sendable` sound.
public final class ClipboardMonitor: @unchecked Sendable {
    public enum PollResult: Sendable {
        case unchanged
        case skipped(SkipReason)
        case captured(ClipDraft)
    }

    public typealias SourceProvider = @Sendable (_ declaredBundleID: String?) -> SourceApp?
    public typealias Handler = @Sendable (ClipDraft) -> Void

    /// Polling intervals: (seconds since last activity, interval).
    static let intervals: [(idle: TimeInterval, interval: TimeInterval)] = [
        (0, 0.25), (20, 0.5), (120, 1.0),
    ]

    private let queue = DispatchQueue(label: "app.pasty.clipboard-monitor", qos: .utility)
    private let pasteboard: NSPasteboard
    private let ownBundleID: String?
    private let sourceProvider: SourceProvider
    private let handler: Handler

    private var timer: DispatchSourceTimer?
    private var currentInterval: TimeInterval = 0
    private var lastChangeCount: Int
    private var lastActivity = Date()
    private var rules: CaptureRules

    public init(
        pasteboard: NSPasteboard,
        rules: CaptureRules,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        sourceProvider: @escaping SourceProvider,
        handler: @escaping Handler
    ) {
        self.pasteboard = pasteboard
        self.rules = rules
        self.ownBundleID = ownBundleID
        self.sourceProvider = sourceProvider
        self.handler = handler
        // Whatever is on the pasteboard at launch was already there; don't re-record it.
        lastChangeCount = pasteboard.changeCount
    }

    deinit {
        timer?.cancel()
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            reschedule(interval: Self.intervals[0].interval)
            timer.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            currentInterval = 0
        }
    }

    public func updateRules(_ rules: CaptureRules) {
        queue.async { [self] in
            let wasPaused = self.rules.isPaused
            self.rules = rules
            // Changes made while paused are deliberately forgotten when resuming.
            if wasPaused, !rules.isPaused { lastChangeCount = pasteboard.changeCount }
        }
    }

    /// Checks immediately, e.g. right before the history panel appears.
    public func checkNow() {
        queue.async { [self] in
            lastActivity = Date()
            tick()
        }
    }

    /// Runs one poll synchronously and reports what happened, without invoking the handler.
    @discardableResult
    public func pollSynchronously() -> PollResult {
        queue.sync { poll() }
    }

    /// Writes to the pasteboard on the monitor's queue and adopts the resulting change count, so
    /// Pasty never records its own writes — with no window for a race.
    @discardableResult
    public func write(_ snapshot: PasteboardSnapshot) -> Int {
        queue.sync {
            let changeCount = PasteboardIO.write(snapshot, to: pasteboard, sourceBundleID: ownBundleID)
            lastChangeCount = changeCount
            return changeCount
        }
    }

    // MARK: Polling

    private func tick() {
        if case let .captured(draft) = poll() {
            handler(draft)
        }
        adaptInterval()
    }

    private func poll() -> PollResult {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return .unchanged }
        lastChangeCount = changeCount
        lastActivity = Date()

        let types = PasteboardIO.types(of: pasteboard)
        let declared = types.contains(PasteboardType.source) ? PasteboardIO.declaredSource(of: pasteboard) : nil
        if let declared, declared == ownBundleID {
            return .skipped(.empty)
        }
        let source = sourceProvider(declared)
        if let reason = PrivacyPolicy.evaluate(types: types, source: source, rules: rules) {
            return .skipped(reason)
        }
        guard let snapshot = PasteboardIO.read(pasteboard, maxBytes: rules.maxEntryBytes, includeImages: rules.captureImages) else {
            return .skipped(.tooLarge)
        }
        // The pasteboard may have changed again while we were reading; the next tick catches it.
        guard var draft = ContentAnalyzer.analyze(snapshot) else { return .skipped(.empty) }
        if rules.skipLikelySecrets, draft.kind == .text || draft.kind == .richText,
           SecretDetector.looksLikeSecret(draft.preview) {
            return .skipped(.likelySecret)
        }
        draft.source = source
        draft.date = Date()
        return .captured(draft)
    }

    private func adaptInterval() {
        let idle = Date().timeIntervalSince(lastActivity)
        let target = Self.intervals.last { idle >= $0.idle }?.interval ?? Self.intervals[0].interval
        if target != currentInterval { reschedule(interval: target) }
    }

    private func reschedule(interval: TimeInterval) {
        currentInterval = interval
        // Generous leeway lets the system coalesce wakeups, which matters more for battery than
        // the exact moment we notice a copy.
        timer?.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(Int(interval * 1_000 * 0.25))
        )
    }
}

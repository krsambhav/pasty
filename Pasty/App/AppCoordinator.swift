import AppKit
import PastyCore

/// Owns every long-lived service and wires them together.
@MainActor
final class AppCoordinator {
    let preferences: Preferences
    let store: ClipboardStore
    let monitor: ClipboardMonitor
    let model: PanelModel
    let launchOptions: LaunchOptions

    private(set) var panelController: PanelController!
    private(set) var pasteCoordinator: PasteCoordinator!
    private var statusItemController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private let hotKeys = HotKeyManager.shared
    private let hud = HUDController()

    private let captures: AsyncStream<ClipDraft>
    private let captureContinuation: AsyncStream<ClipDraft>.Continuation
    private var ingestTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastAppliedHotKey: KeyCombo?
    private(set) var storeOpenError: Error?

    static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PASTY_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pasty", isDirectory: true)
    }

    init(launchOptions: LaunchOptions) {
        self.launchOptions = launchOptions
        preferences = Preferences()

        let databaseURL = Self.dataDirectory.appendingPathComponent("History.sqlite")
        var openError: Error?
        do {
            store = try ClipboardStore.openRecovering(at: databaseURL)
        } catch {
            // Never lose the ability to run: fall back to a session-only history and say so.
            openError = error
            store = try! ClipboardStore(url: nil)
        }
        storeOpenError = openError

        let stream = AsyncStream.makeStream(of: ClipDraft.self, bufferingPolicy: .bufferingNewest(64))
        captures = stream.stream
        captureContinuation = stream.continuation
        let continuation = stream.continuation
        monitor = ClipboardMonitor(
            pasteboard: .general,
            rules: preferences.captureRules,
            sourceProvider: SourceAppResolver.resolve,
            handler: { draft in continuation.yield(draft) }
        )
        model = PanelModel(store: store, preferences: preferences)
    }

    func start() {
        applyAppearance()
        pasteCoordinator = PasteCoordinator(store: store, monitor: monitor, model: model, hud: hud)
        panelController = PanelController(model: model, preferences: preferences)
        panelController.onWillShow = { [weak self] in self?.monitor.checkNow() }
        panelController.onCommand = { [weak self] command in self?.handle(command) }
        pasteCoordinator.panel = panelController

        statusItemController = StatusItemController(coordinator: self)
        statusItemController?.isVisible = preferences.showMenuBarIcon

        preferences.onChange = { [weak self] in self?.preferencesDidChange() }
        applyHotKey()

        startIngesting()
        monitor.start()
        observeWorkspace()

        Task {
            await model.reload()
            panelController.prewarm()
            if let smokeOutput = launchOptions.smokeTestOutput {
                await SmokeTest(coordinator: self, output: smokeOutput).run()
                return
            }
            if let storeOpenError {
                hud.show(.init(symbol: "exclamationmark.triangle", title: "History unavailable", detail: "Pasty is keeping this session's history in memory. \(storeOpenError.localizedDescription)"))
            } else if !preferences.hasLaunchedBefore {
                preferences.hasLaunchedBefore = true
                hud.show(.init(symbol: "doc.on.clipboard", title: "Pasty is ready", detail: "Press \(preferences.hotKey.displayString) to open your clipboard history."), duration: 3.5)
            }
        }
    }

    func stop() {
        monitor.stop()
        ingestTask?.cancel()
        captureContinuation.finish()
        hotKeys.unregister()
    }

    // MARK: Panel

    func togglePanel() {
        panelController.toggle()
    }

    func showPanel() {
        panelController.show()
    }

    private func handle(_ command: PanelCommand) {
        switch command {
        case let .activate(item, action):
            pasteCoordinator.perform(action, on: item)
        case let .togglePin(item):
            Task {
                try? await store.setPinned(!item.isPinned, for: item.id)
                await model.reload()
            }
        case let .delete(item):
            Task {
                try? await store.delete(item.id)
                await model.reload()
            }
        case let .open(item):
            pasteCoordinator.open(item)
        case .showSettings:
            panelController.hide()
            showSettings()
        case .resumeMonitoring:
            preferences.isPaused = false
        }
    }

    // MARK: Capture pipeline

    /// A single consumer keeps inserts strictly ordered even when copies arrive in bursts.
    private func startIngesting() {
        let captures = captures
        ingestTask = Task { [weak self] in
            for await draft in captures {
                guard let self else { return }
                let duplicates = preferences.duplicateHandling
                let limit = preferences.maxHistory
                do {
                    let outcome = try await store.insert(draft, duplicates: duplicates, maxHistory: limit)
                    if outcome != .skipped { model.scheduleReload() }
                } catch {
                    NSLog("Pasty: failed to save clipboard entry: \(error)")
                }
            }
        }
    }

    // MARK: Preferences

    private func preferencesDidChange() {
        monitor.updateRules(preferences.captureRules)
        statusItemController?.isVisible = preferences.showMenuBarIcon
        statusItemController?.refresh()
        applyAppearance()
        applyHotKey()
        model.isPaused = preferences.isPaused
        let limit = preferences.maxHistory
        Task {
            try? await store.enforceLimit(maxHistory: limit)
            await model.reload()
        }
    }

    private func applyHotKey() {
        guard preferences.hotKey != lastAppliedHotKey else { return }
        lastAppliedHotKey = preferences.hotKey
        hotKeys.register(preferences.hotKey) { [weak self] in
            self?.togglePanel()
        }
    }

    private func applyAppearance() {
        switch preferences.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func setPaused(_ paused: Bool) {
        preferences.isPaused = paused
    }

    func clearHistory() async {
        try? await store.clear(keepPinned: preferences.keepPinnedOnClear)
        await model.reload()
    }

    func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(coordinator: self)
        }
        settingsController?.show()
    }

    // MARK: System events

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.stop() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.monitor.start()
                self.monitor.checkNow()
                self.model.now = Date()
            }
        })
    }
}

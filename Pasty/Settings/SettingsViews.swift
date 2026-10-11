import AppKit
import PastyCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// A titled group of setting rows inside a bordered card, separated by hairlines.
private struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.shadSMSemibold)
                    .foregroundStyle(Theme.foreground)
                    .padding(.leading, 2)
            }
            Card { content }
            if let footer {
                Text(footer)
                    .font(.shadXS)
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 24)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let coordinator: AppCoordinator
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginNote: String?
    @State private var accessibilityGranted = AccessibilityPermission.isGranted

    var body: some View {
        @Bindable var preferences = coordinator.preferences
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Activation") {
                SettingRow(title: "Open Pasty", description: HotKeyManager.shared.registrationError ?? "The global shortcut that shows your clipboard history.") {
                    ShortcutRecorder(combo: $preferences.hotKey)
                }
                Separator()
                SwitchRow(
                    title: "Launch at login",
                    description: launchAtLoginNote ?? "Start Pasty automatically when you log in.",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != LaunchAtLogin.isEnabled else { return }
                    launchAtLoginNote = LaunchAtLogin.set(enabled)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
                Separator()
                SwitchRow(
                    title: "Show in menu bar",
                    description: "When hidden, open Pasty from Finder or Spotlight to return here.",
                    isOn: $preferences.showMenuBarIcon
                )
            }

            SettingsSection(title: "Behavior", footer: "⌘↩ does the other action. ⇧↩ always pastes as plain text.") {
                SettingRow(title: "Return key", description: "What happens when you choose an item.") {
                    ShadSelect(selection: $preferences.pasteOnSelect, options: [
                        (true, "Paste into active app"),
                        (false, "Copy to clipboard"),
                    ])
                }
                Separator()
                SettingRow(title: "Appearance") {
                    ShadTabs(
                        selection: $preferences.appearance,
                        options: AppearanceMode.allCases.map { ($0, $0.title) }
                    )
                }
            }

            SettingsSection(title: "Permissions") {
                SettingRow(
                    title: "Paste directly into apps",
                    description: accessibilityGranted
                        ? "Pasty can send ⌘V to the app you were using."
                        : "Pasty needs Accessibility access to send ⌘V for you. Until then, items are copied and you press ⌘V yourself."
                ) {
                    if accessibilityGranted {
                        Badge(text: "Allowed", variant: .outline, symbol: "checkmark")
                    } else {
                        Button("Grant Access…") {
                            AccessibilityPermission.requestWithPrompt()
                            AccessibilityPermission.openSystemSettings()
                        }
                        .buttonStyle(.shad(.primary, size: .sm))
                    }
                }
            }
        }
        .task {
            // Reflect changes made in System Settings while this pane is open.
            while !Task.isCancelled {
                accessibilityGranted = AccessibilityPermission.isGranted
                launchAtLogin = LaunchAtLogin.isEnabled
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns a note for the user when the change needs their attention.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return nil }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return "Couldn’t update login items: \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return "Approve Pasty in System Settings › General › Login Items."
        }
        return nil
    }
}

// MARK: - Clipboard

struct ClipboardSettingsView: View {
    let coordinator: AppCoordinator
    @State private var dialog: AlertDialogContent?
    @State private var itemCount: Int?

    var body: some View {
        @Bindable var preferences = coordinator.preferences
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "History", footer: "Pinned items never expire and don’t count toward the limit.") {
                SwitchRow(
                    title: "Record clipboard history",
                    description: "Turn off to pause recording. Copies made while paused are never saved.",
                    isOn: Binding(get: { !preferences.isPaused }, set: { preferences.isPaused = !$0 })
                )
                Separator()
                SettingRow(title: "History size", description: "Older unpinned items are removed automatically.") {
                    ShadSelect(selection: $preferences.maxHistory, options: historyOptions(current: preferences.maxHistory), width: 170)
                }
                Separator()
                SettingRow(title: "When copied again", description: "How repeated copies of the same content are handled.") {
                    ShadSelect(selection: $preferences.duplicateHandling, options: DuplicateHandling.allCases.map { ($0, $0.title) }, width: 230)
                }
                Separator()
                SwitchRow(title: "Save images", description: "Record screenshots and copied images.", isOn: $preferences.captureImages)
            }

            ImportExportSection(archive: coordinator.archive)

            SettingsSection(title: "Clear") {
                SwitchRow(
                    title: "Keep pinned items",
                    description: "Pinned items survive Clear History.",
                    isOn: $preferences.keepPinnedOnClear
                )
                Separator()
                SettingRow(title: "Clear history", description: itemCount.map { $0 == 1 ? "1 item stored." : "\($0.formatted()) items stored." }) {
                    Button("Clear History…") {
                        dialog = AlertDialogContent(
                            title: "Clear clipboard history?",
                            message: preferences.keepPinnedOnClear
                                ? "All items except pinned ones will be permanently deleted from this Mac."
                                : "All items, including pinned ones, will be permanently deleted from this Mac.",
                            confirmTitle: "Clear History"
                        )
                    }
                    .buttonStyle(.shad(.destructive, size: .sm))
                }
            }
        }
        .task { itemCount = try? await coordinator.store.count() }
        .onChange(of: coordinator.archive.state) { _, _ in
            Task { itemCount = try? await coordinator.store.count() }
        }
        .alertDialog($dialog) {
            Task {
                await coordinator.clearHistory()
                itemCount = try? await coordinator.store.count()
            }
        }
    }

    private func historyOptions(current: Int) -> [(Int, String)] {
        var choices = Preferences.historyLimitChoices
        if !choices.contains(current) { choices.append(current); choices.sort() }
        return choices.map { ($0, "\($0.formatted()) items") }
    }
}

/// Import from / export to `.clipbookarchive` — ClipBook's export format, so history moves both ways.
private struct ImportExportSection: View {
    @Bindable var archive: ArchiveController

    var body: some View {
        SettingsSection(
            title: "Import & Export",
            footer: "To bring over your ClipBook history: in ClipBook open Settings › Import/Export › Export History and Tags…, then choose the exported .clipbookarchive folder here. Favorites become pinned items; existing items aren’t duplicated."
        ) {
            SettingRow(title: "Import history", description: "From a ClipBook or Pasty .clipbookarchive export.") {
                Button("Import…") { archive.chooseAndImport() }
                    .buttonStyle(.shad(.outline, size: .sm))
                    .disabled(archive.isRunning)
            }
            Separator()
            SwitchRow(
                title: "Include images when importing",
                description: "Large archives import much faster without images.",
                isOn: $archive.includeImages
            )
            Separator()
            SettingRow(title: "Export history", description: "Saves everything, including pinned items, as a .clipbookarchive that Pasty and ClipBook can import.") {
                Button("Export…") { archive.chooseAndExport() }
                    .buttonStyle(.shad(.outline, size: .sm))
                    .disabled(archive.isRunning)
            }
            if archive.state != .idle {
                Separator()
                ArchiveStatusRow(archive: archive)
            }
        }
    }
}

private struct ArchiveStatusRow: View {
    let archive: ArchiveController

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            switch archive.state {
            case let .running(title, completed, total):
                VStack(alignment: .leading, spacing: 6) {
                    Text(total > 0 ? "\(title) \(completed.formatted()) of \(total.formatted())…" : "\(title)…")
                        .font(.shadSMMedium)
                        .foregroundStyle(Theme.foreground)
                        .monospacedDigit()
                    ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
                        .progressViewStyle(.linear)
                        .tint(Theme.primary)
                }
                Button("Cancel") { archive.cancel() }
                    .buttonStyle(.shad(.ghost, size: .sm))
            case let .finished(message):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text(message).font(Typeface.font(12.5)).foregroundStyle(Theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.destructive)
                Text(message).font(Typeface.font(12.5)).foregroundStyle(Theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    let coordinator: AppCoordinator
    @State private var dialog: AlertDialogContent?

    var body: some View {
        @Bindable var preferences = coordinator.preferences
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.foreground)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your history never leaves this Mac")
                        .font(.shadSMSemibold)
                        .foregroundStyle(Theme.foreground)
                    Text("No accounts, sync, telemetry or analytics. The only network request is the update check to GitHub, which you can turn off in About.")
                        .font(Typeface.font(12.5))
                        .foregroundStyle(Theme.mutedForeground)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.muted.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.bottom, 24)

            SettingsSection(title: "Sensitive content", footer: "Content that apps mark as confidential — as most password managers do — is always ignored.") {
                SwitchRow(
                    title: "Skip passwords and keys",
                    description: "Best-effort detection of API keys and password-like text. It can’t recognize every password.",
                    isOn: $preferences.skipLikelySecrets
                )
                Separator()
                SwitchRow(
                    title: "Pause recording",
                    description: "Temporarily stop saving new copies.",
                    isOn: $preferences.isPaused
                )
            }

            ExcludedAppsSection(preferences: preferences)

            SettingsSection(title: "Danger zone") {
                SettingRow(title: "Delete all history", description: "Permanently remove everything Pasty has recorded, including pinned items.") {
                    Button("Delete All…") {
                        dialog = AlertDialogContent(
                            title: "Delete all history?",
                            message: "This permanently deletes every item, including pinned ones. This can’t be undone.",
                            confirmTitle: "Delete All"
                        )
                    }
                    .buttonStyle(.shad(.destructive, size: .sm))
                }
            }
        }
        .alertDialog($dialog) {
            Task { await coordinator.clearHistory(keepPinned: false) }
        }
    }
}

private struct ExcludedAppsSection: View {
    @Bindable var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Excluded apps")
                        .font(.shadSMSemibold)
                        .foregroundStyle(Theme.foreground)
                    Text("Copies made in these apps are never recorded.")
                        .font(.shadXS)
                        .foregroundStyle(Theme.mutedForeground)
                }
                Spacer()
                Button("Restore Defaults") { preferences.resetExcludedApps() }
                    .buttonStyle(.shad(.ghost, size: .sm))
                Button {
                    addApps()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("Add App")
                    }
                }
                .buttonStyle(.shad(.outline, size: .sm))
            }
            .padding(.leading, 2)

            Card {
                if preferences.excludedApps.isEmpty {
                    Text("No excluded apps.")
                        .font(.shadSM)
                        .foregroundStyle(Theme.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(18)
                } else {
                    ForEach(Array(preferences.excludedApps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Separator() }
                        ExcludedAppRow(app: app) {
                            preferences.excludedApps.removeAll { $0.id == app.id }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  !preferences.excludedApps.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            preferences.excludedApps.append(ExcludedApp(bundleID: id, name: name))
        }
    }
}

private struct ExcludedAppRow: View {
    let app: ExcludedApp
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = IconCache.shared.appIcon(bundleID: app.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.shadSMMedium).foregroundStyle(Theme.foreground)
                Text(app.bundleID).font(Typeface.font(11)).foregroundStyle(Theme.mutedForeground)
            }
            Spacer()
            if IconCache.shared.appIcon(bundleID: app.bundleID) == nil {
                Badge(text: "Not installed", variant: .outline)
            }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.shad(.ghost, size: .icon))
            .help("Stop excluding \(app.name)")
            .accessibilityLabel("Remove \(app.name)")
            .opacity(hovering ? 1 : 0.6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onHover { hovering = $0 }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    let coordinator: AppCoordinator

    var body: some View {
        @Bindable var preferences = coordinator.preferences
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pasty").font(Typeface.font(20, .bold)).foregroundStyle(Theme.foreground)
                    Text("Version \(version)").font(.shadSM).foregroundStyle(Theme.mutedForeground)
                }
            }
            .padding(.bottom, 24)

            SettingsSection(title: "Updates", footer: "Pasty checks GitHub for new releases every few hours. Only the version check and the download leave your Mac — never your clipboard.") {
                SwitchRow(
                    title: "Update automatically",
                    description: "Download new versions in the background and install them when Pasty is idle.",
                    isOn: $preferences.autoUpdate
                )
                Separator()
                SettingRow(title: updateTitle, description: updateDetail) {
                    HStack(spacing: 8) {
                        if case .ready = coordinator.updater.phase {
                            Button("Restart to Update") { coordinator.restartToUpdate() }
                                .buttonStyle(.shad(.primary, size: .sm))
                        } else {
                            Button(isBusy ? "Checking…" : "Check Now") { coordinator.checkForUpdates() }
                                .buttonStyle(.shad(.outline, size: .sm))
                                .disabled(isBusy || coordinator.updater.unsupportedReason != nil)
                        }
                    }
                }
            }

            SettingsSection(title: "Acknowledgements") {
                SettingRow(title: "Plus Jakarta Sans", description: "Typeface by Tokotype, licensed under the SIL Open Font License 1.1.") {
                    EmptyView()
                }
                Separator()
                SettingRow(title: "shadcn/ui", description: "Design system that Pasty’s interface is modeled on (MIT).") {
                    EmptyView()
                }
            }
        }
    }

    private var isBusy: Bool {
        switch coordinator.updater.phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    private var updateTitle: String {
        switch coordinator.updater.phase {
        case .idle: coordinator.updater.lastChecked == nil ? "Version \(coordinator.updater.currentVersion)" : "Pasty is up to date"
        case .upToDate: "Pasty is up to date"
        case .checking: "Checking for updates…"
        case let .downloading(version): "Downloading \(version)…"
        case let .ready(version): "Version \(version) is ready"
        case let .installing(version): "Installing \(version)…"
        case .failed: "Update failed"
        }
    }

    private var updateDetail: String {
        if let reason = coordinator.updater.unsupportedReason { return reason }
        switch coordinator.updater.phase {
        case let .failed(message): return message
        case .ready: return coordinator.preferences.autoUpdate ? "Installs automatically when Pasty is idle." : "Restart Pasty to finish updating."
        default:
            guard let checked = coordinator.updater.lastChecked else { return "Not checked yet." }
            return "Last checked \(checked.formatted(.relative(presentation: .named)))."
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

// MARK: - Shortcut recorder

/// Click, then press the new shortcut. Escape cancels. Requires ⌘, ⌥ or ⌃.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            HStack(spacing: 3) {
                if recording {
                    Text(rejected ? "Include ⌘, ⌥ or ⌃" : "Type a shortcut…")
                        .font(Typeface.font(12.5, .medium))
                        .foregroundStyle(rejected ? Theme.destructive : Theme.mutedForeground)
                        .padding(.horizontal, 4)
                } else {
                    ForEach(Array(combo.displayKeys.enumerated()), id: \.offset) { _, key in
                        Kbd(key)
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 120, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous).fill(Theme.background))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                    .strokeBorder(recording ? Theme.ring : Theme.input, lineWidth: recording ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(combo.displayString)")
        .accessibilityHint("Click, then type a new shortcut")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        rejected = false
        HotKeyManager.shared.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let result = MainActor.assumeIsolated { handle(keyCode: event.keyCode, flags: event.modifierFlags) }
            return result ? nil : event
        }
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if keyCode == 53 { // Escape
            stop()
            return true
        }
        let candidate = KeyCombo(keyCode: UInt32(keyCode), modifiers: KeyCombo.carbonModifiers(from: flags))
        guard candidate.isValidGlobalShortcut else {
            rejected = true
            NSSound.beep()
            return true
        }
        combo = candidate
        stop()
        return true
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotKeyManager.shared.isSuspended = false
    }
}

extension KeyCombo {
    /// Individual keycaps: ["⇧", "⌘", "V"].
    var displayKeys: [String] {
        modifierSymbols.map(String.init) + [KeyNames.name(for: keyCode)]
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= command }
        if flags.contains(.shift) { modifiers |= shift }
        if flags.contains(.option) { modifiers |= option }
        if flags.contains(.control) { modifiers |= control }
        return modifiers
    }
}

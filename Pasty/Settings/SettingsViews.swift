import AppKit
import PastyCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

struct GeneralSettingsView: View {
    let coordinator: AppCoordinator
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginNote: String?
    @State private var accessibilityGranted = AccessibilityPermission.isGranted

    var body: some View {
        @Bindable var preferences = coordinator.preferences
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        launchAtLoginNote = LaunchAtLogin.set(enabled)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                if let launchAtLoginNote {
                    Text(launchAtLoginNote).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Open Pasty") {
                    ShortcutRecorder(combo: $preferences.hotKey)
                }
                if let error = HotKeyManager.shared.registrationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle(isOn: $preferences.showMenuBarIcon) {
                    Text("Show in menu bar")
                    Text("When hidden, open Pasty again from Finder or Spotlight to see Settings.")
                }
            }

            Section {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Return key", selection: $preferences.pasteOnSelect) {
                    Text("Pastes into the active app").tag(true)
                    Text("Copies to the clipboard").tag(false)
                }
            } footer: {
                Text("⌘↩ does the other action. ⇧↩ pastes as plain text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    if accessibilityGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Open Accessibility Settings…") {
                            AccessibilityPermission.requestWithPrompt()
                            AccessibilityPermission.openSystemSettings()
                        }
                    }
                } label: {
                    Text("Paste directly into apps")
                    Text("Pasty needs Accessibility access to send ⌘V for you. Without it, items are copied and you paste with ⌘V yourself.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
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
    @State private var confirmingClear = false
    @State private var itemCount: Int?

    var body: some View {
        @Bindable var preferences = coordinator.preferences
        Form {
            Section {
                Toggle("Record clipboard history", isOn: Binding(
                    get: { !preferences.isPaused },
                    set: { preferences.isPaused = !$0 }
                ))
                Picker("Keep", selection: $preferences.maxHistory) {
                    ForEach(Preferences.historyLimitChoices, id: \.self) { limit in
                        Text("\(limit.formatted()) items").tag(limit)
                    }
                    if !Preferences.historyLimitChoices.contains(preferences.maxHistory) {
                        Text("\(preferences.maxHistory.formatted()) items").tag(preferences.maxHistory)
                    }
                }
                Picker("When copied again", selection: $preferences.duplicateHandling) {
                    ForEach(DuplicateHandling.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Save images", isOn: $preferences.captureImages)
            } footer: {
                Text("Pinned items never expire and don’t count toward the limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep pinned items when clearing history", isOn: $preferences.keepPinnedOnClear)
                LabeledContent {
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                } label: {
                    Text("Clear history")
                    if let itemCount {
                        Text(itemCount == 1 ? "1 item stored" : "\(itemCount.formatted()) items stored")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .task { itemCount = try? await coordinator.store.count() }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                Task {
                    await coordinator.clearHistory()
                    itemCount = try? await coordinator.store.count()
                }
            }
        } message: {
            Text(preferences.keepPinnedOnClear
                ? "All items except pinned ones will be permanently deleted."
                : "All items, including pinned ones, will be permanently deleted.")
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    let coordinator: AppCoordinator
    @State private var selection: ExcludedApp.ID?
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var preferences = coordinator.preferences
        Form {
            Section {
                Label {
                    Text("Your history is stored only on this Mac and is never sent anywhere. Pasty has no accounts, sync or analytics.")
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            Section {
                Toggle(isOn: $preferences.isPaused) {
                    Text("Pause recording")
                    Text("Copies made while paused are never saved.")
                }
                Toggle(isOn: $preferences.skipLikelySecrets) {
                    Text("Skip text that looks like a password or key")
                    Text("A best-effort heuristic. Content that apps mark as confidential — as most password managers do — is always ignored.")
                }
            }

            Section {
                List(selection: $selection) {
                    ForEach(preferences.excludedApps) { app in
                        HStack(spacing: 8) {
                            if let icon = IconCache.shared.appIcon(bundleID: app.bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "app.dashed").frame(width: 18, height: 18).foregroundStyle(.tertiary)
                            }
                            Text(app.name)
                            Spacer()
                            Text(app.bundleID).font(.caption).foregroundStyle(.tertiary)
                        }
                        .tag(app.id)
                    }
                }
                .frame(height: 150)
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 6) {
                    Button { addApp() } label: { Image(systemName: "plus") }
                        .help("Exclude an app")
                    Button {
                        preferences.excludedApps.removeAll { $0.id == selection }
                        selection = nil
                    } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                        .help("Stop excluding the selected app")
                    Spacer()
                    Button("Restore Defaults") { preferences.resetExcludedApps() }
                        .controlSize(.small)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Never record copies from")
            }

            Section {
                LabeledContent("Delete everything Pasty has recorded") {
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                Task { await coordinator.clearHistory() }
            }
        } message: {
            Text("This permanently deletes your clipboard history from this Mac.")
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        let preferences = coordinator.preferences
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !preferences.excludedApps.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            preferences.excludedApps.append(ExcludedApp(bundleID: id, name: name))
        }
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
            Text(recording ? (rejected ? "Add ⌘, ⌥ or ⌃" : "Type shortcut…") : combo.displayString)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(recording ? Color.accentColor : .primary)
                .frame(minWidth: 96)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : .primary.opacity(0.12), lineWidth: recording ? 1.5 : 0.5)
                )
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
        var modifiers: UInt32 = 0
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers |= KeyCombo.command }
        if flags.contains(.shift) { modifiers |= KeyCombo.shift }
        if flags.contains(.option) { modifiers |= KeyCombo.option }
        if flags.contains(.control) { modifiers |= KeyCombo.control }
        let candidate = KeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers)
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

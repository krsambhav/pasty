import Carbon.HIToolbox
import Observation
import PastyCore

/// Registers the global shortcut with Carbon's `RegisterEventHotKey`.
///
/// Unlike event taps, Carbon hotkeys need no Accessibility or Input Monitoring permission, and
/// the system delivers them directly — the fastest and most reliable path for a global shortcut.
@MainActor
@Observable
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// Non-nil when the last registration failed, e.g. because another app owns the shortcut.
    private(set) var registrationError: String?

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private var action: (@MainActor () -> Void)?
    @ObservationIgnored private var combo: KeyCombo?
    /// While recording a new shortcut in Settings the hotkey is released so the keystroke reaches us.
    @ObservationIgnored var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended {
                unregisterHotKey()
            } else if let combo, let action {
                register(combo, action: action)
            }
        }
    }

    nonisolated private static let signature: OSType = 0x5053_5459 // 'PSTY'

    private init() {}

    func register(_ combo: KeyCombo, action: @escaping @MainActor () -> Void) {
        self.combo = combo
        self.action = action
        installHandlerIfNeeded()
        unregisterHotKey()
        guard !isSuspended else { return }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            registrationError = nil
        } else {
            registrationError = status == OSStatus(eventHotKeyExistsErr)
                ? "\(combo.displayString) is already used by another app."
                : "Couldn’t register \(combo.displayString) (error \(status))."
        }
    }

    func unregister() {
        unregisterHotKey()
        action = nil
        combo = nil
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, id.signature == HotKeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            // Carbon dispatches hotkey events on the main thread.
            MainActor.assumeIsolated { manager.action?() }
            return noErr
        }, 1, &spec, context, &eventHandler)
    }
}

extension KeyCombo {
    /// "⇧⌘V"
    var displayString: String {
        modifierSymbols + KeyNames.name(for: keyCode)
    }
}

/// Human-readable names for virtual key codes, using the current keyboard layout for characters.
enum KeyNames {
    private static let special: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    static func name(for keyCode: UInt32) -> String {
        if let name = special[keyCode] { return name }
        return KeyboardLayout.character(for: UInt16(keyCode))?.uppercased() ?? "#\(keyCode)"
    }
}

/// Translates between virtual key codes and characters for the active keyboard layout.
enum KeyboardLayout {
    static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            let string = String(utf16CodeUnits: characters, count: length)
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
        }
    }

    /// The key code that types `character` in the current layout (e.g. "v" moves on Dvorak).
    static func keyCode(for target: String) -> UInt16? {
        for code in UInt16(0)..<128 where character(for: code)?.lowercased() == target {
            return code
        }
        return nil
    }
}

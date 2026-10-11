import AppKit
import SwiftUI

// Native SwiftUI counterparts of shadcn/ui components. Names, variants and sizes follow
// shadcn's API so the design vocabulary carries over one-to-one.

// MARK: - Button

struct ShadButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, outline, ghost, destructive, link }
    enum Size { case xs, sm, md, icon }

    var variant: Variant = .primary
    var size: Size = .md

    func makeBody(configuration: Configuration) -> some View {
        ShadButtonBody(configuration: configuration, variant: variant, size: size)
    }
}

private struct ShadButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: ShadButtonStyle.Variant
    let size: ShadButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: size == .icon ? height : nil, minHeight: height)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous).fill(background))
            .overlay {
                if variant == .outline {
                    RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                        .strokeBorder(Theme.input, lineWidth: 1)
                }
            }
            .shadow(color: variant == .outline || variant == .primary ? .black.opacity(0.05) : .clear, radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var height: CGFloat {
        switch size {
        case .xs: 24
        case .sm: 28
        case .md: 32
        case .icon: 28
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .xs: 8
        case .sm: 10
        case .md: 14
        case .icon: 0
        }
    }

    private var font: Font {
        size == .xs ? .shadXSMedium : Typeface.font(13, .medium)
    }

    private var foreground: Color {
        switch variant {
        case .primary: Theme.primaryForeground
        case .destructive: Theme.destructiveForeground
        case .link: Theme.foreground
        case .ghost: hovering ? Theme.accentForeground : Theme.foreground
        default: Theme.foreground
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch variant {
        case .primary: return Theme.primary.opacity(pressed ? 0.8 : hovering ? 0.9 : 1)
        case .secondary: return Theme.secondary.opacity(pressed ? 0.7 : hovering ? 0.8 : 1)
        case .destructive: return Theme.destructive.opacity(pressed ? 0.8 : hovering ? 0.9 : 1)
        case .outline: return hovering || pressed ? Theme.accent : Theme.background
        case .ghost: return hovering || pressed ? Theme.accent : .clear
        case .link: return .clear
        }
    }
}

extension ButtonStyle where Self == ShadButtonStyle {
    static func shad(_ variant: ShadButtonStyle.Variant = .primary, size: ShadButtonStyle.Size = .md) -> ShadButtonStyle {
        ShadButtonStyle(variant: variant, size: size)
    }
}

// MARK: - Switch

struct ShadSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShadSwitch(configuration: configuration)
    }
}

private struct ShadSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            Capsule()
                .fill(configuration.isOn ? Theme.primary : Theme.input)
                .frame(width: 36, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Theme.background)
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                        .padding(2)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.5)
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

extension ToggleStyle where Self == ShadSwitchStyle {
    static var shadSwitch: ShadSwitchStyle { ShadSwitchStyle() }
}

// MARK: - Tabs (TabsList + TabsTrigger)

struct ShadTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { option in
                let (value, title) = option
                let isSelected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(compact ? .shadXSMedium : Typeface.font(13, .medium))
                        .foregroundStyle(isSelected ? Theme.foreground : Theme.mutedForeground)
                        .padding(.horizontal, compact ? 10 : 12)
                        .frame(height: compact ? 22 : 26)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                                    .fill(Theme.background)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                                            .strokeBorder(Theme.border.opacity(0.6), lineWidth: 0.5)
                                    )
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.muted))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selection)
    }
}

// MARK: - Kbd

struct Kbd: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(Typeface.font(11, .medium))
            .foregroundStyle(Theme.mutedForeground)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.muted))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
            .accessibilityLabel(keys)
    }
}

// MARK: - Badge

struct Badge: View {
    enum Variant { case primary, secondary, outline, destructive }
    let text: String
    var variant: Variant = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(Typeface.font(11, .semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous).fill(background))
        .overlay {
            if variant == .outline {
                RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous).strokeBorder(Theme.border, lineWidth: 1)
            }
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary: Theme.primaryForeground
        case .destructive: Theme.destructiveForeground
        case .secondary, .outline: Theme.foreground
        }
    }

    private var background: Color {
        switch variant {
        case .primary: Theme.primary
        case .secondary: Theme.secondary
        case .destructive: Theme.destructive
        case .outline: .clear
        }
    }
}

// MARK: - Card & Separator

struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

struct Separator: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// MARK: - Setting row (shadcn "form item" with label + description)

struct SettingRow<Control: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.shadSMMedium)
                    .foregroundStyle(Theme.foreground)
                if let description {
                    Text(description)
                        .font(Typeface.font(12.5))
                        .foregroundStyle(Theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }
}

/// A switch row: the whole row's label is the toggle's accessible name.
struct SwitchRow: View {
    let title: String
    var description: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.shadSMMedium).foregroundStyle(Theme.foreground)
                if let description {
                    Text(description)
                        .font(Typeface.font(12.5))
                        .foregroundStyle(Theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.shadSwitch)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - Select

/// shadcn's Select trigger (an outline field with a chevron) driving a native menu.
struct ShadSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var width: CGFloat = 190

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                let (value, title) = option
                Button {
                    selection = value
                } label: {
                    if value == selection {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                    .font(Typeface.font(13))
                    .foregroundStyle(Theme.foreground)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous).strokeBorder(Theme.input, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Alert Dialog

struct AlertDialogContent: Equatable {
    var title: String
    var message: String
    var confirmTitle: String
    var destructive = true
}

/// shadcn's AlertDialog: a dimmed overlay with a centered card and Cancel / Continue actions.
struct AlertDialogModifier: ViewModifier {
    @Binding var content: AlertDialogContent?
    let onConfirm: () -> Void

    func body(content view: Content) -> some View {
        view.overlay {
            if let dialog = content {
                ZStack {
                    Color.black.opacity(0.45)
                        .onTapGesture { content = nil }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(dialog.title)
                            .font(.shadLGSemibold)
                            .foregroundStyle(Theme.foreground)
                        Text(dialog.message)
                            .font(.shadSM)
                            .foregroundStyle(Theme.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Cancel") { content = nil }
                                .buttonStyle(.shad(.outline))
                                .keyboardShortcut(.cancelAction)
                            Button(dialog.confirmTitle) {
                                content = nil
                                onConfirm()
                            }
                            .buttonStyle(.shad(dialog.destructive ? .destructive : .primary))
                            .keyboardShortcut(.defaultAction)
                        }
                        .padding(.top, 10)
                    }
                    .padding(22)
                    .frame(width: 380)
                    .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
                    .accessibilityAddTraits(.isModal)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: content)
    }
}

extension View {
    func alertDialog(_ content: Binding<AlertDialogContent?>, onConfirm: @escaping () -> Void) -> some View {
        modifier(AlertDialogModifier(content: content, onConfirm: onConfirm))
    }
}

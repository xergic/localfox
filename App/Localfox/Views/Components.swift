import SwiftUI

/// Small square icon button, used in headers and hover action clusters.
struct IconButton: View {
    let symbol: String
    var tint: Color = Theme.secondaryText
    var help: String = ""
    var symbolSize: CGFloat = 11
    var frameSize: CGFloat = 20
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(isHovering ? Theme.primaryText : tint)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// A tinted fact, such as a port or a service state.
struct StatusPill: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.mono(11, .medium))
            .foregroundStyle(tint ?? Theme.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint?.opacity(0.15) ?? Theme.pill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tint?.opacity(0.35) ?? Theme.border, lineWidth: 1)
                    )
            )
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.lfSection)
            .kerning(0.8)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// Primary and secondary button chrome.
struct ActionButton: View {
    let title: String
    var symbol: String?
    var isPrimary = false
    var tint: Color = Theme.primaryText
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(isPrimary ? Theme.onAccent : tint)
            .actionChrome(isPrimary: isPrimary, isHovering: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

extension View {
    /// The pill an `ActionButton` wears, so anything that has to look like one
    /// without being one still changes with it.
    func actionChrome(isPrimary: Bool = false, isHovering: Bool = false) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isPrimary ? Theme.accent : (isHovering ? Theme.cardHover : Theme.pill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isPrimary ? .clear : Theme.border, lineWidth: 1)
                    )
            )
    }
}

struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                IconButton(symbol: "xmark", tint: Theme.danger, help: "Dismiss", action: onDismiss)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.danger.opacity(0.12))
        )
    }
}

/// The three-part empty state used on every surface.
struct EmptyStateView: View {
    let symbol: String
    let message: String
    var hint: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Theme.tertiaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 20)
    }
}

/// The PATH Localfox recovered from the login shell.
struct PathList: View {
    let entries: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PATH")
                .font(.lfSection)
                .kerning(0.8)
                .foregroundStyle(Theme.tertiaryText)
            Text(entries.joined(separator: "\n"))
                .font(.lfSubtitle)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A labelled text field with an inline error, shared by the add and edit sheets.
struct LabelledField: View {
    let label: String
    @Binding var text: String
    var monospaced = false
    /// Draws the value as dots. A tunnel token has no business being on screen.
    var isSecure = false
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.danger)
                }
            }
            field
                .textFieldStyle(.plain)
                .font(monospaced || isSecure ? .lfSubtitle : .system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.background)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    error == nil ? Theme.border : Theme.danger.opacity(0.6),
                                    lineWidth: 1
                                )
                        )
                )
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField("", text: $text)
        } else {
            TextField("", text: $text)
        }
    }
}

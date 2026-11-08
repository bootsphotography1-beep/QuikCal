import SwiftUI
import QuietCalendarCore

/// Flowing sage gradient selection highlight with matched-geometry travel.
/// Reduce Motion → instant/crossfade (no travel). Shared by shortcut + destination pickers.
struct GradientOptionSelector<Option: Hashable, Label: View>: View {
    let options: [Option]
    @Binding var selection: Option
    var namespace: Namespace.ID
    var reduceMotion: Bool
    var accessibilityName: (Option) -> String
    @ViewBuilder var label: (Option) -> Label

    private let accent = Color(red: 0.45, green: 0.62, blue: 0.52)

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    select(option)
                } label: {
                    ZStack {
                        if selection == option {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            accent.opacity(0.55),
                                            accent.opacity(0.22),
                                            accent.opacity(0.40)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .matchedGeometryEffect(
                                    id: reduceMotion ? "static-\(option.hashValue)" : "gradient-selection",
                                    in: namespace,
                                    properties: reduceMotion ? .frame : .frame,
                                    isSource: true
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(accent.opacity(0.65), lineWidth: 1)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }

                        label(option)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityName(option))
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
    }

    private func select(_ option: Option) {
        if reduceMotion {
            selection = option
        } else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                selection = option
            }
        }
    }
}

/// Convenience wrapper for hold-to-talk shortcut keys.
struct HoldShortcutGradientPicker: View {
    @Binding var selection: HoldToTalkShortcutKind
    var onChange: ((HoldToTalkShortcutKind) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ns

    var body: some View {
        GradientOptionSelector(
            options: HoldToTalkShortcutKind.allCases,
            selection: Binding(
                get: { selection },
                set: {
                    selection = $0
                    onChange?($0)
                }
            ),
            namespace: ns,
            reduceMotion: reduceMotion,
            accessibilityName: { $0.displayName }
        ) { kind in
            Text(shortLabel(kind))
        }
    }

    private func shortLabel(_ kind: HoldToTalkShortcutKind) -> String {
        switch kind {
        case .fn: return "Fn"
        case .option: return "Option ⌥"
        case .command: return "Command ⌘"
        case .control: return "Control ⌃"
        }
    }
}

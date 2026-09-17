import SwiftUI

/// One line at the top of the panel: what just went wrong, or what turning AI
/// on would buy.
///
/// Design rules it follows, from the component-states discipline:
/// - **An error and an invitation are not the same component in two colors.**
///   They share a shape, and differ in icon, tint and whether they offer a way
///   forward.
/// - **The dismissal is a real control**, with its own hover state, not a
///   glyph that happens to be clickable.
/// - **The row reserves its MEASURED height** through `PanelMetrics`
///   (`reservesPanelHeight`, applied where this view is placed), so appearing
///   does not shove the search field down: the panel grows from the bottom by
///   however tall the row really is, one line or two.
struct NoticeBar: View {
    @ObservedObject private var notices = NoticeCenter.shared
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var transform = PasteTransform.shared

    @State private var hoveringClose = false

    private var t: AppTheme { theme.theme }

    var body: some View {
        Group {
            if let notice = notices.current {
                row(notice)
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.top, Spacing.related)
                    .transition(.opacity)
            } else if let label = transform.runningLabel {
                // The working state is the same row, so a transform starting
                // does not move the panel and then move it back.
                working(label)
                    .padding(.horizontal, Spacing.comfortable)
                    .padding(.top, Spacing.related)
            }
        }
        .animation(.easeOut(duration: 0.16), value: notices.current)
    }

    // MARK: - The row

    private func row(_ notice: NoticeCenter.Notice) -> some View {
        let isError = notice.kind != .invitation
        let tint = isError ? t.destructive : t.accentOnPanel
        let more = max(0, notices.pending.count - 1)
        return HStack(alignment: .center, spacing: Spacing.tight) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: Spacing.inline) {
                Text(notice.message)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let remedy = notice.remedy {
                    Text(remedy)
                        .font(.system(size: 10))
                        .foregroundStyle(t.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Spacing.tight)

            // "+2 more": the other unresolved notices, listed in Diagnostics.
            if more > 0 {
                ClipLink("+\(more) more", size: .small, theme: t) {
                    AppDelegate.shared?.showDiagnostics()
                }
                .help("Open Diagnostics to see every open notice.")
            }

            if let action = notice.action {
                PrimaryButton(action.title, size: .small, theme: t) { action.run() }
                    .help(notice.kind == .invitation
                          ? "Opens Settings > AI, where a connection is added and the master switch lives."
                          : action.title)
            }

            // A second choice, beside the capsule rather than inside it - the
            // Accessibility row (M8.6) needs both "reset and ask again" and
            // "open System Settings" at once, and giving the second one its
            // own capsule read as two equally strong asks fighting for the
            // same click. A plain link is the quieter of the two on purpose.
            if let secondary = notice.secondaryAction {
                ClipLink(secondary.title, size: .small, isDestructive: isError, theme: t) {
                    secondary.run()
                }
                .help(secondary.title)
            }

            // Data at risk cannot be waved away; everything else can.
            if notice.kind != .integrity {
                closeButton(tint: tint, isError: isError)
            }
        }
        .padding(.horizontal, Spacing.related)
        .padding(.vertical, Spacing.tight)
        .background(tint.opacity(isError ? 0.12 : 0.10),
                    in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous)
            .strokeBorder(tint.opacity(0.28), lineWidth: 1))
        // M19: the wash tints from `destructive` or `accentOnPanel`
        // depending on the notice kind, then the two text tones.
        .themeTokens(["destructive", "accentOnPanel", "textPrimary", "textTertiary"])
    }

    /// The dismiss weight of the one icon-button chrome, so this X and the
    /// action panel's X now answer the pointer the same way.
    private func closeButton(tint: Color, isError: Bool) -> some View {
        Button { notices.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hoveringClose ? t.textPrimary : t.textTertiary)
                .iconButtonChrome(t, variant: .dismiss, highlighted: hoveringClose)
        }
        .buttonStyle(.plain)
        .onHover { hoveringClose = $0 }
        // The two dismissals mean different things, and the tooltip is the only
        // place that can say so before it is pressed.
        .help(isError ? "Dismiss this message"
                      : "Hide this for good. Paste actions stay available in Settings.")
    }

    private func working(_ label: String) -> some View {
        HStack(spacing: Spacing.tight) {
            ProgressView().controlSize(.mini)
            Text("Working: \(label)")
                .font(.system(size: 11))
                .foregroundStyle(t.textSecondary)
            Spacer(minLength: Spacing.tight)
            ClipLink("Cancel", size: .small, theme: t) { PasteTransform.shared.cancel() }
        }
        .padding(.horizontal, Spacing.related)
        .padding(.vertical, Spacing.tight)
        .background(t.surfaceBackground, in: RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: t.radiusCard, style: .continuous)
            .strokeBorder(t.border, lineWidth: 1))
        .themeTokens(["surfaceBackground", "border", "textSecondary"])
    }
}

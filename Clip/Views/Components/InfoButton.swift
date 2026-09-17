import SwiftUI

/// A small "?" that opens a short explanation in a popover.
///
/// Rule (user, 03/09): tabs and rows are for configuration only. A page that
/// would hold nothing but prose does not exist; its text lives behind one of
/// these, next to the control or heading it explains, so the screen stays
/// scannable and the reader chooses when to learn more.
struct InfoButton: View {
    let title: String
    let text: String
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(Typography.subheading)
                .foregroundStyle(hovering || showing ? Color.primary : SettingsPalette.note)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .settingsHover(cornerRadius: Spacing.related)
        .onHover { hovering = $0 }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title).font(Typography.subheading)
                Text(ExplainedSection<EmptyView>.prose(text))
                    .font(.caption)
                    .foregroundStyle(SettingsPalette.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.related)
            .frame(width: 320, alignment: .leading)
        }
        .help("Learn more")
        .accessibilityLabel("About \(title)")
    }
}

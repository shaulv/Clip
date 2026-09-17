import SwiftUI

/// A labelled text field row for a grouped Settings `Form`.
///
/// `TextField("Label", …)` on its own inside a grouped Form hands the label
/// to the row and right-aligns the typed text and its placeholder in the
/// value column. The rule (user, 03/09) is that every settings input has a
/// placeholder and reads from the left, and that the hover belongs to the
/// input, not to the whole row - so the label is drawn by `LabeledContent`
/// and the field itself is a plain boxed control with the shared hover.
struct SettingsTextField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var monospaced: Bool = false

    init(_ label: String, text: Binding<String>, prompt: String, monospaced: Bool = false) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.monospaced = monospaced
    }

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .settingsFieldHover()
                .font(monospaced ? .system(size: 12, design: .monospaced) : Typography.body)
        }
    }
}

/// The secure twin of `SettingsTextField`.
struct SettingsSecureField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    init(_ label: String, text: Binding<String>, prompt: String) {
        self.label = label
        self._text = text
        self.prompt = prompt
    }

    var body: some View {
        LabeledContent(label) {
            SecureField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .settingsFieldHover()
                .font(Typography.body)
        }
    }
}

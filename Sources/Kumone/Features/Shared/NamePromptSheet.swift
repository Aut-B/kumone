import SwiftUI

/// A "type a name and confirm" prompt, presented as a sheet.
///
/// `alert`-with-`TextField` prompts need iOS 16: on iOS 15 the alert appears
/// but the text field is silently dropped, leaving a prompt with a confirm
/// button that can never receive input. This sheet works on every supported
/// OS, so prompts stay usable on the iPhone 6s line.
struct NamePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    let submitLabel: String
    /// Called with the trimmed, non-empty name after the sheet dismisses.
    let onSubmit: (String) -> Void

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(placeholder, text: $name)
                        .focused($nameFocused)
                        #if os(iOS)
                        .submitLabel(.done)
                        #endif
                        .onSubmit(submit)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitLabel, action: submit)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
        .onAppear { nameFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private func submit() {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else { return }
        dismiss()
        onSubmit(trimmed)
    }
}

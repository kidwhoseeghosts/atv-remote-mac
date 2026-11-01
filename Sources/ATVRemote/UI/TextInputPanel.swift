import SwiftUI

struct TextInputPanel: View {
    @EnvironmentObject var controller: RemoteController
    @State private var text = ""
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            PanelHeader(title: String(localized: "Text input"))

            SectionCard {
                HStack(spacing: 8) {
                    Image(systemName: controller.keyboardFocused ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(controller.keyboardFocused ? Color.green : Color.secondary)
                    Text(controller.keyboardFocused
                         ? String(localized: "Text field is active on Apple TV")
                         : String(localized: "Open a text field on Apple TV (for example, search) — the text will appear there"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Text for Apple TV", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(1...4)
                .padding(14)
                .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused($fieldFocused)
                .onChange(of: text) { _, newValue in scheduleSend(newValue) }
                .onSubmit {
                    sendTask?.cancel()
                    controller.sendText(text)
                    controller.press(.select)
                }
                .accessibilityLabel("Text for Apple TV")

            HStack(spacing: 10) {
                Button {
                    text = ""
                    sendTask?.cancel()
                    controller.sendText("", mode: "clear")
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    sendTask?.cancel()
                    controller.sendText(text)
                    controller.press(.select)
                } label: {
                    Label("Enter", systemImage: "return")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send and press “Select” (⌘↩)")
            }
            .controlSize(.large)

            Text("Text is sent as you type. ↩ sends and presses “Select”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { fieldFocused = true }
        }
        .onDisappear { sendTask?.cancel() }
    }

    private func scheduleSend(_ value: String) {
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            controller.sendText(value)
        }
    }
}

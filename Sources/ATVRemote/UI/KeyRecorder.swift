import SwiftUI
import AppKit

/// Кнопка записи сочетания клавиш: клик → нажмите новое сочетание (Esc — отмена).
struct KeyRecorderButton: View {
    let combo: KeyCombo
    let conflict: Bool
    let failed: Bool
    let onChange: (KeyCombo) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            HStack(spacing: 4) {
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if conflict {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
                }
                Text(recording ? String(localized: "Press shortcut…") : combo.displayString)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            .frame(minWidth: 96)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(recording ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(recording ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(failed ? String(localized: "macOS refused to register this shortcut — it is taken by another app (for example, Rectangle)") :
              conflict ? String(localized: "This shortcut is already assigned to another action") : String(localized: "Click to change"))
        .onDisappear(perform: stop)
        .accessibilityLabel("Keyboard shortcut")
        .accessibilityValue(combo.displayString)
    }

    private func start() {
        recording = true
        // на время записи отключаем глобальные хоткеи, иначе они перехватят нажатие
        HotKeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            if let new = KeyCombo(event: event) {
                onChange(new)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        let wasRecording = recording
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if wasRecording {
            // возвращаем хоткеи (RemoteController.hotkeys-observer в AppDelegate перерегистрирует их)
            NotificationCenter.default.post(name: .atvHotKeysNeedRefresh, object: nil)
        }
    }
}

extension Notification.Name {
    static let atvHotKeysNeedRefresh = Notification.Name("atvHotKeysNeedRefresh")
}

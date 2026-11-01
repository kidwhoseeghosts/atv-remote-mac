import SwiftUI
import AppKit

struct SettingsPanel: View {
    @EnvironmentObject var controller: RemoteController
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var failures: [HotKeyAction: OSStatus] = HotKeyManager.shared.failures
    @State private var showHotkeys = false
    @AppStorage("clickpadRingMode") private var ringMode = false

    var body: some View {
        VStack(spacing: 12) {
            PanelHeader(title: String(localized: "Settings"))

            ScrollView {
                VStack(spacing: 14) {
                    SectionCard(title: String(localized: "General")) {
                        Toggle("Launch at login", isOn: Binding(
                            get: { launchAtLogin },
                            set: { setLaunchAtLogin($0) }
                        ))
                        if LoginItem.needsApproval {
                            Button("Allow in Login Items…") { LoginItem.openSystemSettings() }
                                .font(.footnote)
                        }
                        if let loginError {
                            Text(loginError).font(.caption).foregroundStyle(.orange)
                        }
                        Toggle("Show artwork", isOn: $controller.showArtwork)
                        Toggle("Haptic feedback", isOn: $controller.hapticsEnabled)
                        Toggle("Clicking the pad edges = arrow keys", isOn: $ringMode)
                        Toggle("Floating window always on top", isOn: $controller.floatingAlwaysOnTop)
                        Button {
                            controller.onToggleFloatingWindow?()
                        } label: {
                            Label("Show/hide floating window", systemImage: "macwindow")
                        }
                        .font(.footnote)
                    }

                    SectionCard(title: String(localized: "Volume")) {
                        Text(controller.volumeMethod == "auto"
                             ? String(localized: "Method: automatic (MRP → Companion → fallback)")
                             : String(localized: "Method: \(controller.volumeDiagInfo?.methods?.first(where: { $0.id == controller.volumeMethod })?.label ?? controller.volumeMethod)"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            controller.openVolumeDiagnostics()
                        } label: {
                            Label("Volume diagnostics", systemImage: "speaker.wave.2.circle")
                        }
                        .font(.footnote)
                    }

                    SectionCard(title: String(localized: "Global shortcuts")) {
                        Toggle("Enable global shortcuts", isOn: $controller.hotkeysEnabled)
                        DisclosureGroup("Assignments", isExpanded: $showHotkeys) {
                            VStack(spacing: 6) {
                                ForEach(HotKeyAction.allCases) { action in
                                    HStack {
                                        Text(action.title).font(.footnote)
                                        Spacer()
                                        KeyRecorderButton(
                                            combo: controller.hotkeys[action] ?? action.defaultCombo,
                                            conflict: hasConflict(action),
                                            failed: failures[action] != nil && controller.hotkeysEnabled
                                        ) { new in
                                            controller.hotkeys[action] = new
                                        }
                                    }
                                }
                                Button("Reset to defaults") {
                                    var all: [HotKeyAction: KeyCombo] = [:]
                                    for a in HotKeyAction.allCases { all[a] = a.defaultCombo }
                                    controller.hotkeys = all
                                }
                                .font(.footnote)
                                .padding(.top, 4)
                            }
                            .padding(.top, 6)
                        }
                        if !failures.isEmpty && controller.hotkeysEnabled {
                            Label("Some shortcuts are taken by another app (for example, Rectangle uses ⌃⌥+arrows). Change them above.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    SectionCard(title: String(localized: "Python and pyatv")) {
                        HStack {
                            Text(envText).font(.footnote)
                            Spacer()
                        }
                        Button("Reinstall environment…") {
                            controller.panel = .setup
                            controller.environment = .missing
                            controller.interpreters = PythonEnvironment.detectInterpreters()
                        }
                        .font(.footnote)
                        Toggle("Demo mode (virtual Apple TV, PIN 1234)", isOn: $controller.demoMode)
                        if controller.demoMode {
                            Button("Restart the service with the new mode") { controller.restartDaemon() }
                                .font(.footnote)
                        }
                        Button("Show service log in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logFile])
                        }
                        .font(.footnote)
                    }

                    SectionCard(title: String(localized: "Devices")) {
                        Button {
                            controller.panel = .devices
                            controller.scan()
                        } label: {
                            Label("Find devices…", systemImage: "magnifyingglass")
                        }
                        .font(.footnote)
                        if let device = controller.currentDevice {
                            Button(role: .destructive) {
                                controller.forget(device)
                            } label: {
                                Label("Forget “\(device.name)”", systemImage: "trash")
                            }
                            .font(.footnote)
                        }
                    }

                    Text("ATV Remote · powered by pyatv")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.vertical, 2)
            }
        }
        .onAppear { refreshFailures() }
        .onReceive(controller.$hotkeys) { _ in refreshFailures() }
        .onChange(of: controller.hotkeysEnabled) { _, _ in refreshFailures() }
    }

    private var envText: String {
        switch controller.environment {
        case .ready(let v): return String(localized: "pyatv \(v) · environment ready")
        case .installing: return String(localized: "Installing…")
        case .checking: return String(localized: "Checking…")
        case .missing: return String(localized: "Not installed")
        case .broken: return String(localized: "Damaged")
        case .failed: return String(localized: "Installation failed")
        }
    }

    private func hasConflict(_ action: HotKeyAction) -> Bool {
        guard let mine = controller.hotkeys[action] else { return false }
        return controller.hotkeys.contains { $0.key != action && $0.value == mine }
    }

    private func refreshFailures() {
        // регистрация происходит в AppDelegate чуть позже изменения настроек
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            failures = HotKeyManager.shared.failures
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(enabled: on)
            loginError = nil
        } catch {
            loginError = String(localized: "Failed to change launch at login: \(error.localizedDescription). Put the app in /Applications and try again.")
        }
        launchAtLogin = LoginItem.isEnabled
    }
}

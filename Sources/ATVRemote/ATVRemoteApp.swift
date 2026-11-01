import SwiftUI
import AppKit
import Combine

/// Единственный экземпляр состояния — его используют и сцена, и AppDelegate.
@MainActor
enum AppModel {
    static let controller = RemoteController()
}

@main
struct ATVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = AppModel.controller

    var body: some Scene {
        MenuBarExtra {
            RemoteRootView(style: .popover)
                .environmentObject(controller)
        } label: {
            MenuBarLabel(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Значок в строке меню: отражает состояние соединения.
struct MenuBarLabel: View {
    @ObservedObject var controller: RemoteController

    var body: some View {
        icon
            .accessibilityLabel("ATV Remote")
            .accessibilityValue(valueText)
    }

    /// Собственный монохромный template-значок пульта (Assets.xcassets), при проблеме — SF Symbol.
    @ViewBuilder private var icon: some View {
        if let name = assetName {
            Image(name)
                .renderingMode(.template)
        } else {
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.monochrome)
        }
    }

    /// Контур — не подключено; заливка — подключено; nil — предупреждение (нужно сопряжение / ошибка).
    private var assetName: String? {
        switch controller.connection {
        case .connected:
            return "MenuBarRemoteFilled"
        case .needsPairing, .failed:
            return nil
        default:
            return "MenuBarRemote"
        }
    }

    private var valueText: String {
        switch controller.connection {
        case .connected: return String(localized: "connected")
        case .connecting, .reconnecting: return String(localized: "connecting")
        case .needsPairing: return String(localized: "pairing required")
        case .failed: return String(localized: "error")
        case .stopped, .disconnected: return String(localized: "not connected")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    private var refreshObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppModel.controller
        NSApp.setActivationPolicy(.accessory) // без значка в Dock (дублирует LSUIElement)

        if CommandLine.arguments.contains("--demo") {
            controller.demoMode = true
        }

        // плавающее окно
        FloatingWindowController.shared.configure(controller: controller)
        controller.onToggleFloatingWindow = { FloatingWindowController.shared.toggle() }

        // глобальные горячие клавиши
        HotKeyManager.shared.onAction = { action in
            if action == .toggleFloatingWindow {
                FloatingWindowController.shared.toggle()
            } else {
                controller.perform(action)
            }
        }
        // @Published отдаёт значение до записи → переносим на следующий такт main
        Publishers.CombineLatest(controller.$hotkeys, controller.$hotkeysEnabled)
            .receive(on: DispatchQueue.main)
            .sink { _, _ in
                HotKeyManager.shared.apply(enabled: controller.hotkeysEnabled, bindings: controller.hotkeys)
            }
            .store(in: &cancellables)
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .atvHotKeysNeedRefresh, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                HotKeyManager.shared.apply(enabled: controller.hotkeysEnabled, bindings: controller.hotkeys)
            }
        }

        controller.bootstrap()
        FloatingWindowController.shared.restoreIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.controller.stopDaemon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

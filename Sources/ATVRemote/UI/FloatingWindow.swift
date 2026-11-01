import SwiftUI
import AppKit
import Combine

/// Панель, которая может становиться key-окном (нужно для клавиатуры и текстового ввода).
final class FloatingRemotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Отдельное плавающее окно с тем же пультом, что и в popover.
@MainActor
final class FloatingWindowController: NSObject, NSWindowDelegate {
    static let shared = FloatingWindowController()

    private var panel: FloatingRemotePanel?
    private var cancellable: AnyCancellable?
    private weak var controller: RemoteController?
    private static let visibleKey = "floatingWindowVisible"

    var isVisible: Bool { panel?.isVisible ?? false }

    func configure(controller: RemoteController) {
        self.controller = controller
        // @Published шлёт значение до записи, поэтому читаем уже после, на следующем такте
        cancellable = controller.$floatingAlwaysOnTop
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyLevel() }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard let controller else { return }
        if panel == nil { panel = makePanel(controller: controller) }
        guard let panel else { return }
        applyLevel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: Self.visibleKey)
    }

    func hide() {
        panel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
    }

    func restoreIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.visibleKey) { show() }
    }

    private func applyLevel() {
        guard let panel, let controller else { return }
        panel.level = controller.floatingAlwaysOnTop ? .floating : .normal
    }

    private func makePanel(controller: RemoteController) -> FloatingRemotePanel {
        let size = NSSize(width: RemoteMetrics.width, height: RemoteMetrics.contentHeight + 22)
        let panel = FloatingRemotePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "ATV Remote"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.setFrameAutosaveName("ATVRemoteFloatingWindow")

        // «матовое стекло» под SwiftUI-содержимым
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: RemoteRootView(style: .window).environmentObject(controller))
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        effect.addSubview(hosting)
        panel.contentView = effect

        if !panel.setFrameUsingName("ATVRemoteFloatingWindow") {
            panel.center()
        }
        // размер всегда фиксированный, даже если сохранён другой
        panel.setContentSize(size)
        return panel
    }

    // Закрытие красной кнопкой — запоминаем, что окно скрыто.
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
    }
}

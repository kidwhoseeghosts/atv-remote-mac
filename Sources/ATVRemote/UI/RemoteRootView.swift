import SwiftUI
import AppKit

enum RemoteStyle {
    case popover   // выпадающее окно из строки меню
    case window    // отдельное плавающее окно
}

/// Корневой экран: один и тот же пульт показывается и в popover, и в плавающем окне.
struct RemoteRootView: View {
    @EnvironmentObject var controller: RemoteController
    let style: RemoteStyle

    @FocusState private var hasFocus: Bool

    var body: some View {
        ZStack {
            switch controller.panel {
            case .remote:
                RemotePanelView(style: style)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .apps:
                panelContainer { AppsPanel() }
            case .keyboard:
                panelContainer { TextInputPanel() }
            case .devices:
                panelContainer { DevicesPanel() }
            case .pairing:
                panelContainer { PairingPanel() }
            case .settings:
                panelContainer { SettingsPanel() }
            case .volumeDiag:
                panelContainer { VolumeDiagPanel() }
            case .setup:
                panelContainer { SetupPanel() }
            }
        }
        .padding(.top, style == .window ? 22 : 0)
        .frame(width: RemoteMetrics.width, height: RemoteMetrics.contentHeight + (style == .window ? 22 : 0))
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: controller.panel)
        .overlay(alignment: .bottom) {
            if let toast = controller.toast {
                ToastView(text: toast)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: controller.toast)
        // клавиатура: стрелки/Return/Space/Delete работают, когда окно в фокусе
        .focusable()
        .focusEffectDisabled()
        .focused($hasFocus)
        .onAppear { hasFocus = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if controller.panel == .remote { hasFocus = true }
        }
        .onChange(of: controller.panel) { _, panel in
            if panel == .remote { hasFocus = true }
        }
        .onKeyPress(phases: [.down, .repeat]) { press in
            handleKey(press)
        }
    }

    private func panelContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, RemoteMetrics.hPadding)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard controller.panel == .remote else { return .ignored }
        let key: RemoteKey?
        switch press.key {
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .return: key = .select
        case .space: key = .playPause
        case .delete, .escape: key = .menu
        default:
            switch press.characters {
            case "h", "H": key = .home
            case "+", "=": key = .volumeUp
            case "-", "_": key = .volumeDown
            case ",": key = .skipBackward
            case ".": key = .skipForward
            default: key = nil
            }
        }
        guard let key else { return .ignored }
        // .escape в popover закрывает окно — не перехватываем, если нажата только Esc
        if press.key == .escape && style == .popover { return .ignored }
        Haptics.tick()
        controller.press(key)
        return .handled
    }
}

// MARK: - Главная панель пульта

struct RemotePanelView: View {
    @EnvironmentObject var controller: RemoteController
    let style: RemoteStyle

    var body: some View {
        // Высота: 36 + 84 + 196 + 144 + 48 + 5×10 + 28 (отступы) = 586 ≤ RemoteMetrics.contentHeight (590)
        VStack(spacing: 10) {
            header
            if controller.connection.isConnected {
                NowPlayingCard()
                    .transition(.opacity)
            } else {
                // пока нет соединения — статус и подсказка вместо карточки «Сейчас играет»
                StatusBanner(minHeight: 84)
                    .frame(width: RemoteMetrics.innerWidth)
                    .transition(.opacity)
            }
            ClickpadView()
            controlsBlock
            bottomBar
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RemoteMetrics.hPadding)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    // MARK: Верх: таблетка устройства + меню

    private var header: some View {
        HStack(spacing: 8) {
            DevicePill()
            Spacer(minLength: 0)
            if style == .window {
                Button {
                    controller.floatingAlwaysOnTop.toggle()
                    Haptics.click()
                } label: {
                    Image(systemName: controller.floatingAlwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 14, weight: .semibold))
                        .rotationEffect(.degrees(controller.floatingAlwaysOnTop ? 0 : 45))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .glassSurface(Circle(), tint: controller.floatingAlwaysOnTop ? Color.accentColor : nil)
                }
                .buttonStyle(PressScaleStyle())
                .help("Always on top")
                .accessibilityLabel("Always on top")
                .accessibilityValue(controller.floatingAlwaysOnTop ? String(localized: "on") : String(localized: "off"))
            }
            moreMenu
        }
        .frame(width: RemoteMetrics.innerWidth, height: 36)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                controller.onToggleFloatingWindow?()
            } label: {
                Label(style == .window ? String(localized: "Close remote window") : String(localized: "Floating remote window"), systemImage: "macwindow")
            }
            Button {
                controller.panel = .settings
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            Divider()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit ATV Remote", systemImage: "power")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .glassSurface(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(PressScaleStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Menu")
    }

    // MARK: Круглые кнопки

    private var controlsBlock: some View {
        let d: CGFloat = 66
        return HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    RemoteCircleButton(symbol: "chevron.backward", title: String(localized: "Back"), size: d,
                                       dimmed: !controller.isAvailable(.menu)) {
                        controller.press(.menu)
                    }
                    RemoteCircleButton(symbol: "tv", title: String(localized: "Home"), size: d,
                                       dimmed: !controller.isAvailable(.home)) {
                        controller.press(.home)
                    }
                }
                HStack(spacing: 12) {
                    RemoteCircleButton(symbol: controller.playing?.isPlaying == true ? "pause.fill" : "play.fill",
                                       title: String(localized: "Play or pause"), size: d,
                                       dimmed: !controller.isAvailable(.playPause)) {
                        controller.press(.playPause)
                    }
                    RemoteCircleButton(symbol: "speaker.slash.fill", title: String(localized: "Mute"), size: d,
                                       dimmed: !controller.canAdjustVolume) {
                        controller.toggleMute()
                    }
                }
            }
            VolumePill(width: d, height: d * 2 + 12)
        }
        .frame(width: RemoteMetrics.innerWidth)
    }

    // MARK: Нижний ряд

    private var bottomBar: some View {
        HStack(spacing: 12) {
            RemoteCircleButton(symbol: "gobackward.10", title: String(localized: "Back 10 seconds"), size: 48,
                               dimmed: !controller.isAvailable(.skipBackward)) {
                controller.press(.skipBackward)
            }
            RemoteCircleButton(symbol: "goforward.10", title: String(localized: "Forward 10 seconds"), size: 48,
                               dimmed: !controller.isAvailable(.skipForward)) {
                controller.press(.skipForward)
            }
            RemoteCircleButton(symbol: "square.grid.2x2.fill", title: String(localized: "Apps"), size: 48,
                               dimmed: !controller.connection.isConnected) {
                controller.panel = .apps
            }
            RemoteCircleButton(symbol: "keyboard", title: String(localized: "Text input"), size: 48,
                               dimmed: !controller.connection.isConnected,
                               tint: controller.keyboardFocused ? Color.accentColor : nil) {
                controller.panel = .keyboard
            }
            RemoteCircleButton(symbol: "power", title: controller.isPoweredOn ? String(localized: "Turn Apple TV off") : String(localized: "Turn Apple TV on"),
                               size: 48, dimmed: !controller.connection.isConnected,
                               tint: controller.isPoweredOn ? nil : Color.red) {
                controller.togglePower()
            }
        }
        .frame(width: RemoteMetrics.innerWidth)
    }
}

import SwiftUI
import AppKit

// MARK: - Круглая кнопка

struct RemoteCircleButton: View {
    let symbol: String
    let title: String
    var size: CGFloat = 68
    var dimmed = false
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.click()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassSurface(Circle(), tint: tint)
        }
        .buttonStyle(PressScaleStyle())
        .opacity(dimmed ? 0.42 : 1)
        .accessibilityLabel(title)
        .help(title)
    }
}

// MARK: - Кнопка с автоповтором (громкость)

struct RepeatingPillButton: View {
    let symbol: String
    let title: String
    var dimmed = false
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pressed ? Color.primary.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
            .opacity(dimmed ? 0.42 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in begin() }
                    .onEnded { _ in end() }
            )
            .animation(.easeOut(duration: 0.12), value: pressed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .help(title)
    }

    private func begin() {
        guard repeatTask == nil else { return }
        pressed = true
        Haptics.click()
        action()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            while !Task.isCancelled {
                Haptics.tick()
                action()
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
        }
    }

    private func end() {
        pressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}

struct VolumePill: View {
    @EnvironmentObject var controller: RemoteController
    var width: CGFloat = 68
    var height: CGFloat = 148

    var body: some View {
        VStack(spacing: 0) {
            RepeatingPillButton(symbol: "plus", title: String(localized: "Volume Up"), dimmed: !controller.canAdjustVolume) {
                controller.press(.volumeUp)
            }
            Capsule()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 26, height: 1)
            RepeatingPillButton(symbol: "minus", title: String(localized: "Volume Down"), dimmed: !controller.canAdjustVolume) {
                controller.press(.volumeDown)
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
        .glassSurface(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Volume")
    }
}

// MARK: - Обложка

struct ArtworkImage: View {
    let path: String?
    var placeholderSymbol = "play.rectangle.fill"
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Rectangle().fill(Color.primary.opacity(0.08))
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: path) {
            let loaded = path.flatMap { NSImage(contentsOfFile: $0) }
            withAnimation(.easeInOut(duration: 0.25)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Тост и статус

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isStaticText)
    }
}

struct StatusDot: View {
    let state: ConnectionState
    @State private var pulse = false

    var color: Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .needsPairing: return .yellow
        case .failed: return .red
        case .stopped, .disconnected: return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(state.isBusy ? (pulse ? 0.35 : 1) : 1)
            .animation(state.isBusy ? Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true) : Animation.default, value: pulse)
            .onAppear { pulse = true }
            .accessibilityHidden(true)
    }
}

struct StatusBanner: View {
    @EnvironmentObject var controller: RemoteController
    var minHeight: CGFloat?

    var body: some View {
        switch controller.connection {
        case .connected:
            EmptyView()
        case .needsPairing:
            row(icon: "lock.shield", text: String(localized: "Pairing with Apple TV required"), button: String(localized: "Pair")) {
                if let d = controller.currentDevice {
                    controller.startPairing(d)
                } else {
                    controller.panel = .devices
                }
            }
        case .failed(let message):
            row(icon: "exclamationmark.triangle", text: message, button: String(localized: "Retry")) { controller.reconnect() }
        case .connecting:
            row(icon: nil, text: controller.statusMessage.isEmpty ? String(localized: "Connecting…") : controller.statusMessage, button: nil, action: {})
        case .reconnecting:
            row(icon: nil, text: controller.statusMessage.isEmpty ? String(localized: "Reconnecting…") : controller.statusMessage, button: nil, action: {})
        case .disconnected:
            if controller.currentDevice != nil {
                row(icon: "bolt.slash", text: String(localized: "No connection"), button: String(localized: "Connect")) { controller.reconnect() }
            } else {
                row(icon: "appletv", text: String(localized: "Choose an Apple TV"), button: String(localized: "Find")) { controller.panel = .devices; controller.scan() }
            }
        case .stopped:
            row(icon: "exclamationmark.triangle", text: String(localized: "The control service is not running"), button: String(localized: "Start")) { controller.startDaemon() }
        }
    }

    private func row(icon: String?, text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let button {
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Заголовок подпанели

struct PanelHeader<Trailing: View>: View {
    @EnvironmentObject var controller: RemoteController
    let title: String
    var showsBack = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if showsBack {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { controller.panel = .remote }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                        .glassSurface(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Back to remote")
                .keyboardShortcut(.cancelAction)
            }
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: showsBack ? .leading : .center)
                .accessibilityAddTraits(.isHeader)
            trailing()
        }
        .frame(height: 36)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, showsBack: Bool = true) {
        self.title = title
        self.showsBack = showsBack
        self.trailing = { EmptyView() }
    }
}

// MARK: - Карточка-секция для настроек и списков

struct SectionCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

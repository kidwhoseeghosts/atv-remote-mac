import SwiftUI

/// Первый запуск: создаём venv с pyatv.
struct SetupPanel: View {
    @EnvironmentObject var controller: RemoteController
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 14) {
            PanelHeader(title: String(localized: "First-time setup"), showsBack: controller.environment.isReady)

            switch controller.environment {
            case .checking:
                Spacer()
                ProgressView("Checking environment…")
                Spacer()
            case .installing:
                installing
            case .missing, .broken, .failed:
                intro
            case .ready(let version):
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("pyatv \(version) installed").font(.headline)
                Button("Continue") { controller.panel = .remote }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
    }

    private var intro: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text("The pyatv Python module is required")
                .font(.headline)
            Text("The app controls Apple TV through the pyatv library. I'll create an isolated environment in ~/Library/Application Support/ATVRemote/venv and install it there (internet required, about a minute).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let message = problemText {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            if controller.interpreters.isEmpty {
                Label("Python 3.9+ not found. In Terminal run: xcode-select --install or brew install python@3.12", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Check again") { controller.bootstrap() }
                    .buttonStyle(.bordered)
            } else {
                if controller.interpreters.count > 1 {
                    Picker("Python", selection: Binding(
                        get: { selected ?? controller.interpreters.first?.id ?? "" },
                        set: { selected = $0 }
                    )) {
                        ForEach(controller.interpreters) { Text($0.displayName).tag($0.id) }
                    }
                    .labelsHidden()
                } else if let one = controller.interpreters.first {
                    Text(one.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    let chosen = controller.interpreters.first(where: { $0.id == selected }) ?? controller.interpreters.first
                    controller.installEnvironment(interpreter: chosen, recreate: true)
                } label: {
                    Label("Install pyatv", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Toggle("Demo mode (without a real Apple TV)", isOn: $controller.demoMode)
                .toggleStyle(.checkbox)
                .font(.footnote)
            Spacer(minLength: 0)
        }
    }

    private var problemText: String? {
        switch controller.environment {
        case .broken(let m): return String(localized: "Environment is damaged: \(m)")
        case .failed(let m): return m
        default: return nil
        }
    }

    private var installing: some View {
        VStack(spacing: 10) {
            ProgressView(value: controller.installProgress)
                .progressViewStyle(.linear)
            Text("Installing pyatv…").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(controller.installLog.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: controller.installLog.count) { _, _ in proxy.scrollTo("end") }
            }
            .padding(10)
            .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

extension EnvironmentStatus {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

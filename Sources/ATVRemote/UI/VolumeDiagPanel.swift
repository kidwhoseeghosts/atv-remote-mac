import SwiftUI

/// Мастер диагностики громкости: пробует каждый способ по очереди и даёт выбрать тот, что сработал.
struct VolumeDiagPanel: View {
    @EnvironmentObject var controller: RemoteController

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(title: String(localized: "Volume diagnostics")) {
                Button {
                    controller.loadVolumeDiagInfo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                        .glassSurface(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .disabled(isRunning)
                .accessibilityLabel("Refresh")
            }

            ScrollView {
                VStack(spacing: 12) {
                    connectionCard
                    adviceCard
                    runCard
                    if !controller.volumeDiagResults.isEmpty { resultsCard }
                    logHint
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var isRunning: Bool {
        if case .running = controller.volumeDiagPhase { return true }
        if case .loading = controller.volumeDiagPhase { return true }
        return false
    }

    // MARK: Каналы

    private var connectionCard: some View {
        SectionCard(title: String(localized: "Control channels")) {
            if let info = controller.volumeDiagInfo {
                row(String(localized: "Protocols"), info.protocols.isEmpty ? "—" : info.protocols.joined(separator: ", "))
                row(String(localized: "MRP tunnel (AirPlay)"), info.mrpTunnel ? String(localized: "active ✓") : String(localized: "no ✗"), good: info.mrpTunnel)
                row(String(localized: "AirPlay paired"), (info.airplayPaired ?? false) ? String(localized: "yes ✓") : String(localized: "no ✗"), good: info.airplayPaired ?? false)
                row(String(localized: "Selected method"), controller.volumeMethod == "auto" ? String(localized: "auto") : controller.volumeMethod)
            } else if case .failed(let message) = controller.volumeDiagPhase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Reading state…").font(.footnote) }
            }
        }
    }

    @ViewBuilder
    private var adviceCard: some View {
        if let advice = controller.volumeDiagInfo?.advice {
            SectionCard(title: String(localized: "Recommendation")) {
                if advice == "pair_airplay" {
                    Label("The official remote in iPhone Control Center changes volume through the AirPlay tunnel. That requires AirPlay pairing, which hasn't been done yet.", systemImage: "airplayvideo")
                        .font(.caption)
                    Button {
                        controller.pairAirPlayForVolume()
                    } label: {
                        Label("Pair AirPlay", systemImage: "link")
                    }
                    .font(.footnote)
                } else if advice == "force_tunnel" {
                    Label("AirPlay is paired, but the MRP tunnel did not come up. Try forcing the connection.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                    Toggle("Force MRP tunnel", isOn: Binding(
                        get: { controller.forceMrpTunnel },
                        set: { controller.setForceMrpTunnel($0) }
                    ))
                    .font(.footnote)
                }
            }
        }
    }

    // MARK: Запуск

    private var runCard: some View {
        SectionCard(title: String(localized: "Test")) {
            Text("Watch the TV screen. The app will send “up” and “down” with each method in turn (2 s pause). Note at which step the volume changed and select it below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                controller.runVolumeDiagnostics()
            } label: {
                Label(isRunning ? String(localized: "Checking…") : String(localized: "Run test"), systemImage: "play.circle.fill")
            }
            .font(.footnote)
            .disabled(isRunning || controller.volumeDiagInfo == nil)

            if case .running(let index, let total, let label, let direction) = controller.volumeDiagPhase {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(max(index, 1) - 1), total: Double(max(total, 1)))
                    Text("Method \(index) of \(total): \(label) — \(Self.directionName(direction))")
                        .font(.caption.weight(.medium))
                }
            }
            if case .failed(let message) = controller.volumeDiagPhase, controller.volumeDiagInfo != nil {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Результаты

    private var resultsCard: some View {
        SectionCard(title: String(localized: "Results")) {
            ForEach(controller.volumeDiagResults) { step in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(step.label).font(.footnote.weight(.semibold))
                        Spacer()
                        if controller.volumeMethod == step.id {
                            Text("selected").font(.caption2).foregroundStyle(.green)
                        }
                    }
                    Text(summary(step))
                        .font(.caption)
                        .foregroundStyle(step.ok ? Color.secondary : Color.orange)
                    if step.ok {
                        Button("Volume changed — choose this") {
                            controller.chooseVolumeMethod(step.id)
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 2)
                Divider().opacity(0.4)
            }
            HStack {
                Button("Automatic") { controller.resetVolumeMethod() }
                    .font(.footnote)
                Spacer()
                Text("If no method worked, send the service log.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func summary(_ step: VolumeDiagStep) -> String {
        func part(_ r: VolumeStepResult?, _ name: String) -> String {
            guard let r else { return "\(name): —" }
            if r.ok {
                let sent = String(localized: "\(name): sent")
                return sent + ((r.volumeChanged ?? false) ? String(localized: ", level changed") : "")
            }
            return String(localized: "\(name): error — \(r.error ?? String(localized: "unknown"))")
        }
        return part(step.up, Self.directionName("up")) + " · " + part(step.down, Self.directionName("down"))
    }

    static func directionName(_ direction: String) -> String {
        direction == "down" ? String(localized: "down") : String(localized: "up")
    }

    private var logHint: some View {
        Text("Log: ~/Library/Application Support/ATVRemote/daemon.log — it records the result of each method.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
    }

    private func row(_ title: String, _ value: String, good: Bool? = nil) -> some View {
        HStack {
            Text(title).font(.footnote)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(good == nil ? Color.secondary : (good! ? Color.green : Color.orange))
        }
    }
}

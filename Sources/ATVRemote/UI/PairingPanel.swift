import SwiftUI

struct PairingPanel: View {
    @EnvironmentObject var controller: RemoteController
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            PanelHeader(title: String(localized: "Pairing"), showsBack: false) {
                Button("Cancel") { controller.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
            }

            if let device = controller.pairingDevice {
                HStack(spacing: 10) {
                    Image(systemName: device.isTv ? "appletv.fill" : "homepod.fill")
                        .font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.headline)
                        if controller.pairingTotal > 1 {
                            Text(stepText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            content
            Spacer(minLength: 0)
        }
        .onChange(of: controller.pairingPhase) { _, _ in pin = "" }
    }

    private var stepText: String {
        let done = controller.pairingTotal - controller.remainingPairingProtocols.count + 1
        return String(localized: "Step \(min(done, controller.pairingTotal)) of \(Int(controller.pairingTotal))")
    }

    @ViewBuilder
    private var content: some View {
        switch controller.pairingPhase {
        case .idle:
            ProgressView()
        case .starting(let proto):
            VStack(spacing: 12) {
                ProgressView()
                Text("Requesting PIN from Apple TV (\(Self.protocolName(proto)))…")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
        case .awaitingPIN(let proto, let deviceShowsPIN, let fixedPin):
            VStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                Text(Self.protocolName(proto)).font(.headline)
                if deviceShowsPIN {
                    Text("Enter the 4-digit PIN shown on your TV screen.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    pinField
                    Button {
                        controller.submitPairingPIN(pin)
                    } label: {
                        Text("Confirm").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.count < 4)
                } else {
                    Text("Enter this PIN on your Apple TV:")
                        .foregroundStyle(.secondary)
                    Text(String(format: "%04d", fixedPin ?? 0))
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 22).padding(.vertical, 8)
                        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                    Button {
                        controller.submitPairingPIN(nil)
                    } label: {
                        Text("I entered the PIN").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
                if controller.remainingPairingProtocols.count > 1 || proto != "companion" {
                    Button("Skip this protocol") { controller.skipPairingStep() }
                        .buttonStyle(.link)
                        .font(.footnote)
                }
            }
            .onAppear { pinFocused = true }
        case .submitting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Verifying PIN…").foregroundStyle(.secondary)
            }
            .padding(.top, 40)
        case .failed(let proto, let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text("Failed (\(Self.protocolName(proto)))").font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                HStack {
                    Button("Retry") { controller.retryPairingStep() }
                        .buttonStyle(.borderedProminent)
                    Button("Skip") { controller.skipPairingStep() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 20)
        case .done:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: controller.pairingPhase)
                Text("Done! Connecting…").font(.headline)
            }
            .padding(.top, 40)
        }
    }

    private var pinField: some View {
        TextField("PIN", text: $pin)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 36, weight: .semibold, design: .monospaced))
            .frame(width: 170, height: 62)
            .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .focused($pinFocused)
            .onChange(of: pin) { _, value in
                let digits = value.filter(\.isNumber)
                let trimmed = String(digits.prefix(4))
                if trimmed != value { pin = trimmed }
            }
            .onSubmit { if pin.count >= 4 { controller.submitPairingPIN(pin) } }
            .accessibilityLabel("PIN code")
    }

    static func protocolName(_ proto: String) -> String {
        switch proto {
        case "companion": return "Companion"
        case "airplay": return "AirPlay"
        case "mrp": return "MRP"
        default: return proto
        }
    }
}

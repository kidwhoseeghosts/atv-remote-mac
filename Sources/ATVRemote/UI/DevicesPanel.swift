import SwiftUI

struct DevicesPanel: View {
    @EnvironmentObject var controller: RemoteController

    var body: some View {
        VStack(spacing: 12) {
            PanelHeader(title: String(localized: "Devices"), showsBack: controller.currentDevice != nil || !controller.devices.isEmpty) {
                Button {
                    controller.scan()
                } label: {
                    Group {
                        if controller.isScanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
                    .glassSurface(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Search for devices")
            }

            if controller.devices.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    if controller.isScanning {
                        ProgressView()
                        Text("Looking for Apple TV on the local network…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "appletv")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                        Text("No devices found").font(.headline)
                        Text("Your Apple TV and this Mac must be on the same network. On first launch macOS will ask for Local Network access — please allow it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Search again") { controller.scan() }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(controller.devices) { device in
                            DeviceRow(device: device)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var controller: RemoteController
    let device: ATVDevice

    private var isCurrent: Bool { controller.currentDevice?.id == device.id && controller.connection.isConnected }

    private var subtitle: String {
        var parts: [String] = []
        if let m = device.model, !m.isEmpty { parts.append(m) }
        parts.append(device.address)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.isTv ? "appletv.fill" : "homepod.fill")
                .font(.system(size: 22))
                .frame(width: 36)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: device.isPaired ? "checkmark.seal.fill" : "lock.fill")
                    Text(device.isPaired ? (isCurrent ? String(localized: "Connected") : String(localized: "Paired")) : String(localized: "Pairing required"))
                }
                .font(.caption2)
                .foregroundStyle(device.isPaired ? Color.green : Color.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if device.isPaired {
                Button(isCurrent ? String(localized: "Open") : String(localized: "Connect")) {
                    if !isCurrent { controller.connect(device) }
                    controller.panel = .remote
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("Pair") { controller.startPairing(device) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu {
            if device.isPaired {
                Button("Pair again") { controller.startPairing(device) }
                Button("Forget device", role: .destructive) { controller.forget(device) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

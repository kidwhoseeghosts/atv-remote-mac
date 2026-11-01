import SwiftUI

/// Выбор устройства в виде «таблетки» сверху, как в iOS.
struct DevicePill: View {
    @EnvironmentObject var controller: RemoteController

    var body: some View {
        Menu {
            if controller.devices.isEmpty {
                Text("No devices found")
            } else {
                Section("Devices") {
                    ForEach(controller.devices) { device in
                        Button {
                            select(device)
                        } label: {
                            if device.id == controller.currentDevice?.id {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Label(device.name, systemImage: device.isTv ? "appletv" : "homepod")
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                controller.panel = .devices
                controller.scan()
            } label: {
                Label("Find and add…", systemImage: "magnifyingglass")
            }
            if controller.currentDevice != nil {
                Button {
                    controller.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            }
        } label: {
            HStack(spacing: 8) {
                StatusDot(state: controller.connection)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassSurface(Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Device: \(title)")
        .accessibilityHint("Open device list")
    }

    private var title: String {
        controller.currentDevice?.name ?? String(localized: "Choose an Apple TV")
    }

    private func select(_ device: ATVDevice) {
        if device.isPaired {
            controller.connect(device)
        } else {
            controller.startPairing(device)
        }
    }
}

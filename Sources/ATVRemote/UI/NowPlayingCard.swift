import SwiftUI

struct NowPlayingCard: View {
    @EnvironmentObject var controller: RemoteController

    var body: some View {
        let info = controller.playing
        let active = info?.isActive == true && !(info?.displayTitle.isEmpty ?? true)

        HStack(spacing: 12) {
            ArtworkImage(path: active ? controller.artworkPath : nil,
                         placeholderSymbol: active ? "play.rectangle.fill" : "appletv.fill")
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 3) {
                if active, let info {
                    Text(info.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(info.displaySubtitle.isEmpty ? " " : info.displaySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let total = info.totalTime, total > 0 {
                        PlaybackProgress(info: info, total: total)
                            .padding(.top, 2)
                    }
                } else {
                    Text(idleTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(idleSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: RemoteMetrics.innerWidth, height: 84)
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: info?.displayTitle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(info, active: active))
    }

    private var idleTitle: String {
        controller.connection.isConnected ? String(localized: "Nothing playing") : (controller.currentDevice?.name ?? "Apple TV")
    }

    private var idleSubtitle: String {
        switch controller.connection {
        case .connected: return controller.currentDevice?.name ?? String(localized: "Connected")
        case .connecting, .reconnecting: return String(localized: "Connecting…")
        case .needsPairing: return String(localized: "Needs pairing")
        case .failed: return String(localized: "Connection error")
        case .stopped, .disconnected: return String(localized: "Not connected")
        }
    }

    private func accessibilityText(_ info: PlayingInfo?, active: Bool) -> String {
        guard active, let info else { return "\(idleTitle). \(idleSubtitle)" }
        let state = info.isPlaying ? String(localized: "Playing") : String(localized: "Paused")
        return "\(state): \(info.displayTitle). \(info.displaySubtitle)"
    }
}

struct PlaybackProgress: View {
    let info: PlayingInfo
    let total: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = livePosition(at: context.date)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.16))
                        Capsule()
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: max(4, geo.size.width * CGFloat(position / total)))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(format(position))
                    Spacer()
                    Text("−" + format(max(0, total - position)))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    private func livePosition(at date: Date) -> Double {
        var position = info.position ?? 0
        if info.isPlaying, let ts = info.timestamp {
            position += max(0, date.timeIntervalSince1970 - ts)
        }
        return min(max(position, 0), total)
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

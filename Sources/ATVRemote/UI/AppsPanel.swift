import SwiftUI

struct AppsPanel: View {
    @EnvironmentObject var controller: RemoteController
    @State private var query = ""

    private var filtered: [AppInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return controller.apps }
        return controller.apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(spacing: 12) {
            PanelHeader(title: String(localized: "Apps")) {
                Button {
                    controller.loadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                        .glassSurface(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Refresh list")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .glassSurface(Capsule())

            if controller.appsLoading && controller.apps.isEmpty {
                Spacer()
                ProgressView("Loading list…")
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Text(controller.apps.isEmpty ? String(localized: "App list unavailable") : String(localized: "Nothing found"))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filtered) { app in
                            AppTile(app: app) { controller.launch(app) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear { if controller.apps.isEmpty { controller.loadApps() } }
    }
}

struct AppTile: View {
    let app: AppInfo
    let action: () -> Void

    private var initials: String {
        let words = app.name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// Стабильный цвет по имени приложения.
    private var tint: Color {
        let hash = app.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.85)
    }

    var body: some View {
        Button {
            Haptics.click()
            action()
        } label: {
            VStack(spacing: 6) {
                Text(initials)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                    )
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                Text(app.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.94))
        .accessibilityLabel(app.name)
        .accessibilityHint("Launch on Apple TV")
    }
}

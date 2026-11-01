import SwiftUI

/// Единый «стеклянный» фон. На macOS 26+ (Liquid Glass) используется системный `glassEffect`,
/// на более ранних системах — `ultraThinMaterial` с тонкой светлой обводкой.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if let tint {
                content.glassEffect(Glass.regular.tint(tint), in: shape)
            } else {
                content.glassEffect(Glass.regular, in: shape)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.22))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(scheme == .dark ? 0.24 : 0.55),
                            Color.white.opacity(0.04),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.28 : 0.12), radius: 8, y: 3)
    }
}

extension View {
    func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint))
    }
}

/// Пружинная анимация нажатия для кнопок пульта.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

enum RemoteMetrics {
    static let width: CGFloat = 320
    static let contentHeight: CGFloat = 590
    static let hPadding: CGFloat = 16
    static let innerWidth: CGFloat = 288
}

import SwiftUI
import AppKit

/// Большая «сенсорная панель» как в Пункте управления на iPhone:
/// свайп мышью/трекпадом (или прокрутка двумя пальцами) — стрелки, клик — «Выбрать».
struct ClickpadView: View {
    @EnvironmentObject var controller: RemoteController
    @AppStorage("clickpadRingMode") private var ringMode = false

    @State private var highlight: Direction?
    @State private var highlightToken = 0
    @State private var selectPressed = false
    @State private var anchor: CGSize = .zero
    @State private var didSwipe = false
    @State private var isHovering = false
    @State private var scrollMonitor: Any?
    @State private var scrollAccumulator: CGSize = .zero

    private let stepDistance: CGFloat = 34
    private let scrollStep: CGFloat = 38
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .glassSurface(shape)

                ZStack {
                    ForEach(Self.allDirections, id: \.self) { direction in
                        edgeGlow(direction)
                    }
                    Circle()
                        .fill(Color.primary.opacity(selectPressed ? 0.20 : 0.07))
                        .frame(width: 74, height: 74)
                        .scaleEffect(selectPressed ? 0.88 : 1)
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                        .frame(width: 74, height: 74)
                        .scaleEffect(selectPressed ? 0.88 : 1)
                    ForEach(Self.allDirections, id: \.self) { direction in
                        chevron(direction)
                    }
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            .contentShape(shape)
            .gesture(dragGesture(size: geo.size))
            .onHover { isHovering = $0 }
            .onAppear(perform: installScrollMonitor)
            .onDisappear(perform: removeScrollMonitor)
            .opacity(controller.connection.isConnected ? 1 : 0.55)
            .animation(.easeOut(duration: 0.2), value: controller.connection.isConnected)
        }
        .frame(width: RemoteMetrics.innerWidth, height: 196)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touch surface")
        .accessibilityHint("Click to select. Swipe to move focus.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: "Up") { emit(.up) }
        .accessibilityAction(named: "Down") { emit(.down) }
        .accessibilityAction(named: "Left") { emit(.left) }
        .accessibilityAction(named: "Right") { emit(.right) }
    }

    // MARK: Оформление

    private static let allDirections: [Direction] = [.up, .down, .left, .right]

    private func edgeGlow(_ d: Direction) -> some View {
        let points = Self.gradientPoints(d)
        return LinearGradient(
            colors: [Color.accentColor.opacity(0.5), Color.accentColor.opacity(0)],
            startPoint: points.0,
            endPoint: points.1
        )
        .opacity(highlight == d ? 1 : 0)
    }

    private static func gradientPoints(_ d: Direction) -> (UnitPoint, UnitPoint) {
        switch d {
        case .up: return (.top, .center)
        case .down: return (.bottom, .center)
        case .left: return (.leading, .center)
        case .right: return (.trailing, .center)
        }
    }

    private func chevron(_ d: Direction) -> some View {
        let name: String
        let alignment: Alignment
        let padding: EdgeInsets
        switch d {
        case .up:
            name = "chevron.up"; alignment = .top; padding = EdgeInsets(top: 14, leading: 0, bottom: 0, trailing: 0)
        case .down:
            name = "chevron.down"; alignment = .bottom; padding = EdgeInsets(top: 0, leading: 0, bottom: 14, trailing: 0)
        case .left:
            name = "chevron.left"; alignment = .leading; padding = EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 0)
        case .right:
            name = "chevron.right"; alignment = .trailing; padding = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 18)
        }
        return Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(highlight == d ? Color.accentColor : Color.primary.opacity(0.32))
            .scaleEffect(highlight == d ? 1.25 : 1)
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    // MARK: Жесты

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width - anchor.width
                let dy = value.translation.height - anchor.height
                if !didSwipe && selectPressed == false && hypot(dx, dy) < 6 {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { selectPressed = true }
                }
                if max(abs(dx), abs(dy)) >= stepDistance {
                    didSwipe = true
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { selectPressed = false }
                    anchor = value.translation
                    emit(Self.direction(dx: dx, dy: dy))
                }
            }
            .onEnded { value in
                let dx = value.translation.width - anchor.width
                let dy = value.translation.height - anchor.height
                let total = hypot(value.translation.width, value.translation.height)
                if !didSwipe {
                    if total >= 14 {
                        // короткий «флик» тоже считается свайпом
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { selectPressed = false }
                        emit(Self.direction(dx: dx, dy: dy))
                    } else {
                        tap(at: value.startLocation, in: size)
                    }
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { selectPressed = false }
                anchor = .zero
                didSwipe = false
            }
    }

    private static func direction(dx: CGFloat, dy: CGFloat) -> Direction {
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    private func tap(at point: CGPoint, in size: CGSize) {
        if ringMode {
            // как кольцо физического пульта: по краям — стрелки, в центре — «Выбрать»
            let cx = size.width / 2, cy = size.height / 2
            let nx = (point.x - cx) / cx, ny = (point.y - cy) / cy
            if hypot(nx * 0.8, ny) > 0.55 {
                emit(Self.direction(dx: nx, dy: ny))
                return
            }
        }
        select()
    }

    private func select() {
        Haptics.click()
        controller.press(.select)
        withAnimation(.spring(response: 0.15, dampingFraction: 0.5)) { selectPressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { selectPressed = false }
        }
    }

    private func emit(_ d: Direction) {
        Haptics.tick()
        controller.press(d)
        highlightToken += 1
        let token = highlightToken
        withAnimation(.easeOut(duration: 0.08)) { highlight = d }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard token == highlightToken else { return }
            withAnimation(.easeOut(duration: 0.3)) { highlight = nil }
        }
    }

    // MARK: Прокрутка двумя пальцами

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering else { return event }
            // инерцию после жеста игнорируем, иначе стрелок будет больше, чем нужно
            if !event.momentumPhase.isEmpty { return nil }
            if event.phase == .began { scrollAccumulator = .zero }
            // «естественное» направление нормализуем: палец вправо/вниз — вправо/вниз
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            var acc = scrollAccumulator
            acc.width += event.scrollingDeltaX * sign
            acc.height += event.scrollingDeltaY * sign
            let step = event.hasPreciseScrollingDeltas ? scrollStep : 3
            if max(abs(acc.width), abs(acc.height)) >= step {
                emit(Self.direction(dx: acc.width, dy: acc.height))
                acc = .zero
            }
            scrollAccumulator = acc
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        scrollMonitor = nil
    }
}

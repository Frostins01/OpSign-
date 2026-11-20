import SwiftUI
import UIKit

enum SnakeDir {
    case up, down, left, right

    var opposite: SnakeDir {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }

    var dx: Int {
        switch self {
        case .left: return -1
        case .right: return 1
        default: return 0
        }
    }

    var dy: Int {
        switch self {
        case .up: return -1
        case .down: return 1
        default: return 0
        }
    }
}

struct GridPoint: Hashable {
    var x: Int
    var y: Int
}

enum SnakeState {
    case idle, running, paused, over
}

final class SnakeModel: ObservableObject {
    let cols = 16
    let rows = 18

    @Published var snake: [GridPoint] = []
    @Published var food = GridPoint(x: 0, y: 0)
    @Published var score = 0
    @Published var best: Int = UserDefaults.standard.integer(forKey: "snakeBest")
    @Published var state: SnakeState = .idle

    private var dir: SnakeDir = .right
    private var queued: SnakeDir?
    private var timer: Timer?
    private let impact = UIImpactFeedbackGenerator(style: .light)

    init() {
        reset()
    }

    func reset() {
        stopTimer()
        snake = [GridPoint(x: 5, y: 9), GridPoint(x: 4, y: 9), GridPoint(x: 3, y: 9)]
        dir = .right
        queued = nil
        score = 0
        placeFood()
        state = .idle
    }

    func start() {
        if state == .over { reset() }
        state = .running
        scheduleTimer()
    }

    func pause() {
        if state == .running {
            state = .paused
            stopTimer()
        }
    }

    func toggle() {
        switch state {
        case .running:
            pause()
        case .paused:
            state = .running
            scheduleTimer()
        case .idle, .over:
            start()
        }
    }

    func turn(_ d: SnakeDir) {
        if state == .idle { start() }
        guard state == .running else { return }
        let current = queued ?? dir
        if d != current && d != current.opposite {
            queued = d
        }
    }

    private func scheduleTimer() {
        stopTimer()
        let interval = max(0.07, 0.17 - Double(score) * 0.004)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if let q = queued {
            dir = q
            queued = nil
        }
        guard let head = snake.first else { return }
        let next = GridPoint(x: head.x + dir.dx, y: head.y + dir.dy)

        let hitWall = next.x < 0 || next.x >= cols || next.y < 0 || next.y >= rows
        let hitSelf = snake.dropLast().contains(next)
        if hitWall || hitSelf {
            gameOver()
            return
        }

        snake.insert(next, at: 0)
        if next == food {
            score += 1
            impact.impactOccurred()
            placeFood()
            scheduleTimer()
        } else {
            snake.removeLast()
        }
    }

    private func gameOver() {
        stopTimer()
        state = .over
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "snakeBest")
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func placeFood() {
        var free: [GridPoint] = []
        for x in 0..<cols {
            for y in 0..<rows {
                let p = GridPoint(x: x, y: y)
                if !snake.contains(p) { free.append(p) }
            }
        }
        food = free.randomElement() ?? GridPoint(x: 0, y: 0)
    }
}

// MARK: - Экран «Игры»

struct GamesView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var model = SnakeModel()

    var t: Palette { store.palette }

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 16) {
                    Text(store.tr("Игры", "Games"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(t.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 20)

                    HStack(spacing: 12) {
                        scoreBox(store.tr("Счёт", "Score"), model.score, "star.fill")
                        scoreBox(store.tr("Рекорд", "Best"), model.best, "trophy.fill")
                    }

                    board

                    controls
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
            .scrollDisabled(model.state == .running || model.state == .idle)
        }
        .onDisappear { model.pause() }
    }

    // MARK: Табло

    func scoreBox(_ title: String, _ value: Int, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(t.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(t.subtext)
                Text("\(value)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(t.text)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .glassCard(t, radius: 20, padding: 14)
    }

    // MARK: Поле

    var board: some View {
        ZStack {
            Canvas { ctx, size in
                let cw = size.width / CGFloat(model.cols)
                let ch = size.height / CGFloat(model.rows)

                for x in 0..<model.cols {
                    for y in 0..<model.rows where (x + y) % 2 == 0 {
                        let r = CGRect(x: CGFloat(x) * cw, y: CGFloat(y) * ch, width: cw, height: ch)
                        ctx.fill(Path(r), with: .color(t.text.opacity(0.045)))
                    }
                }

                let f = CGRect(x: CGFloat(model.food.x) * cw + cw * 0.14,
                               y: CGFloat(model.food.y) * ch + ch * 0.14,
                               width: cw * 0.72, height: ch * 0.72)
                ctx.fill(Path(ellipseIn: f), with: .color(Color.red))

                for (i, p) in model.snake.enumerated() {
                    let r = CGRect(x: CGFloat(p.x) * cw + 1,
                                   y: CGFloat(p.y) * ch + 1,
                                   width: cw - 2, height: ch - 2)
                    let opacity = max(0.45, 1.0 - Double(i) * 0.03)
                    ctx.fill(Path(roundedRect: r, cornerRadius: cw * 0.32),
                             with: .color(t.accent.opacity(opacity)))
                }
            }

            if model.state != .running {
                overlayPanel
            }
        }
        .aspectRatio(CGFloat(model.cols) / CGFloat(model.rows), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .modifier(GlassSurface(shape: AnyShape(RoundedRectangle(cornerRadius: 26, style: .continuous))))
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { v in
                    let dx = v.translation.width
                    let dy = v.translation.height
                    if abs(dx) > abs(dy) {
                        model.turn(dx > 0 ? .right : .left)
                    } else {
                        model.turn(dy > 0 ? .down : .up)
                    }
                }
        )
    }

    var overlayPanel: some View {
        VStack(spacing: 10) {
            Text(panelTitle)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(t.text)
            Text(panelSubtitle)
                .font(.subheadline)
                .foregroundColor(t.subtext)
                .multilineTextAlignment(.center)
            Button {
                model.toggle()
            } label: {
                Label(panelButton, systemImage: "play.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .glassButton(t.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(22)
        .modifier(GlassSurface(shape: AnyShape(RoundedRectangle(cornerRadius: 26, style: .continuous))))
        .padding(24)
    }

    var panelTitle: String {
        switch model.state {
        case .over: return store.tr("Игра окончена", "Game over")
        case .paused: return store.tr("Пауза", "Paused")
        default: return store.tr("Змейка", "Snake")
        }
    }

    var panelSubtitle: String {
        switch model.state {
        case .over: return store.tr("Твой счёт: \(model.score)", "Your score: \(model.score)")
        case .paused: return store.tr("Игра приостановлена", "The game is paused")
        default: return store.tr("Свайпай по полю или жми стрелки", "Swipe on the board or use the arrows")
        }
    }

    var panelButton: String {
        switch model.state {
        case .over: return store.tr("Играть снова", "Play again")
        case .paused: return store.tr("Продолжить", "Resume")
        default: return store.tr("Играть", "Play")
        }
    }

    // MARK: Кнопки управления

    var controls: some View {
        HStack(spacing: 16) {
            padButton("arrow.left", .left)

            VStack(spacing: 14) {
                padButton("arrow.up", .up)
                padButton("arrow.down", .down)
            }

            padButton("arrow.right", .right)

            Button {
                model.toggle()
            } label: {
                Image(systemName: model.state == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .glassButton(t.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    func padButton(_ icon: String, _ d: SnakeDir) -> some View {
        Button {
            model.turn(d)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(t.text)
                .frame(width: 60, height: 60)
                .glassButton(nil)
        }
        .buttonStyle(.plain)
    }
}

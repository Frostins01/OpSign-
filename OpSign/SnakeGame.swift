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
    let cols = 15
    let rows = 15

    @Published var snake: [GridPoint] = []
    @Published var food = GridPoint(x: 0, y: 0)
    @Published var bonus: GridPoint? = nil
    @Published var bonusLeft = 0
    @Published var score = 0
    @Published var best = 0
    @Published var state: SnakeState = .idle
    @Published var dir: SnakeDir = .right
    @Published var newRecord = false

    // Данные для плавной анимации между шагами
    private(set) var fromPositions: [CGPoint] = []
    private(set) var lastTick: Double = 0
    private(set) var stepInterval: Double = 0.15
    private var frozenProgress: Double = 1

    private var applesEaten = 0
    private var timer: Timer?
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let bestKey = "snakeBest_normal_n"

    init() {
        best = UserDefaults.standard.integer(forKey: bestKey)
        reset()
    }

    // MARK: Управление игрой

    func reset() {
        stopTimer()
        snake = [GridPoint(x: 5, y: 7), GridPoint(x: 4, y: 7), GridPoint(x: 3, y: 7)]
        dir = .right
        score = 0
        applesEaten = 0
        bonus = nil
        bonusLeft = 0
        newRecord = false
        placeFood()
        syncPositions()
        state = .idle
    }

    func start() {
        if state == .over { reset() }
        impact.prepare()
        syncPositions()
        state = .running
        scheduleTimer()
    }

    func pause() {
        if state == .running {
            frozenProgress = progress(at: CACurrentMediaTime())
            state = .paused
            stopTimer()
        }
    }

    func toggle() {
        switch state {
        case .running:
            pause()
        case .paused:
            lastTick = CACurrentMediaTime() - frozenProgress * stepInterval
            state = .running
            scheduleTimer(firstDelay: max(0.01, (1 - frozenProgress) * stepInterval))
        case .idle, .over:
            start()
        }
    }

    /// Поворот срабатывает сразу: змея делает шаг в новую сторону в момент касания
    func turn(_ d: SnakeDir) {
        guard state == .running else { return }
        if d == dir || d == dir.opposite { return }
        dir = d
        impact.impactOccurred(intensity: 0.6)
        tick()
        if state == .running { scheduleTimer() }
    }

    // MARK: Плавное движение

    private func currentInterval() -> Double {
        max(0.08, 0.15 - Double(score) * 0.0025)
    }

    private func syncPositions() {
        fromPositions = snake.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        stepInterval = currentInterval()
        lastTick = CACurrentMediaTime()
        frozenProgress = 1
    }

    func progress(at now: Double) -> Double {
        switch state {
        case .running:
            return min(1, max(0, (now - lastTick) / stepInterval))
        case .paused:
            return frozenProgress
        default:
            return 1
        }
    }

    /// Положение каждого звена змеи (в клетках, дробное) между двумя шагами
    func positions(at now: Double) -> [CGPoint] {
        let p = CGFloat(progress(at: now))
        var result: [CGPoint] = []
        result.reserveCapacity(snake.count)
        for (i, target) in snake.enumerated() {
            let tx = CGFloat(target.x)
            let ty = CGFloat(target.y)
            let from: CGPoint
            if i < fromPositions.count {
                from = fromPositions[i]
            } else if let last = fromPositions.last {
                from = last
            } else {
                from = CGPoint(x: tx, y: ty)
            }
            result.append(CGPoint(x: from.x + (tx - from.x) * p,
                                  y: from.y + (ty - from.y) * p))
        }
        return result
    }

    // MARK: Таймер

    private func scheduleTimer(firstDelay: Double? = nil) {
        stopTimer()
        let delay = firstDelay ?? currentInterval()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tick()
            if self.state == .running { self.scheduleTimer() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Шаг игры

    private func tick() {
        guard state == .running, let head = snake.first else { return }

        let now = CACurrentMediaTime()
        let visual = positions(at: now)

        let nx = head.x + dir.dx
        let ny = head.y + dir.dy

        if nx < 0 || nx >= cols || ny < 0 || ny >= rows {
            gameOver()
            return
        }

        let next = GridPoint(x: nx, y: ny)
        let eatsFood = next == food
        let eatsBonus = bonus != nil && next == bonus
        let grows = eatsFood || eatsBonus

        let body = grows ? snake : Array(snake.dropLast())
        if body.contains(next) {
            gameOver()
            return
        }

        snake.insert(next, at: 0)
        if !grows { snake.removeLast() }

        if eatsFood {
            score += 1
            applesEaten += 1
            impact.impactOccurred()
            placeFood()
            if applesEaten % 5 == 0 { placeBonus() }
        } else if eatsBonus {
            score += 3
            bonus = nil
            bonusLeft = 0
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        if bonus != nil {
            bonusLeft -= 1
            if bonusLeft <= 0 {
                bonus = nil
                bonusLeft = 0
            }
        }

        fromPositions = visual
        lastTick = now
        stepInterval = currentInterval()
    }

    private func gameOver() {
        stopTimer()
        state = .over
        if score > best {
            best = score
            newRecord = true
            UserDefaults.standard.set(best, forKey: bestKey)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func freeCells() -> [GridPoint] {
        var free: [GridPoint] = []
        for x in 0..<cols {
            for y in 0..<rows {
                let p = GridPoint(x: x, y: y)
                if !snake.contains(p) && p != food && p != bonus {
                    free.append(p)
                }
            }
        }
        return free
    }

    private func placeFood() {
        food = GridPoint(x: -1, y: -1)
        food = freeCells().randomElement() ?? GridPoint(x: 0, y: 0)
    }

    private func placeBonus() {
        if let p = freeCells().randomElement() {
            bonus = p
            bonusLeft = 45
        }
    }
}

// MARK: - Большая кнопка-стрелка (срабатывает в момент касания)

struct PadButton: View {
    let icon: String
    let size: CGFloat
    let t: Palette
    var tint: Color? = nil
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.4, weight: .heavy))
            .foregroundColor(tint == nil ? t.text : t.onAccent)
            .frame(width: size, height: size)
            .glassButton(tint)
            .contentShape(Circle())
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            action()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                    }
            )
    }
}

// MARK: - Экран «Игры»

struct GamesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = SnakeModel()
    @State private var swipeOrigin: CGPoint? = nil

    var t: Palette { store.palette }

    var body: some View {
        ZStack {
            ThemedBackground()

            GeometryReader { geo in
                let pad: CGFloat = min(82, (geo.size.width - 60) / 3.4)
                let gap: CGFloat = 10
                let dpadH = pad * 3 + gap * 2
                let headerH: CGFloat = 64
                let spacing: CGFloat = 14
                let boardMax = geo.size.height - headerH - dpadH - spacing * 2 - 16
                let side = max(200, min(geo.size.width - 36, boardMax))

                VStack(spacing: spacing) {
                    header
                        .frame(height: headerH)
                    board(side: side)
                    dpad(pad: pad, gap: gap)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
            }
        }
        .contentShape(Rectangle())
        .gesture(swipe)
        .onDisappear { model.pause() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.pause() }
        }
    }

    // MARK: Свайп по любому месту экрана (срабатывает сразу при движении пальца)

    var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                let origin = swipeOrigin ?? v.startLocation
                let dx = v.location.x - origin.x
                let dy = v.location.y - origin.y
                if max(abs(dx), abs(dy)) >= 12 {
                    if abs(dx) > abs(dy) {
                        model.turn(dx > 0 ? .right : .left)
                    } else {
                        model.turn(dy > 0 ? .down : .up)
                    }
                    swipeOrigin = v.location
                } else if swipeOrigin == nil {
                    swipeOrigin = v.startLocation
                }
            }
            .onEnded { _ in
                swipeOrigin = nil
            }
    }

    // MARK: Шапка

    var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(store.tr("Змейка", "Snake"))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(t.text)
            Spacer()
            chip("star.fill", model.score)
            chip("trophy.fill", model.best)
        }
    }

    func chip(_ icon: String, _ value: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(t.accent)
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(t.text)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassButton(nil)
    }

    // MARK: Поле (перерисовывается с частотой экрана, движение плавное)

    func board(side: CGFloat) -> some View {
        ZStack {
            TimelineView(.animation(minimumInterval: nil, paused: model.state != .running)) { _ in
                Canvas { ctx, size in
                    drawBoard(&ctx, size, CACurrentMediaTime())
                }
            }

            if model.state != .running {
                overlayPanel
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .modifier(GlassSurface(shape: AnyShape(RoundedRectangle(cornerRadius: 28, style: .continuous))))
    }

    func drawBoard(_ ctx: inout GraphicsContext, _ size: CGSize, _ time: Double) {
        let cols = model.cols
        let rows = model.rows
        let cw = size.width / CGFloat(cols)
        let ch = size.height / CGFloat(rows)
        let cell = min(cw, ch)
        let pulse = 0.5 + 0.5 * sin(time * 4)

        // Подложка
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(t.isLight ? Color.white.opacity(0.35) : Color.black.opacity(0.28)))

        // Шахматная клетка
        for x in 0..<cols {
            for y in 0..<rows where (x + y) % 2 == 0 {
                let r = CGRect(x: CGFloat(x) * cw, y: CGFloat(y) * ch, width: cw, height: ch)
                ctx.fill(Path(r), with: .color(t.text.opacity(0.05)))
            }
        }

        func center(_ p: GridPoint) -> CGPoint {
            CGPoint(x: (CGFloat(p.x) + 0.5) * cw, y: (CGFloat(p.y) + 0.5) * ch)
        }

        func centerF(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x + 0.5) * cw, y: (p.y + 0.5) * ch)
        }

        // Яблоко
        let fc = center(model.food)
        let glowR = cell * CGFloat(0.72 + 0.16 * pulse)
        ctx.fill(Path(ellipseIn: CGRect(x: fc.x - glowR, y: fc.y - glowR, width: glowR * 2, height: glowR * 2)),
                 with: .color(Color.red.opacity(0.22)))
        let bodyR = cell * 0.34
        ctx.fill(Path(ellipseIn: CGRect(x: fc.x - bodyR, y: fc.y - bodyR + cell * 0.03, width: bodyR * 2, height: bodyR * 2)),
                 with: .color(Color(red: 1.0, green: 0.27, blue: 0.23)))
        ctx.fill(Path(ellipseIn: CGRect(x: fc.x - bodyR * 0.55, y: fc.y - bodyR * 0.75, width: bodyR * 0.55, height: bodyR * 0.45)),
                 with: .color(Color.white.opacity(0.55)))
        ctx.fill(Path(ellipseIn: CGRect(x: fc.x + cell * 0.02, y: fc.y - bodyR - cell * 0.12, width: cell * 0.2, height: cell * 0.12)),
                 with: .color(Color.green))

        // Золотой бонус
        if let b = model.bonus {
            let blinkOff = model.bonusLeft < 12 && Int(time * 6) % 2 == 0
            if !blinkOff {
                let bc = center(b)
                let ring = cell * CGFloat(0.5 + 0.2 * pulse)
                ctx.stroke(Path(ellipseIn: CGRect(x: bc.x - ring, y: bc.y - ring, width: ring * 2, height: ring * 2)),
                           with: .color(Color.yellow.opacity(0.7)), lineWidth: 2)
                let r = cell * 0.3
                ctx.fill(Path(ellipseIn: CGRect(x: bc.x - r, y: bc.y - r, width: r * 2, height: r * 2)),
                         with: .color(Color(red: 1.0, green: 0.82, blue: 0.1)))
                let r2 = r * 0.45
                ctx.fill(Path(ellipseIn: CGRect(x: bc.x - r2, y: bc.y - r2, width: r2 * 2, height: r2 * 2)),
                         with: .color(Color.white.opacity(0.85)))
            }
        }

        // Змея: плавное движение между клетками
        let pts = model.positions(at: time)
        let n = pts.count
        let bodyW = cell * 0.78

        let ui = UIColor(t.accent)
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        ui.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)

        // Тело от хвоста к голове; цвет плавно темнеет к хвосту
        if n > 1 {
            for i in stride(from: n - 1, through: 1, by: -1) {
                let frac = CGFloat(i) / CGFloat(n - 1)
                let f = 1.0 - 0.42 * frac
                let color = Color(red: Double(cr * f), green: Double(cg * f), blue: Double(cb * f))
                var path = Path()
                path.move(to: centerF(pts[i]))
                path.addLine(to: centerF(pts[i - 1]))
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: bodyW, lineCap: .round, lineJoin: .round))
            }
        }

        // Голова с глазами
        if let first = pts.first {
            let hc = centerF(first)
            let hw = bodyW * 1.1
            ctx.fill(Path(roundedRect: CGRect(x: hc.x - hw / 2, y: hc.y - hw / 2, width: hw, height: hw),
                          cornerRadius: hw * 0.45),
                     with: .color(t.accent))

            let dv = CGPoint(x: CGFloat(model.dir.dx), y: CGFloat(model.dir.dy))
            let pv = CGPoint(x: -dv.y, y: dv.x)
            for s in [-1.0, 1.0] {
                let k = CGFloat(s)
                let ec = CGPoint(x: hc.x + dv.x * cell * 0.14 + pv.x * cell * 0.2 * k,
                                 y: hc.y + dv.y * cell * 0.14 + pv.y * cell * 0.2 * k)
                ctx.fill(Path(ellipseIn: CGRect(x: ec.x - cell * 0.13, y: ec.y - cell * 0.13,
                                                width: cell * 0.26, height: cell * 0.26)),
                         with: .color(.white))
                let pc = CGPoint(x: ec.x + dv.x * cell * 0.04, y: ec.y + dv.y * cell * 0.04)
                ctx.fill(Path(ellipseIn: CGRect(x: pc.x - cell * 0.065, y: pc.y - cell * 0.065,
                                                width: cell * 0.13, height: cell * 0.13)),
                         with: .color(.black))
            }
        }
    }

    // MARK: Панель на поле (старт / пауза / конец игры)

    var overlayPanel: some View {
        VStack(spacing: 12) {
            Text(panelTitle)
                .font(.system(size: 28, weight: .bold, design: .rounded))
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
                    .foregroundColor(t.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .glassButton(t.accent)
            }
            .buttonStyle(PressStyle())

            if model.state == .paused {
                Button {
                    model.reset()
                    model.start()
                } label: {
                    Text(store.tr("Заново", "Restart"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(t.text)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .glassButton(nil)
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(20)
        .modifier(GlassSurface(shape: AnyShape(RoundedRectangle(cornerRadius: 26, style: .continuous))))
        .padding(18)
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
        case .over:
            if model.newRecord {
                return store.tr("Новый рекорд: \(model.score)!", "New record: \(model.score)!")
            }
            return store.tr("Твой счёт: \(model.score)", "Your score: \(model.score)")
        case .paused:
            return store.tr("Игра приостановлена", "The game is paused")
        default:
            return store.tr("Свайпай по экрану или жми стрелки. Золотой шарик даёт +3.",
                            "Swipe anywhere or use the arrows. The golden ball gives +3.")
        }
    }

    var panelButton: String {
        switch model.state {
        case .over: return store.tr("Играть снова", "Play again")
        case .paused: return store.tr("Продолжить", "Resume")
        default: return store.tr("Играть", "Play")
        }
    }

    // MARK: Большие кнопки управления

    func dpad(pad: CGFloat, gap: CGFloat) -> some View {
        VStack(spacing: gap) {
            PadButton(icon: "chevron.up", size: pad, t: t) { model.turn(.up) }

            HStack(spacing: gap) {
                PadButton(icon: "chevron.left", size: pad, t: t) { model.turn(.left) }
                PadButton(icon: model.state == .running ? "pause.fill" : "play.fill",
                          size: pad, t: t, tint: t.accent) { model.toggle() }
                PadButton(icon: "chevron.right", size: pad, t: t) { model.turn(.right) }
            }

            PadButton(icon: "chevron.down", size: pad, t: t) { model.turn(.down) }
        }
        .frame(maxWidth: .infinity)
    }
}

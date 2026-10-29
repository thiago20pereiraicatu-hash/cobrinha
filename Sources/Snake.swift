// linguagem: Swift 5, arquivo: Snake.swift, alvo: iOS 14+ (UIKit programatico, sem storyboard)
// jogo da cobrinha v2: cobra rosa, obstaculos, 3 frutas (maca +1, uva +2, cereja +3), swipe continuo + tap
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = GameViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

final class GameViewController: UIViewController {
    private let gameView = SnakeView(frame: UIScreen.main.bounds)

    override func loadView() {
        view = gameView
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(gameView,
                                               selector: #selector(SnakeView.pauseGame),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)
    }
}

final class SnakeView: UIView {

    struct Cell: Equatable { var x: Int; var y: Int }

    private let COLS = 21, ROWS = 21, FRUIT_SLOTS = 3, OBSTACLE_CELLS = 18
    private let FRUIT_POINTS = [1, 2, 3]

    private var snake: [Cell] = []
    private var obstacles: [Cell] = []
    private var queue: [Cell] = []
    private var fruitPos: [Cell?] = [nil, nil, nil]
    private var fruitKind: [Int] = [0, 0, 0]
    private var dir = Cell(x: 1, y: 0)
    private var score = 0, best = 0
    private var paused = true, over = false, started = false
    private var timer: Timer?
    private var anchor: CGPoint?
    private var moved = false

    private let pinkHead = UIColor(r: 255, g: 201, b: 229)
    private let pinkMid = UIColor(r: 255, g: 138, b: 201)
    private let pinkTail = UIColor(r: 214, g: 51, b: 108)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(r: 8, g: 12, b: 9)
        best = UserDefaults.standard.integer(forKey: "cobrinha_best")
        reset()
    }

    required init?(coder: NSCoder) { fatalError("sem storyboard") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func speed() -> TimeInterval { max(0.07, 0.16 - Double(score) * 0.002) }

    private func reset() {
        snake = [Cell(x: 10, y: 10), Cell(x: 9, y: 10), Cell(x: 8, y: 10)]
        queue = []
        dir = Cell(x: 1, y: 0)
        score = 0
        paused = true
        over = false
        started = false
        makeObstacles()
        for i in 0..<FRUIT_SLOTS { spawnFruit(i) }
        setNeedsDisplay()
    }

    private func makeObstacles() {
        obstacles = []
        var guardCount = 0
        while obstacles.count < OBSTACLE_CELLS && guardCount < 600 {
            guardCount += 1
            let cx = Int.random(in: 0..<COLS), cy = Int.random(in: 0..<ROWS)
            let len = Int.random(in: 2...4)
            let horiz = Bool.random()
            var cluster: [Cell] = []
            for i in 0..<len {
                let x = cx + (horiz ? i : 0), y = cy + (horiz ? 0 : i)
                if x >= COLS || y >= ROWS { break }
                cluster.append(Cell(x: x, y: y))
            }
            var bad = false
            for p in cluster {
                if abs(p.x - 10) + abs(p.y - 10) < 5 { bad = true } // zona do spawn livre
                if obstacles.contains(p) { bad = true }
            }
            if !bad && cluster.count > 1 { obstacles.append(contentsOf: cluster) }
        }
    }

    private func fruitOccupied(_ p: Cell) -> Bool {
        for f in fruitPos { if f == p { return true } }
        return false
    }

    private func spawnFruit(_ slot: Int) {
        var p: Cell
        repeat {
            p = Cell(x: Int.random(in: 0..<COLS), y: Int.random(in: 0..<ROWS))
        } while snake.contains(p) || obstacles.contains(p) || fruitOccupied(p)
        fruitPos[slot] = p
        fruitKind[slot] = Int.random(in: 0..<3)
    }

    @objc func pauseGame() {
        if started && !over { paused = true }
        timer?.invalidate()
        setNeedsDisplay()
    }

    private func togglePause() {
        paused = !paused
        if !paused {
            started = true
            arm()
        } else {
            timer?.invalidate()
        }
        setNeedsDisplay()
    }

    private func arm() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: speed(), target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: false)
    }

    @objc private func tick() {
        guard !paused, !over else { return }
        step()
        arm()
    }

    private func step() {
        if !queue.isEmpty { dir = queue.removeFirst() }
        guard let h0 = snake.first else { return }
        let head = Cell(x: h0.x + dir.x, y: h0.y + dir.y)
        let hitWall = head.x < 0 || head.x >= COLS || head.y < 0 || head.y >= ROWS
        if hitWall || snake.contains(head) || obstacles.contains(head) {
            over = true
            if score > best {
                best = score
                UserDefaults.standard.set(best, forKey: "cobrinha_best")
            }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            setNeedsDisplay()
            return
        }
        snake.insert(head, at: 0)
        var ate = -1
        for i in 0..<FRUIT_SLOTS where fruitPos[i] == head { ate = i; break }
        if ate >= 0 {
            score += FRUIT_POINTS[fruitKind[ate]]
            spawnFruit(ate)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            snake.removeLast()
        }
        setNeedsDisplay()
    }

    // MARK: - toque

    private func turn(_ nd: Cell) {
        if over { return }
        let last = queue.last ?? dir
        if (nd.x != -last.x || nd.y != -last.y) && queue.count < 2 { queue.append(nd) } // sem reversao de 180
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        anchor = touches.first?.location(in: self)
        moved = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let a = anchor, let p = touches.first?.location(in: self) else { return }
        let dx = p.x - a.x, dy = p.y - a.y
        if max(abs(dx), abs(dy)) >= 24 {
            let c = abs(dx) > abs(dy)
                ? Cell(x: dx > 0 ? 1 : -1, y: 0)
                : Cell(x: 0, y: dy > 0 ? 1 : -1)
            turn(c)
            anchor = p // arrasto continuo: pode virar de novo sem soltar
            moved = true
            if paused && !over { togglePause() }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !moved {
            if over { reset(); togglePause() }
            else { togglePause() }
        }
        anchor = nil
    }

    // MARK: - desenho

    private func metrics() -> (cell: CGFloat, ox: CGFloat, oy: CGFloat, u: CGFloat, hud: CGFloat) {
        let w = bounds.width, h = bounds.height
        let hud: CGFloat = 56
        let cell = min(w / CGFloat(COLS), (h - hud) / CGFloat(ROWS))
        let ox = (w - cell * CGFloat(COLS)) / 2
        let oy = hud + (h - hud - cell * CGFloat(ROWS)) / 2
        return (cell, ox, oy, cell / 24, hud)
    }

    private func fillGradRect(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, top: UIColor, bottom: UIColor) {
        ctx.saveGState()
        UIBezierPath(roundedRect: r, cornerRadius: radius).addClip()
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [top.cgColor, bottom.cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: r.minX, y: r.minY),
                                   end: CGPoint(x: r.minX, y: r.maxY),
                                   options: [])
        }
        ctx.restoreGState()
    }

    private func fillGradEllipse(_ ctx: CGContext, _ r: CGRect, top: UIColor, bottom: UIColor) {
        ctx.saveGState()
        UIBezierPath(ovalIn: r).addClip()
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [top.cgColor, bottom.cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: r.minX, y: r.minY),
                                   end: CGPoint(x: r.minX, y: r.maxY),
                                   options: [])
        }
        ctx.restoreGState()
    }

    private func lerp(_ a: UIColor, _ b: UIColor, t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t,
                       blue: ab + (bb - ab) * t, alpha: 1)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let m = metrics()
        let (cell, ox, oy, u) = (m.cell, m.ox, m.oy, m.u)

        // fundo
        fillGradRect(ctx, bounds, radius: 0,
                     top: UIColor(r: 20, g: 28, b: 22), bottom: UIColor(r: 8, g: 12, b: 9))

        // grade sutil
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.05).cgColor)
        ctx.setLineWidth(1)
        for x in 0...COLS {
            let px = ox + CGFloat(x) * cell
            ctx.move(to: CGPoint(x: px, y: oy))
            ctx.addLine(to: CGPoint(x: px, y: oy + CGFloat(ROWS) * cell))
        }
        for y in 0...ROWS {
            let py = oy + CGFloat(y) * cell
            ctx.move(to: CGPoint(x: ox, y: py))
            ctx.addLine(to: CGPoint(x: ox + CGFloat(COLS) * cell, y: py))
        }
        ctx.strokePath()

        func cellRect(_ c: Cell, _ pad: CGFloat) -> CGRect {
            CGRect(x: ox + CGFloat(c.x) * cell + pad,
                   y: oy + CGFloat(c.y) * cell + pad,
                   width: cell - pad * 2, height: cell - pad * 2)
        }

        // obstáculos
        for o in obstacles {
            let r = cellRect(o, 1)
            fillGradRect(ctx, r, radius: cell * 0.22,
                         top: UIColor(r: 84, g: 110, b: 122), bottom: UIColor(r: 38, g: 50, b: 56))
            ctx.setStrokeColor(UIColor(r: 144, g: 164, b: 174).cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: r.minX + 5, y: r.minY + 4))
            ctx.addLine(to: CGPoint(x: r.maxX - 5, y: r.minY + 4))
            ctx.strokePath()
        }

        // frutas
        for i in 0..<FRUIT_SLOTS {
            guard let f = fruitPos[i] else { continue }
            let cx = ox + CGFloat(f.x) * cell + cell / 2
            let cy = oy + CGFloat(f.y) * cell + cell / 2

            // brilho radial
            let glowRGB = fruitKind[i] == 0 ? (244, 67, 54) : fruitKind[i] == 1 ? (171, 71, 188) : (255, 23, 68)
            let inner = UIColor(red: CGFloat(glowRGB.0) / 255, green: CGFloat(glowRGB.1) / 255,
                                blue: CGFloat(glowRGB.2) / 255, alpha: 0.28)
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [inner.cgColor, UIColor.clear.cgColor] as CFArray,
                                     locations: [0, 1]) {
                ctx.drawRadialGradient(grad,
                                       startCenter: CGPoint(x: cx, y: cy), startRadius: 1,
                                       endCenter: CGPoint(x: cx, y: cy), endRadius: 9 * u,
                                       options: [])
            }

            if fruitKind[i] == 0 {
                // maçã
                fillGradEllipse(ctx, CGRect(x: cx - 8 * u, y: cy - 5 * u, width: 16 * u, height: 13 * u),
                                top: UIColor(r: 239, g: 83, b: 80), bottom: UIColor(r: 183, g: 28, b: 28))
                ctx.setStrokeColor(UIColor(r: 121, g: 85, b: 72).cgColor)
                ctx.setLineWidth(2 * u)
                ctx.move(to: CGPoint(x: cx, y: cy - 4 * u))
                ctx.addLine(to: CGPoint(x: cx + 2 * u, y: cy - 9 * u))
                ctx.strokePath()
                UIColor(r: 102, g: 187, b: 106).setFill()
                UIBezierPath(ovalIn: CGRect(x: cx + 3 * u, y: cy - 11 * u, width: 7 * u, height: 4 * u)).fill()
                UIColor(white: 1, alpha: 0.35).setFill()
                UIBezierPath(ovalIn: CGRect(x: cx - 5 * u, y: cy - 2 * u, width: 5 * u, height: 3 * u)).fill()
            } else if fruitKind[i] == 1 {
                // uva — cacho
                UIColor(r: 156, g: 39, b: 176).setFill()
                let offs: [(CGFloat, CGFloat)] = [(-5,-3),(1,-3),(-2,1),(-5,4),(1,4),(-2,7)]
                for (ddx, ddy) in offs {
                    UIBezierPath(ovalIn: CGRect(x: cx + ddx * u - 4 * u,
                                                y: cy - 7 * u + ddy * u - 4 * u,
                                                width: 8 * u, height: 8 * u)).fill()
                }
                ctx.setStrokeColor(UIColor(r: 121, g: 85, b: 72).cgColor)
                ctx.setLineWidth(1.6 * u)
                ctx.move(to: CGPoint(x: cx - 2 * u, y: cy - 6 * u))
                ctx.addLine(to: CGPoint(x: cx - 4 * u, y: cy - 11 * u))
                ctx.strokePath()
                UIColor(r: 102, g: 187, b: 106).setFill()
                UIBezierPath(ovalIn: CGRect(x: cx - 4 * u, y: cy - 12 * u, width: 6 * u, height: 3 * u)).fill()
            } else {
                // cereja — cabinhos curvos + duas bolas
                ctx.setStrokeColor(UIColor(r: 93, g: 64, b: 55).cgColor)
                ctx.setLineWidth(1.6 * u)
                let stem = UIBezierPath()
                stem.move(to: CGPoint(x: cx, y: cy - 10 * u))
                stem.addCurve(to: CGPoint(x: cx - 4 * u, y: cy + 3 * u),
                              controlPoint1: CGPoint(x: cx - 6 * u, y: cy - 10 * u),
                              controlPoint2: CGPoint(x: cx - 7 * u, y: cy - 4 * u))
                stem.move(to: CGPoint(x: cx, y: cy - 10 * u))
                stem.addCurve(to: CGPoint(x: cx + 5 * u, y: cy + 3 * u),
                              controlPoint1: CGPoint(x: cx + 2 * u, y: cy - 8 * u),
                              controlPoint2: CGPoint(x: cx + 7 * u, y: cy - 4 * u))
                stem.stroke()
                UIColor(r: 229, g: 57, b: 53).setFill()
                UIBezierPath(ovalIn: CGRect(x: cx - 9 * u, y: cy - u, width: 10 * u, height: 10 * u)).fill()
                UIBezierPath(ovalIn: CGRect(x: cx, y: cy - u, width: 10 * u, height: 10 * u)).fill()
                UIColor(white: 1, alpha: 0.35).setFill()
                UIBezierPath(ovalIn: CGRect(x: cx - 6.5 * u, y: cy + 1.5 * u, width: 3 * u, height: 2 * u)).fill()
                UIBezierPath(ovalIn: CGRect(x: cx + 2.5 * u, y: cy + 1.5 * u, width: 3 * u, height: 2 * u)).fill()
            }
        }

        // cobra rosa — degradê da cauda à cabeça
        for i in stride(from: snake.count - 1, through: 0, by: -1) {
            let t = snake.count > 1 ? CGFloat(i) / CGFloat(snake.count - 1) : 0
            let body = lerp(pinkMid, pinkTail, t: t)
            let r = cellRect(snake[i], i == 0 ? 1 : 2)
            fillGradRect(ctx, r, radius: cell * 0.3, top: lerp(body, .white, t: 0.3), bottom: body)
        }

        // olhos
        if let head = snake.first {
            let cx = ox + CGFloat(head.x) * cell + cell / 2
            let cy = oy + CGFloat(head.y) * cell + cell / 2
            let fx = CGFloat(dir.x), fy = CGFloat(dir.y)
            let ppx = -fy, ppy = fx
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: cx + fx * 4 * u + ppx * 5 * u - 3.5 * u,
                                        y: cy + fy * 4 * u + ppy * 5 * u - 3.5 * u,
                                        width: 7 * u, height: 7 * u)).fill()
            UIBezierPath(ovalIn: CGRect(x: cx + fx * 4 * u - ppx * 5 * u - 3.5 * u,
                                        y: cy + fy * 4 * u - ppy * 5 * u - 3.5 * u,
                                        width: 7 * u, height: 7 * u)).fill()
            UIColor(r: 35, g: 35, b: 35).setFill()
            UIBezierPath(ovalIn: CGRect(x: cx + fx * 6 * u + ppx * 5 * u - 2 * u,
                                        y: cy + fy * 6 * u + ppy * 5 * u - 2 * u,
                                        width: 4 * u, height: 4 * u)).fill()
            UIBezierPath(ovalIn: CGRect(x: cx + fx * 6 * u - ppx * 5 * u - 2 * u,
                                        y: cy + fy * 6 * u - ppy * 5 * u - 2 * u,
                                        width: 4 * u, height: 4 * u)).fill()
        }

        // HUD
        let hudFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        ("Pontos: \(score)   Recorde: \(best)" as NSString).draw(
            at: CGPoint(x: 8, y: 6),
            withAttributes: [.font: hudFont, .foregroundColor: pinkMid])
        ("deslize move · toque pausa · maçã +1 · uva +2 · cereja +3" as NSString).draw(
            at: CGPoint(x: 8, y: 30),
            withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                             .foregroundColor: UIColor(r: 120, g: 128, b: 122)])

        // overlays
        if over || paused {
            UIColor(white: 0, alpha: 0.6).setFill()
            ctx.fill(bounds)
            let ps = NSMutableParagraphStyle()
            ps.alignment = .center
            let title = over ? "FIM DE JOGO" : (started ? "PAUSADO" : "COBRINHA")
            let sub = over ? "toque para jogar de novo — pontos: \(score)"
                           : "toque para \(started ? "continuar" : "começar") · deslize para mover"
            (title as NSString).draw(in: CGRect(x: 0, y: bounds.height / 2 - 44,
                                                width: bounds.width, height: 44),
                                     withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 30, weight: .bold),
                                                      .foregroundColor: pinkMid,
                                                      .paragraphStyle: ps])
            (sub as NSString).draw(in: CGRect(x: 0, y: bounds.height / 2 + 10,
                                              width: bounds.width, height: 30),
                                   withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                    .foregroundColor: pinkMid,
                                                    .paragraphStyle: ps])
        }
    }
}

extension UIColor {
    convenience init(r: Int, g: Int, b: Int) {
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

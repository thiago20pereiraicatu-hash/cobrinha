// linguagem: Swift 5, arquivo: Snake.swift, alvo: iOS 14+ (UIKit programatico, sem storyboard)
// v3: wrap nas bordas, cobra veste a cor da fruta, SFX + musica via AVAudioEngine (PCM sintetizado), tela de inicio
import UIKit
import AVFoundation

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

    // temas de cor — padrao rosa, depois veste a fruta
    private let THEME_HEAD: [UIColor] = [
        UIColor(r: 255, g: 138, b: 201),
        UIColor(r: 239, g: 99, b: 96),
        UIColor(r: 197, g: 138, b: 249),
        UIColor(r: 255, g: 158, b: 199)
    ]
    private let THEME_TAIL: [UIColor] = [
        UIColor(r: 214, g: 51, b: 108),
        UIColor(r: 183, g: 28, b: 28),
        UIColor(r: 106, g: 27, b: 154),
        UIColor(r: 194, g: 24, b: 91)
    ]

    private var snake: [Cell] = []
    private var obstacles: [Cell] = []
    private var queue: [Cell] = []
    private var fruitPos: [Cell?] = [nil, nil, nil]
    private var fruitKind: [Int] = [0, 0, 0]
    private var dir = Cell(x: 1, y: 0)
    private var score = 0, best = 0
    private var paused = true, over = false, started = false, menu = true
    private var theme = 0
    private var timer: Timer?
    private var anchor: CGPoint?
    private var moved = false

    private var headC: UIColor { THEME_HEAD[theme] }

    // ---------- audio (AVAudioEngine, PCM sintetizado) ----------

    private let engine = AVAudioEngine()
    private let nodeEat = AVAudioPlayerNode()
    private let nodeHit = AVAudioPlayerNode()
    private let nodeDie = AVAudioPlayerNode()
    private let nodeSel = AVAudioPlayerNode()
    private let nodeMusic = AVAudioPlayerNode()
    private var bufEat: AVAudioPCMBuffer?
    private var bufHit: AVAudioPCMBuffer?
    private var bufDie: AVAudioPCMBuffer?
    private var bufSel: AVAudioPCMBuffer?
    private var bufMusic: AVAudioPCMBuffer?
    private var audioReady = false
    private let SR = 44100.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(r: 8, g: 12, b: 9)
        best = UserDefaults.standard.integer(forKey: "cobrinha_best")
        prepareAudioGraph()
        reset(toMenu: true)
    }

    required init?(coder: NSCoder) { fatalError("sem storyboard") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // ondas basicas
    private func osc(_ kind: Int, _ f: Double, _ t: Double) -> Double {
        let ph = f * t
        switch kind {
        case 1: return sin(2 * .pi * ph) >= 0 ? 1 : -1      // quadrada
        case 2: return 2 * asin(sin(2 * .pi * ph)) / .pi // triangulo
        default: return sin(2 * .pi * ph)                   // seno
        }
    }

    private func renderBuffer(dur: Double, gen: (Double, inout UInt32) -> Float) -> AVAudioPCMBuffer? {
        let n = Int(dur * SR)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: SR, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        guard let p = buf.floatChannelData?[0] else { return nil }
        var seed: UInt32 = 8421
        for i in 0..<n {
            let v = max(-0.92, min(0.92, gen(Double(i) / SR, &seed)))
            p[i] = v
        }
        return buf
    }

    // nota com envelope de ataque/decaimento
    private func addNote(_ acc: inout [Float], _ s0: Int, _ d: Double, _ kind: Int, _ f: Double, _ v: Double) {
        let n = Int(d * SR)
        for i in 0..<n where s0 + i < acc.count {
            let t = Double(i) / SR
            var env = exp(-4 * t / d)
            if t < 0.005 { env *= t / 0.005 }
            acc[s0 + i] += Float(osc(kind, f, t) * v * env)
        }
    }

    private func makeBuf(dur: Double, build: (inout [Float]) -> Void) -> AVAudioPCMBuffer? {
        var acc = [Float](repeating: 0, count: Int(dur * SR))
        build(&acc)
        return renderBuffer(dur: dur) { t, _ in
            let i = Int(t * self.SR)
            return i < acc.count ? acc[i] : 0
        }
    }

    private func prepareAudioGraph() {
        // SFX
        bufEat = makeBuf(dur: 0.30) { acc in
            addNote(&acc, 0, 0.07, 1, 659, 0.5)
            addNote(&acc, Int(0.06 * SR), 0.07, 1, 880, 0.5)
            addNote(&acc, Int(0.12 * SR), 0.10, 1, 1319, 0.45)
        }
        bufSel = makeBuf(dur: 0.35) { acc in
            addNote(&acc, 0, 0.09, 2, 523.25, 0.5)
            addNote(&acc, Int(0.10 * SR), 0.16, 2, 784, 0.5)
        }
        bufHit = makeBuf(dur: 0.30) { acc in
            // queda seno grave + ruido
            var phase = 0.0
            let n = Int(0.25 * SR)
            for i in 0..<n {
                let rel = Double(i) / Double(n)
                phase += (160 + (50 - 160) * rel) / SR
                acc[i] += Float(sin(2 * .pi * phase) * 0.8 * (1 - rel))
            }
            var seed: UInt32 = 7
            let nn = Int(0.18 * SR)
            var lp = 0.0
            for i in 0..<nn {
                seed = seed &* 1664525 &+ 1013904223
                let white = (Double(seed >> 16) / 32768.0) - 1.0
                lp += 0.08 * (white - lp)
                acc[i] += Float(lp * 0.9 * exp(-6 * Double(i) / Double(nn)))
            }
        }
        bufDie = makeBuf(dur: 0.75) { acc in
            var phase = 0.0
            let n = Int(0.45 * SR)
            for i in 0..<n {
                let rel = Double(i) / Double(n)
                phase += (440 + (110 - 440) * rel) / SR
                let w: Double = sin(2 * .pi * phase) >= 0 ? 1 : -1
                acc[i] += Float(w * 0.5 * (1 - rel))
            }
            addNote(&acc, n, 0.25, 2, 110, 0.4)
            var seed: UInt32 = 11
            let nn = Int(0.55 * SR)
            var lp = 0.0
            for i in Int(0.40 * SR)..<nn {
                seed = seed &* 1664525 &+ 1013904223
                let white = (Double(seed >> 16) / 32768.0) - 1.0
                lp += 0.08 * (white - lp)
                acc[i] += Float(lp * 0.5 * exp(-6 * Double(i - Int(0.40 * SR)) / Double(nn - Int(0.40 * SR))))
            }
        }

        // musica: 16 tempos, grave quadrada + melodia triangulo + clique no compasso
        bufMusic = makeBuf(dur: 6.4) { acc in
            let bass: [Double] = [110,110,87.31,87.31,130.81,130.81,98,98,110,110,87.31,87.31,98,98,82.41,82.41]
            let lead: [Double] = [440,523.25,659.26,587.33,523.25,659.26,783.99,659.26,880,783.99,698.46,659.26,587.33,698.46,659.26,523.25]
            let q = 0.4
            for b in 0..<16 {
                addNote(&acc, Int(Double(b) * q * SR), q * 0.98, 1, bass[b], 0.30)
                addNote(&acc, Int(Double(b) * q * SR), q * 0.95, 2, lead[b], 0.24)
                if b % 4 == 0 {
                    var seed: UInt32 = UInt32(b + 1)
                    let s0 = Int(Double(b) * q * SR)
                    let nn = Int(0.05 * SR)
                    for i in 0..<nn where s0 + i < acc.count {
                        seed = seed &* 1664525 &+ 1013904223
                        let white = (Double(seed >> 16) / 32768.0) - 1.0
                        acc[s0 + i] += Float(white * 0.25 * (1.0 - Double(i) / Double(nn)))
                    }
                }
            }
        }
    }

    private func audioEnsureStarted() {
        guard !audioReady else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: .mixWithOthers)
        try? session.setActive(true)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: SR, channels: 1) else { return }
        for node in [nodeEat, nodeHit, nodeDie, nodeSel, nodeMusic] {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
        }
        nodeMusic.volume = 0.4
        engine.prepare()
        try? engine.start()
        audioReady = true
    }

    private func sfx(_ node: AVAudioPlayerNode, _ buf: AVAudioPCMBuffer?) {
        guard audioReady, let b = buf else { return }
        node.stop()
        node.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
        node.play()
    }

    private func musicStart() {
        guard audioReady, let b = bufMusic else { return }
        nodeMusic.stop()
        nodeMusic.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil)
        nodeMusic.play()
    }

    private func musicStop() {
        nodeMusic.stop()
    }

    // ---------- jogo ----------

    private func speed() -> TimeInterval { max(0.07, 0.16 - Double(score) * 0.002) }

    private func reset(toMenu: Bool) {
        snake = [Cell(x: 10, y: 10), Cell(x: 9, y: 10), Cell(x: 8, y: 10)]
        queue = []
        dir = Cell(x: 1, y: 0)
        score = 0
        paused = false
        over = false
        started = false
        menu = toMenu
        theme = 0
        makeObstacles()
        for i in 0..<FRUIT_SLOTS { spawnFruit(i) }
        setNeedsDisplay()
    }

    private func startGame() {
        menu = false
        started = true
        audioEnsureStarted()
        sfx(nodeSel, bufSel)
        musicStart()
        arm()
        setNeedsDisplay()
    }

    @objc func pauseGame() {
        if started && !over && !menu { paused = true }
        timer?.invalidate()
        nodeMusic.pause()
        setNeedsDisplay()
    }

    private func togglePause() {
        if over || menu { return }
        paused = !paused
        if !paused {
            arm()
            if audioReady && !nodeMusic.isPlaying { nodeMusic.play() }
        } else {
            timer?.invalidate()
            nodeMusic.pause()
        }
        setNeedsDisplay()
    }

    private func arm() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: speed(), target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: false)
    }

    @objc private func tick() {
        guard !paused, !over, !menu else { return }
        step()
        if !paused && !over { arm() }
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

    private func wrapX(_ x: Int) -> Int { ((x % COLS) + COLS) % COLS }
    private func wrapY(_ y: Int) -> Int { ((y % ROWS) + ROWS) % ROWS }

    private func step() {
        if !queue.isEmpty { dir = queue.removeFirst() }
        guard let h0 = snake.first else { return }
        let head = Cell(x: wrapX(h0.x + dir.x), y: wrapY(h0.y + dir.y)) // wrap nas bordas

        if obstacles.contains(head) { gameOver(selfCollision: false); return }
        if snake.contains(head) { gameOver(selfCollision: true); return }

        snake.insert(head, at: 0)
        var ate = -1
        for i in 0..<FRUIT_SLOTS where fruitPos[i] == head { ate = i; break }
        if ate >= 0 {
            score += FRUIT_POINTS[fruitKind[ate]]
            theme = fruitKind[ate] + 1 // veste a cor da fruta
            sfx(nodeEat, bufEat)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            spawnFruit(ate)
        } else {
            snake.removeLast()
        }
        setNeedsDisplay()
    }

    private func gameOver(selfCollision: Bool) {
        over = true
        timer?.invalidate()
        musicStop()
        sfx(selfCollision ? nodeDie : nodeHit, selfCollision ? bufDie : bufHit)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "cobrinha_best")
        }
        setNeedsDisplay()
    }

    // MARK: - toque

    private func turn(_ nd: Cell) {
        if over || menu { return }
        let last = queue.last ?? dir
        if (nd.x != -last.x || nd.y != -last.y) && queue.count < 2 { queue.append(nd) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        anchor = touches.first?.location(in: self)
        moved = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let a = anchor, let p = touches.first?.location(in: self) else { return }
        let dx = p.x - a.x, dy = p.y - a.y
        if max(abs(dx), abs(dy)) >= 24 {
            if menu { startGame(); anchor = p; moved = true; return }
            let c = abs(dx) > abs(dy)
                ? Cell(x: dx > 0 ? 1 : -1, y: 0)
                : Cell(x: 0, y: dy > 0 ? 1 : -1)
            turn(c)
            anchor = p // arrasto continuo
            moved = true
            if paused && !over { togglePause() }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !moved {
            if menu { startGame() }
            else if over { reset(toMenu: false); startGame() }
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
                // maca
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

        // cobra — degradê da cauda à cabeça na cor do tema
        for i in stride(from: snake.count - 1, through: 0, by: -1) {
            let t = snake.count > 1 ? CGFloat(i) / CGFloat(snake.count - 1) : 0
            let body = lerp(headC, THEME_TAIL[theme], t: t)
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
            withAttributes: [.font: hudFont, .foregroundColor: headC])
        ("deslize move · toque pausa · maçã +1 · uva +2 · cereja +3" as NSString).draw(
            at: CGPoint(x: 8, y: 30),
            withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                             .foregroundColor: UIColor(r: 120, g: 128, b: 122)])

        // overlays
        if menu {
            UIColor(white: 0.03, alpha: 0.78).setFill()
            ctx.fill(bounds)
            let ps = NSMutableParagraphStyle()
            ps.alignment = .center
            let w = bounds.width, h = bounds.height
            ("COBRINHA" as NSString).draw(
                in: CGRect(x: 0, y: h / 2 - 150, width: w, height: 60),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 44, weight: .bold),
                                 .foregroundColor: headC, .paragraphStyle: ps])
            ("maçã +1 · uva +2 · cereja +3" as NSString).draw(
                in: CGRect(x: 0, y: h / 2 - 66, width: w, height: 24),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                 .foregroundColor: UIColor(r: 200, g: 230, b: 201), .paragraphStyle: ps])
            ("a cobra veste a cor da fruta que come" as NSString).draw(
                in: CGRect(x: 0, y: h / 2 - 34, width: w, height: 20),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                 .foregroundColor: UIColor(r: 150, g: 158, b: 152), .paragraphStyle: ps])
            ("as bordas levam para o outro lado" as NSString).draw(
                in: CGRect(x: 0, y: h / 2 - 10, width: w, height: 20),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                 .foregroundColor: UIColor(r: 150, g: 158, b: 152), .paragraphStyle: ps])
            ("TOQUE PARA COMEÇAR" as NSString).draw(
                in: CGRect(x: 0, y: h / 2 + 55, width: w, height: 30),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 15, weight: .bold),
                                 .foregroundColor: headC, .paragraphStyle: ps])
            ("recorde: \(best)" as NSString).draw(
                in: CGRect(x: 0, y: h / 2 + 118, width: w, height: 18),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                 .foregroundColor: UIColor(r: 120, g: 128, b: 122), .paragraphStyle: ps])
        } else if over || paused {
            UIColor(white: 0, alpha: 0.6).setFill()
            ctx.fill(bounds)
            let ps = NSMutableParagraphStyle()
            ps.alignment = .center
            let title = over ? "FIM DE JOGO" : "PAUSADO"
            let sub = over ? "toque para jogar de novo — pontos: \(score)"
                           : "toque para continuar"
            (title as NSString).draw(in: CGRect(x: 0, y: bounds.height / 2 - 44,
                                                width: bounds.width, height: 44),
                                     withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 30, weight: .bold),
                                                      .foregroundColor: headC,
                                                      .paragraphStyle: ps])
            (sub as NSString).draw(in: CGRect(x: 0, y: bounds.height / 2 + 10,
                                              width: bounds.width, height: 30),
                                   withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                    .foregroundColor: headC,
                                                    .paragraphStyle: ps])
        }
    }
}

extension UIColor {
    convenience init(r: Int, g: Int, b: Int) {
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

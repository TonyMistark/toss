import AppKit
import SwiftUI

/// 全窗口共用的坐标空间；机器卡片的篮筐位置和鼠标位置都在这套坐标里换算。
enum TossSpace {
    static let root = "toss.root"
}

/// 当前悬停的篮筐：哪台机器、第几个文件夹、篮筐中心在窗口里的位置。
struct BasketHover: Equatable {
    let targetID: String
    let basket: Int
    let anchor: CGPoint
}

/// 展开的篮筐在窗口里的位置，用来算「拉弓」射线打不打得中。
struct BasketAim: Equatable {
    let anchor: CGPoint
    let rect: CGRect
}

/// 一台展开后可投篮的机器。
struct MachineAim: Equatable {
    let targetID: String
    let cardFrame: CGRect
    let baskets: [BasketAim]
}

/// 松手后要真正投出去：数据、机器、第几个文件夹。
struct LaunchRequest {
    let payload: ThrowPayload
    let targetID: String
    let basket: Int
}

/// 一次投篮的结果，用来把文件沿弧线送出去，并在落点播放投中 / 没投中的特效。
struct ShotResult: Equatable {
    enum Kind: Equatable {
        case scored
        case missed
    }

    let kind: Kind
    /// 出手的位置；没投中时为空，只播落点特效。
    let from: CGPoint
    /// 落点：篮筐中心，或没投中时松开的位置。
    let point: CGPoint
    /// 松手时的拖动距离，决定球飞得多高。
    let power: CGFloat
    let label: String
    let date: Date

    var duration: TimeInterval {
        kind == .scored ? 1.0 : 0.8
    }
}

/// 一次拖拽的现场。
/// 所有投篮的方向都由「固定的中心点 → 鼠标」这条线决定；鼠标往哪边拉，球就往反方向飞。
/// 拖动中只画瞄准弧，真正出手后才让文件沿弧线飞。
final class DragSession: ObservableObject {
    @Published private(set) var isDragging = false
    @Published private(set) var hover: BasketHover?
    @Published private(set) var shot: ShotResult?
    /// 松开后射线穿过篮筐时发出的一次投递请求，由界面层去执行。
    @Published private(set) var launch: LaunchRequest?
    /// 当前射线指中的篮筐（每帧由定时器刷新），用来把目标文件夹画成蓝色描边框。
    @Published private(set) var aim: ShotAim.Result?

    /// 拖动开始时的鼠标位置。
    private(set) var origin: CGPoint = .zero
    /// 最近一次轮询到的鼠标位置，只用于松手兜底，不参与视图刷新。
    private(set) var pointer: CGPoint?
    /// 被拖动文件的名字，出手后写在飞行的小胶囊上；也用来给源文件行画蓝框。
    private(set) var projectile = ""
    /// 被拖动文件所在的目录，配合名字判断是哪一行在拖。
    private(set) var draggingDir = ""

    private var payload: ThrowPayload?
    private var aims: [String: MachineAim] = [:]
    private var timer: Timer?
    private var pendingMiss: DispatchWorkItem?
    private var shotClear: DispatchWorkItem?

    func begin(name: String, payload: ThrowPayload) {
        shotClear?.cancel()
        shotClear = nil
        pendingMiss?.cancel()
        pendingMiss = nil
        shot = nil
        launch = nil

        projectile = name
        draggingDir = payload.sourceDir
        self.payload = payload
        origin = rootPointer() ?? .zero
        hover = nil
        pointer = nil
        aim = nil
        aims = [:]
        isDragging = true
        startTicking()
    }

    func updateHover(targetID: String, basket: Int, anchor: CGPoint) {
        let next = BasketHover(targetID: targetID, basket: basket, anchor: anchor)
        if hover != next {
            hover = next
        }
    }

    func clearHover(targetID: String) {
        guard hover?.targetID == targetID else { return }
        hover = nil
    }

    /// 展开的卡片把自己篮筐的位置报进来；收起时传 nil。
    func setAim(targetID: String, _ aim: MachineAim?) {
        if let aim {
            aims[targetID] = aim
        } else {
            aims.removeValue(forKey: targetID)
        }
    }

    /// 指针在窗口里的实时位置；弧线每帧读它，鼠标一动线就跟着动。
    func currentPointer() -> CGPoint? {
        rootPointer()
    }

    /// 投篮方向用的固定中心点：窗口内容区的正中心。
    func centerPoint() -> CGPoint? {
        guard let content = activeWindow?.contentView else { return nil }
        return CGPoint(x: content.bounds.midX, y: content.bounds.midY)
    }

    /// 机器栏里篮筐所在的那一层，瞄准弧飞到这里为止，而不是贴到具体篮筐上。
    func basketHorizon() -> CGFloat? {
        aims.values.flatMap(\.baskets).map(\.rect.maxY).max()
    }

    /// 当前拉弓射线指向的篮筐；射线没穿过篮筐时也会给最近的篮筐（hit = false）。
    func currentAim() -> ShotAim.Result? {
        guard let mouse = rootPointer(), let center = centerPoint() else { return nil }
        let power = distance(mouse, origin)
        return ShotAim.aim(from: mouse, through: center, power: power, among: Array(aims.values))
    }

    /// 投进了：篮筐位置放一圈绿色特效。
    func finishScored(at point: CGPoint) {
        let power = max(distance(pointer ?? origin, origin), 60)
        finish(kind: .scored, from: origin, point: point, power: power)
    }

    /// 没投进：在指针位置（或最后一个悬停点）放一个红色特效。
    func finishMissed(at point: CGPoint?) {
        finish(kind: .missed, from: .zero,
               point: point ?? pointer ?? hover?.anchor ?? .zero, power: 0)
    }

    /// 松开：按拉弓射线判投中 / 没投中，投中就发出一项真实的投递。
    private func finishReleased(at point: CGPoint?) {
        guard isDragging else { return }
        pendingMiss?.cancel()
        pendingMiss = nil

        let released = point ?? pointer ?? origin
        let power = distance(released, origin)
        let hovered = hover.map {
            ShotAim.Result(targetID: $0.targetID, basket: $0.basket, anchor: $0.anchor, hit: true)
        }
        let aimed: ShotAim.Result?
        if let center = centerPoint() {
            aimed = ShotAim.aim(from: released, through: center, power: power,
                                among: Array(aims.values))
        } else {
            aimed = nil
        }
        let aim = hovered ?? aimed
        let payload = self.payload

        endDrag()

        if let aim, aim.hit, let payload {
            launch = LaunchRequest(payload: payload, targetID: aim.targetID, basket: aim.basket)
            show(ShotResult(kind: .scored, from: released, point: aim.anchor, power: power,
                            label: projectile, date: Date()))
        } else {
            show(ShotResult(kind: .missed, from: .zero, point: released, power: 0,
                            label: projectile, date: Date()))
        }
    }

    private func finish(kind: ShotResult.Kind, from: CGPoint, point: CGPoint, power: CGFloat) {
        guard isDragging else { return }
        pendingMiss?.cancel()
        pendingMiss = nil
        endDrag()
        show(ShotResult(kind: kind, from: from, point: point, power: power,
                        label: projectile, date: Date()))
    }

    private func endDrag() {
        isDragging = false
        hover = nil
        aim = nil
        stopTicking()
        aims = [:]
    }

    private func show(_ result: ShotResult) {
        shot = result

        shotClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shot == result else { return }
            self.shot = nil
        }
        shotClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + result.duration, execute: work)
    }

    // MARK: - 松手兜底

    private func startTicking() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
        pointer = nil
    }

    private func tick() {
        pointer = rootPointer()
        guard isDragging else { return }

        let next = aimedBasket()
        if aim != next {
            aim = next
        }

        if NSEvent.pressedMouseButtons == 0 {
            scheduleMiss()
        }
    }

    /// 用最新指针算一次射线命中，供机器栏把目标文件夹画成蓝框。
    private func aimedBasket() -> ShotAim.Result? {
        guard let mouse = pointer, let center = centerPoint() else { return nil }
        let power = distance(mouse, origin)
        return ShotAim.aim(from: mouse, through: center, power: power,
                           among: Array(aims.values))
    }

    /// 松手和投递回调可能在同一轮 runloop 里赛跑，给投递留一点时间再判没投中。
    private func scheduleMiss() {
        guard pendingMiss == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isDragging else { return }
            self.pendingMiss = nil
            self.finishReleased(at: self.pointer)
        }
        pendingMiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private var activeWindow: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
    }

    private func rootPointer() -> CGPoint? {
        guard let window = activeWindow, let content = window.contentView else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inContent = content.convert(inWindow, from: nil)
        let y = content.isFlipped ? inContent.y : content.bounds.height - inContent.y
        return CGPoint(x: inContent.x, y: y)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
}

// MARK: - 拉弓瞄准

enum ShotAim {
    struct Result: Equatable {
        let targetID: String
        let basket: Int
        let anchor: CGPoint
        let hit: Bool
    }

    /// 拉得太短不算一次投篮，避免误触。
    static let minPull: CGFloat = 20
    /// 同一台机器有多个文件夹时，每多拉这么远就换到下一个文件夹（仅竖直射线的兜底）。
    static let bandPull: CGFloat = 55

    /// 拖动距离落在第几个文件夹：拉得越远落点越高（越靠上）。
    /// 只在射线几乎竖直、没法用交点高度区分时使用。
    static func bandIndex(power: CGFloat, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let raw = Int((power - minPull) / bandPull)
        return max(0, count - 1 - min(max(raw, 0), count - 1))
    }

    /// 射线穿过机器那一列时，用它与卡片中线的交点高度挑文件夹：
    /// 指到哪一层就选哪一层，想换目标只要微调角度，不用改变拉弓力度。
    static func folderIndex(from mouse: CGPoint, direction: CGPoint,
                            machine: MachineAim, power: CGFloat) -> Int {
        let count = machine.baskets.count
        guard count > 1 else { return 0 }
        guard abs(direction.x) > 0.02 else {
            return bandIndex(power: power, count: count)
        }
        let midX = machine.cardFrame.midX
        let t = (midX - mouse.x) / direction.x
        guard t > 0 else { return bandIndex(power: power, count: count) }
        let crossingY = mouse.y + direction.y * t
        var best = 0
        var bestGap = CGFloat.greatestFiniteMagnitude
        for (index, basket) in machine.baskets.enumerated() {
            let gap = abs(basket.anchor.y - crossingY)
            if gap < bestGap {
                best = index
                bestGap = gap
            }
        }
        return best
    }

    /// 从鼠标沿着「鼠标 → 中心点」的方向往外射一条直线：
    /// 穿过某台机器的篮筐就算选中这台机器，再用射线穿过那一列的高度挑第几个文件夹；
    /// 一台都没穿过就退而求其次，给最近的篮筐，但算没投中。
    static func aim(from mouse: CGPoint, through center: CGPoint, power: CGFloat,
                    among aims: [MachineAim]) -> Result? {
        let dx = center.x - mouse.x
        let dy = center.y - mouse.y
        let span = sqrt(dx * dx + dy * dy)
        guard power >= minPull, span > 0, !aims.isEmpty else { return nil }
        let direction = CGPoint(x: dx / span, y: dy / span)

        // 同一台机器的文件夹是竖着一列排的，一条射线会同时穿过整列；
        // 所以先用射线挑中「离得最近的那台机器」，再用拖动距离在同机的文件夹之间切换。
        var machineHit: (distance: CGFloat, machine: MachineAim)?
        for machine in aims {
            var nearest: CGFloat?
            for basket in machine.baskets {
                guard let distance = rayDistance(from: mouse, direction: direction, rect: basket.rect)
                else { continue }
                nearest = min(nearest ?? distance, distance)
            }
            guard let distance = nearest else { continue }
            if machineHit == nil || distance < machineHit!.distance {
                machineHit = (distance, machine)
            }
        }
        if let machineHit {
            let machine = machineHit.machine
            let index = folderIndex(from: mouse, direction: direction,
                                    machine: machine, power: power)
            return Result(targetID: machine.targetID, basket: index,
                          anchor: machine.baskets[index].anchor, hit: true)
        }

        var nearest: (offset: CGFloat, result: Result)?
        for machine in aims {
            for (index, basket) in machine.baskets.enumerated() {
                let vx = basket.anchor.x - mouse.x
                let vy = basket.anchor.y - mouse.y
                let forward = vx * direction.x + vy * direction.y
                guard forward > 0 else { continue }
                let offset = abs(vx * direction.y - vy * direction.x)
                if nearest == nil || offset < nearest!.offset {
                    nearest = (offset, Result(targetID: machine.targetID, basket: index,
                                              anchor: basket.anchor, hit: false))
                }
            }
        }
        return nearest?.result
    }

    /// 射线与矩形的交点距离；slab 法，起点在矩形里也算。
    static func rayDistance(from origin: CGPoint, direction: CGPoint, rect: CGRect) -> CGFloat? {
        var tMin: CGFloat = 0
        var tMax = CGFloat.greatestFiniteMagnitude
        let axes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (origin.x, direction.x, rect.minX, rect.maxX),
            (origin.y, direction.y, rect.minY, rect.maxY),
        ]
        for (o, d, low, high) in axes {
            if abs(d) < 1e-9 {
                if o < low || o > high { return nil }
                continue
            }
            var first = (low - o) / d
            var second = (high - o) / d
            if first > second { swap(&first, &second) }
            tMin = max(tMin, first)
            tMax = min(tMax, second)
            if tMin > tMax { return nil }
        }
        return tMax > 0 ? max(tMin, 0) : nil
    }
}

// MARK: - 投篮弧

/// 投篮弧的纯几何。
enum ShotArc {
    struct Curve: Equatable {
        let start: CGPoint
        let control: CGPoint
        let end: CGPoint
    }

    /// 拖动时的瞄准弧：顺着拉弓方向飞出去，落到机器栏那一层就停，
    /// 不往任何具体篮筐上贴——打不打中由射线另外判断。
    static func preview(from mouse: CGPoint, direction: CGPoint, horizon: CGFloat,
                        power: CGFloat) -> Curve {
        let reach = max(power * 1.8, 90)
        let end: CGPoint
        if direction.y < -0.001 {
            let t = (horizon - mouse.y) / direction.y
            if t > 0 {
                end = CGPoint(x: mouse.x + direction.x * t, y: horizon)
            } else {
                end = CGPoint(x: mouse.x + direction.x * reach, y: mouse.y + direction.y * reach)
            }
        } else {
            end = CGPoint(x: mouse.x + direction.x * reach, y: mouse.y + direction.y * reach)
        }
        return arc(from: mouse, to: end, power: power)
    }

    /// 出手之后：从松开的位置飞向篮筐，弧顶高过两端，像真正的投篮。
    static func shot(from mouse: CGPoint, to basket: CGPoint, power: CGFloat) -> Curve {
        arc(from: mouse, to: basket, power: power)
    }

    static func point(_ curve: Curve, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * curve.start.x + 2 * mt * t * curve.control.x + t * t * curve.end.x,
            y: mt * mt * curve.start.y + 2 * mt * t * curve.control.y + t * t * curve.end.y
        )
    }

    static func path(_ curve: Curve) -> Path {
        var path = Path()
        path.move(to: curve.start)
        path.addQuadCurve(to: curve.end, control: curve.control)
        return path
    }

    private static func arc(from start: CGPoint, to end: CGPoint, power: CGFloat) -> Curve {
        let floor = min(start.y, end.y)
        // 弧顶高度直接跟着拖动距离走：轻轻一拉就抬起来，拉得越远顶越高；
        // 只留一点余量，保证弧顶还在窗口里，不再被两端最低点压扁。
        let wanted = 64 + power * 1.25
        let rise = min(wanted, max(12, floor - 16))
        let apex = floor - rise
        // 二次贝塞尔的最低点（即最高的弧顶）恰好落在 apex 时，控制点 y 的闭式解。
        let controlY = apex - sqrt(max(0, (start.y - apex) * (end.y - apex)))
        return Curve(start: start, control: CGPoint(x: (start.x + end.x) / 2, y: controlY), end: end)
    }
}

// MARK: - 覆盖层

/// 整个窗口的兜底投递口：投篮松手时由它决定系统要不要播放「文件飞回原位」的动画。
/// 射线投中就接受投放（系统不再回弹，由我们自己的飞行/特效接管）；
/// 没投中才拒绝，让系统把文件缩回原位。
struct WindowDropDelegate: DropDelegate {
    let drag: DragSession

    func validateDrop(info: DropInfo) -> Bool {
        drag.isDragging
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    /// 只决定「接不接受」，真正的传输由 DragSession 的出手流程发起。
    func performDrop(info: DropInfo) -> Bool {
        drag.currentAim()?.hit == true
    }
}

/// 覆盖在整个窗口上的投篮层：拖动时只有瞄准弧和中心点，
/// 真正出手后才让文件沿弧线飞，并在落点播放投中 / 没投中的特效。
struct ShotArcOverlay: View {
    @ObservedObject var drag: DragSession

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, _ in
                drawDrag(&context, at: timeline.date)
                drawShot(&context, at: timeline.date)
            }
        }
        .allowsHitTesting(false)
    }

    /// 拖动中：中心点 + 顺着拉弓方向拱出去的瞄准弧，不画文件。
    private func drawDrag(_ context: inout GraphicsContext, at now: Date) {
        guard drag.isDragging,
              let mouse = drag.currentPointer(),
              let center = drag.centerPoint()
        else { return }

        let power = distance(mouse, drag.origin)
        guard power >= ShotAim.minPull else { return }

        let dx = center.x - mouse.x
        let dy = center.y - mouse.y
        let span = sqrt(dx * dx + dy * dy)
        guard span > 0 else { return }
        let direction = CGPoint(x: dx / span, y: dy / span)
        let aim = drag.currentAim()
        let hit = aim?.hit ?? false
        // 命中时弧线直接收到目标文件夹：拉得越远，落点越高。
        // 没命中时仍然按方向飞到机器栏那一层就停。
        let curve: ShotArc.Curve
        if let aim, aim.hit {
            curve = ShotArc.shot(from: mouse, to: aim.anchor, power: power)
        } else {
            let horizon = drag.basketHorizon() ?? (mouse.y - 160)
            curve = ShotArc.preview(from: mouse, direction: direction,
                                    horizon: horizon, power: power)
        }
        let color = hit ? Brand.green : Color.secondary

        // 固定的中心点：所有投篮的方向都是从这里到鼠标。
        let pivot = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: pivot), with: .color(Brand.green.opacity(0.28)))

        context.stroke(
            ShotArc.path(curve),
            with: .color(color.opacity(hit ? 0.42 : 0.24)),
            style: StrokeStyle(lineWidth: 2, dash: hit ? [7, 5] : [4, 4])
        )
    }

    private func drawShot(_ context: inout GraphicsContext, at now: Date) {
        guard let shot = drag.shot else { return }
        let elapsed = now.timeIntervalSince(shot.date)
        guard elapsed >= 0, elapsed < shot.duration else { return }

        switch shot.kind {
        case .scored:
            drawScored(shot, elapsed: elapsed, in: &context)
        case .missed:
            drawMissed(shot, elapsed: elapsed, in: &context)
        }
    }

    /// 投中：文件顺着弧线飞进篮筐，然后两圈绿环 + 放射光条。
    private func drawScored(_ shot: ShotResult, elapsed: TimeInterval, in context: inout GraphicsContext) {
        let point = shot.point

        if shot.from != .zero {
            let curve = ShotArc.shot(from: shot.from, to: point, power: shot.power)
            let flight = clamp(elapsed / 0.34)
            let t = CGFloat(1 - pow(1 - flight, 2))

            context.stroke(
                ShotArc.path(curve),
                with: .color(Brand.green.opacity(0.22 * (1 - flight))),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
            drawProjectile(shot.label, at: ShotArc.point(curve, t: t), color: Brand.green, in: &context)
        }

        for delay in [0.30, 0.44] {
            let progress = clamp((elapsed - delay) / 0.55)
            guard progress < 1 else { continue }
            let radius = CGFloat(9 + 26 * progress)
            let ring = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            context.stroke(
                Path(ellipseIn: ring),
                with: .color(Brand.green.opacity(0.55 * (1 - progress))),
                style: StrokeStyle(lineWidth: 2)
            )
        }

        let burst = clamp((elapsed - 0.30) / 0.45)
        if burst > 0, burst < 1 {
            for index in 0..<8 {
                let angle = Double(index) / 8 * .pi * 2 + .pi / 8
                let inner = CGFloat(10 + 8 * burst)
                let outer = CGFloat(16 + 18 * burst)
                var line = Path()
                line.move(to: CGPoint(x: point.x + CGFloat(cos(angle)) * inner,
                                      y: point.y + CGFloat(sin(angle)) * inner))
                line.addLine(to: CGPoint(x: point.x + CGFloat(cos(angle)) * outer,
                                         y: point.y + CGFloat(sin(angle)) * outer))
                context.stroke(
                    line,
                    with: .color(Brand.green.opacity(0.7 * (1 - burst))),
                    style: StrokeStyle(lineWidth: 1.5)
                )
            }
        }
    }

    /// 没投中：红圈缩下去 + 一个叉 + 文件掉到一边。
    private func drawMissed(_ shot: ShotResult, elapsed: TimeInterval, in context: inout GraphicsContext) {
        let point = shot.point

        let drop = clamp((elapsed - 0.12) / 0.5)
        if drop > 0, drop < 1 {
            drawProjectile(
                shot.label,
                at: CGPoint(x: point.x - CGFloat(34 * drop), y: point.y + CGFloat(46 * drop * drop)),
                color: Brand.miss.opacity(1 - drop),
                in: &context
            )
        }

        let shrink = clamp(elapsed / 0.35)
        if shrink < 1 {
            let radius = CGFloat(18 - 11 * shrink)
            let ring = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            context.stroke(
                Path(ellipseIn: ring),
                with: .color(Brand.miss.opacity(0.7 * (1 - shrink))),
                style: StrokeStyle(lineWidth: 2)
            )
        }

        let cross = clamp(elapsed / 0.3)
        if cross < 1 {
            let arm = CGFloat(7 + 6 * cross)
            var path = Path()
            path.move(to: CGPoint(x: point.x - arm, y: point.y - arm))
            path.addLine(to: CGPoint(x: point.x + arm, y: point.y + arm))
            path.move(to: CGPoint(x: point.x + arm, y: point.y - arm))
            path.addLine(to: CGPoint(x: point.x - arm, y: point.y + arm))
            context.stroke(
                path,
                with: .color(Brand.miss.opacity(0.8 * (1 - cross))),
                style: StrokeStyle(lineWidth: 2)
            )
        }
    }

    /// 出手后：写着文件名的小胶囊沿弧线飞。
    private func drawProjectile(
        _ label: String,
        at point: CGPoint,
        color: Color,
        in context: inout GraphicsContext
    ) {
        let name = label.isEmpty ? "•" : String(label.prefix(10))
        let width: CGFloat = 62
        let height: CGFloat = 17
        let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
        context.fill(
            Path(roundedRect: rect, cornerRadius: 6),
            with: .color(color.opacity(0.92))
        )
        context.draw(
            Text(name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white),
            at: CGPoint(x: point.x, y: point.y)
        )
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

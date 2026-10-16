import UIKit

/// 进度点上方的迷你星球：黑白灰液态玻璃质感。
/// 球面上的经线按球面投影逐帧计算（从一侧边缘出现、正面最宽、另一侧消失），能清楚看出在缓慢自转；
/// 外面一圈细环，一道带拖尾的亮光沿环公转，还有一颗小卫星绕行（经过球后面时被挡住）。
final class PlanetMarkView: UIView {
    static let size = CGSize(width: 30, height: 22)
    private static let sphere: CGFloat = 16
    /// 自转一圈的秒数
    private static let period: CFTimeInterval = 12
    private static let meridians = 6
    /// 环带公转一圈的秒数
    private static let orbitPeriod: CFTimeInterval = 9
    private static let ringTilt: CGFloat = -0.3

    /// 每组：细环底线 + 拖尾（长、淡）+ 亮光头（短、亮）+ 小卫星；后组只显示上半圈（在球后），前组只显示下半圈
    private let backGroup = CALayer()
    private let frontGroup = CALayer()
    private var trailLayers: [CAShapeLayer] = []
    private var moonLayers: [CAShapeLayer] = []
    private var ringEllipse = CGPath(rect: .zero, transform: nil)
    private let body = CAGradientLayer()
    private let lines = CAShapeLayer()
    private let equator = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let highlight = CAGradientLayer()
    private var displayLink: CADisplayLink?
    private let start = CACurrentMediaTime()

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        isUserInteractionEnabled = false

        let d = Self.sphere
        let sphereRect = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)

        // 行星环：倾斜的细椭圆；路径绕两圈，方便用 strokeStart/End 做跨过起点的亮光
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var tilt = CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: Self.ringTilt))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
        let oval = CGRect(x: c.x - 14, y: c.y - 3.2, width: 28, height: 6.4)
        ringEllipse = CGPath(ellipseIn: oval, transform: &tilt)
        let twice = CGMutablePath()
        twice.addPath(ringEllipse)
        twice.addPath(ringEllipse)
        for (group, front) in [(backGroup, false), (frontGroup, true)] {
            group.frame = bounds
            let mask = CALayer()
            mask.backgroundColor = UIColor.black.cgColor
            mask.frame = front ? CGRect(x: 0, y: bounds.midY, width: bounds.width, height: bounds.midY)
                               : CGRect(x: 0, y: 0, width: bounds.width, height: bounds.midY)
            group.mask = mask
            let dim: Float = front ? 1 : 0.45
            // 细环底线
            let base = CAShapeLayer()
            base.frame = bounds
            base.path = ringEllipse
            base.fillColor = nil
            base.lineWidth = 0.7
            base.strokeColor = UIColor(white: 1, alpha: 0.4).cgColor
            base.opacity = dim
            group.addSublayer(base)
            // 拖尾和亮光头
            for (width, alpha) in [(CGFloat(1.4), CGFloat(0.35)), (1.6, 0.6), (1.9, 1.0)] {
                let trail = CAShapeLayer()
                trail.frame = bounds
                trail.path = twice
                trail.fillColor = nil
                trail.lineWidth = width
                trail.lineCap = .round
                trail.strokeColor = UIColor(white: 1, alpha: alpha).cgColor
                trail.shadowColor = UIColor.white.cgColor
                trail.shadowOpacity = alpha >= 1 ? 0.9 : 0
                trail.shadowRadius = 1.5
                trail.shadowOffset = .zero
                trail.opacity = dim
                group.addSublayer(trail)
                trailLayers.append(trail)
            }
            // 小卫星
            let moon = CAShapeLayer()
            moon.frame = bounds
            moon.fillColor = UIColor(white: 1, alpha: 0.95).cgColor
            moon.opacity = dim
            group.addSublayer(moon)
            moonLayers.append(moon)
        }

        // 玻璃球体：半透明灰白，左上亮、右下暗
        body.type = .radial
        body.frame = sphereRect
        body.cornerRadius = d / 2
        body.masksToBounds = true
        body.startPoint = CGPoint(x: 0.35, y: 0.3)
        body.endPoint = CGPoint(x: 1.05, y: 1.05)
        body.colors = [UIColor(white: 1, alpha: 0.42).cgColor, UIColor(white: 0.7, alpha: 0.18).cgColor, UIColor(white: 0.1, alpha: 0.35).cgColor]
        body.locations = [0, 0.55, 1]

        // 经线和赤道：画在球体坐标里
        for l in [lines, equator] {
            l.frame = sphereRect
            l.fillColor = nil
            l.lineWidth = 0.6
            l.lineCap = .round
        }
        lines.strokeColor = UIColor(white: 1, alpha: 0.6).cgColor
        equator.strokeColor = UIColor(white: 1, alpha: 0.35).cgColor
        equator.path = UIBezierPath(ovalIn: CGRect(x: 0.5, y: d / 2 - 1.6, width: d - 1, height: 3.2)).cgPath
        let clip = CAShapeLayer()
        clip.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: d, height: d)).cgPath
        lines.mask = clip

        // 玻璃亮边 + 高光
        rim.frame = sphereRect
        rim.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: d, height: d).insetBy(dx: 0.4, dy: 0.4)).cgPath
        rim.fillColor = nil
        rim.lineWidth = 0.8
        rim.strokeColor = UIColor(white: 1, alpha: 0.85).cgColor
        rim.shadowColor = UIColor.black.cgColor
        rim.shadowOpacity = 0.35
        rim.shadowRadius = 2
        rim.shadowOffset = .zero
        highlight.type = .radial
        highlight.frame = CGRect(x: sphereRect.minX + d * 0.18, y: sphereRect.minY + d * 0.12, width: d * 0.4, height: d * 0.3)
        highlight.startPoint = CGPoint(x: 0.5, y: 0.5)
        highlight.endPoint = CGPoint(x: 1, y: 1)
        highlight.colors = [UIColor(white: 1, alpha: 0.8).cgColor, UIColor(white: 1, alpha: 0).cgColor]

        for l in [backGroup, body, lines, equator, rim, highlight, frontGroup] { layer.addSublayer(l) }
        updateMeridians()
        updateRing()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard alpha > 0.01, window != nil else { return }
        updateMeridians()
        updateRing()
    }

    /// 亮光沿环公转：在“绕两圈”的路径上滑动 strokeStart/End 窗口；小卫星按参数方程绕行
    private func updateRing() {
        let t = CACurrentMediaTime() - start
        let p = CGFloat((t / Self.orbitPeriod).truncatingRemainder(dividingBy: 1))
        // 三层窗口：拖尾 0.22 圈、中段 0.1 圈、亮光头 0.035 圈，头部对齐
        let lengths: [CGFloat] = [0.22, 0.1, 0.035]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, layer) in trailLayers.enumerated() {
            let len = lengths[i % 3]
            let head = p + 1          // 落在第二圈，窗口不会跨出路径
            layer.strokeStart = (head - len) / 2
            layer.strokeEnd = head / 2
        }
        // 小卫星：比亮光慢一些，反向参数
        let a = -t / (Self.orbitPeriod * 1.6) * 2 * .pi + 1.2
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var pos = CGPoint(x: c.x + 15.2 * CGFloat(cos(a)), y: c.y + 3.6 * CGFloat(sin(a)))
        pos = pos.applying(CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: Self.ringTilt))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
        let moon = CGPath(ellipseIn: CGRect(x: pos.x - 0.9, y: pos.y - 0.9, width: 1.8, height: 1.8), transform: nil)
        moonLayers.forEach { $0.path = moon }
        CATransaction.commit()
    }

    /// 经度 θ 的经线在正面投影成半个椭圆，横向半径 = r·|sin θ|；只画朝向我们的（cos θ > 0）
    private func updateMeridians() {
        let r = Self.sphere / 2
        let phase = (CACurrentMediaTime() - start) / Self.period * 2 * .pi
        let path = UIBezierPath()
        for k in 0..<Self.meridians {
            let theta = phase + Double(k) / Double(Self.meridians) * 2 * .pi
            guard cos(theta) > 0.02 else { continue }
            let rx = r * CGFloat(abs(sin(theta)))
            if rx < 0.3 {
                path.move(to: CGPoint(x: r, y: 0))
                path.addLine(to: CGPoint(x: r, y: r * 2))
            } else {
                // 椭圆参数方程画半边：sin θ ≥ 0 在右半边，否则左半边
                let steps = 16
                for i in 0...steps {
                    let t = -Double.pi / 2 + Double(i) / Double(steps) * .pi
                    let x = r + CGFloat(sin(theta) >= 0 ? cos(t) : -cos(t)) * rx
                    let y = r + CGFloat(sin(t)) * r
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lines.path = path.cgPath
        CATransaction.commit()
    }
}

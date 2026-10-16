import UIKit

/// 关闭标签页时的“风化成粒子”效果（参考 Telegram 删除消息的视觉，自己实现）：
/// 把卡片截图切成小颗粒，从左往右依次向右上方飘散、缩小、淡出。全部是 GPU 合成的图层动画。
enum DustEffect {
    /// frame 是窗口坐标
    static func run(on window: UIWindow, frame: CGRect) {
        guard frame.width > 1, frame.height > 1 else { return }
        // 截取窗口里这块区域
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let cg = image.cgImage else { return }

        let container = UIView(frame: window.bounds)
        container.isUserInteractionEnabled = false
        window.addSubview(container)

        let tile: CGFloat = 4
        let columns = Int(ceil(frame.width / tile)), rows = Int(ceil(frame.height / tile))
        let now = CACurrentMediaTime()
        var longest: CFTimeInterval = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for r in 0..<rows {
            for c in 0..<columns {
                let rect = CGRect(x: CGFloat(c) * tile, y: CGFloat(r) * tile, width: tile, height: tile)
                let particle = CALayer()
                particle.frame = rect.offsetBy(dx: frame.minX, dy: frame.minY)
                particle.contents = cg
                particle.contentsRect = CGRect(x: rect.minX / frame.width, y: rect.minY / frame.height,
                                               width: tile / frame.width, height: tile / frame.height)
                container.layer.addSublayer(particle)

                // 从左往右扫过去，带一点随机，看起来像被风吹散
                let sweep = Double(rect.minX / frame.width) * 0.42 + Double(rect.minY / frame.height) * 0.08
                let delay = sweep + Double.random(in: 0...0.1)
                let duration = Double.random(in: 0.55...0.95)

                let start = particle.position
                let drift = CGPoint(x: start.x + .random(in: -10...42), y: start.y + .random(in: -78 ... -16))
                let move = CAKeyframeAnimation(keyPath: "position")
                let path = UIBezierPath()
                path.move(to: start)
                // 先略微往外鼓再上飘，轨迹带弧度
                path.addQuadCurve(to: drift, controlPoint: CGPoint(x: (start.x + drift.x) / 2 + .random(in: -12...12), y: start.y - .random(in: 0...20)))
                move.path = path.cgPath
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)

                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.timingFunction = CAMediaTimingFunction(name: .easeIn)

                let shrink = CABasicAnimation(keyPath: "transform.scale")
                shrink.fromValue = 1
                shrink.toValue = CGFloat.random(in: 0.2...0.7)

                let group = CAAnimationGroup()
                group.animations = [move, fade, shrink]
                group.beginTime = now + delay
                group.duration = duration
                group.fillMode = .both          // 开始前停在原位（拼成完整的卡片），结束后保持消失
                group.isRemovedOnCompletion = false
                particle.add(group, forKey: "dust")
                longest = max(longest, delay + duration)
            }
        }
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + longest + 0.05) {
            container.removeFromSuperview()
        }
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }
}

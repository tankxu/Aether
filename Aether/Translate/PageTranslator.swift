import UIKit
import Vision
import WebKit

/// 网页翻译的原生一侧。aether-translate.js 在独立的 content world 里收集文字、找出画面里的图片，
/// 这里负责翻译，以及截取图片（含 canvas、CSS 背景图）所在区域识别文字后返回译文方框。
final class PageTranslator: NSObject, WKScriptMessageHandlerWithReply {
    static let messageName = "aetherTranslate"
    static let world = WKContentWorld.world(name: "aether-translate")

    /// 这个网页现在是否应该翻译
    var isActive: (WKWebView) -> Bool = { _ in false }
    var onError: (String) -> Void = { _ in }

    private var lastError: (message: String, date: Date)?

    static func state(active: Bool) -> [String: Any] {
        [
            "active": active,
            "target": TranslationSettings.target,
            "display": TranslationSettings.display.rawValue,
            "images": TranslationSettings.translateImages,
            // 云端引擎按量计费：只翻译屏幕附近的文字，滚到哪翻到哪
            "lazy": TranslationSettings.engine != .system,
        ]
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String, let webView = message.webView else {
            return (nil, "bad message")
        }
        switch type {
        case "state":
            return (Self.state(active: isActive(webView)), nil)
        case "translate":
            guard isActive(webView) else { return (nil, "inactive") }
            let texts = body["texts"] as? [String] ?? []
            do {
                // 没翻成的位置给 null，页面稍后重试
                let translated = try await TranslationService.shared.translate(texts)
                return (translated.map { $0 as Any? ?? NSNull() }, nil)
            } catch {
                report(error)
                return (nil, error.localizedDescription)
            }
        case "ocr":
            // 子框架拿不到自己在页面里的位置，图片识别只做主框架
            guard isActive(webView), message.frameInfo.isMainFrame, let rect = body["rect"] as? [String: Any] else { return ([], nil) }
            // null 表示这次没翻成（额度、网络），页面稍后重新识别
            return (await recognize(in: webView, rect: rect) ?? NSNull(), nil)
        default:
            return (nil, "unknown message")
        }
    }

    /// 同一个错误 10 秒内只提示一次（一页会同时发出很多批）
    private func report(_ error: Error) {
        let message = error.localizedDescription
        if let lastError, lastError.message == message, Date().timeIntervalSince(lastError.date) < 10 { return }
        lastError = (message, Date())
        onError(message)
    }

    // MARK: - 图片文字

    /// rect：可视区域里的位置（已乘页面缩放，单位是视图的点）；返回的方框以 CSS 像素计，相对 rect 左上角
    private func recognize(in webView: WKWebView, rect: [String: Any]) async -> [[String: Any]]? {
        func n(_ key: String) -> CGFloat { CGFloat((rect[key] as? NSNumber)?.doubleValue ?? 0) }
        let scale = max(n("scale"), 0.1)
        let inset = webView.scrollView.adjustedContentInset
        let requested = CGRect(x: n("x") + inset.left, y: n("y") + inset.top, width: n("w"), height: n("h"))
        let area = requested.intersection(webView.bounds)
        guard !area.isNull, area.width >= 30, area.height >= 14 else { return [] }

        let config = WKSnapshotConfiguration()
        config.rect = area
        // 换图时旧的译文框刚被移除，要等屏幕刷新后再截，免得把自己的译文截进去
        config.afterScreenUpdates = true
        guard let image = try? await webView.takeSnapshot(configuration: config), let cgImage = image.cgImage else { return [] }

        let lines = await Task.detached(priority: .userInitiated) { ImageTextRecognizer.recognize(cgImage) }.value
        guard !lines.isEmpty else { return [] }
        let translated: [String?]
        do {
            translated = try await TranslationService.shared.translate(lines.map(\.text))
        } catch {
            report(error)
            return nil
        }
        // 翻好的行先盖上；一行都没翻成才让页面稍后重试
        guard translated.count == lines.count, translated.contains(where: { $0 != nil }) else { return nil }

        // 截图区域被视图边界裁过时，方框要补上偏移
        let dx = (area.minX - requested.minX) / scale, dy = (area.minY - requested.minY) / scale
        let w = area.width / scale, h = area.height / scale
        return zip(lines, translated).compactMap { line, text in
            guard let text, text != line.text else { return nil }
            return [
                "x": dx + line.box.minX * w, "y": dy + line.box.minY * h,
                "w": line.box.width * w, "h": line.box.height * h,
                "text": text, "bg": line.background, "fg": line.foreground,
            ]
        }
    }
}

/// Vision 识别图片里的文字行，顺便取每行周围的底色，译文方框用同样的底色盖住原文
nonisolated enum ImageTextRecognizer {
    struct Line: Sendable {
        let text: String
        /// 归一化坐标，原点在左上
        let box: CGRect
        let background: String
        let foreground: String
    }

    static func recognize(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])

        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
            let b = observation.boundingBox
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            let pixels = CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height)
            let (background, foreground) = colors(around: pixels, in: image)
            return Line(text: text, box: box, background: background, foreground: foreground)
        }
    }

    /// 文字框外面一圈像素里最多的颜色当底色（平均会被字的颜色拉偏），字色取黑或白里对比度高的
    private static func colors(around rect: CGRect, in image: CGImage) -> (String, String) {
        let fallback = ("rgba(255,255,255,0.92)", "#111")
        let pad = max(3, rect.height * 0.25)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let padded = rect.insetBy(dx: -pad, dy: -pad).intersection(bounds).integral
        guard !padded.isNull, padded.width >= 4, padded.height >= 4, let crop = image.cropping(to: padded) else { return fallback }
        let w = 48, h = 16
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return fallback }
        // 原文字框在缩略图里的位置，只统计它外面的像素；字框贴着图片边缘时退回统计整块
        let sx = CGFloat(w) / padded.width, sy = CGFloat(h) / padded.height
        let inner = CGRect(x: (rect.minX - padded.minX) * sx, y: (rect.minY - padded.minY) * sy, width: rect.width * sx, height: rect.height * sy)
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        func add(onlyOutside: Bool) {
            for y in 0..<h {
                for x in 0..<w {
                    if onlyOutside, inner.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { continue }
                    let i = (y * w + x) * 4
                    let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                    let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
                    let old = buckets[key] ?? (0, 0, 0, 0)
                    buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
                }
            }
        }
        add(onlyOutside: true)
        if buckets.values.reduce(0, { $0 + $1.count }) < 12 { add(onlyOutside: false) }
        guard let top = buckets.values.max(by: { $0.count < $1.count }) else { return fallback }
        let r = top.r / top.count, g = top.g / top.count, b = top.b / top.count
        let luminance = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255
        return ("rgb(\(r),\(g),\(b))", luminance > 0.55 ? "#111" : "#fff")
    }
}

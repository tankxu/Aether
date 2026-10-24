import NaturalLanguage
import SwiftUI
import Translation

/// 系统翻译。TranslationSession 只能从 SwiftUI 的 translationTask 拿到（这样语言包没下载时系统能弹窗下载），
/// 所以在浏览器界面里挂一个看不见的 SwiftUI 视图，按语言对排队执行。
@available(iOS 18.0, *)
final class SystemTranslator {
    static let shared = SystemTranslator()

    private let model = SystemTranslationModel()
    private(set) lazy var hostController: UIViewController = {
        let host = UIHostingController(rootView: SystemTranslationHost(model: model))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host
    }()

    /// 最近一次从大段文字里认出的语言，当作这一页的主要语言
    private var pageLanguage: String?
    private var installed: Set<String> = []

    /// 按源语言分组（同一页面里常混着几种语言），已经是目标语言的原样返回
    func translate(_ texts: [String], target: String) async throws -> [String] {
        let joined = texts.joined(separator: "\n")
        let detected = Self.detect(joined)
        if joined.count >= 200, let (language, confidence) = detected, confidence > 0.8 { pageLanguage = language }
        let batchLanguage = detected.flatMap { $0.1 > 0.6 ? $0.0 : nil } ?? pageLanguage

        // 空字符串表示认不出语言，交给系统自己判断
        var groups: [String: [Int]] = [:]
        for (i, text) in texts.enumerated() {
            let language = await source(for: text, fallback: batchLanguage, target: target) ?? ""
            groups[language, default: []].append(i)
        }
        var out = texts
        for (language, indices) in groups {
            if !language.isEmpty, TranslationService.sameLanguage(language, target) { continue }
            let source = language.isEmpty ? nil : Locale.Language(identifier: language)
            let translated = try await model.enqueue(indices.map { texts[$0] }, source: source,
                                                    target: Locale.Language(identifier: target))
            for (k, i) in indices.enumerated() { out[i] = translated[k] }
        }
        return out
    }

    /// 短句、识别错的 OCR 文字常被误认成别的语言，一旦用了没装的语言，系统就会弹窗要求下载。
    /// 所以只有已经装好的语言、或者够长且很有把握的才单独用，其余跟随整批或整页的主要语言。
    private func source(for text: String, fallback: String?, target: String) async -> String? {
        if text.count >= 6, let (language, confidence) = Self.detect(text), confidence > 0.6 {
            if language == fallback || language == pageLanguage { return language }
            if await isInstalled(language, target: target) { return language }
            if text.count >= 20, confidence > 0.9 { return language }
        }
        return fallback
    }

    private func isInstalled(_ language: String, target: String) async -> Bool {
        // 只缓存已安装的：没装的语言之后可能在系统设置里下载好
        let key = language + ">" + target
        if installed.contains(key) { return true }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: language), to: Locale.Language(identifier: target))
        if status == .installed { installed.insert(key) }
        return status == .installed
    }

    private static func detect(_ text: String) -> (String, Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 1).first.map { ($0.key.rawValue, $0.value) }
    }
}

@available(iOS 18.0, *)
@Observable
final class SystemTranslationModel {
    var configuration: TranslationSession.Configuration?

    private struct Job {
        let texts: [String]
        let source: Locale.Language?
        let target: Locale.Language
        let continuation: CheckedContinuation<[String], Error>
    }

    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var running = false

    func enqueue(_ texts: [String], source: Locale.Language?, target: Locale.Language) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.append(Job(texts: texts, source: source, target: target, continuation: continuation))
            startNext()
        }
    }

    /// 改 configuration 会让 translationTask 重新执行；同一语言对用 invalidate() 再触发一次
    private func startNext() {
        guard !running, let job = queue.first else { return }
        running = true
        if var configuration, configuration.source == job.source, configuration.target == job.target {
            configuration.invalidate()
            self.configuration = configuration
        } else {
            configuration = .init(source: job.source, target: job.target)
        }
    }

    /// translationTask 的回调：把排在前面、同一语言对的任务都做完
    func run(_ session: TranslationSession) async {
        while let job = queue.first, job.source == configuration?.source, job.target == configuration?.target {
            queue.removeFirst()
            do {
                // 会话只在这个循环里按顺序使用，不会被并发访问
                nonisolated(unsafe) let session = session
                nonisolated(unsafe) let requests = job.texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
                var out = job.texts
                for response in try await session.translations(from: requests) {
                    if let id = response.clientIdentifier, let i = Int(id), out.indices.contains(i) { out[i] = response.targetText }
                }
                job.continuation.resume(returning: out)
            } catch {
                job.continuation.resume(throwing: error)
            }
        }
        running = false
        startNext()
    }
}

@available(iOS 18.0, *)
private struct SystemTranslationHost: View {
    let model: SystemTranslationModel

    var body: some View {
        Color.clear
            .translationTask(model.configuration) { session in
                await model.run(session)
            }
    }
}

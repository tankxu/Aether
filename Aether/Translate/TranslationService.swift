import Foundation
import NaturalLanguage

enum TranslateFailure: LocalizedError {
    case missingKey(String)
    case badResponse(String)
    case unsupported
    /// 额度用完：until 是服务给出的恢复时间
    case quota(String, until: Date?)

    var errorDescription: String? {
        switch self {
        case .missingKey(let engine): L("还没有填写 %@ 的 API Key（设置 → 网页翻译）", engine)
        case .badResponse(let detail): L("翻译服务返回了无法识别的结果：%@", detail)
        case .unsupported: L("系统翻译需要 iOS 18 或更新版本")
        case .quota(let engine, let until):
            if let until, until.timeIntervalSinceNow > 60 {
                L("%@ 的额度用完了，约 %@ 后恢复", engine, Self.duration(until.timeIntervalSinceNow))
            } else {
                L("%@ 的请求太频繁，稍后会自动重试", engine)
            }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: seconds) ?? ""
    }
}

/// 网页翻译的统一入口：去重、缓存、跳过已经是目标语言的文字，再分批交给选定的引擎
final class TranslationService {
    static let shared = TranslationService()

    private var cache: [String: String] = [:]
    /// 云端引擎额度用完后到这个时间之前不再发请求，免得白白重试
    private var pausedUntil: [TranslationEngine: (date: Date, error: TranslateFailure)] = [:]

    /// texts 已经去掉首尾空白；返回同样顺序的译文，不需要翻译的原样返回，这次没翻成的是 nil（之后可以重试）。
    /// 全部失败时抛出错误，方便提示原因。
    func translate(_ texts: [String]) async throws -> [String?] {
        let engine = TranslationSettings.engine
        let target = TranslationSettings.target
        let prefix = "\(engine.rawValue)|\(target)|"

        var todo: [String] = []
        var seen = Set<String>()
        for text in texts where cache[prefix + text] == nil && Self.needsTranslation(text, target: target) {
            if seen.insert(text).inserted { todo.append(text) }
        }
        if !todo.isEmpty {
            let (translated, error) = await run(todo, engine: engine, target: target)
            var succeeded = false
            for (source, output) in zip(todo, translated) {
                guard let output else { continue }
                cache[prefix + source] = output
                succeeded = true
            }
            if !succeeded, let error { throw error }
            if cache.count > 20000 { cache.removeAll() }
        }
        return texts.map { text in
            if let hit = cache[prefix + text] { return hit }
            return Self.needsTranslation(text, target: target) ? nil : text
        }
    }

    /// 系统翻译每批 40 条、约 3000 字；云端按请求次数限额（免费额度一天只有几十次），一批装得多些，最多两批并发。
    /// 每批各自成败，失败的位置是 nil，同时带回最后一个错误。
    private func run(_ texts: [String], engine: TranslationEngine, target: String) async -> ([String?], Error?) {
        let cloud = engine != .system
        let maxCount = cloud ? 100 : 40, maxChars = cloud ? 6000 : 3000
        var chunks: [[String]] = [[]]
        var chars = 0
        for t in texts {
            if chunks[chunks.count - 1].count >= maxCount || chars + t.count > maxChars, !chunks[chunks.count - 1].isEmpty {
                chunks.append([])
                chars = 0
            }
            chunks[chunks.count - 1].append(t)
            chars += t.count
        }

        switch engine {
        case .system:
            guard #available(iOS 18.0, *) else { return (texts.map { _ in nil }, TranslateFailure.unsupported) }
            var out: [String?] = []
            var lastError: Error?
            for chunk in chunks {
                do { out += try await SystemTranslator.shared.translate(chunk, target: target) }
                catch { out += chunk.map { _ in nil }; lastError = error }
            }
            return (out, lastError)
        case .gemini, .openai:
            let account = engine == .gemini ? TranslationSettings.geminiKeyAccount : TranslationSettings.openAIKeyAccount
            guard let key = Keychain.get(account), !key.isEmpty else {
                return (texts.map { _ in nil }, TranslateFailure.missingKey(engine.name))
            }
            if let paused = pausedUntil[engine], paused.date > Date() { return (texts.map { _ in nil }, paused.error) }
            let request = LLMTranslator.Request(
                engine: engine == .gemini ? .gemini : .openai,
                name: engine.name,
                key: key,
                model: engine == .gemini ? TranslationSettings.geminiModel : TranslationSettings.openAIModel,
                baseURL: TranslationSettings.openAIBaseURL,
                target: target
            )
            var parts = [[String?]?](repeating: nil, count: chunks.count)
            var lastError: Error?
            // 两批一组并发
            for group in stride(from: 0, to: chunks.count, by: 2).map({ Array($0..<min($0 + 2, chunks.count)) }) {
                if let paused = pausedUntil[engine], paused.date > Date() { lastError = paused.error; break }
                let results = await withTaskGroup(of: (Int, Result<[String?], Error>).self) { tasks in
                    for i in group {
                        let chunk = chunks[i]
                        tasks.addTask {
                            do { return (i, .success(try await LLMTranslator.translate(chunk, request: request))) }
                            catch { return (i, .failure(error)) }
                        }
                    }
                    var results: [(Int, Result<[String?], Error>)] = []
                    for await r in tasks { results.append(r) }
                    return results
                }
                for (i, result) in results {
                    switch result {
                    case .success(let part): parts[i] = part
                    case .failure(let error):
                        lastError = error
                        if case TranslateFailure.quota(_, let until?) = error, until.timeIntervalSinceNow > 60 {
                            pausedUntil[engine] = (until, error as! TranslateFailure)
                        }
                    }
                }
            }
            let out = zip(chunks, parts).flatMap { chunk, part in part ?? chunk.map { _ in nil } }
            return (out, lastError)
        }
    }

    /// 改了引擎、模型或 Key 之后，之前的额度暂停不再适用
    func resetPause() { pausedUntil.removeAll() }

    /// 没有字母（价格、数字、符号）或者已经是目标语言的不翻
    nonisolated static func needsTranslation(_ text: String, target: String) -> Bool {
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        guard text.count >= 4, let detected = detectLanguage(text) else { return true }
        return !sameLanguage(detected, target)
    }

    nonisolated static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.6 else { return nil }
        return language.rawValue
    }

    /// zh-Hans / zh-Hant 要区分，其他语言只比主语言代码
    nonisolated static func sameLanguage(_ a: String, _ b: String) -> Bool {
        if a.hasPrefix("zh") || b.hasPrefix("zh") { return a == b }
        return a.split(separator: "-").first == b.split(separator: "-").first
    }
}

/// 大模型翻译：把一批文字按 JSON 数组发过去，要求按同样顺序返回
nonisolated enum LLMTranslator {
    enum Provider: Sendable { case gemini, openai }

    struct Request: Sendable {
        let engine: Provider
        let name: String
        let key: String
        let model: String
        let baseURL: String
        let target: String
    }

    /// 按编号收发（{"0": "...", "1": "..."}）：模型偶尔会漏掉或合并几条，用数组的话后面的译文会全部错位。
    /// 漏掉的位置返回 nil，交给页面稍后重试。
    static func translate(_ texts: [String], request: Request) async throws -> [String?] {
        var numbered: [String: String] = [:]
        for (i, text) in texts.enumerated() { numbered[String(i)] = text }
        let input = String(data: try JSONSerialization.data(withJSONObject: numbered, options: .sortedKeys), encoding: .utf8) ?? "{}"
        let content: String
        switch request.engine {
        case .gemini: content = try await gemini(input, request: request)
        case .openai: content = try await openAI(input, request: request)
        }
        guard let data = content.data(using: .utf8),
              let output = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslateFailure.badResponse(String(content.prefix(120)))
        }
        // 原样返回、而且明显不是目标语言的，算没翻成（模型偶尔会把整批照抄回来）
        let result = texts.indices.map { i -> String? in
            guard let t = output[String(i)] as? String else { return nil }
            return t == texts[i] && TranslationService.needsTranslation(t, target: request.target) ? nil : t
        }
        guard result.contains(where: { $0 != nil }) else { throw TranslateFailure.badResponse(String(content.prefix(120))) }
        return result
    }

    private static func prompt(target: String) -> String {
        let name = Locale(identifier: "en").localizedString(forIdentifier: target) ?? target
        return """
        You translate text fragments from a web page into \(name).
        The user message is a JSON object mapping ids to fragments, in page order; nearby fragments give each other context.
        Reply with only a JSON object with exactly the same ids, each mapped to the translation of that fragment. Never merge, split or skip ids.
        Every fragment must come back fully in \(name): translate all words, including names of dishes, places and shops, currency names and units.
        For example, into Chinese (Simplified) "120 บาท" becomes "120 泰铢" and "ร้านอาหารบ้านสวน" becomes "班苏安餐厅" (transliterate proper names).
        Keep digits, symbols such as $ € ¥ ฿ %, emoji, URLs and placeholders as they are.
        Return a fragment unchanged only if it is already entirely in \(name), or is code.
        Do not add explanations, quotes or notes.
        """
    }

    private static func gemini(_ input: String, request: Request) async throws -> String {
        let model = request.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? request.model
        var urlRequest = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.key, forHTTPHeaderField: "x-goog-api-key")
        var generation: [String: Any] = ["responseMimeType": "application/json", "temperature": 0.2]
        // 翻译要的是速度，尽量少思考：2.5 系列用 thinkingBudget（Flash 能关成 0），3 系列以后只认 thinkingLevel
        if request.model.contains("2.5") {
            if request.model.contains("flash") { generation["thinkingConfig"] = ["thinkingBudget": 0] }
        } else if request.model.contains("gemini") {
            generation["thinkingConfig"] = ["thinkingLevel": request.model.contains("pro") ? "low" : "minimal"]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": prompt(target: request.target)]]],
            "contents": [["role": "user", "parts": [["text": input]]]],
            "generationConfig": generation,
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(urlRequest, name: request.name)
        let candidates = json["candidates"] as? [[String: Any]]
        let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        guard let text = parts?.compactMap({ $0["text"] as? String }).joined(), !text.isEmpty else {
            throw TranslateFailure.badResponse(String(describing: json).prefix(120).description)
        }
        return text
    }

    private static func openAI(_ input: String, request: Request) async throws -> String {
        let base = request.baseURL.hasSuffix("/") ? String(request.baseURL.dropLast()) : request.baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw TranslateFailure.badResponse(base) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.key)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": request.model,
            "messages": [
                ["role": "system", "content": prompt(target: request.target)],
                ["role": "user", "content": input],
            ],
            "response_format": ["type": "json_object"],
        ]
        // 官方接口上的 GPT-5 系列关掉推理（翻译不需要，只会变慢）：最早的 gpt-5 / -mini / -nano 只认 minimal，5.1 以后是 none
        if url.host() == "api.openai.com", request.model.hasPrefix("gpt-5"), !request.model.contains("pro") {
            body["reasoning_effort"] = request.model == "gpt-5" || request.model.hasPrefix("gpt-5-") ? "minimal" : "none"
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(urlRequest, name: request.name)
        let choices = json["choices"] as? [[String: Any]]
        guard let text = (choices?.first?["message"] as? [String: Any])?["content"] as? String else {
            throw TranslateFailure.badResponse(String(describing: json).prefix(120).description)
        }
        return text
    }

    /// 429 / 5xx：服务说几秒后重试的就等一下再试一次，额度用完的带上恢复时间抛出去
    private static func send(_ request: URLRequest, name: String, retry: Bool = true) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return json }
        let error = json["error"] as? [String: Any]
        let message = error?["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
        if http.statusCode == 429 || http.statusCode >= 500 {
            let delay = retryDelay(error: error, headers: http) ?? (http.statusCode == 429 ? nil : 2)
            if retry, let delay, delay <= 20 {
                try await Task.sleep(for: .seconds(delay))
                return try await send(request, name: name, retry: false)
            }
            if http.statusCode == 429 {
                throw TranslateFailure.quota(name, until: delay.map { Date().addingTimeInterval($0) })
            }
        }
        throw TranslateFailure.badResponse("HTTP \(http.statusCode) \(message.prefix(160))")
    }

    /// Gemini 在 error.details 的 RetryInfo 里给 "43411s"，OpenAI 用 Retry-After 头
    private static func retryDelay(error: [String: Any]?, headers: HTTPURLResponse) -> TimeInterval? {
        for detail in error?["details"] as? [[String: Any]] ?? [] {
            if let delay = detail["retryDelay"] as? String, let seconds = Double(delay.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) {
                return seconds
            }
        }
        if let value = headers.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value) { return seconds }
        return nil
    }
}

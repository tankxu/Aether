import Foundation
import Security

/// 网页翻译用哪家的能力
enum TranslationEngine: String, CaseIterable, Identifiable {
    /// 系统自带的翻译（离线模型，iOS 18+）
    case system
    case gemini
    /// OpenAI 兼容接口（ChatGPT，也可以填别家兼容服务的地址）
    case openai

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: L("系统翻译")
        case .gemini: "Gemini"
        case .openai: "ChatGPT"
        }
    }
}

/// 译文怎么显示
enum TranslationDisplay: String, CaseIterable, Identifiable {
    /// 直接替换原文（和 Safari 一样）
    case replace
    /// 原文后面跟着译文
    case bilingual

    var id: String { rawValue }

    var name: String {
        switch self {
        case .replace: L("替换原文")
        case .bilingual: L("双语对照")
        }
    }
}

enum TranslationSettings {
    static let engineKey = "translate.engine"
    static let targetKey = "translate.target"
    static let displayKey = "translate.display"
    static let imagesKey = "translate.images"
    static let geminiModelKey = "translate.geminiModel"
    static let openAIModelKey = "translate.openaiModel"
    static let openAIBaseURLKey = "translate.openaiBaseURL"

    static let defaultGeminiModel = "gemini-flash-lite-latest"
    static let defaultOpenAIModel = "gpt-5.4-mini"
    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"

    private static var defaults: UserDefaults { .standard }

    /// 目标语言，名字用这种语言自己的写法
    static let targets: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("it", "Italiano"), ("pt", "Português"),
        ("ru", "Русский"), ("th", "ไทย"), ("vi", "Tiếng Việt"), ("id", "Bahasa Indonesia"), ("ar", "العربية"),
    ]

    static var engine: TranslationEngine {
        get { TranslationEngine(rawValue: defaults.string(forKey: engineKey) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: engineKey) }
    }

    /// 默认翻译成 App 界面语言
    static var target: String {
        get { defaults.string(forKey: targetKey) ?? AppLanguage.current }
        set { defaults.set(newValue, forKey: targetKey) }
    }

    static var targetName: String {
        targets.first { $0.code == target }?.name ?? target
    }

    static var display: TranslationDisplay {
        get { TranslationDisplay(rawValue: defaults.string(forKey: displayKey) ?? "") ?? .replace }
        set { defaults.set(newValue.rawValue, forKey: displayKey) }
    }

    /// 图片里的文字也翻译（识别后盖在原图上）
    static var translateImages: Bool {
        get { defaults.object(forKey: imagesKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: imagesKey) }
    }

    static var geminiModel: String {
        let m = defaults.string(forKey: geminiModelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? defaultGeminiModel : m
    }

    static var openAIModel: String {
        let m = defaults.string(forKey: openAIModelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? defaultOpenAIModel : m
    }

    static var openAIBaseURL: String {
        let u = defaults.string(forKey: openAIBaseURLKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return u.isEmpty ? defaultOpenAIBaseURL : u
    }

    static let geminiKeyAccount = "gemini"
    static let openAIKeyAccount = "openai"
}

/// 按网站自动翻译
enum AutoTranslatePolicy {
    private static let key = "translate.autoHosts"

    static var hosts: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: key) }
    }

    static func isEnabled(_ host: String?) -> Bool {
        guard let host else { return false }
        let h = host.lowercased()
        return hosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static func setEnabled(_ host: String, _ enabled: Bool) {
        let h = AppLinkPolicy.normalize(host)
        if enabled { hosts.append(h) } else { hosts.removeAll { $0 == h } }
    }
}

/// API Key 存在钥匙串里，不进 UserDefaults
nonisolated enum Keychain {
    private static let service = "com.tankxu.aether.translate"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

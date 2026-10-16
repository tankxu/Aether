import Foundation

/// App 界面语言。不跟 AppleLanguages 走——那个被“地区与语言”用来控制网页语言了，
/// 界面文字直接从选定语言的 .lproj 里取，两者互不影响。改了之后重新打开 App 生效。
nonisolated enum AppLanguage {
    /// 源语言是简体中文：代码里的中文就是翻译的键，没有对应 .lproj 时原样显示
    static let supported: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"), ("ko", "한국어"),
        ("en", "English"), ("es", "Español"), ("fr", "Français"),
    ]
    static let key = "app.language"

    /// 实际使用的语言代码
    static let current: String = {
        if let saved = UserDefaults.standard.string(forKey: key), supported.contains(where: { $0.code == saved }) { return saved }
        // 跟随系统：用系统原本的语言列表（启动时在被网页语言覆盖之前记下的）
        let preferred = UserDefaults.standard.stringArray(forKey: "region.systemLanguages") ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: supported.map(\.code), forPreferences: preferred).first ?? "zh-Hans"
    }()

    /// 简体中文是源语言，没有 .lproj：为 nil 时直接显示原文。
    /// 不能退回 Bundle.main——它会按系统语言挑一个现有的 .lproj（繁中或英文），简体用户反而看到别的语言
    static let bundle: Bundle? = {
        guard current != "zh-Hans", let path = Bundle.main.path(forResource: current, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    static let locale = Locale(identifier: current)
}

/// 界面文字：键是简体中文原文
nonisolated func L(_ key: String) -> String {
    guard let bundle = AppLanguage.bundle else { return key }
    return bundle.localizedString(forKey: key, value: key, table: nil)
}

/// 带参数的界面文字（%@ / %d），各语言可以调整语序
nonisolated func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.locale, arguments: args)
}

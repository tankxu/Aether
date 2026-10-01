import Foundation

// 解析 AdBlock Plus / uBlock Origin / AdGuard 规则语法。
// 只依赖 Foundation，在后台线程运行（也能在 macOS 命令行里直接测试）。

nonisolated struct NetworkRule: Hashable, Sendable {
    var urlFilter: String
    var caseSensitive = false
    var loadType: String?
    var resourceTypes: [String] = []
    var loadContext: [String] = []
    var ifDomain: [String] = []
    var unlessDomain: [String] = []
}

nonisolated struct CosmeticRule: Hashable, Sendable {
    var selector: String
    var include: [String]
    var exclude: [String]
}

/// 需要在网页里用 JS 执行的规则：脚本规则、过程式选择器、:style()
nonisolated struct PageRule: Hashable, Sendable {
    enum Kind: String, Sendable { case scriptlet = "s", procedural = "p", style = "c" }
    var kind: Kind
    var payload: [String]
    var include: [String]
    var exclude: [String]
}

nonisolated struct FilterSet: Sendable {
    var blocks: [NetworkRule] = []
    var exceptions: [NetworkRule] = []
    /// 整站放行（@@||site^$document）
    var documentExceptions: Set<String> = []
    /// 整站不做元素隐藏（$elemhide）
    var elemhideExceptions: Set<String> = []
    /// 整站不做通用元素隐藏（$generichide）
    var generichideExceptions: Set<String> = []

    var cosmetics: [CosmeticRule] = []
    var genericCosmeticExceptions: Set<String> = []
    var cosmeticExceptions: [String: Set<String>] = [:]

    var pageRules: [PageRule] = []
    /// 例外：域名 → 被禁用的规则键（"*" 表示全部）
    var pageRuleExceptions: [String: Set<String>] = [:]

    /// 无条件拦截的域名，用于判断弹窗目标
    var blockedHosts: Set<String> = []

    var badfilters: Set<String> = []
    var skipped = 0
}

nonisolated enum FilterParser {
    /// uBO `!#if` 指令里视为真的环境标记
    static let environment: Set<String> = ["ext_ublock", "env_mobile", "env_safari", "cap_user_stylesheet"]

    /// 网页里实现了的脚本规则（名字 → 规范名）。和 aether-adblock.js 保持一致。
    static let scriptletAliases: [String: String] = {
        var m: [String: String] = [:]
        let groups: [[String]] = [
            ["set-constant", "set", "set-constant"],
            ["abort-on-property-read", "aopr"],
            ["abort-on-property-write", "aopw"],
            ["abort-current-script", "acs", "abort-current-inline-script", "acis"],
            ["abort-on-stack-trace", "aost"],
            ["addEventListener-defuser", "aeld", "prevent-addEventListener"],
            ["no-setTimeout-if", "nostif", "prevent-setTimeout", "setTimeout-defuser"],
            ["no-setInterval-if", "nosiif", "prevent-setInterval", "setInterval-defuser"],
            ["adjust-setTimeout", "nano-stb", "nano-setTimeout-booster"],
            ["adjust-setInterval", "nano-sib", "nano-setInterval-booster"],
            ["no-window-open-if", "nowoif", "prevent-window-open", "window.open-defuser"],
            ["json-prune"],
            ["json-prune-fetch-response"],
            ["json-prune-xhr-response"],
            ["no-fetch-if", "prevent-fetch"],
            ["no-xhr-if", "prevent-xhr"],
            ["noeval-if", "prevent-eval-if", "noeval"],
            ["remove-attr", "ra"],
            ["remove-class", "rc"],
            ["remove-node-text", "rmnt"],
            ["nowebrtc"],
            ["set-cookie"],
            ["set-local-storage-item"],
            ["set-session-storage-item"],
            ["trusted-replace-fetch-response"],
            ["trusted-replace-xhr-response"],
        ]
        for g in groups { for n in g { m[n] = g[0] } }
        return m
    }()

    static let proceduralOperators = [
        ":has-text(", ":-abp-contains(", ":contains(", ":upward(", ":xpath(", ":matches-css(",
        ":matches-css-before(", ":matches-css-after(", ":min-text-length(", ":matches-path(",
        ":remove(", ":style(", ":remove-attr(", ":remove-class(", ":nth-ancestor(", ":watch-attr(",
        ":if(", ":if-not(", ":matches-attr(", ":matches-prop(", ":others(", ":matches-media(", ":-abp-properties(",
    ]

    // MARK: - 入口

    /// trusted：是否允许 trusted-* 脚本规则（只给 uBO 自家列表和用户规则）
    static func parse(_ text: String, trusted: Bool, into set: inout FilterSet) {
        var conditions: [Bool] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#") {
                handleDirective(line, &conditions)
                continue
            }
            if conditions.contains(false) { continue }
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            if !parseCosmetic(line, trusted: trusted, into: &set) {
                parseNetwork(line, into: &set)
            }
        }
    }

    /// 先扫一遍所有列表收集 $badfilter（它可能出现在被作废规则之后、甚至其他列表里）
    static func collectBadfilters(_ text: String, into set: inout FilterSet) {
        for raw in text.split(whereSeparator: \.isNewline) where raw.contains("badfilter") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let dollar = line.lastIndex(of: "$") else { continue }
            let kept = line[line.index(after: dollar)...].split(separator: ",").filter { $0 != "badfilter" }
            set.badfilters.insert(String(line[..<dollar]) + (kept.isEmpty ? "" : "$" + kept.joined(separator: ",")))
        }
    }

    /// 所有列表解析完后调用：去重
    static func finalize(_ set: inout FilterSet) {
        set.blocks = Array(Set(set.blocks))
        set.exceptions = Array(Set(set.exceptions))
        set.cosmetics = Array(Set(set.cosmetics))
        set.pageRules = Array(Set(set.pageRules))
    }

    // MARK: - !#if

    private static func handleDirective(_ line: String, _ conditions: inout [Bool]) {
        if line.hasPrefix("!#if ") {
            conditions.append(evaluate(String(line.dropFirst(5))))
        } else if line.hasPrefix("!#else") {
            if let last = conditions.popLast() { conditions.append(!last) }
        } else if line.hasPrefix("!#endif") {
            _ = conditions.popLast()
        }
    }

    /// 支持 !、&&、||、括号
    static func evaluate(_ expr: String) -> Bool {
        var tokens: [String] = []
        var i = expr.startIndex
        while i < expr.endIndex {
            let c = expr[i]
            if c == " " { i = expr.index(after: i); continue }
            if "()!".contains(c) { tokens.append(String(c)); i = expr.index(after: i); continue }
            if c == "&" || c == "|" {
                tokens.append(String(expr[i...].prefix(2)))
                i = expr.index(i, offsetBy: 2, limitedBy: expr.endIndex) ?? expr.endIndex
                continue
            }
            var j = i
            while j < expr.endIndex, expr[j].isLetter || expr[j].isNumber || expr[j] == "_" { j = expr.index(after: j) }
            if j == i { j = expr.index(after: i) }
            tokens.append(String(expr[i..<j]))
            i = j
        }
        var pos = 0
        func primary() -> Bool {
            guard pos < tokens.count else { return false }
            let t = tokens[pos]; pos += 1
            if t == "!" { return !primary() }
            if t == "(" { let v = or(); if pos < tokens.count, tokens[pos] == ")" { pos += 1 }; return v }
            return environment.contains(t)
        }
        func and() -> Bool {
            var v = primary()
            while pos < tokens.count, tokens[pos] == "&&" { pos += 1; let r = primary(); v = v && r }
            return v
        }
        func or() -> Bool {
            var v = and()
            while pos < tokens.count, tokens[pos] == "||" { pos += 1; let r = and(); v = v || r }
            return v
        }
        return or()
    }

    // MARK: - 元素隐藏 / 脚本规则

    private static let separators = ["#@?#", "#@$#", "#@%#", "#$?#", "#@#", "##", "#?#", "#$#", "#%#"]

    private static func parseCosmetic(_ line: String, trusted: Bool, into set: inout FilterSet) -> Bool {
        guard let hash = line.firstIndex(of: "#") else { return false }
        let prefix = line[..<hash]
        // 域名部分不可能含这些字符，否则是网址里的 #
        if prefix.contains(where: { "/|$^@&=?".contains($0) }) { return false }
        let rest = line[hash...]
        guard let sep = separators.first(where: { rest.hasPrefix($0) }) else { return false }
        let body = String(rest.dropFirst(sep.count)).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { set.skipped += 1; return true }
        let (include, exclude) = domains(prefix, separator: ",")

        switch sep {
        case "##", "#?#":
            if body.hasPrefix("+js(") {
                addScriptlet(body, include, exclude, trusted: trusted, into: &set)
            } else if body.hasPrefix("^") {
                set.skipped += 1
            } else {
                addSelector(body, include, exclude, into: &set)
            }
        case "#@#", "#@?#":
            if body.hasPrefix("+js(") {
                let key = scriptletKey(body) ?? "*"
                for d in include.isEmpty ? ["*"] : include { set.pageRuleExceptions[d, default: []].insert(key) }
            } else {
                let selector = normalizeSelector(body)
                if include.isEmpty {
                    set.genericCosmeticExceptions.insert(selector)
                } else {
                    set.cosmeticExceptions[selector, default: []].formUnion(include)
                }
                // 过程式规则的例外交给网页脚本
                if isProcedural(selector) {
                    for d in include.isEmpty ? ["*"] : include { set.pageRuleExceptions[d, default: []].insert("p:" + selector) }
                }
            }
        default:
            set.skipped += 1
        }
        return true
    }

    private static func addSelector(_ body: String, _ include: [String], _ exclude: [String], into set: inout FilterSet) {
        let selector = normalizeSelector(body)
        if isProcedural(selector) {
            // 纯 CSS + :style() → 注入样式；其他都走过程式引擎
            if let r = selector.range(of: ":style("), selector.hasSuffix(")"),
               !isProcedural(String(selector[..<r.lowerBound])) {
                let css = String(selector[r.upperBound..<selector.index(before: selector.endIndex)])
                set.pageRules.append(PageRule(kind: .style, payload: [String(selector[..<r.lowerBound]), css], include: include, exclude: exclude))
            } else {
                // 通用的过程式规则开销大，跳过
                guard !include.isEmpty else { set.skipped += 1; return }
                set.pageRules.append(PageRule(kind: .procedural, payload: [selector], include: include, exclude: exclude))
            }
            return
        }
        set.cosmetics.append(CosmeticRule(selector: selector, include: include, exclude: exclude))
    }

    static func normalizeSelector(_ s: String) -> String {
        s.replacingOccurrences(of: ":-abp-has(", with: ":has(")
            .replacingOccurrences(of: ":-abp-contains(", with: ":has-text(")
            .replacingOccurrences(of: ":contains(", with: ":has-text(")
    }

    static func isProcedural(_ s: String) -> Bool {
        proceduralOperators.contains { s.contains($0) }
    }

    private static func addScriptlet(_ body: String, _ include: [String], _ exclude: [String], trusted: Bool, into set: inout FilterSet) {
        guard var args = scriptletArgs(body), !args.isEmpty else { set.skipped += 1; return }
        var name = args.removeFirst()
        if name.hasSuffix(".js") { name.removeLast(3) }
        guard let canonical = scriptletAliases[name] else { set.skipped += 1; return }
        if canonical.hasPrefix("trusted-"), !trusted { set.skipped += 1; return }
        set.pageRules.append(PageRule(kind: .scriptlet, payload: [canonical] + args, include: include, exclude: exclude))
    }

    /// `+js(name, a, b)` → ["name", "a", "b"]；`\,` 是转义的逗号
    static func scriptletArgs(_ body: String) -> [String]? {
        guard body.hasPrefix("+js("), body.hasSuffix(")") else { return nil }
        let inner = body.dropFirst(4).dropLast()
        var args: [String] = []
        var current = ""
        var escaped = false
        for c in inner {
            if escaped {
                if c != "," { current.append("\\") }
                current.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "," {
                args.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        if escaped { current.append("\\") }
        args.append(current)
        return args.map { arg in
            let t = arg.trimmingCharacters(in: .whitespaces)
            if t.count >= 2, let f = t.first, let l = t.last, (f == "'" && l == "'") || (f == "\"" && l == "\"") {
                return String(t.dropFirst().dropLast())
            }
            return t
        }
    }

    static func scriptletKey(_ body: String) -> String? {
        guard var args = scriptletArgs(body), let first = args.first, !first.isEmpty else { return nil }
        var name = first
        if name.hasSuffix(".js") { name.removeLast(3) }
        args[0] = scriptletAliases[name] ?? name
        return args.joined(separator: "\u{1}")
    }

    /// "a.com,~b.a.com" → (["a.com"], ["b.a.com"])；`example.*` 这种实体域名原样保留
    static func domains<S: StringProtocol>(_ s: S, separator: Character) -> ([String], [String]) {
        var include: [String] = [], exclude: [String] = []
        for part in s.split(separator: separator) {
            var d = part.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = d.hasPrefix("~")
            if negated { d.removeFirst() }
            guard !d.isEmpty, d != "*" else { continue }
            if negated { exclude.append(d) } else { include.append(d) }
        }
        return (include, exclude)
    }

    // MARK: - 网络规则

    private static let typeMap: [String: [String]] = [
        "script": ["script"], "image": ["image"], "img": ["image"],
        "stylesheet": ["style-sheet"], "css": ["style-sheet"], "font": ["font"], "media": ["media"],
        "xmlhttprequest": ["raw"], "xhr": ["raw"], "websocket": ["raw"], "ping": ["raw"], "beacon": ["raw"],
        "other": ["raw"], "object": ["raw"],
        "popup": ["popup"],
    ]
    private static let allTypes = ["script", "image", "style-sheet", "font", "media", "raw", "svg-document", "document", "popup"]
    private static let unsupported: Set<String> = [
        "redirect", "redirect-rule", "removeparam", "csp", "replace", "rewrite", "denyallow", "header",
        "permissions", "urltransform", "method", "to", "popunder", "cookie", "jsonprune", "hls", "strict1p",
        "strict3p", "empty", "mp4", "network", "app", "inline-script", "inline-font", "webrtc", "specifichide",
        "shide", "genericblock", "urlskip", "uritransform", "responseheader", "ipaddress", "header", "extension",
        "content", "jsinject", "stealth", "referrerpolicy", "csp-report",
    ]

    private static func parseNetwork(_ input: String, into set: inout FilterSet) {
        var line = Substring(input)
        let isException = line.hasPrefix("@@")
        if isException { line = line.dropFirst(2) }

        var pattern = line
        var options: [Substring] = []
        if let dollar = line.lastIndex(of: "$") {
            let tail = line[line.index(after: dollar)...]
            if looksLikeOptions(tail) {
                pattern = line[..<dollar]
                options = tail.split(separator: ",")
            }
        }

        if options.contains(where: { $0 == "badfilter" }) || set.badfilters.contains(input) { return }

        var rule = NetworkRule(urlFilter: "")
        var types: [String] = []
        var negatedTypes: [String] = []
        var isDocument = false, isElemhide = false, isGenerichide = false

        for raw in options {
            var name = Substring(raw)
            var value: Substring = ""
            if let eq = raw.firstIndex(of: "=") {
                name = raw[..<eq]
                value = raw[raw.index(after: eq)...]
            }
            let negated = name.hasPrefix("~")
            if negated { name = name.dropFirst() }
            let key = name.lowercased()

            switch key {
            case "third-party", "3p":
                rule.loadType = negated ? "first-party" : "third-party"
            case "first-party", "1p":
                rule.loadType = negated ? "third-party" : "first-party"
            case "domain", "from":
                let (inc, exc) = domains(value, separator: "|")
                rule.ifDomain = inc.compactMap(blockerDomain)
                rule.unlessDomain = exc.compactMap(blockerDomain)
                // 只有实体域名（example.*）时 WebKit 表达不了
                if !inc.isEmpty && rule.ifDomain.isEmpty { set.skipped += 1; return }
            case "match-case":
                rule.caseSensitive = true
            case "important", "_", "all":
                break
            case "document", "doc":
                isDocument = true
            case "elemhide", "ehide":
                isElemhide = true
            case "generichide", "ghide":
                isGenerichide = true
            case "subdocument", "frame":
                if negated { negatedTypes.append("document") } else { types.append("document"); rule.loadContext = ["child-frame"] }
            default:
                if let mapped = typeMap[key] {
                    if negated { negatedTypes += mapped } else { types += mapped }
                } else {
                    // 不支持的选项（redirect、csp…）：整条跳过，避免误拦
                    set.skipped += 1
                    return
                }
            }
        }

        // 整站例外
        if isException, isDocument || isElemhide || isGenerichide {
            guard let host = plainHost(pattern) else { set.skipped += 1; return }
            let targets = rule.ifDomain.isEmpty ? [host] : rule.ifDomain.map { String($0.drop(while: { $0 == "*" })) }
            for t in targets {
                if isDocument { set.documentExceptions.insert(t) }
                if isElemhide { set.elemhideExceptions.insert(t) }
                if isGenerichide { set.generichideExceptions.insert(t) }
            }
            return
        } else if isElemhide || isGenerichide {
            set.skipped += 1
            return
        }
        if isDocument { types.append("document") }

        if !negatedTypes.isEmpty, types.isEmpty {
            types = allTypes.filter { !negatedTypes.contains($0) && $0 != "document" && $0 != "popup" }
        }
        rule.resourceTypes = Array(Set(types)).sorted()
        // 子框架规则只在纯 document 类型时附加 load-context
        if rule.resourceTypes != ["document"] { rule.loadContext = [] }

        guard let filter = regex(fromPattern: pattern) else { set.skipped += 1; return }
        rule.urlFilter = filter
        // 只限定了实体域名的规则：转换后会变成全局规则，跳过
        if rule.urlFilter == ".*", rule.ifDomain.isEmpty, rule.unlessDomain.isEmpty, rule.resourceTypes.isEmpty, rule.loadType == nil {
            set.skipped += 1
            return
        }

        if isException {
            set.exceptions.append(rule)
        } else {
            set.blocks.append(rule)
            if rule.ifDomain.isEmpty, rule.unlessDomain.isEmpty, rule.loadType == nil,
               rule.resourceTypes.isEmpty || rule.resourceTypes.contains("popup"),
               let host = plainHost(pattern) {
                set.blockedHosts.insert(host)
            }
        }
    }

    private static func looksLikeOptions(_ s: Substring) -> Bool {
        guard !s.isEmpty else { return false }
        for opt in s.split(separator: ",") {
            let name = opt.split(separator: "=", maxSplits: 1).first ?? ""
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "~" || $0 == "_" }) else { return false }
        }
        return true
    }

    /// `||example.com^` → example.com
    static func plainHost(_ pattern: Substring) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var host = pattern.dropFirst(2)
        if host.hasSuffix("^") { host = host.dropLast() }
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        return host.lowercased()
    }

    /// WebKit 的 if-domain：小写 ASCII，前缀 * 表示含子域名
    static func blockerDomain(_ d: String) -> String? {
        guard !d.hasSuffix(".*"), d.allSatisfy({ $0.isASCII }), !d.contains("/") else { return nil }
        return "*" + d
    }

    /// ABP 通配符 → WebKit url-filter 正则（WebKit 不支持 | 分支和 {n} 量词）
    static func regex(fromPattern input: Substring) -> String? {
        var s = input
        if s.hasPrefix("/"), s.hasSuffix("/"), s.count > 2 { return nil }
        guard s.allSatisfy(\.isASCII) else { return nil }
        var out = ""
        let hostAnchored = s.hasPrefix("||")
        if s.hasPrefix("||") {
            out = "^[^:]+://+([^:/]+\\.)?"
            s = s.dropFirst(2)
        } else if s.hasPrefix("|") {
            out = "^"
            s = s.dropFirst()
        }
        var anchorEnd = false
        if s.hasSuffix("|") {
            anchorEnd = true
            s = s.dropLast()
        }
        let separator = "[^a-zA-Z0-9_.%-]"
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            switch c {
            case "*":
                if !out.hasSuffix(".*") { out += ".*" }
            case "^":
                // 结尾的 "(分隔符.*)?$" 会让 WebKit 编译慢十几倍。
                // 紧跟域名的 ^ 后面必然是 / 或端口的 :，直接写成 [/:]
                let isHostEnd = hostAnchored && i == chars.count - 1 && !chars[..<i].contains("/")
                out += isHostEnd ? "[/:]" : separator
            case ".", "+", "?", "{", "}", "(", ")", "[", "]", "\\", "$", "|":
                out += "\\" + String(c)
            default:
                out.append(c)
            }
        }
        if anchorEnd { out += "$" }
        if out.isEmpty || out == ".*" { return ".*" }
        if out.hasPrefix(".*") { out.removeFirst(2) }
        if out.hasSuffix(".*") { out.removeLast(2) }
        return out.isEmpty ? ".*" : out
    }
}

import Foundation

/// WebKit 内容拦截规则（JSON 格式）
nonisolated struct WKRule: Encodable, Hashable, Sendable {
    struct Trigger: Encodable, Hashable, Sendable {
        var urlFilter: String
        var caseSensitive: Bool?
        var loadType: [String]?
        var resourceType: [String]?
        var loadContext: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case caseSensitive = "url-filter-is-case-sensitive"
            case loadType = "load-type"
            case resourceType = "resource-type"
            case loadContext = "load-context"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
        }
    }

    struct Action: Encodable, Hashable, Sendable {
        var type: String
        var selector: String?
    }

    var trigger: Trigger
    var action: Action

    static func ignore(domains: [String]) -> WKRule {
        WKRule(trigger: Trigger(urlFilter: ".*", ifDomain: domains), action: Action(type: "ignore-previous-rules"))
    }

    /// 编译失败时用于二分：把合并的选择器拆开
    func splitSelectors() -> [WKRule]? {
        guard action.type == "css-display-none", let selector = action.selector else { return nil }
        let parts = RuleListBuilder.splitSelectorList(selector)
        guard parts.count > 1 else { return nil }
        return parts.map { var r = self; r.action.selector = $0; return r }
    }
}

/// 一张待编译的规则表：主体规则 + 追加在末尾的例外（例外只对同一张表生效）
nonisolated struct RuleListSpec: Sendable {
    var name: String
    var rules: [WKRule]
    var tail: [WKRule]
}

nonisolated struct BuildOutput: Sendable {
    var lists: [RuleListSpec]
    /// 注入网页的 JS 规则数据（JSON）
    var pageData: String
    var blockedHosts: Set<String>
    var ruleCount: Int
}

nonisolated enum RuleListBuilder {
    /// 单表上限 15 万条，留足余量
    static let chunkSize = 40_000
    static let selectorsPerRule = 100

    static func build(_ set: FilterSet, prefix: String) -> BuildOutput {
        var lists: [RuleListSpec] = []

        let documentTail = set.documentExceptions.isEmpty ? [] : [WKRule.ignore(domains: set.documentExceptions.sorted().map { "*" + $0 })]
        let elemhideTail = set.elemhideExceptions.isEmpty ? [] : [WKRule.ignore(domains: set.elemhideExceptions.sorted().map { "*" + $0 })]
        let generichideTail = set.generichideExceptions.isEmpty ? [] : [WKRule.ignore(domains: set.generichideExceptions.sorted().map { "*" + $0 })]

        // 网络规则
        let blocks = set.blocks.map { networkRule($0, action: "block") }.sorted(by: ruleOrder)
        let exceptions = set.exceptions.map { networkRule($0, action: "ignore-previous-rules") }.sorted(by: ruleOrder)
        for (i, start) in stride(from: 0, to: blocks.count, by: chunkSize).enumerated() {
            let chunk = Array(blocks[start..<min(start + chunkSize, blocks.count)])
            lists.append(RuleListSpec(name: "\(prefix)net\(i)", rules: chunk, tail: exceptions + documentTail))
        }

        // 元素隐藏
        var generic: [String] = []
        var genericWithExclusions: [[String]: [String]] = [:]
        var specific: [[String]: [String]] = [:]
        for rule in set.cosmetics {
            if set.genericCosmeticExceptions.contains(rule.selector) { continue }
            let excepted = set.cosmeticExceptions[rule.selector] ?? []
            if rule.include.isEmpty {
                let exclude = Set(rule.exclude).union(excepted).compactMap(FilterParser.blockerDomain).sorted()
                if exclude.isEmpty { generic.append(rule.selector) } else { genericWithExclusions[exclude, default: []].append(rule.selector) }
            } else {
                let include = rule.include.filter { !excepted.contains($0) }.compactMap(FilterParser.blockerDomain).sorted()
                guard !include.isEmpty else { continue }
                specific[include, default: []].append(rule.selector)
            }
        }

        var genericRules: [WKRule] = []
        let sortedGeneric = generic.sorted()
        for start in stride(from: 0, to: sortedGeneric.count, by: selectorsPerRule) {
            let batch = sortedGeneric[start..<min(start + selectorsPerRule, sortedGeneric.count)]
            genericRules.append(cssRule(batch.joined(separator: ", ")))
        }
        for (exclude, selectors) in genericWithExclusions.sorted(by: { $0.key.joined() < $1.key.joined() }) {
            genericRules.append(cssRule(selectors.sorted().joined(separator: ", "), unless: exclude))
        }
        if !genericRules.isEmpty {
            lists.append(RuleListSpec(name: "\(prefix)cssg", rules: genericRules, tail: documentTail + elemhideTail + generichideTail))
        }

        var specificRules: [WKRule] = []
        for (include, selectors) in specific.sorted(by: { $0.key.joined() < $1.key.joined() }) {
            let sorted = selectors.sorted()
            for start in stride(from: 0, to: sorted.count, by: selectorsPerRule) {
                specificRules.append(cssRule(sorted[start..<min(start + selectorsPerRule, sorted.count)].joined(separator: ", "), if: include))
            }
        }
        for (i, start) in stride(from: 0, to: specificRules.count, by: chunkSize).enumerated() {
            let chunk = Array(specificRules[start..<min(start + chunkSize, specificRules.count)])
            lists.append(RuleListSpec(name: "\(prefix)csss\(i)", rules: chunk, tail: documentTail + elemhideTail))
        }

        let count = lists.reduce(0) { $0 + $1.rules.count }
        return BuildOutput(lists: lists, pageData: pageData(set), blockedHosts: set.blockedHosts, ruleCount: count)
    }

    private static func ruleOrder(_ a: WKRule, _ b: WKRule) -> Bool {
        a.trigger.urlFilter < b.trigger.urlFilter
    }

    private static func networkRule(_ r: NetworkRule, action: String) -> WKRule {
        var t = WKRule.Trigger(urlFilter: r.urlFilter)
        if r.caseSensitive { t.caseSensitive = true }
        if let lt = r.loadType { t.loadType = [lt] }
        if !r.resourceTypes.isEmpty { t.resourceType = r.resourceTypes }
        if !r.loadContext.isEmpty { t.loadContext = r.loadContext }
        // WebKit 不允许 if-domain 和 unless-domain 同时出现：有包含就只保留包含
        if !r.ifDomain.isEmpty { t.ifDomain = r.ifDomain } else if !r.unlessDomain.isEmpty { t.unlessDomain = r.unlessDomain }
        return WKRule(trigger: t, action: WKRule.Action(type: action))
    }

    private static func cssRule(_ selector: String, if include: [String]? = nil, unless exclude: [String]? = nil) -> WKRule {
        WKRule(trigger: WKRule.Trigger(urlFilter: ".*", ifDomain: include, unlessDomain: exclude),
               action: WKRule.Action(type: "css-display-none", selector: selector))
    }

    /// 按顶层逗号拆分选择器列表（跳过括号、引号、转义里的逗号）
    static func splitSelectorList(_ s: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var quote: Character?
        var escaped = false
        var current = ""
        for c in s {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { current.append(c); escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil }
                current.append(c)
                continue
            }
            switch c {
            case "\"", "'": quote = c
            case "(", "[": depth += 1
            case ")", "]": depth -= 1
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            default: break
            }
            current.append(c)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    // MARK: - 网页脚本数据

    /// {"r":[[kind, payload, exclude]], "d":{domain:[i]}, "e":{entity:[i]}, "g":[i], "x":{domain:[key]}}
    private static func pageData(_ set: FilterSet) -> String {
        var rules: [[Any]] = []
        var byDomain: [String: [Int]] = [:]
        var byEntity: [String: [Int]] = [:]
        var generic: [Int] = []
        for rule in set.pageRules.sorted(by: { $0.payload.joined() < $1.payload.joined() }) {
            let i = rules.count
            rules.append([rule.kind.rawValue, rule.payload, rule.exclude])
            if rule.include.isEmpty {
                generic.append(i)
            }
            for d in rule.include {
                if d.hasSuffix(".*") { byEntity[String(d.dropLast(2)), default: []].append(i) } else { byDomain[d, default: []].append(i) }
            }
        }
        let exceptions = set.pageRuleExceptions.mapValues { Array($0).sorted() }
        let object: [String: Any] = ["r": rules, "d": byDomain, "e": byEntity, "g": generic, "x": exceptions]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated enum StableHash {
    /// FNV-1a 64 位；Swift 的 hashValue 每次启动都不同，不能用来做缓存键
    static func hex(_ data: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in data {
            h ^= UInt64(b)
            h &*= 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }
}

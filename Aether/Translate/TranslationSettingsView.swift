import SwiftUI

struct TranslationSettingsView: View {
    var onChange: () -> Void = {}

    @AppStorage(TranslationSettings.engineKey) private var engine = TranslationEngine.system.rawValue
    @AppStorage(TranslationSettings.targetKey) private var target = AppLanguage.current
    @AppStorage(TranslationSettings.displayKey) private var display = TranslationDisplay.replace.rawValue
    @AppStorage(TranslationSettings.imagesKey) private var images = true
    @AppStorage(TranslationSettings.geminiModelKey) private var geminiModel = ""
    @AppStorage(TranslationSettings.openAIModelKey) private var openAIModel = ""
    @AppStorage(TranslationSettings.openAIBaseURLKey) private var openAIBaseURL = ""
    @State private var geminiKey = Keychain.get(TranslationSettings.geminiKeyAccount) ?? ""
    @State private var openAIKey = Keychain.get(TranslationSettings.openAIKeyAccount) ?? ""
    @State private var autoHosts = AutoTranslatePolicy.hosts

    private var systemAvailable: Bool {
        if #available(iOS 18.0, *) { true } else { false }
    }

    var body: some View {
        Form {
            Section {
                Picker(L("翻译成"), selection: $target) {
                    ForEach(TranslationSettings.targets, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker(L("显示方式"), selection: $display) {
                    ForEach(TranslationDisplay.allCases) { Text($0.name).tag($0.rawValue) }
                }
                Toggle(L("翻译图片里的文字"), isOn: $images)
            } footer: {
                Text(L("图片、canvas 和背景图里的文字会先在本机识别，再把译文盖在原来的位置。"))
            }

            Section {
                Picker(L("翻译引擎"), selection: $engine) {
                    ForEach(TranslationEngine.allCases) { e in
                        Text(e.name).tag(e.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(L("翻译引擎"))
            } footer: {
                Text(engineFooter)
            }

            if engine == TranslationEngine.gemini.rawValue {
                Section {
                    SecureField("API Key", text: $geminiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: geminiKey) { Keychain.set(TranslationSettings.geminiKeyAccount, geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    LabeledContent(L("模型")) {
                        TextField(TranslationSettings.defaultGeminiModel, text: $geminiModel)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Gemini")
                } footer: {
                    Text(L("在 Google AI Studio（aistudio.google.com）创建 API Key。Key 只保存在本机钥匙串里。"))
                }
            }

            if engine == TranslationEngine.openai.rawValue {
                Section {
                    SecureField("API Key", text: $openAIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: openAIKey) { Keychain.set(TranslationSettings.openAIKeyAccount, openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    LabeledContent(L("模型")) {
                        TextField(TranslationSettings.defaultOpenAIModel, text: $openAIModel)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent(L("接口地址")) {
                        TextField(TranslationSettings.defaultOpenAIBaseURL, text: $openAIBaseURL)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("ChatGPT")
                } footer: {
                    Text(L("在 platform.openai.com 创建 API Key。接口地址可以换成其他兼容 OpenAI 的服务。Key 只保存在本机钥匙串里。"))
                }
            }

            Section {
                if autoHosts.isEmpty {
                    Text(L("没有网站")).foregroundStyle(.secondary)
                }
                ForEach(autoHosts, id: \.self) { Text($0) }
                    .onDelete { offsets in
                        autoHosts.remove(atOffsets: offsets)
                        AutoTranslatePolicy.hosts = autoHosts
                    }
            } header: {
                Text(L("自动翻译的网站（%d）", autoHosts.count))
            } footer: {
                Text(L("在网页的 ⋯ 菜单 → 网站设置里打开“自动翻译此网站”。左滑可以删除。"))
            }
        }
        .navigationTitle(L("网页翻译"))
        .navigationBarTitleDisplayMode(.inline)
        // 换了 Key 或模型，之前因额度用完的暂停就不作数了
        .onDisappear { TranslationService.shared.resetPause() }
        .onChange(of: engine) { onChange() }
        .onChange(of: target) { onChange() }
        .onChange(of: display) { onChange() }
        .onChange(of: images) { onChange() }
    }

    private var engineFooter: String {
        switch TranslationEngine(rawValue: engine) ?? .system {
        case .system:
            systemAvailable
                ? L("免费，在本机离线翻译，第一次翻译某种语言时会提示下载语言包。整页一次翻完。")
                : L("系统翻译需要 iOS 18 或更新版本")
        case .gemini, .openai:
            L("网页文字会发送给所选服务翻译，按用量计费。为了省钱，只翻译屏幕附近的内容，滚到哪翻到哪。")
        }
    }
}

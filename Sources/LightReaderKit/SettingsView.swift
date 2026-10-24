import SwiftUI

struct SettingsView: View {
    @State private var configuration = SettingsStore.shared.configuration
    @State private var modelSecret = ""
    @State private var baiduSecret = ""
    @State private var message: String?
    @State private var isError = false
    @State private var testing = false
    @State private var secretsLoaded = false
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "character.bubble.fill").font(.system(size: 26)).foregroundStyle(readerAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译设置").font(.system(size: 22, weight: .semibold))
                    Text("连接你自己的翻译服务，配置在所有文献窗口中生效。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Picker("翻译来源", selection: $configuration.provider) {
                ForEach(TranslationProvider.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 17) {
                if configuration.provider == .model {
                    field("API 地址") { TextField("https://your-api.example/v1", text: $configuration.endpoint) }
                    Text("支持 Chat Completions 兼容协议。可填基础地址或完整的 /chat/completions 地址；支持本机 HTTP 服务。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).padding(.top, -8)
                    field("API Key") { SecureField("本机服务无需密钥时可留空", text: $modelSecret) }
                    field("模型名称") { TextField("填写服务商提供的模型 ID", text: $configuration.model) }
                } else {
                    field("APP ID") { TextField("百度翻译开放平台的 APP ID", text: $configuration.baiduAppID) }
                    field("密钥") { SecureField("百度翻译密钥", text: $baiduSecret) }
                    Text("请在百度翻译开放平台开通「通用文本翻译」。默认将英文翻译为简体中文；单次选文需少于 6000 字节。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                }
            }.textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(readerAccent)
                Text("密钥以本地文件保存，仅当前用户可读写，不使用钥匙串。只有选中的文字会发送到当前服务，PDF 文件保留在本地。").foregroundStyle(.secondary)
            }.font(.system(size: 11)).lineSpacing(4).padding(13).frame(maxWidth: .infinity, alignment: .leading).background(readerAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Button("打开配置文件夹") {
                do {
                    try FileManager.default.createDirectory(at: LocalStorage.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(LocalStorage.directory)
                } catch { message = error.localizedDescription; isError = true }
            }.buttonStyle(.link).font(.system(size: 11))
            if let message {
                Label(message, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(isError ? Color.red : readerAccent).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack {
                Button { testConnection() } label: {
                    HStack(spacing: 7) { if testing { ProgressView().controlSize(.small) }; Text(testing ? "正在测试…" : "测试连接") }
                }.disabled(testing || !secretsLoaded)
                Spacer()
                Button("保存设置") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!secretsLoaded || testing)
            }
        }
        .padding(30).frame(width: 530, height: 580).tint(readerAccent)
        .task {
            guard !secretsLoaded else { return }
            do {
                modelSecret = try SettingsStore.shared.secret(for: .model)
                baiduSecret = try SettingsStore.shared.secret(for: .baidu)
                secretsLoaded = true
            } catch { message = error.localizedDescription; isError = true }
        }
        .onChange(of: configuration) { _, _ in cancelTest() }
        .onChange(of: modelSecret) { _, _ in cancelTest() }
        .onChange(of: baiduSecret) { _, _ in cancelTest() }
        .onDisappear { testTask?.cancel() }
    }
    private func field<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 12, weight: .medium)); content() }
    }
    private func cancelTest() { testTask?.cancel(); testing = false; message = nil }
    private func save() {
        do {
            let secret = configuration.provider == .model ? modelSecret : baiduSecret
            _ = try TranslationService.request(text: "Test", configuration: configuration, secret: secret)
            try SettingsStore.shared.save(configuration, modelSecret: modelSecret, baiduSecret: baiduSecret)
            isError = false
            message = "设置已保存，在所有文献窗口中生效。"
        } catch { isError = true; message = error.localizedDescription }
    }
    private func testConnection() {
        testing = true
        message = nil
        let config = configuration
        let secret = config.provider == .model ? modelSecret : baiduSecret
        testTask = Task { @MainActor in
            do {
                let result = try await TranslationService().translate("Scientific research helps us understand the world.", configuration: config, secret: secret)
                guard !Task.isCancelled else { return }
                message = "连接成功：\(result)"
                isError = false
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
                isError = true
            }
            testing = false
        }
    }
}

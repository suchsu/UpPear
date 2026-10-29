import SwiftUI

struct SettingsView: View {
    @Bindable var model: UpdateModel
    @Bindable var selfUpdater: SelfUpdater
    @State private var license: String?
    var body: some View {
        Form {
            Section("检查更新") {
                Picker("App Store 优先地区", selection: $model.primaryRegion) {
                    ForEach([("CN", "中国大陆"), ("US", "美国"), ("HK", "中国香港"), ("JP", "日本"), ("KR", "韩国"), ("SG", "新加坡"), ("GB", "英国"), ("DE", "德国")], id: \.0) { code, title in Text(title).tag(code) }
                }
                Toggle("包括 Homebrew 命令行软件包", isOn: $model.includeFormulae)
                Toggle("包括 Sparkle 预发布版本", isOn: $model.includePreReleases)
                Toggle("每天自动检查一次", isOn: $model.dailyCheck)
                Button("按当前设置重新检查") { model.checkNow() }.disabled(model.isChecking || model.isUpgrading)
            }
            Section("系统") {
                Toggle("发现新的更新时通知", isOn: Binding(get: { model.notifyNewUpdates }, set: model.setNotifications))
                Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled))
            }
            Section("UpPear 自身更新") {
                Toggle("自动检查 UpPear 更新", isOn: Binding(
                    get: { selfUpdater.automaticallyChecksForUpdates },
                    set: selfUpdater.setAutomaticallyChecksForUpdates))
                if let date = selfUpdater.lastUpdateCheckDate {
                    Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if selfUpdater.isWaitingToRestart {
                    Label("等待当前升级完成后重启", systemImage: "pause.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("检查 UpPear 更新…") { selfUpdater.checkForUpdates() }
                    .disabled(!selfUpdater.canCheckForUpdates || model.isUpgrading)
            }
            Section("关于 UpPear \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0")") {
                Text("作者：suchsu")
                Text("基于 Pearcleaner 5.4.3 的更新代码开发。原作者：Alin Lupascu / alienator88。UpPear 是独立的社区衍生项目。")
                Link("Pearcleaner 原项目", destination: URL(string: "https://github.com/alienator88/Pearcleaner")!)
                HStack {
                    Button("项目许可证") { loadLicense("LICENSE", extension: "md") }
                    Button("来源声明") { loadLicense("NOTICE", extension: "md") }
                    Button("第三方许可") { loadLicense("Sparkle-LICENSE", extension: "txt") }
                }
                Text("免费、公开源码 · Apache 2.0 + Commons Clause\nSparkle 2.8.0 · MIT").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(12).frame(width: 560, height: 640)
        .sheet(isPresented: Binding(get: { license != nil }, set: { if !$0 { license = nil } })) {
            VStack(spacing: 16) {
                ScrollView { Text(license ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("完成") { license = nil }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 700, height: 550)
        }
    }
    private func loadLicense(_ name: String, extension ext: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext), let content = try? String(contentsOf: url, encoding: .utf8) { license = content }
        else { license = "许可文件无法读取，请查阅随源码分发的许可文件。" }
    }
}

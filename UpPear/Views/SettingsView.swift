import SwiftUI

struct SettingsView: View {
    @Bindable var model: UpdateModel
    @State private var license: String?
    var body: some View {
        Form {
            Section("检查更新") {
                Picker("App Store 优先地区", selection: $model.primaryRegion) {
                    ForEach([("CN", "中国大陆"), ("US", "美国"), ("HK", "中国香港"), ("JP", "日本"), ("KR", "韩国"), ("SG", "新加坡"), ("GB", "英国"), ("DE", "德国")], id: \.0) { code, title in Text(title).tag(code) }
                }
                Text("未在优先地区找到应用时，会查询其他地区。此设置不会更改商店账号地区。").font(.caption).foregroundStyle(.secondary)
                Toggle("包括 Homebrew 命令行软件包", isOn: $model.includeFormulae)
                Toggle("包括 Sparkle 预发布版本", isOn: $model.includePreReleases)
                Text("Microsoft 软件通过官方 AutoUpdate 检查；PopClip 扩展单独检查，并核实当前 PopClip 与 macOS 的兼容性。可在项目详情中分别忽略。").font(.caption).foregroundStyle(.secondary)
                Toggle("每天自动检查一次", isOn: $model.dailyCheck)
                Text("UpPear 运行时自动检查；Mac 睡眠或应用退出期间不会检查。").font(.caption).foregroundStyle(.secondary)
                Button("按当前设置重新检查") { model.checkNow() }.disabled(model.isChecking || model.isUpgrading)
            }
            Section("系统") {
                Toggle("发现新的更新时通知", isOn: Binding(get: { model.notifyNewUpdates }, set: model.setNotifications))
                Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled))
                Text("登录启动建议在将 UpPear 放入“应用程序”后启用。").font(.caption).foregroundStyle(.secondary)
            }
            Section("关于 UpPear \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0")") {
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

import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: UpdateModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("UpPear · \(model.updateCount) 个可用更新")
        if model.failureCount > 0 { Text("另有 \(model.failureCount) 个检查失败") }
        Divider()
        ForEach([UpdateSource.appStore, .homebrewCask, .homebrewFormula, .sparkle], id: \.rawValue) { source in
            let count = model.records.filter { $0.source == source && $0.state == .updateAvailable }.count
            if count > 0 { Text("\(source.title)  ·  \(count)") }
        }
        if model.isChecking { Text(model.progress.message) }
        if model.isUpgrading { Text("正在升级 \(model.upgradingName ?? "软件")") }
        Divider()
        Button("检查更新") { model.checkNow() }.disabled(model.isChecking || model.isUpgrading)
        if model.isChecking { Button("取消检查") { model.cancelCheck() } }
        Button("打开 UpPear") { openWindow(id: "main"); NSApplication.shared.activate() }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 UpPear") { NSApplication.shared.terminate(nil) }.disabled(model.isUpgrading)
    }
}

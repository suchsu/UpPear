// Modified for UpPear: keep fixture and screenshot automation outside production sources.
import AppKit
import SwiftUI

@main
struct UpPearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = UpdateModel()

    var body: some Scene {
        Window("UpPear", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 940, minHeight: 600)
                .task {
                    model.start()
                }
        }
        .defaultSize(width: 1160, height: 740)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 UpPear") { delegate.showAbout() }
            }
            CommandGroup(after: .newItem) {
                Button("检查软件更新") { model.checkNow() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isChecking || model.isUpgrading)
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出 UpPear") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command).disabled(model.isUpgrading)
            }
        }
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label(model.updateCount > 0 ? "\(model.updateCount)" : "UpPear", systemImage: "arrow.up.circle")
                .accessibilityIdentifier("uppear-status-item")
                .accessibilityLabel("UpPear，\(model.updateCount) 个可用更新")
        }
        Settings { SettingsView(model: model) }
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "UpPear",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .credits: NSAttributedString(string: "作者：suchsu\n基于 Pearcleaner 5.4.3 的更新功能\n原作者：Alin Lupascu / alienator88\nApache 2.0 + Commons Clause\nSparkle 2.8.0 · MIT\n\nUpPear 是独立社区衍生项目。")
        ])
    }
}

import AppKit
import SwiftUI

struct RecordDetail: View {
    let record: UpdateRecord
    @Bindable var model: UpdateModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(nsImage: model.icon(for: record)).resizable().scaledToFit().frame(width: 64, height: 64)
                    Text(record.name).font(.title2.bold()).textSelection(.enabled)
                    Label(record.state.title, systemImage: record.state == .updateAvailable ? "arrow.up.circle" : "info.circle")
                        .font(.callout).foregroundStyle(record.state == .failed ? .orange : .secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow { Text("更新来源").foregroundStyle(.secondary); Text(record.source.title) }
                    GridRow { Text("已安装").foregroundStyle(.secondary); Text(record.installedVersion.isEmpty ? "未知" : record.installedVersion) }
                    if let installedBuild = record.installedBuild { GridRow { Text("构建号").foregroundStyle(.secondary); Text(installedBuild) } }
                    if let version = record.availableVersion { GridRow { Text("源中版本").foregroundStyle(.secondary); Text(version) } }
                    if let build = record.availableBuild { GridRow { Text("新构建号").foregroundStyle(.secondary); Text(build) } }
                    if let region = record.foundInRegion { GridRow { Text("商店地区").foregroundStyle(.secondary); Text(region) } }
                }.font(.callout).textSelection(.enabled)
                Text(record.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                VStack(alignment: .leading, spacing: 10) {
                    Button(ActionResolver.action(for: record, primaryRegion: model.primaryRegion).title) { model.performAction(record) }
                        .buttonStyle(.borderedProminent).tint(.green).disabled(model.isUpgrading)
                        .accessibilityIdentifier("record-action")
                    Button(model.ignoredIDs.contains(record.id) ? "恢复自动检查" : "忽略此项目") { model.toggleIgnored(record) }
                        .buttonStyle(.borderless).disabled(model.isChecking || model.isUpgrading)
                    if let app = record.app {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([app.path]) }.buttonStyle(.borderless)
                    }
                }
                if let notes = record.releaseNotes, !notes.isEmpty {
                    Divider()
                    Text("更新说明").font(.headline)
                    Text(Self.plainNotes(notes)).font(.callout).textSelection(.enabled)
                }
                if let url = record.releaseNotesURL, ["https", "http"].contains(url.scheme) {
                    Link("查看完整更新说明", destination: url)
                }
                if let url = record.homepage, ["https", "http"].contains(url.scheme) { Link("开发者网站", destination: url) }
                if let app = record.app { Text(app.path.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func plainNotes(_ string: String) -> String {
        string.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</li>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct UpgradeConfirmation: View {
    let record: UpdateRecord
    @Bindable var model: UpdateModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("升级 \(record.name)", systemImage: "shippingbox").font(.title2.bold())
            Text("Homebrew 将升级此项目及所需依赖。请先保存工作并关闭相关应用。")
            if case .brewUpgrade(let plan) = ActionResolver.action(for: record, primaryRegion: model.primaryRegion) {
                Text(plan.displayCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("如果安装程序需要管理员验证，可复制命令到终端运行。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("复制命令") { model.copyCommand(record) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("升级") { dismiss(); model.upgrade(record) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 530)
    }
}

import AppKit
import SwiftUI

// Modified for UpPear 1.0.1: keep split-pane identity stable when the user
// clears list selection by clicking unused space.

enum AppFilter: String, CaseIterable, Identifiable {
    case updates, all, failed, unsupported, ignored, appStore, homebrew, sparkle, microsoft, popClip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .updates: "可用更新"
        case .all: "全部项目"
        case .failed: "检查失败"
        case .unsupported: "手动检查"
        case .ignored: "忽略与跳过"
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .sparkle: "Sparkle"
        case .microsoft: "Microsoft"
        case .popClip: "PopClip 扩展"
        }
    }
    var symbol: String {
        switch self {
        case .updates: "arrow.up.circle"
        case .all: "square.grid.2x2"
        case .failed: "exclamationmark.circle"
        case .unsupported: "questionmark.circle"
        case .ignored: "eye.slash"
        case .appStore: "bag"
        case .homebrew: "shippingbox"
        case .sparkle: "sparkles"
        case .microsoft: "square.grid.2x2"
        case .popClip: "puzzlepiece.extension"
        }
    }
    func includes(_ record: UpdateRecord) -> Bool {
        switch self {
        case .updates: record.state == .updateAvailable
        case .all: true
        case .failed: record.state == .failed
        case .unsupported: [.unsupported, .unverified, .incompatible].contains(record.state)
        case .ignored: [.skipped, .versionSkipped].contains(record.state)
        case .appStore: record.source == .appStore
        case .homebrew: [.homebrewCask, .homebrewFormula].contains(record.source)
        case .sparkle: record.source == .sparkle
        case .microsoft: record.source == .microsoftAutoUpdate
        case .popClip: record.source == .popClip
        }
    }
}

enum ManagedUpdateSection: String, CaseIterable, Identifiable {
    case ignored = "已忽略", skipped = "已跳过"
    var id: String { rawValue }
}

struct MainWindow: View {
    @Bindable var model: UpdateModel
    @State private var filter: AppFilter? = .updates
    @State private var selection: String?
    @State private var search = ""
    @State private var showOutput = false
    @State private var managedSection: ManagedUpdateSection = .ignored

    private var visibleRecords: [UpdateRecord] {
        let candidates: [UpdateRecord]
        if filter == .ignored {
            candidates = managedSection == .ignored ? model.records.filter { $0.state == .skipped } : model.skippedRecords
        } else { candidates = model.records.filter { (filter ?? .updates).includes($0) } }
        return candidates.filter {
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.source.title.localizedCaseInsensitiveContains(search))
        }.sorted {
            if $0.state == .updateAvailable && $1.state != .updateAvailable { return true }
            if $1.state == .updateAvailable && $0.state != .updateAvailable { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var selectedRecord: UpdateRecord? { visibleRecords.first(where: { $0.id == selection }) }

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section("软件") {
                    ForEach(Array(AppFilter.allCases.prefix(5))) { item in sidebarRow(item) }
                }
                Section("更新来源") {
                    ForEach(Array(AppFilter.allCases.dropFirst(5))) { item in sidebarRow(item) }
                }
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                Label("UpPear", systemImage: "arrow.up.circle.fill").font(.headline).foregroundStyle(.green)
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            VStack(spacing: 0) {
                summary
                Divider()
                HSplitView {
                    VStack(spacing: 0) {
                        if filter == .ignored {
                            Picker("管理更新", selection: $managedSection) {
                                Text("已忽略 (\(model.ignoredCount))").tag(ManagedUpdateSection.ignored)
                                Text("已跳过 (\(model.skippedVersions.count))").tag(ManagedUpdateSection.skipped)
                            }.pickerStyle(.segmented).padding(12)
                            Text(managedSection == .ignored ? "停止自动检查此项目，直到手动恢复。" : "仅跳过指定版本；后续新版会自动恢复提醒。")
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.bottom, 8)
                        }
                        if visibleRecords.isEmpty { emptyState }
                        else {
                            List(visibleRecords, selection: $selection) { record in
                                row(record).tag(record.id)
                            }.listStyle(.inset)
                        }
                        Text("\(visibleRecords.count) 个项目 · \(filter?.title ?? "可用更新")")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                    }.frame(minWidth: 320, idealWidth: 420)
                    // Keep one arranged subview in HSplitView across selection
                    // changes so AppKit preserves the user's divider position.
                    VStack(spacing: 0) {
                        if let selectedRecord {
                            RecordDetail(record: selectedRecord, model: model)
                        } else {
                            ContentUnavailableView("选择一个项目", systemImage: "sidebar.right", description: Text("查看版本、更新来源和官方更新入口。"))
                        }
                    }.frame(minWidth: 280, idealWidth: 310, maxWidth: 420, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let message = model.errorMessage {
                    HStack {
                        Label(message, systemImage: "exclamationmark.circle").font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(.orange.opacity(0.1))
                }
                if let warnings = model.snapshot?.warnings, !warnings.isEmpty {
                    DisclosureGroup("\(warnings.count) 条检查说明") {
                        ScrollView { Text(warnings.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    }.font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(filter?.title ?? "UpPear")
            .searchable(text: $search, placement: .toolbar, prompt: "搜索软件与扩展")
            .toolbar {
                ToolbarItemGroup {
                    if model.operationOutput != nil { Button("操作记录", systemImage: "text.alignleft") { showOutput = true } }
                    if model.isChecking { Button("取消检查", systemImage: "xmark.circle") { model.cancelCheck() } }
                    Button("检查更新", systemImage: "arrow.clockwise") { model.checkNow() }
                        .disabled(model.isChecking || model.isUpgrading).keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .onChange(of: filter) { _, value in
            if value == .ignored, model.ignoredCount == 0, !model.skippedVersions.isEmpty { managedSection = .skipped }
            selection = visibleRecords.first?.id
        }
        .onChange(of: visibleRecords.map(\.id)) { _, _ in
            if !visibleRecords.contains(where: { $0.id == selection }) { selection = visibleRecords.first?.id }
        }
        .onAppear { selection = visibleRecords.first?.id }
        .sheet(item: $model.pendingUpgrade) { record in UpgradeConfirmation(record: record, model: model) }
        .sheet(isPresented: $showOutput) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Homebrew 操作记录").font(.title2)
                ScrollView { Text(model.operationOutput ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("完成") { showOutput = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 720, height: 480)
        }
    }

    private func sidebarRow(_ item: AppFilter) -> some View {
        HStack {
            Label(item.title, systemImage: item.symbol)
            Spacer()
            let count = item == .ignored ? model.ignoredCount + model.skippedVersions.count
                : model.records.filter { item.includes($0) }.count
            if count > 0 { Text("\(count)").font(.caption).foregroundStyle(item == .updates ? .green : .secondary).monospacedDigit() }
        }.tag(item)
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isUpgrading ? "正在升级 \(model.upgradingName ?? "软件")" : (model.isChecking ? "正在检查软件更新" : "\(model.updateCount) 个可用更新"))
                    .font(.title2.bold()).accessibilityIdentifier("update-summary")
                if model.isChecking {
                    Text(model.progress.message).font(.callout).foregroundStyle(.secondary)
                    if model.progress.total > 0 { ProgressView(value: Double(model.progress.completed), total: Double(model.progress.total)).frame(width: 250) }
                } else if let snapshot = model.snapshot {
                    HStack(spacing: 4) { Text("上次完成检查"); Text(snapshot.completedAt, style: .relative); Text("前") }.font(.caption).foregroundStyle(.secondary)
                } else { Text("检查软件、Microsoft 和 PopClip 扩展更新。").font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(model.records.count) 个软件、扩展与软件包").font(.callout)
                if model.failureCount > 0 { Label("\(model.failureCount) 个检查失败", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(22)
    }

    private func row(_ record: UpdateRecord) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: model.icon(for: record)).resizable().scaledToFit().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.name).font(.headline).lineLimit(1)
                Text(record.source.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                if record.state == .updateAvailable {
                    Text("\(record.installedVersion.isEmpty ? "未知" : record.installedVersion) → \(record.availableVersion ?? "未知")").font(.caption.monospacedDigit()).lineLimit(1)
                    Text(record.isPinned ? "已固定版本" : (record.isPreRelease ? "预发布版" : "有更新")).font(.caption).foregroundStyle(.green)
                } else {
                    if let skipped = model.skippedVersions[record.id] {
                        Text("已跳过 \(skipped.displayVersion)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if record.state != .versionSkipped {
                        Text(record.state.title).font(.caption).foregroundStyle([.failed, .incompatible].contains(record.state) ? .orange : .secondary)
                    }
                }
            }
        }.padding(.vertical, 7).contentShape(Rectangle())
    }

    private var emptyState: some View {
        ContentUnavailableView(model.isChecking ? "正在检查" : (filter == .updates ? "没有确认的待更新项目" : "没有匹配的项目"),
            systemImage: model.isChecking ? "arrow.triangle.2.circlepath" : "checkmark.circle",
            description: Text(filter == .ignored
                ? (managedSection == .ignored ? "在项目详情中选择“忽略此项目”，可在这里恢复。" : "在更新详情中选择“跳过此更新”，可在这里恢复提醒。")
                : (model.snapshot == nil ? "点击“检查更新”开始扫描。" : "查询失败和无法自动检测的应用，可在左侧分别查看。")))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


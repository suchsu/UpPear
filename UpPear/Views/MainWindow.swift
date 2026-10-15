import AppKit
import SwiftUI

enum AppFilter: String, CaseIterable, Identifiable {
    case updates, all, failed, unsupported, ignored, appStore, homebrew, sparkle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .updates: "可用更新"
        case .all: "全部软件"
        case .failed: "检查失败"
        case .unsupported: "手动检查"
        case .ignored: "已忽略"
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .sparkle: "Sparkle"
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
        }
    }
    func includes(_ record: UpdateRecord) -> Bool {
        switch self {
        case .updates: record.state == .updateAvailable
        case .all: true
        case .failed: record.state == .failed
        case .unsupported: record.state == .unsupported
        case .ignored: record.state == .skipped
        case .appStore: record.source == .appStore
        case .homebrew: [.homebrewCask, .homebrewFormula].contains(record.source)
        case .sparkle: record.source == .sparkle
        }
    }
}

struct MainWindow: View {
    @Bindable var model: UpdateModel
    @State private var filter: AppFilter? = .updates
    @State private var selection: String?
    @State private var search = ""
    @State private var showOutput = false

    private var visibleRecords: [UpdateRecord] {
        model.records.filter {
            (filter ?? .updates).includes($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.source.title.localizedCaseInsensitiveContains(search))
        }.sorted {
            if $0.state == .updateAvailable && $1.state != .updateAvailable { return true }
            if $1.state == .updateAvailable && $0.state != .updateAvailable { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var selectedRecord: UpdateRecord? { model.records.first(where: { $0.id == selection }) }

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section("软件") {
                    ForEach(Array(AppFilter.allCases.prefix(5))) { item in sidebarRow(item) }
                }
                Section("更新来源") {
                    ForEach(Array(AppFilter.allCases.suffix(3))) { item in sidebarRow(item) }
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
                    if let selectedRecord {
                        RecordDetail(record: selectedRecord, model: model).frame(minWidth: 280, idealWidth: 310, maxWidth: 420)
                    } else {
                        ContentUnavailableView("选择一个项目", systemImage: "sidebar.right", description: Text("查看版本、更新来源和官方更新入口。"))
                            .frame(minWidth: 280, idealWidth: 310, maxWidth: 420)
                    }
                }
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
            .navigationTitle(filter?.title ?? "UpPear")
            .searchable(text: $search, placement: .toolbar, prompt: "搜索软件")
            .toolbar {
                ToolbarItemGroup {
                    if model.operationOutput != nil { Button("操作记录", systemImage: "text.alignleft") { showOutput = true } }
                    if model.isChecking { Button("取消检查", systemImage: "xmark.circle") { model.cancelCheck() } }
                    Button("检查更新", systemImage: "arrow.clockwise") { model.checkNow() }
                        .disabled(model.isChecking || model.isUpgrading).keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .onChange(of: filter) { _, _ in selection = visibleRecords.first?.id }
        .onChange(of: model.snapshot?.completedAt) { _, _ in
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
            let count = model.records.filter { item.includes($0) }.count
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
                } else { Text("检查 App Store、Homebrew 和 Sparkle 更新。").font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(model.records.count) 个软件与软件包").font(.callout)
                if model.failureCount > 0 { Label("\(model.failureCount) 个检查失败", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                if model.isFixture { Text("界面验证示例").font(.caption).foregroundStyle(.secondary) }
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
                } else { Text(record.state.title).font(.caption).foregroundStyle(record.state == .failed ? .orange : .secondary) }
            }
        }.padding(.vertical, 7).contentShape(Rectangle())
    }

    private var emptyState: some View {
        ContentUnavailableView(model.isChecking ? "正在检查" : (filter == .updates ? "没有确认的待更新项目" : "没有匹配的项目"),
            systemImage: model.isChecking ? "arrow.triangle.2.circlepath" : "checkmark.circle",
            description: Text(model.snapshot == nil ? "点击“检查更新”开始扫描。" : "查询失败和无法自动检测的应用，可在左侧分别查看。"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


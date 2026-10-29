import SwiftUI

struct GitHubSourceSheet: View {
    let record: UpdateRecord
    @Bindable var model: UpdateModel
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var branch = ""
    @State private var pinnedTag = ""
    @State private var tagPrefix = ""
    @State private var assetPattern = ""
    @State private var baseline = ""
    @State private var stream: GitHubReleaseStream = .stable
    @State private var preview: UpdateRecord?
    @State private var previewBinding: GitHubSourceBinding?
    @State private var error: String?
    @State private var checking = false
    @State private var candidates: [SourceCandidate] = []
    @State private var loaded = false
    @State private var showAdvanced = false
    @State private var assetChoices: [String] = []
    @State private var savedChoices: [GitHubSourceBinding] = []
    @State private var selectedPriorBinding: GitHubSourceBinding?
    @State private var previewTask: Task<Void, Never>?

    private var fingerprint: String {
        [repository, branch, pinnedTag, tagPrefix, assetPattern, baseline, stream.rawValue].joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("指定 GitHub 更新来源").font(.title2.bold())
            Text(record.name + " · " + record.installedVersion).foregroundStyle(.secondary)
            ScrollView {
                Form {
                    Section("仓库") {
                        TextField("GitHub 链接或 owner/repo", text: $repository)
                            .accessibilityIdentifier("github-repository")
                        if !savedChoices.isEmpty {
                            Menu("已保存的来源") {
                                ForEach(savedChoices) { binding in
                                    Button(binding.repository.slug + " · " + (binding.branch.isEmpty ? binding.stream.title : binding.branch)) {
                                        adopt(binding)
                                    }
                                }
                            }
                        }
                        if !candidates.isEmpty {
                            Menu("从应用内项目链接选择") {
                                ForEach(candidates) { candidate in
                                    Button(candidate.repository.slug) {
                                        repository = candidate.repository.slug
                                        assetPattern = candidate.assetPattern ?? ""
                                    }.help(candidate.evidence)
                                }
                            }
                        }
                    }
                    Section("发行版") {
                        Picker("发布流", selection: $stream) {
                            ForEach(GitHubReleaseStream.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if !assetChoices.isEmpty {
                            Picker("安装包", selection: $assetPattern) {
                                Text("自动选择").tag("")
                                if !assetPattern.isEmpty, !assetChoices.contains(assetPattern) {
                                    Text(assetPattern).tag(assetPattern)
                                }
                                ForEach(assetChoices, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        DisclosureGroup("高级选项", isExpanded: $showAdvanced) {
                            TextField("分支", text: $branch, prompt: Text("任意分支"))
                            TextField("固定标签", text: $pinnedTag, prompt: Text("跟随新版"))
                            TextField("标签前缀", text: $tagPrefix, prompt: Text("例如 desktop-v"))
                            TextField("安装包规则", text: $assetPattern, prompt: Text("例如 *mac*arm64*.dmg"))
                            TextField("已安装的发行版本", text: $baseline, prompt: Text(record.installedVersion))
                        }
                    }
                    if let preview {
                        Section("检查预览") {
                            LabeledContent("版本", value: "\(record.installedVersion) → \(preview.availableVersion ?? "待确认")")
                            LabeledContent("状态", value: preview.state.title)
                            if let info = preview.github {
                                LabeledContent("仓库", value: info.binding.repository.slug)
                                LabeledContent("分支 / 发布流", value: (info.binding.branch.isEmpty ? "未限定分支" : info.binding.branch) + " · " + info.binding.stream.title)
                                LabeledContent("tag", value: info.releaseTag ?? "未匹配")
                                LabeledContent("产物", value: info.assetName ?? "未确认，请指定规则")
                            }
                            if [.failed, .unverified, .incompatible].contains(preview.state) {
                                Text(preview.detail).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }
                    }
                }.formStyle(.grouped)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                if let app = record.app, model.githubBinding(for: app) != nil {
                    Button("解除手动绑定") { model.removeGitHubBinding(for: app); dismiss() }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(checking ? "正在检查…" : "检查并预览") { checkPreview() }
                    .disabled(checking || repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("github-preview")
                Button("保存来源") {
                    guard let binding = previewBinding else { return }
                    model.saveGitHubBinding(binding, preview: preview); dismiss()
                }.buttonStyle(.borderedProminent).disabled(previewBinding == nil || checking)
                    .accessibilityIdentifier("github-save")
            }
        }.padding(24).frame(width: 700, height: 600)
        .onAppear { load() }
        .onChange(of: fingerprint) { _, _ in
            preview = nil; previewBinding = nil; error = nil
            previewTask?.cancel(); previewTask = nil; checking = false
        }
        .onDisappear { previewTask?.cancel() }
    }

    private func load() {
        guard !loaded, let original = record.app else { return }; loaded = true
        let app = SourceDiscovery.identify(original)
        candidates = SourceDiscovery.candidates(for: app)
        savedChoices = model.githubBindings.filter {
            $0.installationPath == app.id || ($0.matchesIdentity(app) && !FileManager.default.fileExists(atPath: $0.installationPath))
        }
        if let binding = model.githubBinding(for: app) ?? record.github?.binding {
            adopt(binding)
        } else if savedChoices.count == 1, let binding = savedChoices.first { adopt(binding) }
        else if savedChoices.isEmpty, candidates.count == 1, let candidate = candidates.first {
            repository = candidate.repository.slug; assetPattern = candidate.assetPattern ?? ""
        }
    }

    private func adopt(_ binding: GitHubSourceBinding) {
        selectedPriorBinding = binding
        repository = binding.repository.slug; branch = binding.branch; pinnedTag = binding.pinnedTag
        tagPrefix = binding.tagPrefix; assetPattern = binding.assetPattern
        baseline = binding.installedReleaseVersion; stream = binding.stream
    }

    private func checkPreview() {
        guard let original = record.app else { return }
        do {
            let app = SourceDiscovery.identify(original)
            let repo = try GitHubRepository(repository)
            var binding = GitHubSourceBinding(app: app, repository: repo, evidence: "用户在来源预览中手动指定")
            if let prior = selectedPriorBinding ?? model.githubBinding(for: app) ?? record.github?.binding, prior.repository == repo {
                binding.id = prior.id; binding.repositoryID = prior.repositoryID
                binding.requiredManifestAsset = prior.requiredManifestAsset
            }
            binding.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            binding.pinnedTag = pinnedTag.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: repository), url.host?.lowercased() == "github.com" {
                let parts = url.pathComponents.filter { $0 != "/" }
                if parts.count > 3, parts[2] == "tree", binding.branch.isEmpty { binding.branch = parts.dropFirst(3).joined(separator: "/") }
                if parts.count > 4, parts[2] == "releases", parts[3] == "tag", binding.pinnedTag.isEmpty { binding.pinnedTag = parts.dropFirst(4).joined(separator: "/") }
            }
            binding.tagPrefix = tagPrefix; binding.assetPattern = assetPattern
            binding.installedReleaseVersion = baseline; binding.stream = stream
            try binding.validate()
            checking = true; error = nil; previewBinding = nil
            let draft = binding, expected = fingerprint
            previewTask = Task {
                let result = await GitHubUpdateChecker.check(app: app, binding: draft, api: GitHubAPI.production())
                guard !Task.isCancelled, fingerprint == expected else { return }
                preview = result; previewBinding = result.github?.binding ?? draft; checking = false
                assetChoices = result.github?.candidateAssets ?? []
            }
        } catch { self.error = error.localizedDescription; checking = false }
    }
}

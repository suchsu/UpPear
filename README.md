# UpPear

UpPear — Keep your Mac apps up to date.

作者：**suchsu**。

[下载 UpPear 1.0.0](https://github.com/suchsu/UpPear/releases/tag/uppear-v1.0.0) · [DMG 安装包](https://github.com/suchsu/UpPear/releases/download/uppear-v1.0.0/UpPear-1.0.0-macOS-arm64.dmg)

基于 [Pearcleaner 5.4.3](https://github.com/alienator88/Pearcleaner/tree/c52695d90c43f60abd5cd10c363f2e122c65f191) 的独立原生 macOS 更新管理器。灵感和更新引擎来自 Alin Lupascu / alienator88 的 Pearcleaner；保留并适配已有检测代码，来源映射见 [PROVENANCE.md](docs/PROVENANCE.md)。

## 使用

需要 Apple Silicon 和 macOS 27.0 或更新。打开 DMG，将 UpPear.app 拖入 Applications，再点击“检查更新”。当前 DMG 原样封装作者提供的 1.0.0 App，签名类型为 ad-hoc。

- App Store 默认中国区，保留地区回退；点击打开对应官方商店页面。
- Homebrew Cask / Formula 按实际安装记录与自身平台分支检查，单项升级先显示命令并确认，已固定版本保持固定。
- Sparkle 使用官方框架检查兼容更新，点击打开原应用，交由应用自身更新。
- App Store 收据优先，多来源结果合并；查询失败和手动检查不计入确认更新数量。

关闭主窗口后可通过菜单栏查看结果和重新检查。每日检查需要 App 保持运行，通知和登录启动可在设置中选择开启。

1.0 仅包含上述更新源，不含专用 MAU、清理、卸载或 UpPear 特权 Helper。

## 构建

使用 Xcode 27，打开 UpPear.xcodeproj，选择共享 scheme UpPear。App、Views、Core 同模块编译，唯一外链框架是精确固定的 Sparkle 2.8.0。

```sh
swift test --scratch-path /private/tmp/UpPear-build
scripts/build_app.sh Release
```

构建中间目录默认放在临时目录，日志、缓存和软件清单放在忽略的 work/ 或 dist/。测试与 Diagnostics 的 Swift Package 可独立使用。

用户定稿的 Icon Composer 工程位于 UpPear/Resources/UpPear.icon，由 Xcode 原生编译，完整保留图层与外观。来源摘要见 [ICON_SOURCE.json](docs/ICON_SOURCE.json)。

## 检测与数据

商店版本元数据可能与账号实际可更新时间不同。Homebrew 的复杂 tap/latest/HEAD 不能可靠比较时保守显示，自定义 tap 静态定义需要自行刷新。Sparkle 兼容性由官方框架决定；网络和证书失败明确显示。

检查结果仅保存在本机 Application Support/UpPear/snapshot.json；版本查询会访问 Apple、Homebrew 和对应应用的更新服务器。私人交接日志、详细软件清单和本地历史包不进入公开仓库或发行包。

## 来源与许可

UpPear 是 Pearcleaner 的独立社区衍生作品，免费、公开源码（source-available），保留 **Apache 2.0 + Commons Clause**，不是 MIT 或 OSI 标准开源许可。完整条款见 [LICENSE.md](LICENSE.md)，来源和署名见 [NOTICE.md](NOTICE.md)，第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。许可全文随 App 和 DMG 分发，关于页显示作者 suchsu 与 Pearcleaner 来源。

源码归档记录原始 1.0 构建代码提交；发行说明见 [RELEASE_NOTES.md](releases/1.0.0/RELEASE_NOTES.md)。

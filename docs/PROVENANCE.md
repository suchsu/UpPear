# 代码来源与必要修改

固定基线：[Pearcleaner 5.4.3](https://github.com/alienator88/Pearcleaner/tree/c52695d90c43f60abd5cd10c363f2e122c65f191)，提交 `c52695d90c43f60abd5cd10c363f2e122c65f191`。

完整原始 Git 历史保留在本仓库。源码当前目录仅保留更新管理所需部分，原模块可用 `git show 5.4.3:路径` 查阅。UpPear 衍生文件均带显著修改声明。

| UpPear 文件 | 上游来源 | 保留的实现 | 修改原因 |
|---|---|---|---|
| Core/AppStoreUpdateChecker.swift | Logic/AppsUpdater/AppStoreUpdateChecker.swift | adamID 快查、bundleId 查找、实体隔离、CN/US/HK/JP/KR/SG 回退、版本判断 | 解耦私有 CommerceKit/StoreFoundation；中国区默认值；错误/无结果显式区分；身份校验与请求限流 |
| Core/SparkleUpdateChecker.swift | Logic/AppsUpdater/SparkleUpdateChecker.swift | SPUUpdater、单应用操作、系统/通道/预发布过滤、显示版本和构建号判断、无更新原因 | 改为官方 probe API；不安装；超时/取消；禁止降级误报；不在不同过滤结果间缓存候选 |
| Core/AppScanner.swift | Logic/AppInfoFetch.swift：AppInfoFetcher / AppCategoryDetector | Bundle 版本元数据、MAS 收据、iOS Wrapper、Setapp 排除 | 仅读取更新需要的元数据；刷新 plist；保留外层启动路径；扫描错误可见 |
| Core/AppScanner.swift：SparkleFeed | Logic/AppsUpdater/SparkleUpdateChecker.swift：feedURL | SUFeedURL 与 DevMate fallback | URL 验证；支持 SUFeedUrl 大小写旧配置 |
| Core/HomebrewUpdateChecker.swift | Logic/Brew/HomebrewController.swift、Logic/Logic.swift 的 cask 识别 | Cellar/Caskroom 安装记录、公共 API、实际 App 与收据版本取高值、构建号决胜、tap 静态解析 | 去掉卸载/清理及全局状态；用实际安装路径关联；保留固定版本；显式失败；选择正确最高安装版本 |
| Core/BrewVersion.swift | Logic/Brew/HomebrewController.swift：String.stripBrewRevisionSuffix / PkgVersion | Homebrew 后缀清理及修订版本比较 | 仅加入 Sendable 和来源声明 |
| Core/VersionComparison.swift | Logic/AppsUpdater/VersionComparison.swift | Version 模型、元数据归一化、预发布判断 | 取消不符合语义相等约定的 Hashable；比较委托 Sparkle 自己的 SUStandardVersionComparator，修复多段版本提前返回相等 |

新代码：Models、Networking、CommandRunner、UpdateAction、UpdateEngine 与 App/Views、Tests、Diagnostics、工程/构建脚本及文档。

Sparkle 保持上游已经使用的 2.8.0，精确固定。原 AlinFoundation、swift-argument-parser、私有 CommerceKit / StoreFoundation / PackageKit、特权 Helper 不再是 UpPear 构建依赖。

## 相对上游的行为约束

- MAS 收据优先，完全排除直接更新及换源安装。
- Sparkle 使用 `checkForUpdateInformation`，只读取 appcast，不下载 App 安装包；保留官方检测要求，失败可见。
- Homebrew 只对本地安装记录成立的包显示管理入口；升级使用参数数组，不经过 shell。单项升级需用户确认。
- tap 保留原静态解析方式，明确提示其依据本地定义；复杂 Ruby/HEAD/latest 无法可靠比较时不猜测。
- macOS/架构分支数据不能使用上游过时硬编码系统代号猜测。

## 许可文件

LICENSE.md 与上游 5.4.3 完全一致。NOTICE.md / THIRD_PARTY_NOTICES.md 与许可全文随 App 资源一起分发；设置/About 中有来源声明及许可入口。


## 2026-10-14 续作修改

- HomebrewUpdateChecker：沿用上游版本判断，新增与 Homebrew::API.merge_variations 一致的精确平台合并；通过已安装 Homebrew 的只读 Ruby 表达式获取当前tag，避免自行维护系统代号表。CommandRunner 的环境覆盖仅作用于子进程。
- AppScanner：读取失败/无版本的 .app 启动器保留为手动项目，消除扫描遗漏。
- UpPearApp 的截图验证辅助：原固定标题查找改为稳定窗口标识和本进程窗口捕获。系统 ScreenCaptureKit 仅用于明确指定的 fixture screenshot 路径，不参与普通更新流程。
- UpPear 原始图标由 scripts/create_icon.swift 的矢量路径绘制；没有复用 Pearcleaner 图标。原 LICENSE 条款和署名维持。
- WorkBuddy 的原生工程、共享 scheme 与20项测试继续使用；未重建这些工程工作。

## 2026-10-14 用户定稿图标接入

用户在 Icon Composer 中手工调整并保存的 final-v2/UpPear.icon 是当前唯一图标准稿。完整五文件包复制到 UpPear/Resources/UpPear.icon；icon.json 与四个 SVG 均逐字核对，文件摘要见 ICON_SOURCE.json。没有使用旁边的旧 build_icon.py、components、design.json 或预览重建，没有改动用户源工程。

此定稿替换上述早期 create_icon.swift / ICNS 方案；旧图标和旧生成脚本已从当前工作树移除，仍可在历史检查点恢复。Xcode 工程使用 folder.iconcomposer.icon 原生资源类型与 ASSETCATALOG_COMPILER_APPICON_NAME=UpPear，直接由 actool 编译 Assets.car 和系统生成的 UpPear.icns；Info.plist 的图标声明由编译器合并。所有轮廓、层序、颜色、外观特化、Liquid Glass 和透明度均由未改写的用户工程驱动。

接入方式依据 [Apple Icon Composer 文档](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer) 和本机 Xcode 27 的 StandardFileTypes / AssetCatalogCompiler 规范。许可、更新引擎和来源署名保持不变。

## 2026-10-19 UpPear 1.1

新增的 MicrosoftAutoUpdateChecker、PopClipExtensionScanner、PopClipDirectoryClient、PopClipUpdateChecker 为 UpPear 新代码，不来自 Pearcleaner。它们只读使用官方工具、包元数据与公开目录；数据依据及行为见 UPDATES_1_1.md。Models/UpdateEngine/UpdateAction 与 App/Views 增加两个来源、兼容性与版本待确认状态、独立扩展身份和官方入口；保留 1.0.1 的分栏结构和 macOS 14/通用版设置。没有增加第三方代码依赖，许可证和用户定稿图标不变。

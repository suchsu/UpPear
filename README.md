# UpPear

UpPear — Keep your Mac apps up to date.

UpPear 是一款原生 macOS 更新管理器，可统一查看应用、软件包和 PopClip 扩展的更新。作者：**suchsu**。

**UpPear 1.1.0 现已发布。** 支持 macOS 14 或更高版本，兼容 Apple Silicon 和 Intel Mac，安装包已完成开发者签名和 Apple 公证。

[下载 DMG 安装包](https://github.com/suchsu/UpPear/releases/download/uppear-v1.1.0/UpPear-1.1.0-macOS-universal.dmg) · [下载 ZIP 压缩包](https://github.com/suchsu/UpPear/releases/download/uppear-v1.1.0/UpPear-1.1.0-macOS-universal.zip) · [查看 1.1.0 发行说明](https://github.com/suchsu/UpPear/releases/tag/uppear-v1.1.0)

## 1.1.0 更新内容

- 新增 **Microsoft AutoUpdate** 支持，检查微软应用更新并打开官方更新器安装。
- 新增 **PopClip 扩展更新**支持，检查当前 PopClip 和 macOS 的兼容性，必要时查找可核实的历史兼容版本。
- 新增 **“跳过此更新”**，只跳过当前版本，后续新版自动恢复提醒；与“已忽略”共用管理入口，可分别恢复。
- 修复 AdGuard、Logi Options+ 等应用自行更新后，Homebrew 仍显示旧版本或重复项目的问题。

## 支持的更新来源

- **App Store**：默认中国区，支持地区回退，打开对应的官方商店页面安装更新。
- **Homebrew Cask / Formula**：结合安装记录、本机应用版本和当前系统平台检查。单项升级前显示命令并确认，已固定的版本保持固定。
- **Sparkle**：通过应用的更新源检查兼容版本，打开原应用完成更新。
- **Microsoft AutoUpdate**：使用本机官方更新器检查微软应用，沿用当前更新频道；App Store 版本继续通过商店更新。
- **PopClip 扩展**：按唯一标识符匹配官方目录，检查扩展发布版本及兼容要求。下载后由 PopClip 确认安装；可单独忽略 PopClip 主程序，继续检查扩展。

同一应用的多个更新来源会合并显示。检查失败、版本待确认和不兼容的项目会单独标明，不计入可用更新数量。

## 使用

1. 打开 DMG，将 UpPear 拖入 Applications；或解压 ZIP 后将应用移入 Applications。
2. 打开 UpPear，点击“检查更新”，在详情中查看版本和官方更新入口。
3. 选择“跳过此更新”可暂时隐藏当前版本，后续新版会恢复提醒；选择“忽略此项目”可停止自动检查，直到手动恢复。
4. 在“忽略与跳过”入口中，分别管理“已忽略”和“已跳过”的项目。

关闭主窗口后，可通过菜单栏查看结果和重新检查。每日检查需要 App 保持运行，通知和登录启动可在设置中开启。

## 构建

使用 Xcode 27 打开 `UpPear.xcodeproj`，选择共享 scheme `UpPear`。依赖固定为 Sparkle 2.8.0。

```sh
scripts/build_app.sh Release
```

核心库也可独立构建：

```sh
swift build --scratch-path /private/tmp/UpPear-build
```

## 检测与隐私

检查结果和设置保存在本机。版本查询会访问 Apple、Homebrew、PopClip 官方目录及对应应用的更新服务器；Microsoft 检查使用本机 Microsoft AutoUpdate。

PopClip 官方目录数据通常缓存一小时；网络不可用时保留已有信息并显示数据时间，重新核实前关闭扩展下载入口。UpPear 不直接覆盖已安装的扩展，也不修改 PopClip 的配置、签名或授权。

自定义 Homebrew tap 的静态定义需要自行刷新；`latest`、`HEAD` 等无法可靠比较的版本会明确标明。商店元数据与账号实际可更新时间可能存在差异。

更新来源的实现依据见 [1.1 更新来源说明](docs/UPDATES_1_1.md)。

## 来源与许可

UpPear 基于 [Pearcleaner 5.4.3](https://github.com/alienator88/Pearcleaner/tree/c52695d90c43f60abd5cd10c363f2e122c65f191) 的更新功能开发，灵感和更新引擎来自 Alin Lupascu / alienator88 的 Pearcleaner。来源映射见 [PROVENANCE.md](docs/PROVENANCE.md)。

UpPear 免费、公开源码（source-available），保留 **Apache 2.0 + Commons Clause**。完整条款见 [LICENSE.md](LICENSE.md)，署名见 [NOTICE.md](NOTICE.md)，第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。完整许可随应用分发。

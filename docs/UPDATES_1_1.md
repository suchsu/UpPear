# UpPear 1.1 更新来源

1.1 在 1.0.1 的原生界面、macOS 14 最低系统、Apple Silicon / Intel 通用版基础上新增两个更新源。列表空白处取消选择时，分栏结构保持稳定。

1.0 的检查缓存继续可读；升级后首次启动会补扫新来源，不必等待原有的每日检查周期。

## 忽略与跳过

“忽略此项目”停止自动检查，直到手动恢复。“跳过此更新”只隐藏当前已确认的更新版本，仍继续查询更新源；后续版本（包括有可靠新构建号的同版本更新）自动恢复提醒。

两类设置保存在本机，在“忽略与跳过”入口的“已忽略”和“已跳过”页签分别管理。跳过后立即从可用更新数、菜单栏和通知中排除；可手动恢复当前更新。检查失败、过期或不兼容结果保留其原有状态，不能因跳过设置变成已是最新版。

Homebrew 的 PKG 安装收据会读取嵌套的应用标识符，将旧收据与实际应用关联；应用自行更新后沿用本机版本，多来源合并成一项。读取过程不执行任何卸载或安装指令。

## Microsoft AutoUpdate

使用已安装的官方 `msupdate --config --format plist` 读取登记信息、`msupdate --list --format plist` 查询更新。核实应用的实际安装路径与 MAU 登记一致后才显示检测结果，保留当前更新频道。App Store 收据始终优先；Edge 和 Teams 继续使用它们自己的更新机制。

支持官方 MAU 标识符对应的 Word、Excel、PowerPoint、Outlook、OneNote、OneDrive、Windows App、Defender、Company Portal、Copilot 等应用，以及 MAU 本身。没有登记、工具缺失、响应格式未知、权限/XPC 错误与超时均单独显示，不能解释为没有更新。

点击更新打开 Microsoft AutoUpdate，由官方更新器显示说明、下载和安装。UpPear 不执行 MAU 安装命令，不切换更新频道，不终止 Office 进程。

依据：[Microsoft msupdate 文档](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/update-office-for-mac-using-msupdate)。MAU 某些版本在没有更新时即使请求 plist 也输出 `No updates available`；仅在退出成功、没有错误并且精确出现该结果时接受。未知格式保守显示检查失败。

## PopClip 扩展

从用户的 PopClip 扩展目录只读扫描 `.popclipext` 包。支持旧版 plist、JSON，以及 YAML/JS/TS 等配置的顶层标量头信息；不执行任何扩展代码。存在多种配置时核实标识符一致。

官方发布号取自 `_Signature.plist` 的 `Metadata.version`，并核对 `Metadata.identifier` 与扩展配置。`popclipVersion` / 旧格式 `Required Software Version` 是最低 PopClip 构建，不能作为扩展发布版本。没有可靠发布号时显示版本待确认，不因文件不同或名称相似报告更新。

读取 [PopClip 官方目录](https://www.popclip.app/extensions/) 本身加载的公开 JSON 数据，按唯一标识符匹配。资源文件名从网页动态发现，不硬编码构建后的资源哈希，不执行下载的 JavaScript。随后核实详情中的标识符、发布版本、最低 PopClip 构建和最低 macOS 版本。

兼容更新直接提供官方包的下载入口。最新版不兼容时，最多查询 20 个比本地新的历史版本，核实官方归档的标识符、发布号和要求，提供已核实的兼容更新；不提供降级，不承诺目录一定存在适用历史版本。归档只读取元数据，不展开到扩展目录；检查路径、符号链接、重复项和大小限制。

下载后由用户打开扩展包，交给 PopClip 确认安装，再点击“安装后重新检查”。UpPear 不覆盖已安装扩展，不改写 PopClip 配置、签名、授权，不自动更新 PopClip 主程序。

主程序与每个扩展拥有独立的忽略标识符。菜单栏和通知仅统计本次已核实的兼容更新；不兼容、版本待确认、检查失败和过期缓存不计为更新。

依据：[包结构与配置格式](https://www.popclip.app/dev/packages)、[顶层字段](https://www.popclip.app/dev/top-level-properties)、[官方路径](https://www.popclip.app/kb/paths)、[含历史版本的官方详情示例](https://www.popclip.app/extensions/x/8tjp5p)。目录数据布局不是官方承诺稳定的公共 API；布局变化时明确报错并保留官方查看入口。

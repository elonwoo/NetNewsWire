# Notes for coding agents

本文件只做导航：动手之前先读对应文档，再核对源码的实际写法。文档与代码不一致时按代码的写法做，并在最终回复里列出发现的冲突点。

## 构建、测试与首次初始化

做任何构建、跑测试、配置签名之前，先读 [docs/build-and-test.md](docs/build-and-test.md)，再核对 `buildscripts/build_and_test.sh`、`buildscripts/quiet_build_and_test.sh`、`setup.sh` 和 `NetNewsWire.xctestplan` 的实际内容。脚本才是命令的来源；文档里的命令与脚本不一致时以脚本为准。

## 架构、模块与平台代码

改 `Modules/`、`Mac/`、`iOS/`、`Shared/` 下的代码之前，先读 [docs/architecture.md](docs/architecture.md)，再核对目标模块的公开 API 与 `NetNewsWire.xcodeproj` 中的 target 配置。

涉及扩展点（Share 扩展、Safari 扩展、iOS Widget、macOS AppleScript、Siri Intent）时，同样先读 [docs/architecture.md](docs/architecture.md) 的 Extension Points 一节，再核对对应的 target 与扩展目录。

## 代码风格

写或改 Swift 代码之前，先读 [docs/code-style.md](docs/code-style.md) 和上游权威指南 [Technotes/CodingGuidelines.md](Technotes/CodingGuidelines.md)。前者只记录本 fork 更严格或补充的约定；两者冲突时按更严格的项目指令执行（已知冲突：force unwrap）。动手时再核对目标文件周边代码的既有写法。

## 测试通过不等于 bug 修好

宣布某个 bug 已修复之前，先读 [LESSONS.md](LESSONS.md)，按其中规则确认有会失败的测试覆盖，或在没有测试、不可测时完成手动验证。

## Technotes 主题索引

`Technotes/` 下是与上游同步的技术文档，本 fork 不修改、不删除。下面是本仓库实际会用到的部分；引用路径为 `Technotes/` 内的相对位置。

### 编码与平台技术选型

| 文档 | 用途 | 注意事项 |
| --- | --- | --- |
| `CodingGuidelines.md` | 上游编码权威指南：价值观、Swift 风格、API 设计、断言与导入约定 | 与本 fork 的 [docs/code-style.md](docs/code-style.md) 冲突时，按更严格的一方执行 |
| `SwiftUI-UIKit-AppKit-Guidelines.markdown` | 决定某个界面用 SwiftUI、UIKit 还是 AppKit | 选型前先读，再核对目标平台现有界面的实现方式 |

### 数据模型、存储与清理

| 文档 | 用途 | 注意事项 |
| --- | --- | --- |
| `Accounts.markdown` | 账户体系：Local、iCloud 与各同步服务的差异 | 改账户行为前读，再核对 `Modules/Account` |
| `ArticlesAndStatuses.markdown` | 为什么 `Article` 与 `ArticleStatus` 分表存放 | 改数据模型或查询前读，再核对 `Modules/ArticlesDatabase` |
| `DatabaseCleanup.md` | 旧文章与状态的清理机制（主要适用于 OnMyMac 账户） | 改清理逻辑前读，并确认其他同步账户是否应沿用各自规则 |
| `RetentionPolicy.markdown` | 保留策略：哪些文章应展示给用户，以及实现方式 | 改展示过滤或保留上限前读 |
| `AvoidFeedParsing.markdown` | 直连订阅源时如何避免不必要的 feed 解析 | 改 `Modules/RSParser` 调用路径前读 |
| `Testing/StateRestoration.md` | 状态恢复的人工测试步骤（iPhone/iPad） | 需要手动验证，不能用单测替代 |

### 界面、渲染与扩展

| 文档 | 用途 | 注意事项 |
| --- | --- | --- |
| `Themes.md` | `.nnwtheme` 主题包结构与渲染约定 | 改文章渲染或主题加载前读，再核对 `Themes/` 与 `Shared/` |
| `Widgets.md` | iOS 各尺寸 Widget 的清单与行为 | 改 `Widget/` 前读 |
| `Accessibility.md` | 自定义控件的可访问性要求 | 新增或大改界面控件前读 |
| `HiddenPrefs.md` | 隐藏偏好项的命名与查找方式（键定义见 `AppDefaults.swift`） | 加偏好项前读，再核对 `AppDefaults.swift` |
| `Dependencies.markdown` | 第三方依赖清单（FMDB 等）与自有框架说明 | 引入依赖或改 `Modules/RSDatabase` 前读 |

### 发布与开发流程

| 文档 | 用途 | 注意事项 |
| --- | --- | --- |
| `HowToDoiOSAppStoreRelease.markdown` | iOS App Store 发布步骤 | 发布前读，按其中的顺序逐条执行 |
| `HowToDoiOSTestFlightRelease.markdown` | iOS TestFlight 发布步骤（含构建版本号修改） | 发布前读，先确认所在分支正确 |
| `HowToDoMacSparkleRelease.markdown` | macOS Sparkle 发布步骤（含各 xcconfig 的版本字段） | 发布前读，注意要同步修改多个 xcconfig |
| `DevelopmentAlphaBeta.md` | Development、Alpha、Beta、Final 各阶段对版本质量的定义 | 判断当前版本处于什么阶段时读 |
| `FindingYourDevelopmentTeamID.md` | 如何在本机找到 Development Team ID | 首次配置签名时读；签名配置见 [docs/build-and-test.md](docs/build-and-test.md) |
| `HowToSupportNetNewsWire.markdown` | 如何支持本项目（说明项目不接受捐款） | 回答支持方式或贡献渠道时读 |
| `privacypolicy.markdown` | 隐私政策原文 | 涉及数据收集、上报的问题先读 |

### 上游状态与发布记录（不代表本 fork 当前状态）

| 文档 | 用途 | 注意事项 |
| --- | --- | --- |
| `Status.md` | 上游当前的里程碑与各平台发布状态 | 上游快照，不代表本 fork 的实际状态；判断本 fork 状态以仓库代码为准 |
| `ReleaseNotes-iOS.markdown` | 上游 iOS 发布记录 | 同上，不代表本 fork 已包含这些版本 |
| `ReleaseNotes-Mac.markdown` | 上游 macOS 发布记录 | 同上，不代表本 fork 已包含这些版本 |

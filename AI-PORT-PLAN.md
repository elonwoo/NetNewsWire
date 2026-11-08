# AI 功能移植实施计划

目标：把 `AI-PORT-TODO.md` 里的 29 项搬进本仓库。策略是先串行建共享地基，再用四个 worktree 并行开发，最后合并验收。

## 一、为什么不能一上来就并行

四个工作包都会依赖同一批东西：数据模型、模型客户端、提示词、任务队列、事件通知。这些东西如果各包各写一套，合并时必然打架；如果每包都去改共享文件，worktree 隔离就失效了。

所以顺序是：**阶段 0 把共享接口冻结，阶段 1 才开 worktree。**

## 二、阶段 0：共享地基（主分支，串行）

### 0.1 摸清接入点（已完成）

已确认：

- `Mac` 和 `Shared` 是 `PBXFileSystemSynchronizedRootGroup`，往里加文件不改 pbxproj。
- 新增 SPM 模块必须改 `project.pbxproj`：产品声明、`PBXBuildFile`、Frameworks/Embed phase、目标 `packageProductDependencies`；测试还要改 `NetNewsWire.xctestplan`。
- 数据库是 SQLite + FMDB，迁移用「建表 if not exists + 检查列再 ALTER」。
- `RSWeb` 支持 POST/JSON/自定义 header，无流式。
- Keychain 凭据类型是固定枚举，加 AI 密钥要改 `Modules/Secrets`。
- 没有可复用的持久化任务队列，AI 队列自己写。
- 快捷键帮助页已存在，是静态 HTML，只需补内容。

### 0.2 新建 AI 模块

建议做成独立 SPM 模块 `Modules/AI`，理由：可单测、边界清楚、并行时不碰主 App 的构建配置。

模块里一次定死：

| 内容 | 说明 |
|---|---|
| 数据模型 | `Translation`、`Rewrite`、`ChatMessage`、`AIJob` |
| 存储协议 | `AIStore` 协议 + SQLite 实现；表结构和迁移在模块内 |
| 模型客户端 | `AIClient` 协议 + magpie 实现（`http://127.0.0.1:3425`，模型 `deepseek-v4.1-flash`） |
| 提示词 | 五套改写提示词、标题与正文翻译协议、伴读系统提示词、12 条阅读任务 |
| 任务队列 | 串行执行、失败退避、可暂停、退出不丢任务 |
| 事件 | 译文就绪、改写就绪、任务状态变化 |

### 0.3 项目接线

- `Package.swift` 加模块。
- Xcode 项目引用模块。
- 主 App 侧留一个 `AIEnvironment` 单例作为入口。

### 0.4 阶段 0 验收

- 模块能编译。
- 能对本地 magpie 发一次真实请求并拿到回答。
- 能写入并读回一条译文记录。
- 主 App 能编译，行为不变。

## 三、阶段 1：四个并行工作包

| 包 | 范围 | 主要目录 | 依赖阶段 0 的 | 验收 |
|---|---|---|---|---|
| W1 四栏与 AI 栏 | 主窗口四栏、AI 对话栏、原文 / 中文页签、翻译视图切换、快捷键提示面板 | `Mac/MainWindow/**`、`Mac/AI/UI/**` | 数据模型、事件 | 四栏可开合、宽度记忆正确、AI 栏能收发消息、三栏模式不回归 |
| W2 翻译与改写 | 标题翻译、正文翻译、改写、质量校验、缓存、改写队列、模型失败重试 | `Mac/AI/Translation/**`、`Mac/AI/Rewrite/**` | 客户端、提示词、队列 | 选中文章自动补标题；正文翻译出对照视图；改写进中文页签；失败可重试 |
| W3 内容源 | RSSHub、Product Hunt 官网、Hugging Face 论文卡片、微信目录与图片代理、YouTube 内嵌、X News、乔木博客 | `Mac/AI/Sources/**` | 存储、事件 | 七个源能抓、微信图片能显示、YouTube 链接内嵌播放 |
| W4 快捷键与沉浸阅读 | J / K 上下篇、A 问 AI、`[` / `]` 订阅、I 沉浸阅读、Esc 退出 | `Shared/Resources/*.plist`、`Mac/MainWindow/Keyboard/**` | 无 | 全部键位生效、沉浸模式进出正常、不影响现有键位 |

### 路径不相交检查

- W1 与 W4 都碰 `Mac/MainWindow`，但文件不同：W1 改 `MainWindowController.swift`，W4 改 `Keyboard/` 下的文件和三个 plist。
- W2 与 W1 都在 `Mac/AI` 下，但子目录不同。
- W3 全部是新增文件。
- 共享注册点只有 `Package.swift` 和 `project.pbxproj`，都在阶段 0 处理完，阶段 1 不动。

### 每包的契约

- 范围：只动上表列出的目录，不改共享接口。
- 需要改共享接口时：停下来，回报，由主分支先改。
- 验证命令：
  ```
  xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire \
    -destination "platform=macOS,arch=arm64" -configuration Debug \
    build CODE_SIGNING_ALLOWED=NO
  ```
- 同一报错连续两次修不好：停下来报告，不硬试。
- 完成标准：上面的验收项全部实际跑过，附命令输出。

## 四、worktree 与 Orca 会话

### 位置

worktree 放在仓库内的 `.worktrees/` 下，不越出项目目录：

```
NetNewsWire/
  .worktrees/
    w1-ui/
    w2-ai/
    w3-sources/
    w4-keys/
```

`.gitignore` 加一行 `.worktrees/`。

### 建 worktree

```sh
cd /Users/elonwoo/Dev/Github/NetNewsWire
git worktree add .worktrees/w1-ui -b ai/w1-ui
git worktree add .worktrees/w2-ai -b ai/w2-ai
git worktree add .worktrees/w3-sources -b ai/w3-sources
git worktree add .worktrees/w4-keys -b ai/w4-keys
```

每个 worktree 在 Orca 里单独开一个会话，会话目录指到对应 `.worktrees/<name>`。

### 分支与提交

- 每包只在自己的分支上提交，按文件名 stage。
- 不改共享文件；需要改就回到主分支。
- 不 push，不开 PR，等合并时统一处理。

## 五、合并与验收

1. 四个包分别通过自己的验收。
2. 按 W1 → W2 → W3 → W4 顺序合并到主分支，每次合并后跑一次完整构建。
3. 合并冲突只应出现在 `project.pbxproj` 或 `Package.swift`；出现其他文件的冲突说明路径划分被破坏，停下来查。
4. 合并完做一次整体验收：启动 app，走一遍「订阅 → 选中 → 自动补标题 → 翻译 → 改写 → 对话 → 沉浸阅读」。
5. 跑一次现有测试，确认没有回归。

## 六、风险与规避

| 风险 | 规避 |
|---|---|
| `project.pbxproj` 在四个分支同时被改 | 阶段 0 确认 synchronized group；如果必须改 pbxproj，就在阶段 0 一次加好所有目录 |
| Swift 6 并发报错集中在阶段 1 | 阶段 0 定好 `Sendable` 边界，客户端和队列用 actor |
| 数据库迁移冲突 | 表结构只在阶段 0 的模块里定义，阶段 1 只调用 |
| 四个分支各自能编译、合并后编译不过 | 每包验收必须包含一次完整构建，不只看单文件 |
| worktree 内构建产物互相污染 | 每个 worktree 用独立 DerivedData 路径 |

## 七、开工前确认

- 方向：按本文档的阶段 0 串行、阶段 1 四包并行推进。
- 槽位：阶段 0 由主循环定契约、派 subagent 实现、主循环验收；阶段 1 四个包各派 subagent，主循环做验收和合并。
- 自动驾驶：阶段 0 完成后停下来给你看一次，阶段 1 一路跑完再交付。

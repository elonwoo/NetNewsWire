# NetNewsWire MCP Server 实施契约（v2）

> 这是 v2 设计契约，已按它实现并通过评审。**实现以代码为准**：本文件与代码冲突时按代码执行。
>
> 本文件中的路径均相对于 `Tools/NetNewsWireMCP/`：源码在 `Sources/NetNewsWireMCPCore/`，入口在 `Sources/NetNewsWireMCP/`，测试在 `Tests/NetNewsWireMCPTests/`，验收脚本在 `scripts/`。

本文件只定义「要什么、怎么算对」。可执行命令不写在这里：验收脚本随代码进仓库 `scripts/`，由 developer 实现、evaluator 实跑复核。契约里没有任何需要被编译或执行的内容。

- 形态：独立 SPM 可执行文件，MCP stdio transport，只读。
- 账户：仅 OnMyMac。
- 版本：v2 增量。v1 的 5 个工具保持参数面，新增 `query`，并给 `list_articles` / `search_articles` 加游标分页。
- 事实来源：§B 各条于 2026-11-15 对真实库复验；它们约束实现，但不是验收期望值。

---

## 实现状态

| 节 | 一句话对应 |
| --- | --- |
| A. 范围与文件清单 | 由 `Package.swift`、`Sources/NetNewsWireMCP/main.swift`、`Sources/NetNewsWireMCPCore/` 下的各源文件、`Tests/NetNewsWireMCPTests/` 与 `scripts/` 落地。 |
| B. 数据与账户口径 | 数据根与账户闸门在 `DataLocator.swift`，schema 断言在 `Database.swift`，订阅树在 `OPML.swift`，名称与统计口径在 `ListFeeds.swift`。 |
| C. 工具面 | 注册与参数校验在 `Tools.swift`，六个工具分别在 `ListFeeds.swift`、`ListArticles.swift`、`SearchArticles.swift`、`GetArticle.swift`、`UnreadDigest.swift`、`Query.swift`，游标在 `Pagination.swift`，体积与截断在 `ContentLimits.swift`，返回值结构在 `Models.swift`。 |
| D. 不变量 | 由 §C 各工具文件保证；对应的行为测试在 `Tests/NetNewsWireMCPTests/ToolsTests.swift`、`PaginationAndQueryTests.swift`、`ReadOnlyTests.swift`。 |
| E. 退出码 | 启动校验顺序与映射在 `Tools.swift` 的 `Startup`，进程退出在 `main.swift`，根/账户错误在 `DataLocator.swift`，数据库与 schema 错误在 `Database.swift`，OPML 错误在 `OPML.swift`。 |
| F. 地雷清单 | 只读连接、ATTACH、hot journal 在 `Database.swift`，根选择在 `DataLocator.swift`，FTS/LIKE 在 `SearchArticles.swift`，SQL 闸门与预算在 `Query.swift`，名称与正文来源在 `ListFeeds.swift`/`GetArticle.swift`，字节边界在 `ContentLimits.swift`。 |
| G. 分阶段与验收类别 | 握手与客户端在 `scripts/handshake.py`、`scripts/mcp_client.py`、`scripts/verify_client.py`，数据与工具验收在 `scripts/verify_list_feeds.py`、`verify_articles.py`、`verify_search.py`、`verify_digest.py`、`verify_pagination.py`、`verify_readonly.py`、`verify_fixtures.py`，单测在 `Tests/NetNewsWireMCPTests/`。 |
| H. Stop 条件 | 流程约束，无对应产品代码；由 `scripts/` 的验收脚本与人工执行。 |

---

## A. 范围与文件清单

### A.1 新增文件（唯一允许改动的目录：`Tools/NetNewsWireMCP/`）

| 路径 | 作用 |
| --- | --- |
| `Package.swift`、`Package.resolved` | SPM 清单与锁定 |
| `Sources/NetNewsWireMCP/main.swift` | stdio 入口、Server 装配 |
| `Sources/NetNewsWireMCPCore/DataLocator.swift` | 数据根定位、候选与 mtime、账户闸门 |
| `Sources/NetNewsWireMCPCore/Database.swift` | 只读打开、ATTACH、schema 断言、单事务、进度预算 |
| `Sources/NetNewsWireMCPCore/OPML.swift` | OPML 解析（文件夹、feed 名） |
| `Sources/NetNewsWireMCPCore/Models.swift` | 工具返回值结构、日期格式、JSON 值映射 |
| `Sources/NetNewsWireMCPCore/ContentLimits.swift` | 体积上限、正文截断、有界编码 |
| `Sources/NetNewsWireMCPCore/Tools.swift` | 启动校验、工具注册、参数校验、错误映射 |
| `Sources/NetNewsWireMCPCore/ListFeeds.swift` | 工具 1 |
| `Sources/NetNewsWireMCPCore/ListArticles.swift` | 工具 2 |
| `Sources/NetNewsWireMCPCore/SearchArticles.swift` | 工具 3 |
| `Sources/NetNewsWireMCPCore/GetArticle.swift` | 工具 4 |
| `Sources/NetNewsWireMCPCore/UnreadDigest.swift` | 工具 5 |
| `Sources/NetNewsWireMCPCore/Query.swift` | 工具 6（受控只读 SQL） |
| `Sources/NetNewsWireMCPCore/Pagination.swift` | keyset 游标编码与过滤指纹 |
| `Tests/NetNewsWireMCPTests/Fixtures/{schema.sql,seed.sql}` | 假库 fixture |
| `Tests/NetNewsWireMCPTests/{DataLocatorTests,DatabaseTests,ToolsTests,ReadOnlyTests,PaginationAndQueryTests}.swift` | 单元测试 |
| `scripts/{handshake,mcp_client,verify_list_feeds,verify_articles,verify_search,verify_digest,verify_pagination,verify_readonly,verify_fixtures,verify_client}.py` | 握手探针、客户端验收与各层验收脚本；内容由 developer 定 |
| `README.md` | 运行方式、客户端注册、6 个工具的参数、游标与截断语义（P0 产出） |

### A.2 明确不碰

`NetNewsWire.xcodeproj`、`project.pbxproj`、`xcconfig/`、`buildscripts/`、`setup.sh`、任何 app target 或 scheme、`Modules/`、`Mac/`、`iOS/`、`Shared/`、`Themes/`、`Technotes/`、已有测试、用户数据目录。构建只走 `swift build`。没有文件改动落在 `Tools/NetNewsWireMCP/` 之外。

### A.3 依赖与构建

- 唯一直接依赖：官方 `https://github.com/modelcontextprotocol/swift-sdk`，产品 `MCP`，精确锁定 0.12.1。传递依赖为 swift-nio、swift-log、eventsource、swift-system、swift-atomics、swift-collections（以 `Package.resolved` 为准），不直接引用。
- SQLite 走系统 `import SQLite3` 的 C API；不使用 `RSDatabase`、`ArticlesDatabase`，不引入 FMDB。
- `Package.swift` 必须声明 `.macOS("13.0")`；不声明平台会被依赖的最低版本顶掉。
- 构建只要求 `swift build -c release`；不生成 Xcode 工程，不加构建脚本。

---

## B. 数据与账户口径

### B.1 数据根

- 两个候选（不是优先级）：`~/Library/Application Support/NetNewsWire`（活跃，非沙盒）与 `~/Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Application Support/NetNewsWire`（2026-11-09 旧副本）。
- 两者都存在时，比较 `Accounts/OnMyMac/DB.sqlite3` 的 mtime，取较新者；不比较目录 mtime。mtime 读不到时，选择能读到 mtime 的候选；两者都读不到时取第一个存在的候选。相同 mtime 时取候选列表中的第一个。
- 环境变量 `NNW_MCP_DATA_ROOT` 是覆盖：设置后只用该根，找不到即退出 4，不回退。纯空白值视为未设置；路径中的 `~` 会展开。
- 自动模式下固定两个候选；override 模式下只有 override 根这一项，且不回退默认根。选中根、全部候选及各自 mtime、是否歧义，必须同时出现在 stderr 与 `list_feeds` 返回值里（GUI 客户端看不到 stderr）。
- 两个候选的 mtime 都可能是旧的：活跃库实测停更 20 到 58 分钟是常态，「mtime 新」不等于「刚写过」，也不据此推断 app 是否在运行。

### B.2 账户

- `Accounts/` 下每个目录是一个账户；只有 `OnMyMac` 可读。
- 其它账户只读目录名，绝不打开其数据库文件。
- 只有其它账户 → 退出 4，stderr 含「暂不支持账户：<name>」（多个账户名以「、」连接）；`Accounts/` 为空 → 退出 4，stderr 含「暂不支持」但没有账户名可报。OnMyMac 与其它账户并存 → 正常服务，`warnings` 中出现 `暂不支持账户：<name>`。
- 不依据 `Settings.plist` 的 `isActive` 判断账户是否启用（本机 OnMyMac 为 false 但数据在更新）。

### B.3 文件

- OnMyMac 账户目录下三个必需文件：`DB.sqlite3`、`FeedSettings.db`、`Subscriptions.opml`。其它账户目录只读目录名，不检查也不打开其文件。
- `DB.sqlite3`：文章、状态、检索索引。
- `FeedSettings.db`：`feedSettings(feedURL, feedID, editedName, homePageURL, folderRelationship, ...)`。
- `Subscriptions.opml`：订阅树与文件夹；文件夹只在这里。

### B.4 schema（按名字断言，不依赖版本号）

- 活跃库 `DB.sqlite3` 的必需列：`articles(articleID, feedID, title, url, externalURL, datePublished, dateModified, searchRowID, contentText, contentHTML, authors)`、`statuses(articleID, read, starred, dateArrived)`、`search` 必须是 FTS4 且至少包含 `title`、`body` 两列，且至少一个 trigger 的 SQL 引用 `search`。
- 两套库的 `articles` 都有 `contentText`、`contentHTML` 列；旧副本这两列内容全空，不是缺列。旧副本的数据库从不打开，只读它的 `DB.sqlite3` mtime。
- `FeedSettings.db`：`feedSettings` 表存在。
- 两套库的 `user_version` 都是 0，没有迁移信息；断言只按对象名，失败即退出 3。
- 两套库的 `articles` 列不完全相同；一律显式列名查询，禁止 `select *`。

### B.5 值域与已知空洞

- 全库 `journal_mode = delete`，没有 WAL；活跃目录没有 `-wal`/`-shm`，旧副本目录残留一个 32 KB 的 `FeedSettings.db-shm`。
- 数据根目录下有 `Images.db` 且使用 WAL（带 `-wal`/`-shm`），与本服务无关；WAL 判定只针对两个目标库文件（见 H4）。
- `datePublished` 存 epoch 秒，类型混杂（integer / real / null）；实测 4 篇日期在未来。
- `feedID` 与 `feedURL` 全等（79/79）；OPML 的 `xmlUrl` 集合与之一致。
- `feedSettings.folderRelationship` 全空；文件夹只能从 OPML 取。
- OPML 的 79 个 feed 全部位于 4 个文件夹内，没有根级 feed。
- `search.title` 空串 14 行、null 0 行；对外统一把空串归一为 null。
- `statuses` 当前无缺行，但规则仍按「缺行 = 未读」处理。
- URL：`url` 空 3442/6053，`externalURL` 空 1220，两者不同时为空；7 对重复 `url`。
- 时间字段一律 UTC ISO-8601，无值输出 null。

### B.6 正文与检索语料

- 可读纯文本主体来自 FTS4 的 `search.body`：已剥标签、空白归一、撇号被去掉，可能带站点尾注；最长十余万字符。
- `articles.contentText` 大多为空（19 篇非空，最长 1253 字符），只作兜底；`markdown` 全空，不可用；`contentHTML` 是原始 HTML，v1 不返回。
- 标题以 `search.title` 为准；`articles.title` 只用于展示，两列在部分行上不同。
- FTS4 默认 simple tokenizer：中文只能整词命中，整词命中数显著少于子串命中数，子串必须走 LIKE；ASCII 大小写不敏感。
- 容量口径（截至 2026-11-15）：`DB.sqlite3` 约 125 MB；`search.body` 约 18.5M 字符 / 26.7 MB UTF-8。LIKE 全表扫随库体积线性增长。

---

## C. 工具面（6 个，v2）

### C.0 通用约定

- 每个工具标注 `readOnlyHint: true`、`openWorldHint: false`、`idempotentHint: true`、`destructiveHint: false`。
- 返回只有一个 text content block，内容是紧凑 JSON；工具级失败时 `isError: true`，content 是可读中文错误文本并点名原因。
- **一次工具调用只用一条连接、一个 `BEGIN DEFERRED` 读事务**：计数、列表、单篇的所有 SQL 都在同一事务内完成，结束后回滚/关闭；不跨调用持有事务或语句。OPML 在事务外读一次并复用。
- **两个库在同一连接上用 `ATTACH` 合并**：主连接以 `SQLITE_OPEN_READONLY` 打开 `DB.sqlite3`，随后 `ATTACH` 把 `FeedSettings.db` 挂成别名（如 `fs`）。附加库继承主连接的打开标志，自动只读。实现约束：把 `ATTACH` 放在 `BEGIN DEFERRED` 之前完成，使附加库与主库进入同一个读事务；随后开启读事务，跨库 `SELECT` 与主库同处该事务。不要为 `FeedSettings.db` 另开第二条连接。`ATTACH` 的路径按 SQL 字符串字面量用单引号拼接并转义内部单引号。
- `feed_title` 使用 C.1 的名称优先级；`folder` 来自 OPML；文章 `title` 的空串一律归一为 null。
- 列表排序固定 `datePublished DESC, articleID DESC`，null 日期排最后；其它列表排序见各工具。
- 分页工具（`list_articles`、`search_articles`）的游标是**不透明字符串**，客户端不得解析，只能原样回传；游标只在相同过滤条件下有效，格式非法或条件不匹配 → `isError`。
- 每个响应受字节上限约束。列表类工具超限从尾部丢弃条目（digest 丢整个 feed）并置 `truncated`/`omitted`，不截断单条对象内部字段；`get_article` 只截正文并置 `content_truncated`（见 C.4）。
- 所有读失败按未知处理并整体报错，不返回空集冒充「没有数据」。

### C.1 `list_feeds`（无参数）

返回字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `data_root` | string | 选中根 |
| `data_root_mtime` | string | 选中根 `DB.sqlite3` 的 mtime（UTC） |
| `data_age_seconds` | int | 当前时间减 mtime，负数 clamp 到 0 |
| `ambiguous_data_roots` | bool | 自动模式下两候选都存在、两者 mtime 都可读到且 mtime 相差 < 300 秒；override 模式恒为 false |
| `data_root_candidates` | array | 每项 `{path, exists, db_mtime, selected}`；自动模式固定 2 项，override 模式只有 1 项 |
| `warnings` | string[] | 只有三类：数据超过 86400 秒、根歧义、`暂不支持账户：<name>` |
| `account` | string | 固定 `OnMyMac` |
| `unsupported_accounts` | string[] | 其它账户目录名 |
| `generated_at` | string | 生成时刻（UTC） |
| `totals` | object | `feeds`、`folders`、`articles`、`unread`、`starred` |
| `folders` | array | `{name, feed_count, unread_count}`，按 `name ASC` 排序 |
| `feeds` | array | 字段见下，按 `unread_count DESC, title ASC, feed_id ASC` 排序 |
| `truncated` / `omitted` | bool / int | 是否因 64 KiB 丢弃了 feed 及丢弃数 |

`feeds[]` 每项：`feed_id`（string）、`title`（string，空串归一后的值）、`folder`（string 或 null）、`home_page_url`（string 或 null）、`article_count`（int）、`unread_count`（int）、`latest_published_at`（string 或 null）。

- 名称优先级：`FeedSettings.editedName`（非空）→ OPML `text`（空则 `title`）→ `feedID`。
- `home_page_url` 取 `FeedSettings.homePageURL`（非空）→ OPML `htmlUrl` → null。
- `FeedSettings` 中 `feedURL` 为 NULL、空串或纯空白（trim 后为空）的行一律丢弃：不计入 `totals.feeds`，不出现在 `feeds[]`。理由与 §C.5 对空 `feedID` 的处理一致：不是可识别的 feed。
- `folders[]` 只来自 OPML，不设「未分组」桶。当且仅当所有 feed 都归属某个文件夹时，`sum(feed_count) == totals.feeds` 且 `sum(unread_count) == totals.unread`；存在根级 feed 时两条都取 `<= totals`，差额就是根级 feed 的计数。
- `totals` 始终按全量统计，不受 `feeds` 截断影响。

### C.2 `list_articles`

| 参数 | 类型 | 必填 | 默认 | 约束 |
| --- | --- | --- | --- | --- |
| `feed_id` | string | 否 | null | 精确匹配；未知则 `isError` |
| `unread_only` | bool | 否 | false | 只读过滤 |
| `since` | string | 否 | null | ISO 8601；含下界，`datePublished >= since`；`datePublished` 为 null 不满足；无法解析 → `isError` |
| `after` | string | 否 | null | 不透明游标；无效 → `isError` |
| `limit` | int | 否 | 20 | 1..100 |

返回字段：`total_matched`、`returned`、`omitted`、`truncated`、`next_cursor`（string 或 null）、`articles[]`。每项：`article_id`、`title`（string 或 null）、`feed_id`、`feed_title`、`folder`、`published_at`、`url`、`read`、`starred`、`author`、`excerpt`、`content_chars`。

- `feed_id` 的已知集合 = `FeedSettings.feedID` ∪ OPML `xmlUrl` ∪ `articles.feedID` 的并集；只有不在此集合中的值才 `isError`。未过滤列表可以出现孤儿 feedID（不在 FeedSettings 与 OPML 中），此时 `feed_title` 回退为 feedID、`folder` 为 null；用该 feed_id 过滤必须能命中，不得报未知。
- `feedID` 与 `feedURL` 当前全等，但契约只承诺 `feed_id` 使用 feed 标识本身（当前即 `articles.feedID` 列），不承诺 `feedURL` 列可作为 `feed_id`；过滤不做 url 列兜底。
- `title` 取 `search.title`，空串归一为 null；`articles.title` 只用于展示，不参与返回。
- `excerpt` 取 `search.body` 前 160 字符并压平换行。
- `author` 取 `authors` JSON 首元素 `name`；列 null、解析失败或空数组为 null。
- `content_chars` 是 `get_article` 对同一篇会返回的那份正文（`search.body` 非空用它，否则 `contentText`，都空为 0）的总 Character 数，等于该篇的 `content_total_chars`。`excerpt` 只看 `search.body`，因此 body 为空而 `contentText` 非空时 `excerpt` 为空串而 `content_chars > 0`。
- `read` 缺 `statuses` 行按未读计。
- `since` 与 `datePublished` 的比较按 UTC 秒；`datePublished` 为 null 的行在带 `since` 时一律排除。
- `after` 按 `datePublished DESC, articleID DESC`（null 日期最后）从游标位置之后取数；`total_matched` 始终是满足过滤条件的全量条数，与 `limit`/`after` 无关；每次调用做两次 COUNT（全量匹配数、游标之后剩余数），当前库约 6132 行，索引计数在毫秒级。`list_articles` 不安装 progress budget；3000 ms 预算只用于 `search_articles` 与 `query`。
- `next_cursor` 仅当当前页最后一行之后还有满足过滤条件的行时返回，否则为 null；因字节上限被丢弃的行也在「之后」，同样会给出游标。
- 上限 48 KiB。

### C.3 `search_articles`

| 参数 | 类型 | 必填 | 默认 | 约束 |
| --- | --- | --- | --- | --- |
| `query` | string | 是 | — | trim 后 1..200 字符 |
| `after` | string | 否 | null | 不透明游标；无效 → `isError` |
| `limit` | int | 否 | 20 | 1..50 |

返回字段：`query`、`mode_used`（`terms` / `substring` / `hybrid`）、`total_matched`、`returned`、`omitted`、`truncated`、`next_cursor`（string 或 null）、`articles[]`。每项：`article_id`、`title`、`feed_id`、`feed_title`、`published_at`、`url`、`read`、`starred`、`snippet`。

检索策略（两类词项不得交叉）：

- 分类单位是字符段：空白切 token 后，按字符类别拆成 ASCII 字母数字段与 CJK 段；同一 token 内两类都有时也拆开并取交集。
- **CJK 判定**：Character 落在 U+3400–U+4DBF、U+4E00–U+9FFF、U+F900–U+FAFF 之一；全角标点不算 CJK。
- **ASCII 段只走 FTS**：每个 ASCII 字母数字段作为一个词项，加双引号，空格连接（隐式 AND），最多 20 项；操作符 `AND`、`OR`、`NOT`、`NEAR` 一律作为被引号包住的字面词，不做布尔解析。
- **CJK 段只走 LIKE**：对 `search.title` 或 `search.body` 做字面量子串匹配，`%`、`_`、`\` 逐个转义并声明 `ESCAPE '\'`；CJK 段不进 FTS。
- **混合查询**：ASCII 段走 FTS、CJK 段走 LIKE，两者取交集；`mode_used = hybrid`。全部为 ASCII 段时 `terms`，全部为 CJK 段时 `substring`。
- 拆分后既没有 ASCII 字母数字段、也没有 CJK 段（例如全是标点）→ `isError`「查询没有可检索的词项」，不返回 `mode_used`。
- `snippet` 取法：先在 `search.title` 中找首个命中位置，找不到再在 `search.body` 中找；以命中位置为中心，前 80 字符到后 80 字符，压平换行，总长不超过 400 字符；两处都不命中时从 `body` 开头取。混合查询优先用 CJK 词项的命中位置。
- 任何触发 LIKE 的查询设 3000 ms 预算，超时返回 `isError` 并提示缩小范围。
- `after` 与 `next_cursor` 的语义同 C.2：按 `datePublished DESC, articleID DESC`（null 最后）取游标之后的行，`total_matched` 不随 `after`/`limit` 变化。
- 上限 32 KiB。

### C.4 `get_article`

| 参数 | 类型 | 必填 | 默认 | 约束 |
| --- | --- | --- | --- | --- |
| `article_id` | string | 二选一 | null | 精确匹配 |
| `url` | string | 二选一 | null | 先 `url`，再 `externalURL`；多命中按 `datePublished DESC, articleID DESC` 取第一 |
| `max_chars` | int | 否 | 20000 | 500..32000，按 Character 计 |

返回字段：`article_id`、`feed_id`、`feed_title`、`folder`、`title`、`url`、`external_url`、`published_at`、`modified_at`、`arrived_at`、`read`、`starred`、`authors`、`content_source`、`content`、`content_chars`、`content_total_chars`、`content_bytes`、`content_truncated`、`duplicate_count`。

- 两个定位参数都没给或都给了 → `isError`；找不到 → `isError` 并回显查询值。
- `authors`：string[] 或 null。取 `authors` JSON 数组每个元素的 `name` 组成字符串数组，缺 `name` 的元素跳过，结果为空数组时返回 `[]`；列 null、JSON 非法或顶层不是数组时返回 null。
- `title` 取 `search.title`，空串归一为 null；`articles.title` 只用于展示，不参与返回。
- 正文来源优先级：`search.body` 非空 → `contentText` 非空 → 空串；`content_source` 取 `search_index_text` / `contentText` / `none`。
- 空正文返回空串与 0 计数，不是错误。
- **96 KiB 是 `get_article` 整个 JSON 响应的 UTF-8 字节上限**，不是 `content` 字段单独的上限。
- 截断顺序：先按 `max_chars` 截 Character；若整个响应仍超 96 KiB，继续按 Character 边界缩短 `content` 直到放下；任一缩短都置 `content_truncated: true`。`content` 已为空仍超限（元数据过大）→ `isError`「响应过大」。
- `duplicate_count` 口径：按 `url` 查询时等于 `articles.url` 等于该值的行数；按 `externalURL` 查询时等于 `articles.externalURL` 等于该值的行数；按 `article_id` 查询时固定为 1。

### C.5 `unread_digest`

| 参数 | 类型 | 必填 | 默认 | 约束 |
| --- | --- | --- | --- | --- |
| `days` | int | 否 | 1 | 1..90 |

返回字段：`window{since, until}`、`totals{unread_total, unread_in_window, articles_in_window, unread_feeds}`、`feeds[]`、`truncated`、`omitted_feeds`、`omitted_unread_in_window`。

`feeds[]` 每项：

| 字段 | 类型 | 口径 |
| --- | --- | --- |
| `feed_id` | string | feed URL |
| `title` | string | 名称优先级同 C.1 |
| `folder` | string 或 null | 来自 OPML；不在任何文件夹时为 null |
| `unread_total` | int | 该 feed 全量未读数，含窗口外与日期为 null 的文章 |
| `unread_in_window` | int | 该 feed 窗口内 `read = 0` 的文章数 |
| `latest_published_at` | string 或 null | 该 feed **窗口内全部文章**（不论读否）的最大 `datePublished`；窗口内无文章为 null |
| `articles` | array | 窗口内**未读**文章，按 `datePublished DESC, articleID DESC`，最多 3 条；每项 `{article_id: string, title: string 或 null, published_at: string 或 null}`，`title` 空串归一为 null |

- 只列出 `unread_in_window > 0` 的 feed；`unread_total` 仍是该 feed 全量未读数。
- 窗口口径固定为 `since <= datePublished <= until`，两端都含；`until` 是本次生成的时刻，`since = until - days * 86400`。
- **`feedID` 为空串的文章完全排除**：`totals` 四个字段、`feeds[]` 与 `omitted_unread_in_window` 一致地不计。理由：空 `feedID` 不是可识别的 feed；与 `list_feeds` 对 `feedURL` 为 NULL 或空串的行按同一口径处理。真实库 0 行。
- `totals.unread_total` 是全库未读总数，含日期为 null 的文章、不含 `feedID` 为空串的文章；`unread_in_window` 只含窗口内未读。
- `articles_in_window` 是窗口内全部文章（不论读否，`feedID` 非空）；`unread_feeds` 是窗口内至少一篇未读的 feed 数。
- feed 排序 `unread_in_window DESC, latest_published_at DESC, feed_id ASC`，null 日期排最后。
- 字节上限 48 KiB 时**从尾部丢弃整个 feed**，单个 feed 的 3 条明细不单独丢弃；`omitted_feeds` 是被丢的 feed 数，`omitted_unread_in_window` 是这些 feed 的 `unread_in_window` 之和，`truncated` 当且仅当 `omitted_feeds > 0`。
- **不加游标**：`unread_digest` 不提供 `after`，也不提供 `after_feed_id`。理由：它上限 200 个 feed / 48 KiB，当前 79 个 feed 永不截断；为不存在的截断场景加分页只增加状态与验收成本。将来截断频繁出现再议。

### C.6 `query`

受控的只读 SQL 出口，不是主路径：它把 schema 知识推给调用方，表结构变更时最先坏；保留它是工具面覆盖不到时的逃生门。

| 参数 | 类型 | 必填 | 默认 | 约束 |
| --- | --- | --- | --- | --- |
| `sql` | string | 是 | — | 单条 `SELECT` 或 `WITH` 语句 |
| `limit` | int | 否 | 50 | 1..100 |

返回字段：

| 字段 | 类型 | 口径 |
| --- | --- | --- |
| `columns` | string[] | 结果列名，按 SELECT 顺序；允许重名 |
| `rows` | array | 二维数组，每行按 `columns` 顺序。NULL → null；INTEGER/REAL → number，绝对值超过 2^53 的 INTEGER 转十进制字符串；TEXT → string；BLOB → 小写十六进制字符串 |
| `row_count` | int | 等于 `rows.length` |
| `truncated` | bool | 是否有行因上限未返回 |
| `truncated_reason` | string 或 null | `row_limit` / `byte_limit` / null；两者同时触发报 `byte_limit`。单行超限走错误路径，不产生该值 |
| `elapsed_ms` | int | 本次执行耗时（毫秒） |

硬约束（安全边界，逐条实现）：

1. **单条语句**：去掉末尾分号与注释后，不允许出现第二条语句；多语句 → `isError`，类别 `multiple_statements`。
2. **只允许 `SELECT` 或 `WITH` 开头**：跳过前导空白与注释后取首关键字，大小写不敏感；`EXPLAIN`、`PRAGMA`、`ATTACH`、`UPDATE`、`DELETE`、`INSERT` 等一律 → `isError`，类别 `not_select`。
3. **自动加限**：有效行数上限 = `min(limit, 100)`。实现不改写 SQL、不追加 `LIMIT`；按原语句逐行读取，取够上限后再多读一行判断是否还有剩余，因此返回列名与直接执行原语句一致。语句自带更小的 `LIMIT` 时以语句为准，且不置截断。
4. **行数与字节上限**：有效行数上限 = `min(limit, 100)`；响应上限 64 KiB。若**第一行**单独编码后的 JSON 字节数（含外层数组括号）就超过 64 KiB，返回 `isError`，类别 `single_row_too_large`，文本含实际字节数与「请缩小列投影或加过滤」；只有多行累计超限才从尾部丢行，`truncated = true`，原因按第 8 条填。
5. **3000 ms 预算**：与 `search_articles` 使用相同的 progress handler 实现（每 1000 条 VM 指令检查一次）；超时 → `isError`，类别 `timeout`，文本「查询超时」。
6. **同一只读连接与事务**：主库 `DB.sqlite3` + `ATTACH` 的 `fs`（`FeedSettings.db`）可用，语句与其它查询同处一个 `BEGIN DEFERRED`；只读标志与 `query_only` 兜底，任何写尝试（包括 `WITH` 内的写）都会失败并返回 `execution_error`，不产生副作用。这是有意的：静态判定一条 `WITH` 是否可写代价过高，只读连接是最终防线，不做静态拒绝。
7. **错误不回显完整 SQL**：只返回类别 + 原 SQL 前 200 字符。类别至少覆盖 `multiple_statements` / `not_select` / `syntax_error` / `timeout` / `execution_error` / `single_row_too_large`。
8. **截断原因优先级**：因字节上限丢行 → `byte_limit`；仅因行数上限丢行 → `row_limit`；两者同时发生报 `byte_limit`。没有丢行时 `truncated = false`、原因为 null。

结果顺序不承诺，除非语句自带 `ORDER BY`。`query` 不提供游标；需要翻页时由调用方把游标条件下推进 SQL。

### C.7 每个保留参数的证明责任

| 参数 | 由哪条验收类别证明 |
| --- | --- |
| `list_articles.feed_id` | P1 过滤计数：同一快照按 feed 直查的计数等于 `total_matched`，返回项 `feed_id` 全等于参数；孤儿 feedID 用同一口径 |
| `list_articles.unread_only` | P1 过滤计数：与直查 `read = 0` 的计数相等 |
| `list_articles.limit` | P1 上限不变量：`returned + omitted == min(remaining_matched, limit)` 且 `returned == articles.length` |
| `list_articles.since` | P1 since 对照：与同快照按 `datePublished >= since` 直查（null 不计）相等 |
| `list_articles.after` | P1 游标：跨 null 日期边界与遍历完备性 |
| `search_articles.query` | P2 检索对照：ASCII 对 FTS 直查、CJK 对 LIKE 直查、混合对交集直查 |
| `search_articles.limit` | P2 上限不变量：同 D5 |
| `search_articles.after` | P2 游标：复用 P1 的两份游标 fixture 同一口径 |
| `query.sql` | P2 query 拒绝：多语句、非 SELECT、只读无副作用 |
| `query.limit` | P2 query 限流：自动加限、行数与字节上限 |
| `get_article.article_id` | P1 单篇对照：字段与同快照直查行相等 |
| `get_article.url` | P1 URL 对照：按并列规则取第一且 `duplicate_count` 符合 C.4 口径 |
| `get_article.max_chars` | P1 截断不变量：见 D9 |
| `unread_digest.days` | P2 窗口对照：与同边界（含上界）直查计数相等 |
| `list_feeds` 无参数 | 无数值参数需要证明 |

---

## D. 不变量（永远成立，不依赖具体数据）

- **D1** `unread_digest` 中 `sum(feeds[].unread_in_window) + omitted_unread_in_window == totals.unread_in_window`，任何截断下都成立；分母不含 `feedID` 为空串的文章。
- **D2** `totals.unread_in_window` 等于窗口内 `read = 0` 的文章数，窗口为 `since <= datePublished <= until` 两端含；分母不含 `feedID` 为空串的文章。
- **D3** `totals.unread_total` 包含没有 `datePublished` 的未读文章（同样不含 `feedID` 为空串的文章），窗口计数不包含它们。
- **D4** `list_articles` 的 `returned == articles.length`；`omitted` 只统计当前页（游标之后、limit 窗口内）因体积被丢弃的条数；`returned + omitted == min(remaining_matched, limit)`，无 `after` 时 `remaining_matched == total_matched`。
- **D5** `search_articles` 的 `returned == articles.length`；`omitted` 只统计当前页（游标之后、limit 窗口内）因体积被丢弃的条数；`returned + omitted == min(remaining_matched, limit)`，无 `after` 时 `remaining_matched == total_matched`。
- **D6** 列表类工具的 `total_matched` 与 `limit`、`after` 无关，只由过滤条件决定。
- **D7** `get_article.content_bytes` 等于 `content` 的 UTF-8 字节数。
- **D8** `get_article.content_chars <= content_total_chars`。
- **D9** `content_truncated` 为真当且仅当 `content_chars < content_total_chars`；为假时两者相等。
- **D10** 每个响应的 UTF-8 字节数不超过该工具上限；列表类工具的 `truncated` 为真当且仅当本次响应丢弃了条目，`get_article` 用 `content_truncated` 表示正文被截。
- **D11** 文章列表按 `datePublished DESC, articleID DESC`，null 日期排最后；`list_feeds.feeds` 按 `unread_count DESC, title ASC, feed_id ASC`，`folders` 按 `name ASC`，`unread_digest.feeds` 按 `unread_in_window DESC, latest_published_at DESC, feed_id ASC`。
- **D12** 按 `url` 或 `externalURL` 命中时按 `datePublished DESC, articleID DESC` 取第一行；`duplicate_count` 按 C.4 的列口径计数。
- **D13** `data_age_seconds == max(0, 当前时间 - data_root_mtime)`（±10 秒），候选中有且仅有一个 `selected`。
- **D14** `list_feeds.totals` 按全量统计；`folders[]` 只来自 OPML，当且仅当所有 feed 都归属某个文件夹时 `sum(folders[].feed_count) == totals.feeds` 且 `sum(folders[].unread_count) == totals.unread`，存在根级 feed 时两条均 `<= totals` 且差额即根级 feed；`warnings` 非空当且仅当数据超过 86400 秒、根歧义或存在其它账户。
- **D15** 缺 `statuses` 行的文章按未读计，计入 `unread` 与 `unread_only`。
- **D16** `excerpt` 不超过 160 字符，`snippet` 不超过 400 字符。
- **D17** 过滤类参数（`feed_id`、`unread_only`）下，返回的每一项都满足该条件，且 `total_matched` 等于同条件直查计数。
- **D18** 空正文返回 `content: ""`、`content_chars = content_total_chars = 0`，不是错误。
- **D19** `unread_digest` 的 `unread_feeds == len(feeds) + omitted_feeds`。
- **D20** `unread_digest` 的 `articles` 只含窗口内未读文章，最多 3 条；`latest_published_at` 只由窗口内文章决定。
- **D21** 游标采用 keyset 语义：位置由排序键 `(datePublished, articleID)` 决定，禁止用 offset。在固定数据上，沿 `next_cursor` 逐页走完得到的 `articleID` 序列等于不带游标时的全量结果，且无重复；游标编码必须区分「有日期」与「无日期」两段，能跨越 null 日期边界。遍历期间新增的行是否出现由其在排序中的位置决定，已存在的行不重复、不跳过。不采用快照式游标：快照会在本次遍历中永久隐藏遍历期间到达的新文章。
- **D22** `query` 只执行单条 `SELECT`/`WITH`；有效行数不超过 `min(limit, 100)`，响应不超过 64 KiB，执行超过 3000 ms 即中止并报错；拒绝多语句与非 `SELECT`/`WITH`，错误不回显完整 SQL。

---

## E. 退出码

| 码 | 含义 | 触发条件 |
| --- | --- | --- |
| 3 | schema 不符 | 必需表/列缺失、`search` 不是 FTS4、没有引用 `search` 的 trigger |
| 4 | 数据根/账户/文件缺失 | 根不存在、根不是目录、`Accounts/OnMyMac` 缺失、三个文件中任一缺失、只有其它账户 |
| 5 | 数据库打开失败（含打开阶段的首次读取） | 不是数据库、`DB.sqlite3` 或 `FeedSettings.db` 为 0 字节、不可读、hot journal 导致只读无法回滚、busy 超时 |
| 6 | OPML 不可用 | 不可读、0 字节、XML 非法、缺 `<body>` |

优先级：4 先于 5，5 先于 3，3 先于 6。即「缺文件」先报 4；0 字节 DB 先报 5；schema 坏了即使 OPML 也坏，仍报 3；只有 schema 通过后才可能报 6。

schema 校验阶段发生的读取失败按 3 处理：`Startup` 把 `validateDatabase` / `validateFeedSettings` 抛出的所有 `DatabaseError` 映射为退出码 3；退出码 5 覆盖的是打开连接时（含 `ReadOnlyDatabase.init` 里的首次读取）的失败。

**启动失败（3/4/5/6）stdout 必须为 0 字节**，stderr 一段可读错误，点名原因与尝试过的路径。工具级失败不走退出码，按 C.0 返回 `isError` JSON。只有其它账户时，stderr 必须含「暂不支持」。

---

## F. 地雷清单（均已实测或由实测推出）

1. **rollback journal 的读锁**：读事务持 SHARED 锁期间，app 的写提交会被拒绝。每次调用用一个 `BEGIN DEFERRED` 事务并在结束时关闭；`busy_timeout` 2000 ms；开 `query_only`；禁止 `immutable=1`；不要尝试切 WAL。
2. **打开方式**：普通路径字符串 + `SQLITE_OPEN_READONLY`，不开 `SQLITE_OPEN_URI`。路径中的 `?`、`#`、`%` 在 URI 里会被当参数，可能夹带 `?immutable=1`。
3. **没有版本号**：`user_version` 为 0，只能按对象名断言；`select *` 在另一套库上会按位置错列。
4. **两个数据根**：容器副本是 2026-11-09 的旧数据；选错不报错，只静默返回过期数据。只比较 `DB.sqlite3` 的 mtime，并把候选与选中项同时暴露。
5. **hot journal（两个分支均已实测）**：`DB.sqlite3-journal` 与 `FeedSettings.db-journal` 都要处理。
   - 有效 magic 的 hot journal（fixture magic `d9d505f920a163d7`）：只读无法回滚，启动 `exit=5`、stdout 0 字节、journal 原样保留。
   - 零 magic 的残留（或只读读取成功）：启动 `exit=0`，stderr 记录 `hot_journal=… 存在；只读读取成功，未删除 journal`，调用结束后 journal 字节数不变（实测 4616 字节）。
   任何分支都不自行删除 journal。
6. **其它账户**：只读目录名，绝不打开其 `DB.sqlite3`；对外文案固定含「暂不支持」。
7. **FTS 查询**：原始 query 直接拼 MATCH 会 `malformed MATCH expression`；必须参数化并清洗词项，操作符加引号当字面词。
8. **LIKE 成本**：全表扫，125 MB 库热缓存几十毫秒、冷缓存数百毫秒，随体积线性增长；所有含 LIKE 的路径都要有 progress handler 预算。
9. **未来日期**：实测 4 篇 `datePublished` 在未来；窗口不带 `<= until` 会把它们算进来并让计数对不上。
10. **空值**：`search.title` 有 14 行空串、0 行 null，对外统一归一为 null；`datePublished` 可为 null、正文可为空、`statuses` 行可缺失。
11. **URL**：`url` 与 `externalURL` 都稀疏且可能重复，重复行可能 `datePublished` 完全相同；必须用 `datePublished DESC, articleID DESC` 决出唯一一行。
12. **名称来源**：文件夹只在 OPML；`feedSettings.folderRelationship` 永远为空；名称优先级 `editedName` → OPML `text`/`title` → `feedID`；`home_page_url` 优先 `FeedSettings.homePageURL`。
13. **正文来源**：`search.body` 是归一化文本（撇号被删、可能带尾注），`contentText` 大多为空，`markdown` 全空，`contentHTML` 是原始 HTML 且 v1 不返回。
14. **字符与字节**：`max_chars` 按 Character 截；96 KiB 是整条响应的上限，只在 4 字节码点或巨大元数据时先触发，缩短仍在 Character 边界。
15. **stdio 纯净**：stdout 只放 JSON-RPC（换行分隔），日志一律 stderr；stdin 立即 EOF 时拿不到任何输出，客户端必须保持 stdin 打开。
16. **快照**：测试用 `.backup` 在只读连接上生成一致快照；直接 `cp` 活库会拿到撕裂副本。
17. **0 字节文件不是打开错误**：SQLite 只读打开 0 字节文件会当空库（`schema_version = 0`、无表），不报错；必须先 stat 文件大小，否则「0 字节 DB → 5」永远触发不了。
18. **兄弟文件陷阱**：两个数据根下都有一个 0 字节的 `DB.sqlite`（无 3）；路径必须精确匹配 `DB.sqlite3`，禁止 glob 或前缀匹配。
19. **平台声明**：根 `Package.swift` 不声明 `.macOS("13.0")` 会因依赖的最低平台要求而构建失败。
20. **WAL 误判**：数据根目录下的 `Images.db` 使用 WAL 且带 `-wal`/`-shm`；WAL 判定只针对 `Accounts/OnMyMac/DB.sqlite3` 与 `FeedSettings.db` 两个文件。
21. **第二连接陷阱**：为 `FeedSettings.db` 另开连接会让计数与 feed 名称来自两个快照。必须用 `ATTACH` 挂到同一只读连接；附加库继承主连接的打开标志，自动只读，无需 URI，也不需要读写打开。

---

## G. 分阶段与验收类别

验收类别只说明「拿什么和什么比、结果必须是什么」，不写命令。命令由 developer 写在 `scripts/` 下，evaluator 实跑并按类别逐条判 pass/fail。

**fixture 通用要求**：数据类 fixture 由实现者在 `Tests/` 里用临时库构造，不依赖真实数据；真实数据验收只覆盖「数据形态恰好有」的路径。数据 fixture 必须能独立重跑，构造与清理都在临时目录内。本节 fixture 清单是唯一口径，但两处覆盖并不完全重合：`scripts/verify_fixtures.py` 覆盖进程级与工具级场景（退出码、hot journal、env 覆盖、账户闸门、64 KiB 截断、游标、query 限流等），`Tests/NetNewsWireMCPTests/` 覆盖工具级数据 fixture；两个 P2 数据 fixture（`unread_digest` 48 KiB 整 feed 截断、3000 ms LIKE 预算中断）只在单测中构造（`testUnreadDigestTruncatesWholeFeeds`、`testSearchLikeBudgetInterrupts`）。客户端 fixture 不适用临时库，见 P2。

**为什么这两个 fixture 留在单测**：这是有意决定，不是漏搬。两条的原因不一样，分开写。

1. **LIKE 预算在 MCP 层没有注入点。** `SearchArticlesTool.run` 的 `likeBudgetMilliseconds` 是 Swift 参数，默认 3000；服务端分发（`Tools.swift` 的 `search_articles` 分支）只传 `arguments` 和 `context`，请求里多传键会被 `ToolArgument.rejectUnknown` 拒绝，也没有对应的环境变量。单测能直接传 `1` 毫秒，中断必然发生。走验收脚本只能用默认的 3000 毫秒，要撞上它得让 LIKE 真实跑满 3 秒：本机用 release 包实测，4000 行、每行 3200 个 CJK 字符（约 38 MB 正文）的 CJK LIKE 查询连整次 MCP 会话（含握手）约 0.07 秒，按线性外推需要约 30 万行、约 3 GB 正文才够。每次验收都造这种数据、等满预算，换来的仍是「超时后返回什么」这一条断言；而且耗时依赖机器，快机器上未必触发。

2. **48 KiB 整 feed 截断搬过去很便宜，但没有新增覆盖。** 单测造 300 个 feed、每个一条未读文章（feed 标题各补到约 90 字符），实测这套数据构造约 0.01 秒，一次 MCP 会话约 0.25 秒；返回 49,029 字节，丢掉尾部 152 个 feed 后剩 148 个，正好卡在 49,152 字节（48 KiB）上限内。技术上完全搬得动，这里不拿「不方便」当理由。`encodeUnreadDigestBounded` 的做法是从尾部整只丢弃 feed，并把丢弃 feed 的 `unread_in_window` 累加进 `omittedUnreadInWindow`；单测直接对临时库调这个工具，字节上限、整 feed 丢弃和 D1/D19 不变量都已断言。验收脚本再跑一遍只是多包一层进程与 JSON-RPC，断言一模一样。

3. **两个单测的断言就是这两条验收要判的东西。** digest 侧断言：`json.utf8.count <= ContentLimits.unreadDigestBytes`、`truncated == true`、`omittedFeeds > 0`、每个 feed 的 `articles.count <= maxArticlesPerFeed`、`sum(returned unread) + omitted_unread_in_window == totals.unread_in_window`、`totals.unread_feeds == feeds.count + omittedFeeds`。search 侧断言：1 毫秒预算时抛出的错误文本含「检索超时」；同一查询把预算放到 60 秒时会返回 `total_matched == 1000`，证明中断来自预算而不是数据或 SQL 错误。MCP 层只负责转发参数、把错误包成 `isError`，这部分已由 `verify_fixtures.py` 的其他用例覆盖。如果以后 LIKE 预算改成可通过环境变量或工具参数配置，这条差异就该消掉，把它搬进验收脚本。

### P0：骨架 + 数据定位 + 闸门 + `list_feeds`

产出：§A.1 中除 `ListArticles`、`SearchArticles`、`GetArticle`、`UnreadDigest`、`Query` 外的全部文件，含 `README.md`；`tools/list` 只有 1 个工具。

验收类别：

- **构建**：`swift build -c release` 成功，产物可直接启动。
- **握手**：真实 MCP 客户端完成 initialize 与 tools/list，工具数 = 1，每个工具 `readOnlyHint = true`。
- **数值对照**：`list_feeds.totals.feeds` = `FeedSettings` 中 `feedURL` 非 NULL、非空白的行数；`articles` / `unread` / `starred` = 同一数据根上的等价直查；`folders` = OPML 文件夹数。真实数据 79 个 feed 全在文件夹内，两条 folders 求和取等号。
- **根级 feed**：需要 fixture：造一个不属于任何文件夹的 feed，验证它不出现在 `folders[]`、没有未分组桶，且两条 folders 求和取 `<= totals`，差额等于该 feed 的计数。单测与 `scripts/verify_fixtures.py` 各一份。
- **数据根（自动模式）**：返回值含选中根、两个候选及 mtime、`data_age_seconds` = 当前时间 - mtime（±10 秒，负数按 0）；有且仅有一个 `selected`。
- **env 覆盖**：需要 fixture：把 `NNW_MCP_DATA_ROOT` 指向不存在的路径，必须退出 4 且不回退到默认根；指向合法临时根时 `data_root_candidates` 只有 1 项且 `selected = true`。
- **账户**：仅其它账户时退出 4 且 stderr 含「暂不支持」；OnMyMac 与其它账户并存时正常返回且 `warnings` 含 `暂不支持账户：<name>`。
- **启动失败**：缺文件 → 4、0 字节 DB → 5、非数据库文件 → 5、不可读 → 5；四种情形 stdout 均为 0 字节，stderr 点名原因。
- **退出码 3**：需要 fixture：分别造「缺必需列」「`search` 不是 FTS4」「没有引用 `search` 的 trigger」三个临时库，确均退出 3 且 stdout 为 0。
- **退出码 6**：需要 fixture：分别造「OPML 0 字节」「非法 XML」「不可读」「缺 `<body>`」四个临时库，确均退出 6 且 stdout 为 0。
- **体积（64 KiB）**：需要 fixture：造出几百个 feed 使 `list_feeds` 超过 64 KiB；真实 79 个 feed 约 22 KB，触发不了。
- **hot journal**：需要 fixture：造两枚 journal——有效 magic（如 `d9d505f920a163d7`）与零 magic 残留；前者必须退出 5、stdout 0 字节、journal 保留，后者必须正常服务、stderr 记录且 journal 未被删除。
- **只读**：对一致快照连续 200 次调用前后，两个库文件的 sha256 与 mtime 不变。
- **stdout 纯净**：stdio 会话中 stdout 上每一行都能被 JSON 解析，日志只出现在 stderr。

### P1：文章读取（`list_articles` + `get_article`）

产出：两个工具实现与对应单元测试；`tools/list` 为 3 个工具。

验收类别：

- **握手**：工具数 = 3，名字与 §C 一致。
- **过滤计数**：`feed_id` 与 `unread_only` 组合下的 `total_matched` 等于同一快照上同条件直查计数；返回项全部满足过滤条件。
- **since 对照**：取一个 ISO 时间点，`total_matched` 等于同快照按 `datePublished >= since` 直查的计数，null 日期文章不计；无法解析的 since 返回 `isError`。
- **孤儿 feedID**：需要 fixture：造一篇 `articles.feedID` 不在 `FeedSettings` 与 OPML 的文章；未过滤列表必须能列出它（`feed_title` = feedID、`folder` = null），按该 feed_id 过滤必须命中而不是报未知。真实数据孤儿 feedID 为 0。
- **上限不变量**：`limit` 取 1、20、100 时均满足 `returned == articles.length`；无 `after` 时 `returned + omitted == min(total_matched, limit)`，有 `after` 时用游标之后的剩余条数。
- **游标跨 null 日期**：需要 fixture：造有日期与 null 日期混合的十余条数据，用小 limit 逐页走完；有日期行全部排在 null 行之前，边界处不重复、不丢行。
- **游标遍历完备性**：需要 fixture：造超过 100 条（如 250）符合过滤条件的数据，limit=40 逐页走完；收集的 articleID 集合等于无游标全量，且无重复。固定数据上判定；并发新增只验已存在行不重复、不跳过。
- **单篇对照**：抽一篇正文非空的文章，逐字段与同快照直查行比较，必须相等；抽一篇空正文文章，返回空串与 0 计数且不是错误。
- **作者形态**：需要 fixture：造 `authors` 为 null、`[]`、非法 JSON 三行，分别要求返回 null、`[]`、null；真实数据只有 null 形态（1110 行），`[]` 与非法 JSON 为 0 行。
- **contentText 兜底**：需要 fixture：造一篇 `search.body` 为空、`contentText` 非空的文章，`content_source` 必须为 `contentText` 且正文来自该列；同时该篇在 `list_articles` 中的 `excerpt` 为空串、`content_chars` 等于 `get_article` 的 `content_total_chars` 且大于 0；真实数据中该组合为 0 行。
- **statuses 缺行**：需要 fixture：造一篇没有 `statuses` 行的文章，必须按未读计；真实数据缺行为 0。
- **内容不变量**：`content_bytes` = 正文 UTF-8 字节数；`content_chars <= content_total_chars`；`content_truncated` 当且仅当字符数小于总字符数。
- **URL 对照**：用一个重复 URL 查询，返回按并列规则确定的第一行，`duplicate_count` 等于该列同值行数；用 `article_id` 查询时 `duplicate_count = 1`。
- **体积**：`limit = 100` 的列表响应不超 48 KiB。
- **96 KiB 上限**：需要 fixture：造正文由 32000 个 4 字节码点组成的文章，使整条响应超过 96 KiB，验证继续截断并置 `content_truncated`。
- **只读**：重复 P0 的快照哈希检查，结果不变。

### P2：检索、摘要、完整验收

产出：`search_articles`、`unread_digest`、`query`；`tools/list` 为 6 个工具。

验收类别：

- **握手**：工具数 = 6，名字集合与 §C 完全一致。
- **检索对照**：ASCII 词条与同快照 FTS 直查计数相等；纯 CJK 与 `search.title`/`search.body` 的 LIKE 直查相等，且 CJK 不进 FTS；混合查询与「FTS 交 LIKE」直查相等；三者都验证 `total_matched` 与 `limit` 无关。
- **检索行为**：`mode_used` 与策略一致；结果按 `datePublished DESC, articleID DESC` 排序；`snippet` 不超过 400 字符且围绕首个命中位置。
- **search 游标**：`search_articles` 的 `after`/`next_cursor` 复用 P1 的两份游标 fixture（null 边界与遍历完备性），并验证 `total_matched` 与 `limit`/`after` 无关。
- **query 多语句**：需要 fixture：造两条 SELECT 用分号连接的语句与一条带尾分号的单条语句；前者报 `multiple_statements`，后者正常执行。
- **query 非 SELECT**：需要 fixture：分别以 `EXPLAIN`、`PRAGMA`、`ATTACH`、`UPDATE` 开头提交，全部报 `not_select`，只读库无任何副作用。
- **query 自动加限**：需要 fixture：造超过 100 行的临时表；无 LIMIT 且 limit=10 时返回 10 行、`truncated`、原因 `row_limit`；语句自带 LIMIT 5、limit=50 时返回 5 行且不截断。
- **query 字节上限**：需要 fixture：造两组装数据——第一行单独超过 64 KiB 时返回 `isError`（类别 `single_row_too_large`，文本含实际字节数）；多行累计超过 64 KiB 时从尾部丢行、`truncated = true`、原因 `byte_limit`、`row_count == rows.length`。
- **空查询**：全标点查询返回 `isError`，不返回结果对象。
- **窗口对照**：`unread_digest` 的 `articles_in_window`、`unread_in_window` 与同一 `since`/`until` 直查相等；日期在未来的文章不计入。
- **截断不变量**：需要 fixture：造超过 200 个 feed 或超过 48 KiB 的窗口，验证 `sum + omitted_unread_in_window == totals.unread_in_window`、`unread_feeds == len(feeds) + omitted_feeds`、`truncated` 等价于 `omitted_feeds > 0`。
- **空 feedID**：需要 fixture：造一篇 `feedID = ''` 的窗口内未读文章，验证 `totals` 四个字段、`feeds[]`、`omitted_unread_in_window` 都不含它，D1 与 D2 同时成立；真实库 0 行，NetNewsWire 不写空 feedID。
- **3000 ms 预算**：需要 fixture：造一张足够大的正文表使 LIKE 超过 3 秒，验证返回明确 `isError` 而不是挂起或部分结果；真实数据 LIKE 约 60 ms，触发不了。
- **延迟**：在 125 MB 快照上，含 LIKE 的查询 p95 < 500 ms、单次 < 2500 ms。
- **客户端**：需要 fixture：可用的 MCP 客户端与可注册的 server 条目（不是数据 fixture，无法用临时库构造）；注册后列表显示 `Connected`，验收结束移除并确认列表为 0。
- **只读**：全量 6 个工具下再跑一次快照哈希检查。

---

## H. Stop 条件（停下回报，不自行绕路）

1. `swift build` 连续两次因依赖解析或 swift-sdk 编译失败。不改依赖版本、不换 transport、不手写 JSON-RPC。
2. swift-sdk 0.12.1 的实际 API 与契约不符（`Server`、`StdioTransport`、`CallTool.Result` 形状变化）。报差异，不猜替代 API。
3. 真实库出现第三种 schema 形态（契约未列出的表/列变化，或 `search` 不再是 FTS4）。只报 `sqlite_master` 原文，不做兼容猜测、不写库。
4. **只有 `Accounts/OnMyMac/DB.sqlite3` 与 `Accounts/OnMyMac/FeedSettings.db`** 的 `journal_mode` 变成 WAL，或这两个文件旁出现对应 `-wal` 文件。数据根下的 `Images.db` 等其它库不触发这条。
5. 自动模式下真实数据根不在两个候选，或 override 模式下 `NNW_MCP_DATA_ROOT` 指向无效。列出探测结果，不扩大搜索到全盘。
6. 验收需要的动作越界：改 xcodeproj、改 app 代码、给用户数据目录写权限。
7. 客户端注册连续两次不是 `Connected`，且 stderr 无明确原因。
8. 快照（工具是唯一可能写者）的哈希发生变化。活库哈希变化不判 fail，因为 app 在写、无法归因。
9. `git status` 出现 `Tools/NetNewsWireMCP/` 之外的改动。
10. 需要第 7 个工具，或需要给 `unread_digest` 加游标/`after_feed_id`，或需要恢复一个已砍掉的参数。工具面是冻结的，先回来讨论。
11. 发现契约自身矛盾（两条不变量无法同时成立、窗口边界与计数口径冲突）。停止并改契约，不用代码绕过。

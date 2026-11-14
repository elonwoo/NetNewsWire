# NetNewsWire MCP Server

只读的 NetNewsWire MCP 服务端，独立 SPM 可执行文件，使用 MCP stdio transport。

本仓库当前实现 **P0 阶段**：数据根定位、账户闸门、只读数据库打开与 schema 断言，以及 `list_feeds` 工具。`tools/list` 在 P0 只注册 1 个已实现的工具；其余工具属于后续阶段。

## 构建

```sh
swift build -c release --package-path Tools/NetNewsWireMCP
```

产物：`Tools/NetNewsWireMCP/.build/release/NetNewsWireMCP`。

要求 macOS 13.0 或更新。唯一直接依赖是 `modelcontextprotocol/swift-sdk` 0.12.1；SQLite 使用系统 `SQLite3` 模块。

## 运行与客户端注册

服务端通过 stdin/stdout 通信：**stdout 只输出换行分隔的 JSON-RPC，所有日志和诊断写入 stderr**。stdin 关闭时进程退出；客户端必须保持 stdin 打开。

Claude Code 示例：

```sh
claude mcp add --transport stdio netnewswire -- \
  /absolute/path/to/Tools/NetNewsWireMCP/.build/release/NetNewsWireMCP
```

通用 MCP 客户端配置：

```json
{
  "mcpServers": {
    "netnewswire": {
      "command": "/absolute/path/to/Tools/NetNewsWireMCP/.build/release/NetNewsWireMCP",
      "args": []
    }
  }
}
```

## 数据根

默认探测两个候选；两者都存在时比较 `Accounts/OnMyMac/DB.sqlite3` 的 mtime，取较新者，不比较目录 mtime：

1. `~/Library/Application Support/NetNewsWire`
2. `~/Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Application Support/NetNewsWire`

环境变量 `NNW_MCP_DATA_ROOT` 是覆盖：设置后只使用该根，找不到直接退出 4，不回退到默认候选。客户端在 GUI 中看不到 stderr，因此选中根、两个候选与各自 mtime、根歧义也会出现在 `list_feeds` 返回值里。

账户只接受 `Accounts/OnMyMac`。其它账户目录只读取目录名，绝不打开其数据库；存在其它账户时通过 `unsupported_accounts` 与 `warnings` 的 `暂不支持账户：<name>` 报告。

## 只读保证

- 普通路径字符串 + `SQLITE_OPEN_READONLY` 打开，不启用 URI。
- 每次打开后执行 `PRAGMA query_only = ON`，调用 `sqlite3_busy_timeout(database, 2000)`（2000 ms），并立即 `PRAGMA schema_version` 强制真实读取。
- 每次工具调用只使用一条连接、一个 `BEGIN DEFERRED` 读事务；`FeedSettings.db` 通过 `ATTACH` 附加在同一连接上（附加库继承 `SQLITE_OPEN_READONLY` 与 `query_only`），不另开连接。调用结束前 `ROLLBACK`，不跨调用持有事务。
- 不删除 hot journal，不切换 WAL，不写任何用户数据目录。
- 打开前显式 stat 文件大小：0 字节数据库按退出 5 处理。
- 可空字段（feed 的 `folder`、`home_page_url`、`latest_published_at` 与候选根的 `db_mtime`）在无值时输出显式 `null`，键始终存在，不会被省略。

## 工具（P0）

### `list_feeds`

无参数。返回 OnMyMac 账户的订阅源、文件夹、文章与未读统计。

主要字段：

- `data_root`、`data_root_mtime`、`data_age_seconds`、`ambiguous_data_roots`
- `data_root_candidates`：每项 `{path, exists, db_mtime, selected}`
- `warnings`：数据超过 86400 秒未更新、根歧义、`暂不支持账户：<name>`
- `account`、`unsupported_accounts`、`generated_at`
- `totals`：`feeds`、`folders`、`articles`、`unread`、`starred`
- `folders`：`{name, feed_count, unread_count}`，按 `name` 升序
- `feeds`：`{feed_id, title, folder, home_page_url, article_count, unread_count, latest_published_at}`，按 `unread_count` 降序、`title` 升序、`feed_id` 升序
- `truncated` / `omitted`：响应超过 64 KiB 时从尾部丢弃 feed

口径：

- 名称优先级：`FeedSettings.editedName`（非空）→ OPML `text`（空则 `title`）→ `feedID`。
- `home_page_url`：`FeedSettings.homePageURL`（非空）→ OPML `htmlUrl` → `null`。
- `folder` 只来自 `Subscriptions.opml`。
- 缺 `statuses` 行的文章按未读计。
- `feedURL` 为 `NULL` 或空串的行不是可识别的 feed，不计入 `totals.feeds` 与 `feeds[]`。
- 根级 feed 的 `folder` 为 `null`，不进入 `folders[]`；`folders[]` 不会生成合成的「未分组」桶。因此 `sum(folders[].feed_count)` 可能小于 `totals.feeds`，差额就是根级 feed 数（`unread_count` 同理）。
- `totals` 始终按全量统计，不受 `feeds` 截断影响。
- 时间字段为 UTC ISO-8601，无值输出 `null`。
- `null` 是显式值：`folder`、`home_page_url`、`latest_published_at`、`db_mtime` 的键不会因为值为空而消失。
- trigger 是否引用 `search` 按 SQL 标识符判断；`searchRowID` 是一个独立标识符，不会被误判为对 `search` 表的引用。

## 退出码

| 码 | 含义 |
| --- | --- |
| 3 | schema 不符（必需表/列缺失、`search` 不是 FTS4、没有引用 `search` 的 trigger） |
| 4 | 数据根/账户/必需文件缺失，或 `NNW_MCP_DATA_ROOT` 指向无效路径 |
| 5 | 数据库打开或读取失败（非数据库、0 字节、不可读、busy 超时、hot journal 无法回滚） |
| 6 | OPML 不可用（不可读、0 字节、XML 非法、缺 `<body>`） |

启动失败时 stdout 保持 0 字节，stderr 给出原因与尝试过的路径。工具级失败不走退出码，而是返回 `isError: true` 与可读中文错误。

## 测试与验收脚本

```sh
swift test --package-path Tools/NetNewsWireMCP

python3 Tools/NetNewsWireMCP/scripts/handshake.py
python3 Tools/NetNewsWireMCP/scripts/verify_list_feeds.py
python3 Tools/NetNewsWireMCP/scripts/verify_readonly.py
python3 Tools/NetNewsWireMCP/scripts/verify_fixtures.py
```

- `handshake.py`：真实 stdio 会话，`initialize` + `tools/list` + 一次 `list_feeds`。
- `verify_list_feeds.py`：在活跃数据根上把 `totals` 与等价 SQL 直查逐项比较。
- `verify_readonly.py`：用 SQLite `.backup` 生成一致快照，连续 200 次调用前后比较三个文件的 sha256 与 mtime。
- `verify_fixtures.py`：临时库构造退出码 3/4/5/6、env 覆盖、账户闸门、64 KiB 截断与 stdout 纯净性。

单元测试全部在临时目录内构造数据库与 OPML，不读写真实 `~/Library/Application Support/NetNewsWire`。

## hot journal 行为

`DB.sqlite3-journal` 与 `FeedSettings.db-journal` 都不删除，分两个实测分支：

- **零 magic 的残留/伪造 journal**：不是真 hot journal。只读读取成功，进程退出 0，stderr 记录 journal 路径，journal 保留。
- **有效 magic 的真 hot journal**：写事务被强杀后留下。只读无法回滚，进程退出 5，stdout 为 0 字节，journal 保留。

两个分支都由 `scripts/verify_fixtures.py` 用临时副本构造并断言。

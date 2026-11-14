# NetNewsWire MCP Server

只读的 NetNewsWire MCP 服务端，独立 SPM 可执行文件，使用 MCP stdio transport。

本仓库实现 **v2**：数据根定位、账户闸门、只读数据库打开与 schema 断言，以及 6 个只读工具：`list_feeds`、`list_articles`、`get_article`、`search_articles`、`unread_digest`、`query`。`list_articles` 与 `search_articles` 支持 keyset 游标分页；`query` 是受控的只读 SQL 出口。`initialize` 响应的 `instructions` 是服务自描述：只读、覆盖本机 NetNewsWire 订阅源（不代表全网），以及各工具的用法要点（如 `search_articles` 无时间参数，需先取当前时间再按结果的 `published_at` 筛选时间窗口）。

## 构建

```sh
swift build -c release --package-path Tools/NetNewsWireMCP
```

产物：`Tools/NetNewsWireMCP/.build/release/NetNewsWireMCP`。

要求 macOS 13.0 或更新。唯一直接依赖是 `modelcontextprotocol/swift-sdk` 0.12.1；SQLite 使用系统 `SQLite3` 模块。

## 运行与客户端注册

服务端通过 stdin/stdout 通信：**stdout 只输出换行分隔的 JSON-RPC，所有日志和诊断写入 stderr**。stdin 关闭时进程退出；客户端必须保持 stdin 打开。

Claude Code 示例（用户级注册）：

```sh
claude mcp add --scope user netnewswire -- \
  /absolute/path/to/Tools/NetNewsWireMCP/.build/release/NetNewsWireMCP
```

`scripts/verify_client.py` 会自动完成「注册 → `claude mcp list` 显示 Connected → 立即移除 → 确认 `~/.claude.json` 无残留」的检查。

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
- 每次工具调用只使用一条连接、一个 `BEGIN DEFERRED` 读事务；`FeedSettings.db` 通过 `ATTACH` 附加在同一连接上（附加库继承 `SQLITE_OPEN_READONLY` 与 `query_only`），不另开连接。`ATTACH` 在 `BEGIN DEFERRED` 之前完成，使两个库进入同一个读事务；调用结束前 `ROLLBACK`，不跨调用持有事务。
- 不删除 hot journal，不切换 WAL，不写任何用户数据目录。
- 打开前显式 stat 文件大小：0 字节数据库按退出 5 处理。
- 可空字段（feed 的 `folder`、`home_page_url`、`latest_published_at` 与候选根的 `db_mtime`）在无值时输出显式 `null`，键始终存在，不会被省略。

## 工具（6 个）

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

### `list_articles`

参数：

| 参数 | 类型 | 默认 | 约束 |
| --- | --- | --- | --- |
| `feed_id` | string | null | 精确匹配 `articles.feedID`；未知则 `isError` |
| `unread_only` | bool | false | 只返回未读文章；缺 `statuses` 行按未读计 |
| `since` | string | null | ISO 8601 下界，含 `datePublished >= since`；`datePublished` 为 null 不满足；解析失败 `isError` |
| `after` | string | null | 上一页的 `next_cursor`，不透明，原样回传；只能与相同 `feed_id`/`unread_only`/`since` 同用 |
| `limit` | int | 20 | 1..100 |

返回 `total_matched`、`returned`、`omitted`、`truncated`、`next_cursor`、`articles[]`。每项：`article_id`、`title`、`feed_id`、`feed_title`、`folder`、`published_at`、`url`、`read`、`starred`、`author`、`excerpt`、`content_chars`。

口径：

- `feed_id` 的已知集合 = `FeedSettings.feedID` ∪ OPML `xmlUrl` ∪ `articles.feedID`。不在集合里的值才返回 `isError`；`feedURL` 列不参与判断，过滤也不会回退到 `articles.url`/`feedURL`。
- 未过滤列表可能出现孤儿 `feedID`（不在 `FeedSettings` 与 OPML 中）：此时 `feed_title` 回退为 `feedID`、`folder` 为 `null`；用该 `feed_id` 过滤能正常命中。
- 排序固定 `datePublished DESC, articleID DESC`，null 日期排最后；`total_matched` 与 `limit` 无关。
- `title` 取 `search.title`，空串归一为 `null`；`articles.title` 不参与返回。
- `excerpt` 取 `search.body` 前 160 个 Character 并把换行压成空格。
- `author` 取 `authors` JSON 首元素的 `name`；列 null、解析失败或空数组为 `null`。
- `content_chars` 是 `get_article` 会返回的那份正文的总 Character 数（`search.body` 非空用它，否则用 `contentText`），不返回正文本身。
- `feed_title` / `folder` 的取值与 `list_feeds` 一致。
- 响应超过 48 KiB 时从尾部丢弃文章并置 `truncated` / `omitted`；`returned + omitted == min(remaining_matched, limit)`，`omitted` 只统计 `limit` 窗口内被丢弃的条数。
- 游标是 keyset 语义，位置由 `(datePublished, articleID)` 决定，不使用 offset。游标区分「有日期」与「无日期」两段，能跨 null 日期边界：有日期行全部走完后，下一页从 null 行继续。
- `next_cursor` 仅在当前页最后一行之后还有满足过滤条件的行时非 null；因字节上限被丢弃的行也在「之后」，同样会给出游标。`total_matched` 与 `after`/`limit` 无关。
- 游标只在相同过滤条件（`feed_id`、`unread_only`、`since`）下有效；格式非法或条件不匹配返回 `isError`。

### `get_article`

参数：

| 参数 | 类型 | 默认 | 约束 |
| --- | --- | --- | --- |
| `article_id` | string | null | 与 `url` 二选一，精确匹配 |
| `url` | string | null | 与 `article_id` 二选一；先匹配 `articles.url`，再匹配 `articles.externalURL` |
| `max_chars` | int | 20000 | 500..32000，按 Character 截断正文 |

返回 `article_id`、`feed_id`、`feed_title`、`folder`、`title`、`url`、`external_url`、`published_at`、`modified_at`、`arrived_at`、`read`、`starred`、`authors`、`content_source`、`content`、`content_chars`、`content_total_chars`、`content_bytes`、`content_truncated`、`duplicate_count`。

口径：

- 两个定位参数都缺或都给 → `isError`；找不到 → `isError` 并回显查询值。
- 正文来源优先级：`search.body` 非空 → `contentText` 非空 → 空串；`content_source` 依次为 `search_index_text`、`contentText`、`none`。空正文返回 `content: ""` 与 0 计数，不是错误。
- `authors` 是 `authors` JSON 数组每个元素的 `name` 组成的字符串数组，缺 `name` 的元素跳过；空数组返回 `[]`。列 null、JSON 非法或顶层不是数组时返回 `null`。
- `content_bytes` 等于返回正文的 UTF-8 字节数；`content_truncated` 当且仅当 `content_chars < content_total_chars`。
- 先按 `max_chars` 截 Character；若整条 JSON 响应仍超过 96 KiB，继续在 Character 边界缩短 `content`，任一次缩短都置 `content_truncated: true`。正文已为空仍超限 → `isError`「响应过大」。
- `duplicate_count`：按 `article_id` 查询固定为 1；按 `url` 命中 `articles.url` 时等于该列同值行数，否则等于 `articles.externalURL` 同值行数。
- 多行命中时按 `datePublished DESC, articleID DESC`（null 日期最后）取第一行。

### `search_articles`

参数：

| 参数 | 类型 | 默认 | 约束 |
| --- | --- | --- | --- |
| `query` | string | 必填 | trim 后 1..200 个 Character |
| `after` | string | null | 上一页的 `next_cursor`，不透明，原样回传；只能与相同 `query` 同用 |
| `limit` | int | 20 | 1..50 |

返回 `query`、`mode_used`、`total_matched`、`returned`、`omitted`、`truncated`、`next_cursor`、`articles[]`。每项：`article_id`、`title`、`feed_id`、`feed_title`、`published_at`、`url`、`read`、`starred`、`snippet`。

检索策略：

- 先按空白切 token，再按字符类别拆成「ASCII 字母数字段」与「CJK 段」；同一 token 内两类都有时拆开并取交集。CJK 判定为 U+3400–U+4DBF、U+4E00–U+9FFF、U+F900–U+FAFF，全角标点不算 CJK。
- ASCII 段只走 FTS4：每段加双引号、空格连接（隐式 AND），最多 20 项。`AND`/`OR`/`NOT`/`NEAR` 只是被引号包住的字面词，不做布尔解析。
- CJK 段只走 LIKE：在 `search.title` 或 `search.body` 上做字面量子串匹配，`%`、`_`、`\` 逐个转义并声明 `ESCAPE '\'`，CJK 段不进 FTS。
- 全部为 ASCII 段时 `mode_used = terms`，全部为 CJK 段时 `substring`，两类都有时 `hybrid`（FTS ∩ LIKE）。拆分后没有任何可检索词项（例如全是标点）→ `isError`「查询没有可检索的词项」，不返回结果对象。
- 任何含 LIKE 的查询都有 3000 ms 预算；超时返回 `isError`「检索超时」并提示缩小范围，不返回部分结果。
- `snippet`：先在 `search.title` 找首个命中位置，找不到再找 `search.body`；以命中位置为中心取前后各 80 个 Character，压平换行，总长不超过 400。两处都不命中时取 `body` 开头。混合查询优先用 CJK 词项的命中位置。
- 排序固定 `datePublished DESC, articleID DESC`，null 日期排最后；`total_matched` 与 `limit`/`after` 无关。
- 游标语义与 `list_articles` 相同：keyset、区分有无日期、可跨 null 边界、只在相同 `query` 下有效。
- 响应超过 32 KiB 时从尾部丢弃文章，`returned + omitted == min(remaining_matched, limit)`。

### `unread_digest`

参数：

| 参数 | 类型 | 默认 | 约束 |
| --- | --- | --- | --- |
| `days` | int | 1 | 1..90 |

返回 `window{since, until}`、`totals{unread_total, unread_in_window, articles_in_window, unread_feeds}`、`feeds[]`、`truncated`、`omitted_feeds`、`omitted_unread_in_window`。

`feeds[]` 每项：`feed_id`、`title`、`folder`、`unread_total`、`unread_in_window`、`latest_published_at`、`articles[]`（最多 3 条 `{article_id, title, published_at}`）。

口径：

- 窗口固定 `since <= datePublished <= until`，两端都含；`until` 是本次生成时刻，`since = until - days * 86400`。`datePublished` 为 null 的文章不进窗口计数，但计入 `unread_total`。
- 只列出 `unread_in_window > 0` 的 feed；`unread_total` 仍是该 feed 的全量未读数。
- `latest_published_at` 取该 feed 窗口内全部文章（不论读否）的最大 `datePublished`；窗口内无文章为 null。
- `articles` 只含窗口内未读文章，排序 `datePublished DESC, articleID DESC`。
- `feed` 排序为 `unread_in_window DESC, latest_published_at DESC, feed_id ASC`，null 日期排最后。
- 响应超过 48 KiB 时从尾部丢弃整个 feed（不拆单条明细）；`truncated` 当且仅当 `omitted_feeds > 0`。
- 不变量：`sum(feeds[].unread_in_window) + omitted_unread_in_window == totals.unread_in_window`，且 `unread_feeds == len(feeds) + omitted_feeds`，任何截断下都成立。

### `query`

受控的只读 SQL 出口，不是主路径：它把 schema 知识推给调用方，表结构变更时最先坏；保留它是工具面覆盖不到时的逃生门。

| 参数 | 类型 | 默认 | 约束 |
| --- | --- | --- | --- |
| `sql` | string | 必填 | 单条 `SELECT` 或 `WITH` 语句 |
| `limit` | int | 50 | 1..100 |

返回 `columns`、`rows`、`row_count`、`truncated`、`truncated_reason`、`elapsed_ms`。

- `columns` 按 SELECT 顺序，允许重名；列名与直接执行原语句一致。
- `rows` 是二维数组：NULL → `null`；INTEGER/REAL → number，绝对值超过 2^53 的 INTEGER 转十进制字符串；TEXT → string；BLOB → 小写十六进制字符串。
- 单条语句：多语句返回 `isError`，类别 `multiple_statements`；末尾多余分号与注释允许。
- 跳过前导空白与注释后首关键字必须是 `SELECT` 或 `WITH`（大小写不敏感）。`EXPLAIN`、`PRAGMA`、`ATTACH`、`UPDATE`、`DELETE`、`INSERT` 等一律 `isError`，类别 `not_select`。
- 自动限流：有效行数上限 `min(limit, 100)`。实现按原语句逐行读取并在第 `limit+1` 行停止，因此不改写 SQL、不改列名；语句自带更小的 `LIMIT` 时以语句为准且不置截断。
- 响应上限 64 KiB。第一行单独超过 64 KiB → `isError`，类别 `single_row_too_large`，文本含实际字节数与「请缩小列投影或加过滤」。只有多行累计超限才从尾部丢行，`truncated = true`、原因 `byte_limit`。
- 3000 ms 预算，与 `search_articles` 共用同一 progress handler；超时返回 `isError`，类别 `timeout`。
- 与其它工具使用同一条只读连接与同一个 `BEGIN DEFERRED` 事务，`ATTACH` 的 `fs` 别名可用（`fs.feedSettings`）。任何写尝试（包括 `WITH` 内的写）由只读连接拦下并返回 `execution_error`，不做静态可写性判定。
- 错误不回显整条 SQL：只给错误类别与原 SQL 前 200 字符。类别覆盖 `multiple_statements`、`not_select`、`syntax_error`、`timeout`、`execution_error`、`single_row_too_large`。
- `truncated_reason` 优先级：因字节上限丢行 → `byte_limit`；仅因行数上限丢行 → `row_limit`；两者同时发生报 `byte_limit`。
- 结果顺序不承诺，除非语句自带 `ORDER BY`；`query` 不提供游标，需要翻页时由调用方把条件下推进 SQL。

### 已知限制

- FTS4 使用默认 simple tokenizer：中文只能整词命中，子串检索必须走 LIKE；LIKE 是全表扫，成本随 `search.body` 体积线性增长（125 MB 库热缓存约几十毫秒），所以含 LIKE 的查询有 3000 ms 预算。
- LIKE 的 `%`/`_`/`\` 转义是防御性实现：按字符类拆分后 CJK 段只含 CJK 码点，不会出现这三个字符，因此这条转义路径实际不可达，也没有专门的端到端测试覆盖。
- `unread_digest` 完全排除 `feedID` 为空串的文章（空值不是可识别的 feed）：`totals`、`feeds[]`（含 `unread_total`）与 `omitted_unread_in_window` 三处口径一致，保证 D1 在任何数据形态下成立。
- `search.body` 是归一化文本（标签已剥、空白归一、撇号被删，可能带站点尾注），不是原始 HTML。
- 全文索引与 `articles` 通过 `searchRowID` 关联；`searchRowID` 为 null 的文章不参与全文检索，也不会出现在 `search_articles` 结果里。
- 当前只支持 OnMyMac 账户；其它账户只报告名称，不读取其数据。

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
python3 Tools/NetNewsWireMCP/scripts/verify_articles.py
python3 Tools/NetNewsWireMCP/scripts/verify_search.py
python3 Tools/NetNewsWireMCP/scripts/verify_digest.py
python3 Tools/NetNewsWireMCP/scripts/verify_pagination.py
python3 Tools/NetNewsWireMCP/scripts/verify_readonly.py
python3 Tools/NetNewsWireMCP/scripts/verify_fixtures.py
python3 Tools/NetNewsWireMCP/scripts/verify_client.py
```

- `handshake.py`：真实 stdio 会话，`initialize`（校验 `instructions` 非空）+ `tools/list`（6 个工具，全部 `readOnlyHint: true`）+ 一次 `list_feeds`。
- `verify_list_feeds.py`：在活跃数据根上把 `totals` 与等价 SQL 直查逐项比较。
- `verify_articles.py`：在活跃数据根上把 `list_articles` 的过滤计数与上限不变量、`get_article` 的 `content_bytes`、重复 URL 的 `duplicate_count` 与等价 SQL 直查比较。
- `verify_search.py`：在活跃数据根上分别用 ASCII、CJK、混合查询，把 `total_matched` 与「FTS 直查 / LIKE 直查 / 两者交集」比较，并检查 `mode_used`、排序、`snippet` 上限与 `total_matched` 与 `limit` 无关。
- `verify_digest.py`：用工具返回的 `window.since`/`until` 作为同一窗口边界，把 `unread_digest` 的窗口计数与直查比较，并检查 D1、D19、截断标记、排序与明细。
- `verify_pagination.py`：在活跃数据根上走完 `list_articles` 的全部页（全量与 `unread_only`），与直查比较集合、顺序、重复与 `total_matched` 稳定性；验证 `since` 对照与 null 日期边界；对 `query` 跑计数、join `fs.feedSettings`、自动加限、多语句/非 SELECT 拒绝、首行超限与多行字节截断。
- `verify_readonly.py`：用 SQLite `.backup` 生成一致快照，连续 200 次调用前后比较三个文件的 sha256 与 mtime。
- `verify_fixtures.py`：临时库构造退出码 3/4/5/6、env 覆盖、账户闸门、64 KiB 截断、stdout 纯净性，P1 的 `contentText` 兜底、`statuses` 缺行、96 KiB 响应截断、孤儿 `feedID`、作者形态，以及 v2 的游标跨 null 边界、分页完备性、游标条件不匹配拒绝、`query` 多语句/非 SELECT/自动限流/字节截断/首行超限。
- `verify_client.py`：用 `claude mcp add --scope user` 注册本服务，确认 `claude mcp list` 显示 Connected，随后立即移除并确认 `~/.claude.json` 无残留。

P2 的两个数据 fixture（`unread_digest` 48 KiB 整 feed 截断、3000 ms LIKE 预算中断）由单元测试在临时库中构造：`testUnreadDigestTruncatesWholeFeeds`、`testSearchLikeBudgetInterrupts`。

单元测试全部在临时目录内构造数据库与 OPML，不读写真实 `~/Library/Application Support/NetNewsWire`。

## hot journal 行为

`DB.sqlite3-journal` 与 `FeedSettings.db-journal` 都不删除，分两个实测分支：

- **零 magic 的残留/伪造 journal**：不是真 hot journal。只读读取成功，进程退出 0，stderr 记录 journal 路径，journal 保留。
- **有效 magic 的真 hot journal**：写事务被强杀后留下。只读无法回滚，进程退出 5，stdout 为 0 字节，journal 保留。

两个分支都由 `scripts/verify_fixtures.py` 用临时副本构造并断言。

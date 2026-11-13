# 代码风格

本文件只记录本 fork 的代码风格约定，以及它与上游权威指南的关系。上游的完整编码指南在 [Technotes/CodingGuidelines.md](../Technotes/CodingGuidelines.md)；本文件不复制其内容，只写本 fork 更严格或补充的部分。

## 本 fork 的约定

- 优先使用地道的现代 Swift：

  > Prefer idiomatic modern Swift.

- 优先写 `if let x` 和 `guard let x`，而不是 `if let x = x` 和 `guard let x = x`。

  > Prefer `if let x` and `guard let x` over `if let x = x` and `guard let x = x`.

- Logger 消息中不要使用 `...` 或 `…`。

  > Don’t use `...` or `…` in Logger messages.

- Guard 语句的 return 必须另起一行。

  > Guard statements should always put the return in a separate line.

- 不要对 optional 做 force unwrap。

  > Don’t do force unwrapping of optionals.

## 与 Technotes/CodingGuidelines.md 的关系

- `Technotes/CodingGuidelines.md` 是上游的编码权威文档，随上游同步，本仓库不修改它。
- 本文件只记录本 fork 更严格或额外的约定；上游指南覆盖而本文件未重复的规则，同样适用。
- 两者冲突时，按更严格的项目指令执行。

### 已知冲突：force unwrap

- `Technotes/CodingGuidelines.md` 第 39 行允许把 force-unwrapping 当作 precondition failure 的简写，但要求 sparingly 使用。
- 本 fork 的约定是**不**对 optional 做 force unwrap。
- 按更严格的项目指令执行：在本仓库中不做 force unwrap，即使上游指南留了 sparingly 的口子。

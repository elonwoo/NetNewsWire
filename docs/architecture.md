# 项目架构

本文件记录项目的高层结构与模块划分，供动手前定位代码。具体实现以源码为准；文档与代码冲突时按代码执行并指出冲突。

## 高层结构

NetNewsWire 是一个多平台 RSS 阅读器，macOS 与 iOS 各有独立 target，采用模块化架构，业务逻辑共享。

## 关键模块（位于 `/Modules`）

- **RSCore**：核心工具、扩展与共享基础设施。
- **RSParser**：feed 解析（RSS、Atom、JSON Feed、RSS-in-JSON）。
- **RSWeb**：HTTP 网络、下载、缓存与 Web 服务。
- **RSDatabase**：基于 FMDB 的 SQLite 数据库抽象层。
- **Account**：账户管理（Local、Feedbin、Feedly、NewsBlur、Reader API、CloudKit）。
- **Articles**：文章与作者数据模型。
- **ArticlesDatabase**：文章存储与搜索功能。
- **SyncDatabase**：跨设备同步状态管理。
- **Secrets**：凭据与 API key 的安全管理。

## 平台专属代码

- **Mac/**：macOS 专属 UI（AppKit）、偏好设置、主窗口管理。
- **iOS/**：iOS 专属 UI（UIKit）、设置、导航。
- **Shared/**：跨平台业务逻辑、文章渲染、智能订阅源。

## 关键架构模式

- **Account System**：可插拔的 account delegate，对接不同同步服务。
- **Feed Management**：文件夹/订阅源的层级组织，支持 OPML 导入导出。
- **Article Rendering**：基于模板的 HTML 渲染，配合自定义 CSS 主题。
- **Smart Feeds**：虚拟订阅源（Today、All Unread、Starred），以 `PseudoFeed` 协议实现。
- **Timeline/Detail**：经典三栏界面（sidebar、timeline、detail）。

## 扩展点

- 两个平台各自的 Share 扩展。
- Safari extension：用于订阅 feed 的 Safari 扩展。
- iOS 的 Widget 支持。
- macOS 的 AppleScript 支持。
- 面向 Siri shortcuts 的 Intent 扩展。

## 开发备注

- 文档与技术笔记位于 `Technotes/` 目录；Technotes 的主题索引见 [../AGENTS.md](../AGENTS.md)。
- 构建、测试、签名与开发环境相关事实见 [build-and-test.md](build-and-test.md)。

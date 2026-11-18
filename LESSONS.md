# LESSONS.md

本文件记录本项目的踩坑教训与对应规则。编程项目的教训写在这里，跟着仓库走。

**单元测试通过不等于 bug 已修好。**
- 后果：某个 bug 可能根本没有测试覆盖，甚至不可测，只能手动验证；单测全绿时宣布修好，等于把未验证的状态当成已验证。
- 规则：宣布「已修复」前，先确认这个 bug 有会失败的测试；没有测试或无法测试时，按实际步骤手动验证一遍，并在回复里写明用的是哪种验证。
- Seen 1× (2026-11-13，来源：原 `CLAUDE.md` 的「Things to Know」，本次拆分迁入；非新增事故记录).

**构建产物只能留 /Applications 那一份，别处不留副本。**
- 2026-11-18 查「登录项与扩展」里十几个同名 NetNewsWire 分享扩展：磁盘上存在 30 份 App 副本，分别来自 4 个 Xcode DerivedData、/tmp 下的临时构建目录、已删除的 worktree 构建。每份副本都会各自注册一条 Sharing 扩展，系统按路径登记、同名不合并，设置里就堆成一片同名列。
- 2026-11-19 装包后又发现 `~/Library/Developer/Xcode/DerivedData/NetNewsWire-*/Build/Products/Debug/NetNewsWire.app` 残留旧 Debug 副本：已做过 `lsregister -u` 反注册，但没删磁盘上的 bundle。反注册只清登记，不清副本，副本还在就会被系统重新扫到登记。
- 规则：每次构建/安装后，除了装进 /Applications 的那一份，其他位置的 `NetNewsWire.app` 一律删掉。固定跑这三步：
  1. 删副本（只删 .app bundle，不动 Build/Intermediates、Index、SourcePackages 等编译缓存）：
     `rm -rf ~/Library/Developer/Xcode/DerivedData/NetNewsWire-*/Build/Products/*/NetNewsWire.app`
  2. 核对零命中：`find ~/Library/Developer/Xcode/DerivedData -maxdepth 8 -name 'NetNewsWire.app' -type d` 输出为空。
  3. 核对正式包完好：`ls -ld /Applications/NetNewsWire.app`。
- 用 `-derivedDataPath` 指到 /tmp 的产物、worktree 里的构建产物同样用完即删；删完对残留路径执行 `lsregister -u <app 路径>` 反注册，用 `lsregister -dump | grep 'NetNewsWire Share Extension.appex'` 核对只剩一条。
- Seen 2× (2026-11-18, 2026-11-19).

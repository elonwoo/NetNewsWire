# 构建、测试与首次初始化

本文件是构建、测试、初始化与签名配置的唯一落点。命令以 `buildscripts/` 下的脚本和 `xcodeproj` 为准；脚本与本文不一致时按脚本执行，并在回复里指出差异。

## 构建与测试

- **全量构建与测试**：`./buildscripts/build_and_test.sh` —— 构建 macOS 与 iOS 两个 target 并运行全部测试。
- **安静模式构建与测试**：`./buildscripts/quiet_build_and_test.sh` —— 同上，输出更精简。
- **手动 Xcode 构建**：
  - macOS：`xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire -destination "platform=macOS,arch=arm64" build`
  - iOS：`xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire-iOS -destination "platform=iOS Simulator,name=iPhone 17" build`

## 测试

- 跑全部测试：使用 `NetNewsWire.xctestplan`，它包含所有模块的测试。
- 跑单个测试：沿用上面的 `xcodebuild` 命令形式，把 `build` action 换成 `test`。

## 首次初始化

- 首次配置：运行 `./setup.sh` 配置开发环境与代码签名。
- 手动配置：在上一级目录创建 `SharedXcodeSettings/DeveloperSettings.xcconfig`。

`setup.sh` 会依次询问 Developer Team ID 与 organization identifier（例如 `com.developername`），然后创建 `../SharedXcodeSettings/DeveloperSettings.xcconfig`，写入 `CODE_SIGN_IDENTITY`、`DEVELOPMENT_TEAM`、`CODE_SIGN_STYLE`、`ORGANIZATION_IDENTIFIER`、`DEVELOPER_ENTITLEMENTS`、`PROVISIONING_PROFILE_SPECIFIER` 等键。查找 Developer Team ID 的方法见 [Technotes/FindingYourDevelopmentTeamID.md](../Technotes/FindingYourDevelopmentTeamID.md)。

## 开发环境相关事实

- 工程使用 Xcode project，模块依赖通过 Swift Package Manager 管理。
- 脚本需要 `xcbeautify` 来格式化构建输出。
- API key 由 `buildscripts/updateSecrets.sh` 管理，该脚本在构建过程中运行。
- 由于缺少私有 API key，部分功能在开发构建中被禁用。
- 代码签名通过 `SharedXcodeSettings` 配置，供开发使用。

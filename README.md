<p align="center">
  <img src="Assets/FFXIVCNMacIconSource.png" alt="FF14 国服 Mac 启动器" width="128">
</p>

<h1 align="center">FF14 国服 Mac 启动器</h1>

<p align="center">
  Apple Silicon · macOS 26+ · SwiftUI · DXMT-only
</p>

<p align="center">
  <a href="https://github.com/shmckfd7dc-stack/XIVCN-Mac-Launcher/actions"><img src="https://github.com/shmckfd7dc-stack/XIVCN-Mac-Launcher/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/shmckfd7dc-stack/XIVCN-Mac-Launcher/releases"><img src="https://img.shields.io/github/v/release/shmckfd7dc-stack/XIVCN-Mac-Launcher?display_name=tag&sort=semver" alt="Release"></a>
  <a href="https://github.com/shmckfd7dc-stack/XIVCN-Mac-Launcher/blob/main/NOTICE"><img src="https://img.shields.io/badge/license-see%20NOTICE-informational" alt="License"></a>
</p>

`FF14 国服 Mac 启动器` 是面向 Apple Silicon Mac 的最终幻想 XIV 中国大陆国服启动器。项目使用原生 SwiftUI 界面，提供账号登录、游戏启动、游戏版本更新、外部游戏管理，以及可选的 Dalamud 国服/Soil 注入。

当前发布基线为 `XIVCN Mac Launcher 1.0.0`。

## 设计概览

项目采用偏工具型的现代 macOS 界面：主页面集中展示账号、游戏来源、当前运行状态和启动动作；设置按通用、图形、账号、游戏、Dalamud 和高级能力分组，避免把 Runtime 细节暴露给普通用户。

核心流程保持状态驱动：游戏和 Dalamud 的版本检查、下载、校验、激活、注入与退出均由统一状态流管理；国服 Dalamud 和 Soil 使用相互隔离的运行目录，用户只选择一个变体进行注入。MetalFX、Retina、MSync 和键盘映射等图形能力通过现有设置进入启动链路，不额外维护第二套启动器。

## 功能

- 快速续登、账号密码、扫码、验证码和 WeGame 登录流程
- 国服游戏来源选择、版本检查、更新和用户主动完整性修复
- 裸游戏启动或单选 Dalamud 国服/Soil 后启动
- Dalamud 下载、版本更新、插件目录、清理和变体隔离
- XOM 5.4.2 Wine、DXMT-only、Modern MoltenVK 图形路径
- MetalFX、Retina、MSync、键盘映射和超域旅行设置
- Apple Silicon 原生 UI，Core Bridge 通过 Rosetta 提供登录和启动能力

## 运行要求

- Apple Silicon Mac
- macOS 26 或更高版本
- Rosetta 2（用于 x64 Core Bridge）
- 通过最终 DMG 安装后，Wine、DXMT 和其他运行时资源由 App 自带

## 构建与测试

源码仓库只保存项目代码、测试和构建脚本。固定 .NET SDK、XOM/DXMT 构建资源和离线复现材料位于配套维护交接包中，避免把大型运行时二进制直接提交到 Git 历史。

在完整维护环境的项目目录执行：

```sh
sh scripts/validate-cn-config.sh
sh work/validate-runtime.sh
sh scripts/test-core.sh
```

构建最终 App/DMG：

```sh
XIVCN_LAUNCHER_VERSION=1.0.0 sh scripts/build-dmg.sh
```

当前核心回归测试为 44 项。正式发布应同时检查签名、Runtime 来源哈希和 DMG 内的应用名称与版本号。

## 项目结构

```text
Sources/XIVLauncherCNMac/  SwiftUI App 与生产逻辑
Tests/                     核心回归测试
work/core-bridge/          JSON Core Bridge 源码
scripts/                   构建、测试和来源验证脚本
Assets/                    App 图标源文件
docs/licenses/             运行时与上游许可说明
```

## 维护原则

- 以 `XIVCN Mac Launcher 1.0.0` 为基线，先增加测试再修改行为。
- 复用现有 Core Bridge、更新器和状态流，不重复实现第二套后端。
- 日常检查保持轻量，完整扫描只在用户主动触发时执行。
- 不把账号、Token、Keychain 内容、用户路径或运行日志提交到仓库。
- Wine、DXMT、Core 组件和发行源变更必须记录来源、版本、哈希并进行实机验证。

## 注意事项

- 本启动器已在国服版本 `2026.8.5` 上完成实际测试，游戏启动和 Dalamud 注入均正常。
- 游戏下载功能尚未完成实际首次下载测试。当前验证使用的是本地此前已经下载好的游戏文件，后续维护者应单独验证首次游戏下载、取消、失败恢复和重新启动流程。
- MetalFX 动态超分仍属于实验性功能。MetalHUD 对动态超分状态的读取/显示存在显示 Bug，但实际功能已确认可以生效，判断应以实际 FPS 表现为准。
- 游戏内 DLSS 选项显示为灰色且不可选择属于正常现象。FF14 实际使用的是转译层的动态超分机制，该显示状态不代表功能失效。
- 如果动态超分没有正常激活，可在设置中先选择“低于 60 FPS 时启用”，保存后再切换为“一直启用”并保存；进入游戏移动或晃动视角，观察 FPS 是否明显提升。
- 仅支持 macOS 26 及以上版本和 Apple Silicon Mac，不支持 Intel Mac。

## 项目来源与参考

项目只列出实际参与构建、运行时来源或代码/协议参考的项目：

- [XIVLauncher / FFXIVQuickLauncher](https://github.com/goatcorp/FFXIVQuickLauncher)：登录、游戏启动和 Dalamud 运行流程参考。
- [Dalamud](https://github.com/goatcorp/Dalamud)：插件运行时架构和协议参考；国服发行资源使用项目配置的中国大陆发行源。
- [XIV on Mac](https://github.com/marzent/XIV-on-Mac)：macOS Wine、Metal、HiDPI 和 XOM 运行时参考；当前 App 使用固定版本的 XOM Wine/DXMT 运行时输入。
- [DXMT](https://github.com/3Shain/dxmt)：Direct3D 11/DXGI 到 Metal 的转换组件，当前产品使用 DXMT-only 路径。
- 国服相关登录、Dalamud 和发行源行为参考了 `UPSTREAMS.json` 中列出的 China launcher 项目；这些项目不属于本仓库的原创代码，也不作为本项目的产品名称或作者声明。

详细许可证文本和第三方归属见 [`NOTICE`](NOTICE) 与 [`docs/licenses`](docs/licenses)。

## 发布

最终 DMG 作为 GitHub Release Asset 发布，不提交到 Git 历史。发布包应包含 SHA-256，版本标签使用 `v1.0.0`。

## 许可与来源

本项目及其依赖的来源和许可证见 [`NOTICE`](NOTICE)、[`docs/licenses`](docs/licenses) 以及各上游源码目录中的许可证文件。

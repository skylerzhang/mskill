# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

MSkill 是一个 SwiftUI 编写的 macOS 应用（Swift Package，无 Xcode 工程），用来扫描本机各 Agent（Codex、Claude Code、Cursor、Gemini CLI 等）的用户级 Skill 目录，读取 `SKILL.md`，并把 Skill 文件夹以“复制”或“软链接”方式同步到其他 Agent。只读写本地文件，不连接网络。UI 文案、错误信息和代码注释都用中文。

## 常用命令

需要 macOS 14+ 和 Swift 6 工具链。测试使用 Swift Testing（`import Testing`），需要完整 Xcode；只装了 Command Line Tools 时，先执行：
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

```sh
swift run MSkill                       # 直接运行
swift build                            # 构建
swift test                             # 全部测试
swift test --filter SkillCoreTests/linkModeCreatesSymlinkThatTracksSource   # 单个测试
zsh scripts/build-app.sh && open dist/MSkill.app   # 打包为 .app（release 构建、生成 icns、临时签名）
swift scripts/prepare-app-icon.swift <源图> Sources/MSkill/Resources/AppIcon.png   # 重新生成图标
```

## 架构

只有两个源文件，职责划分很清楚：

- `Sources/MSkill/SkillCore.swift`：纯 Foundation 逻辑，不依赖 UI，所有测试都针对这一层。
  - `AgentDefinition.known`：内置 Agent 列表（id、各 Agent 相对 home 的 Skill 根目录、对应的 `.app` 名称）。新增一种 Agent 时改这里；`executableNames` 是在 `id` 上做 switch 单独维护的。
  - `SkillScanner.scan()` → `ScanResult`：Agent 满足以下任一条件就算“已安装”：Skill 根目录存在、在 `/Applications` 或 `~/Applications`（最多两层子目录）中找到对应应用、或在常见 bin 目录中找到可执行文件。之后在 `~`、`~/.config`、`~/.local/share`、`~/Library/Application Support` 下找名为 `skills` 的目录，用来发现未知 Agent。`scanRoot` 最多递归 4 层，遇到含 `SKILL.md` 的文件夹就视为一个 Skill。它会跟随软链接，并把失效链接收集为 `BrokenLink`。
  - `SkillScanner.fingerprint`：对目录内容做 SHA256（会解析软链接；忽略 `.git`、`node_modules`、`dist`、`build`、`.mskill-backups`、`.DS_Store`）。“已同步/冲突”就是靠比较这个值来判断的。
  - `SkillSyncer`：`state(for:target:)` 计算 `SyncState`；`sync` 先写入 `.mskill-staging-<UUID>` 临时位置，再移动到目标位置。目标若是实体文件夹，会先移入 `.mskill-backups/`；目标若是软链接，则直接替换。任一步失败都会回滚。`removeBrokenLink` 只删除失效的链接本身。
- `Sources/MSkill/MSkillApp.swift`：SwiftUI 层。`SkillStore`（`@MainActor ObservableObject`）持有扫描结果，把自定义 Agent 以 JSON 存进 `UserDefaults`（键 `MSkill.customAgents.v1`），同步方式存在 `@AppStorage("MSkill.syncMode")`，同步时调用 `SkillSyncer`。每次同步或修改后都整体重新执行 `refresh()`。

## 需要注意的约定

- 处理软链接时，路径**不能带结尾斜杠**（用 `directoryHint: .notDirectory`），否则 remove/move 会作用到链接指向的目录上。比较真实路径时用 `URL.realFileURL`（基于 `realpath`），不要用 `resolvingSymlinksInPath`，后者会去掉 `/private` 前缀，导致临时目录下的路径比较出错。
- 扫描时要跳过 `.mskill-backups` 和 `.mskill-staging-*`；新增类似的内部目录时，`scanRoot` 和 `fingerprint` 两处的忽略列表都要更新。
- 测试通过注入 `SkillScanner(home:applications:definitions:customAgents:)` 在 `temporaryDirectory` 下构造假的 home 目录，不碰真实用户目录。新测试照这个写法来。

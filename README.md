# MSkill

一个用 SwiftUI 编写的 macOS 本地 Skill 管理应用。它扫描本机 Agent 的 Skill 目录，读取 `SKILL.md`，并将选中的 Skill 文件夹同步到其他 Agent。

## 功能

- 自动检测 Codex、Claude Code、Cursor、Gemini CLI、OpenCode、Windsurf、GitHub Copilot 和通用 Agents 的常见用户级 Skill 目录，并发现常见配置位置中的其他 Skill 根目录。
- 按客户端浏览、搜索 Skill，并查看来源路径与描述。
- 已安装 Agent 优先显示本地应用图标，支持 `/Applications`、`~/Applications` 及其中的分类子目录；找不到对应应用时使用通用符号。
- 添加任意自定义 Skill 目录，支持扫描其中的嵌套文件夹。
- 将 Skill 复制到其他已检测到的客户端；相同内容显示“已同步”。
- 同名内容冲突时先确认，替换前备份原文件夹到目标目录的 `.mskill-backups`。

## 运行

需要 macOS 14 或更新版本及 Swift 6 工具链。运行测试需要完整 Xcode；若当前使用 Command Line Tools，可先执行 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

```sh
swift run MSkill
```

生成可双击运行的应用：

```sh
zsh scripts/build-app.sh
open dist/MSkill.app
```

此脚本生成本机临时签名的应用，适合本地使用；公开分发需开发者签名与公证。

应用图标使用蓝色技能卡片方案，源图为 `Sources/MSkill/Resources/AppIcon.png`。构建脚本会生成包含标准及 Retina 尺寸的 `AppIcon.icns`；Dock 和应用侧栏使用同一图案。

图标圆角外使用透明背景；若需从选定原图重新生成，可运行：

```sh
swift scripts/prepare-app-icon.swift design/icon-options/04-skill-stack.png Sources/MSkill/Resources/AppIcon.png
```

## 说明

MSkill 只扫描本地文件，不连接账号或云服务。自动检测覆盖内置列表中的常见目录；客户端使用不同路径时可通过“添加自定义路径”接入。同步使用文件夹复制，因此后续源目录修改后，需要再次同步。应用首次读取受 macOS 隐私保护的目录时，系统可能要求授予文件访问权限。

当前自动发现面向用户级 Skill 目录。项目内的 `.cursor/skills`、`.claude/skills` 等路径可以通过“添加自定义路径”接入。内置目录参考了 [Cursor](https://cursor.com/help/customization/skills)、[Gemini CLI](https://geminicli.com/docs/cli/creating-skills/)、[OpenCode](https://docs.opencode.ai/docs/skills/) 和 [GitHub Copilot](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/add-skills) 的文档。

# 参与贡献（Contributing）

感谢关注「文件抽屉」！欢迎 Issue 与 PR。本文覆盖开发环境、项目约定与发版流程。

## 开发环境

- macOS 14+（与 App 最低部署版本一致）
- Xcode 15+（完整版或 Command Line Tools 均可编译；跑测试建议完整版）
- 无任何第三方依赖：纯 Swift Package Manager，`swift build` 即起

```bash
git clone git@github.com:kingsxiao/mac-file-drawer.git
cd mac-file-drawer
make test        # 跑全量单元测试（当前 199 个）
make app         # 构建 build/FileDrawer.app
make install     # 装进 /Applications 并启动
make dmg         # 分发用 DMG
make help        # 全部目标
```

调试用技巧（裸进程隔离、测试数据注入）见仓库内 `scripts/smoke_automation.sh` 与 README.zh-CN「项目结构」。

## 项目约定

- **零警告门槛**：release 构建不允许出现任何编译器警告（CI 会 grep `warning:` 拦截）。
- **测试**：改行为必须带测试；视觉/对比度类约束（如 WCAG 对比度）以契约测试固化，不要只靠肉眼。
- **本地化**：基准语言是中文，代码里的 key 即中文原文；新 UI 文案需同步补
  `Sources/FileDrawer/Resources/en.lproj/Localizable.strings`（缺译自动回退中文，不会乱码，但仍请补全）。
- **SF Symbol 陷阱**：`textformat` 系符号在中文环境会被本地化成汉字，选图标前先离屏渲染目检。
- **提交信息**：`类型(范围): 中文描述`（如 `fix(ui): …`、`feat(search): …`），
  正文写清动机与验证方式；一行提交即可承载完整上下文，不要求拆分。
- **CHANGELOG**：面向用户的变更写入 `CHANGELOG.md` 的 `## Unreleased` 段，合并前更新。

## 提交 PR

1. 大改动请先开 Issue 对齐方向，避免做完不合。
2. 从最新 `main` 切分支，一个 PR 聚焦一件事。
3. 自查（PR 模板会再提醒一遍）：
   - `make test` 全绿
   - release 构建零警告（`swift build -c release 2>&1 | grep warning:` 应无输出）
   - 新 UI 文案已补英文表
   - 用户可感知的变更已记入 `CHANGELOG.md`（`Unreleased`）
   - 涉及界面改动附截图（标准 / 紧凑 / 明暗模式按需）
4. CI（构建 + 测试 + 零警告 + 打包）通过后等待 review。

## 发版流程（维护者）

版本号唯一来源是 `make_app.sh` 顶部的 `VERSION` / `BUILD`；`CHANGELOG.md` 与之对应。

常规发版三步（`scripts/cut_release.sh` 自动完成前两步）：

```bash
# 1. 准备：把 CHANGELOG 的 Unreleased 内容定稿；脚本会改版本号、改 CHANGELOG 标题、提交并打 tag
zsh scripts/cut_release.sh --version 1.7.0          # BUILD 自动 +1
zsh scripts/cut_release.sh --version 1.7.0 --push   # 连同 tag 一起推远端

# 2. 推送后 GitHub Actions（release.yml）自动：测试 → 零警告 → universal 构建
#    → 校验 tag 与版本一致 → DMG/zip + SHA256SUMS → 发 GitHub Release（Notes 取自 CHANGELOG 对应段）

# 3. （可选）正式签名与公证：仓库 Secrets 配置后自动走，未配置则保持 ad-hoc
#    SIGN_IDENTITY / APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID
```

注意事项：

- 版本号语义：新功能 +0.1，修复 +0.01 级别微调，随意但前后一致；tag 必须形如 `v1.7.0` 且与
  `make_app.sh` 的 `VERSION` 一致，release 流水线会强校验。
- CHANGELOG 段标题格式固定为 `## 1.7.0（build 14）`（全角括号），流水线按此提取 Release Notes；
  没有 `Unreleased` 段也可发版（Notes 回退为空提示）。
- 不想发 Release 只想本地出包：`make dmg UNIVERSAL=1` 或 `zsh ./make_dmg.sh --universal`。
- 公证只对 DMG 做（notarytool 直接收 dmg）；本地手工公证清单见 README「分发与公证就绪」。

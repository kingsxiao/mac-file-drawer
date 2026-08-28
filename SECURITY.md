# 安全策略（Security Policy）

## 支持的版本

只对**最新一个 Release** 提供安全修复；发现漏洞请先升级到最新版再确认是否仍然存在。

| 版本 | 支持情况 |
| --- | --- |
| 最新 Release | ✅ 安全修复 |
| 更早版本 | ❌ 请升级 |

## 如何报告漏洞

**请不要在公开 Issue 里描述可被利用的细节。**

优先使用 GitHub 的私密漏洞报告：仓库页 **Security → Advisories → Report a vulnerability**，
只有你和我能看到内容，修复后再转公开披露。

若不便使用，也可在 Issue 里只写「发现一个疑似安全问题，请私聊提供详情」，通过 Issue 留下的联系方式私下同步。

- 报告时请附：macOS 版本、机型（Apple Silicon / Intel）、App 版本（关于面板可见）、复现步骤；
- 我会在 **7 天内**首次回应；修复随下一个 Release 发布，重大问题会提前在 Release Notes 标注。

## 发行物完整性

本项目当前为 **ad-hoc 签名**（无 Apple Developer ID），首次打开会被 Gatekeeper 拦截，
属预期行为（右键 → 打开 放行，或 `xattr -dr com.apple.quarantine FileDrawer.app`）。
下载后建议校验完整性：

```bash
shasum -a 256 -c SHA256SUMS.txt   # 与 Release 附带的校验和文件比对
```

校验和与 DMG / zip 一同附在 [Releases](https://github.com/kingsxiao/mac-file-drawer/releases) 页面。

## 范围说明

- 抽屉数据（条目、分组）保存在本机 `defaults` 域 `com.wangxiao.filedrawer`，
  不含网络上报、无遥测；「导出诊断信息」为用户主动触发、只写本地文件。
- 「自动化接口」（`filedrawer://` URL Scheme 与 Shortcuts App Intents）可被本机其它程序调用
  以操纵抽屉内容，视为本机信任边界内的设计行为；如发现**越权**路径（如未经同意读写任意目录之外的文件），请按上述渠道报告。

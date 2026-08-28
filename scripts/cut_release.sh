#!/bin/zsh
# 发版助手：定稿 CHANGELOG 后一键完成 版本号更新 → 提交 → 打 tag；
# push tag 后 GitHub Actions（release.yml）自动构建并发 GitHub Release。
# 用法：zsh scripts/cut_release.sh --version 1.7.0 [--build 14] [--push] [--skip-test] [--dry-run]
#   --version x.y.z   必填，与 make_app.sh 的 VERSION 及 CHANGELOG 段标题一致
#   --build N         不传则自动取当前 BUILD + 1
#   --push            提交后连同 tag 一起推远端（真正触发发版）
#   --skip-test       跳过 swift test（赶时间时自担风险）
#   --dry-run         只打印计划，不做任何修改
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="" BUILD="" PUSH=0 SKIP_TEST=0 DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --build)     BUILD="$2"; shift 2 ;;
    --push)      PUSH=1; shift ;;
    --skip-test) SKIP_TEST=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    *) echo "✗ 未知参数：$1" >&2; exit 1 ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ --version 需为 x.y.z，如 1.7.0"; exit 1 }

CUR_VERSION="$(grep -E '^VERSION=' make_app.sh | head -1 | sed -E 's/VERSION="([^"]+)"/\1/')"
CUR_BUILD="$(grep -E '^BUILD=' make_app.sh | head -1 | sed -E 's/BUILD="([^"]+)"/\1/')"
[[ -n "$BUILD" ]] || BUILD=$((CUR_BUILD + 1))

TAG="v$VERSION"
VERSION_SECTION="## $VERSION（build $BUILD）"

# ── 前置校验（不改任何文件）────────────────────────────────────────
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "✗ tag $TAG 已存在"; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "✗ 工作区不干净，请先提交（git status）"; exit 1; }

BRANCH="$(git branch --show-current)"
[[ "$BRANCH" == "main" ]] || echo "⚠ 当前在分支 $BRANCH（非 main），发版通常从 main 切"

if [[ "$VERSION" == "$CUR_VERSION" && "$BUILD" == "$CUR_BUILD" ]]; then
  echo "• 版本未变（$VERSION build $BUILD），本次只补 tag 与提交"
fi

HAS_UNRELEASED=0
grep -q '^## Unreleased$' CHANGELOG.md && HAS_UNRELEASED=1
HAS_SECTION=0
grep -qF "$VERSION_SECTION" CHANGELOG.md && HAS_SECTION=1

if (( HAS_UNRELEASED )); then
  # Unreleased 里得有实际内容（标题与下一个 ## 之间至少一个非空行）
  if ! awk '/^## Unreleased$/{u=1;next} /^## /{u=0} u && NF{found=1} END{exit !found}' CHANGELOG.md; then
    echo "✗ CHANGELOG 的 Unreleased 段是空的——先把发布说明写好再发版"; exit 1
  fi
elif (( ! HAS_SECTION )); then
  echo "✗ CHANGELOG 既无 Unreleased 也无「$VERSION_SECTION」段，请先定稿发布说明"; exit 1
fi

echo "发版计划：$CUR_VERSION(build $CUR_BUILD) → $VERSION(build $BUILD)，tag $TAG$( ((PUSH)) && echo '，含推送' )"
(( DRY_RUN )) && { echo "（dry-run 结束，未做任何修改）"; exit 0; }

# ── 执行 ──────────────────────────────────────────────────────────
if (( ! SKIP_TEST )); then
  echo "🧪 swift test…"
  DEV="${DEVELOPER_DIR:-}"; [[ -d "$DEV" ]] || DEV=/Applications/Xcode.app/Contents/Developer
  [[ -d "$DEV" ]] || DEV="$(xcode-select -p)"
  DEVELOPER_DIR="$DEV" swift test -q
else
  echo "⚠ 跳过测试（--skip-test）"
fi

# 版本号唯一来源：make_app.sh 顶部两行
if [[ "$VERSION" != "$CUR_VERSION" || "$BUILD" != "$CUR_BUILD" ]]; then
  V="$VERSION" B="$BUILD" perl -pi -e 's/^VERSION=".*"/VERSION="$ENV{V}"/; s/^BUILD=".*"/BUILD="$ENV{B}"/' make_app.sh
fi

(( HAS_UNRELEASED )) && V="$VERSION" B="$BUILD" perl -pi -e \
  'BEGIN{$d=0} if (!$d && /^## Unreleased$/) { $_ = "## $ENV{V}（build $ENV{B}）\n"; $d = 1 }' CHANGELOG.md
grep -qF "$VERSION_SECTION" CHANGELOG.md || { echo "✗ CHANGELOG 更新未生效，中止"; exit 1; }

git add make_app.sh CHANGELOG.md
if git diff --cached --quiet; then
  echo "• 无需提交（版本与 CHANGELOG 均未变化）"
else
  git commit -m "chore(release): v$VERSION（build $BUILD）"
fi
git tag -a "$TAG" -m "FileDrawer $VERSION (build $BUILD)"

if (( PUSH )); then
  git push origin "$BRANCH"
  git push origin "$TAG"
  echo "🚀 已推送 $TAG——GitHub Actions 正在构建并发版："
  echo "   https://github.com/kingsxiao/mac-file-drawer/actions/workflows/release.yml"
else
  echo "✅ 本地完成：提交 + tag $TAG。确认无误后推送触发发版："
  echo "   git push origin $BRANCH && git push origin $TAG"
fi

#!/bin/zsh
# 一键安装：构建 → 退出旧实例 → 安装 FileDrawer.app → 启动
# 用法：./install.sh [--app-dir <目录>] [--universal] [--no-launch] [--skip-build]
#   --app-dir    安装目录，默认 /Applications
#   --universal  构建 Universal 二进制（arm64 + x86_64）
#   --no-launch  安装后不启动
#   --skip-build 复用 build/FileDrawer.app，跳过编译（不存在时仍会构建）
set -e

cd "$(dirname "$0")"

APP_DIR="/Applications"
LAUNCH=1
SKIP_BUILD=0
BUILD_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)   APP_DIR="${2:?--app-dir 缺少参数}"; shift 2 ;;
    --universal) BUILD_ARGS+=(--universal); shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help)   sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

APP="build/FileDrawer.app"
if (( ! SKIP_BUILD )) || [[ ! -d "$APP" ]]; then
  ./make_app.sh "${BUILD_ARGS[@]}"
fi

TARGET_APP="$APP_DIR/FileDrawer.app"

# 退出正在运行的实例：先发正常退出，超时才强杀，避免替换正在使用的 .app
if pgrep -x FileDrawer >/dev/null 2>&1; then
  echo "🚪 退出正在运行的 FileDrawer…"
  osascript -e 'tell application "FileDrawer" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do
    pgrep -x FileDrawer >/dev/null 2>&1 || break
    sleep 0.25
  done
  pkill -x FileDrawer >/dev/null 2>&1 || true
fi

echo "📦 安装到 $APP_DIR…"
mkdir -p "$APP_DIR"
rm -rf "$TARGET_APP"
if ! ditto "$APP" "$TARGET_APP" 2>/dev/null; then
  # 目录非当前用户可写时（极少见）用 sudo 兜底
  sudo rm -rf "$TARGET_APP"
  sudo ditto "$APP" "$TARGET_APP"
fi
# 本机构建本无隔离标记；从下载产物重装时顺手清掉，免去 Gatekeeper 拦截
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

codesign --verify --strict "$TARGET_APP"

if (( LAUNCH )); then
  open -a "$TARGET_APP"
  echo "🚀 已启动 $TARGET_APP"
else
  echo "✅ 已安装 $TARGET_APP（未启动）"
fi

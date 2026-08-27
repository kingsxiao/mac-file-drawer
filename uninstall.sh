#!/bin/zsh
# 卸载 FileDrawer：退出应用 → 删除已安装的 .app → 清除偏好设置（可选连数据一起清）
# 用法：./uninstall.sh [--app-dir <目录>] [--purge-data]
#   --app-dir     额外检查的自定义安装目录（默认仍会扫 /Applications、~/Applications 与项目 build/）
#   --purge-data  连同收件箱数据 ~/Library/Application Support/FileDrawer 一并删除
set -e

cd "$(dirname "$0")"

EXTRA_APP_DIR=""
PURGE_DATA=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)    EXTRA_APP_DIR="${2:?--app-dir 缺少参数}"; shift 2 ;;
    --purge-data) PURGE_DATA=1; shift ;;
    -h|--help)    sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

# 退出正在运行的实例：先发正常退出，超时才强杀
if pgrep -x FileDrawer >/dev/null 2>&1; then
  echo "🚪 退出正在运行的 FileDrawer…"
  osascript -e 'tell application "FileDrawer" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do
    pgrep -x FileDrawer >/dev/null 2>&1 || break
    sleep 0.25
  done
  pkill -x FileDrawer >/dev/null 2>&1 || true
fi

REMOVE_APP() {
  local app="$1"
  [[ -d "$app" ]] || return 1
  if rm -rf "$app" 2>/dev/null || sudo rm -rf "$app"; then
    echo "🗑  已删除 $app"
    return 0
  fi
  return 1
}

FOUND=0
for dir in /Applications "$HOME/Applications" "$EXTRA_APP_DIR" "$PWD/build"; do
  [[ -n "$dir" ]] || continue
  if REMOVE_APP "$dir/FileDrawer.app"; then
    FOUND=1
  fi
done
if (( ! FOUND )); then
  echo "ℹ️  未找到已安装的 FileDrawer.app"
fi

if defaults delete com.wangxiao.filedrawer 2>/dev/null; then
  echo "🗑  已清除偏好设置（com.wangxiao.filedrawer）"
else
  echo "ℹ️  无偏好设置需要清除"
fi

DATA_DIR="$HOME/Library/Application Support/FileDrawer"
if (( PURGE_DATA )); then
  if [[ -d "$DATA_DIR" ]]; then
    rm -rf "$DATA_DIR"
    echo "🗑  已清除收件箱数据（$DATA_DIR）"
  fi
else
  if [[ -d "$DATA_DIR" ]]; then
    echo "ℹ️  保留收件箱数据：$DATA_DIR（加 --purge-data 可一并删除）"
  fi
fi

echo "ℹ️  若曾开启「登录启动」，请在 系统设置 → 通用 → 登录项与扩展 里确认残余条目已移除"
echo "✅ 卸载完成"

#!/bin/zsh
# 自动化接口端到端冒烟：逐条投递 filedrawer:// 动作，读取 v3 持久化容器断言条目/分组状态。
#
# 用法：./scripts/smoke_automation.sh [选项]
#   --app <path>     指定 .app（默认 build/FileDrawer.app）
#   --isolated       defaults 域已有数据时：备份 → 冒烟 → 恢复（推荐本机使用）
#
# 安全：FileDrawer 正在运行时直接拒绝（动作会打进真实会话）；
#       域非空且未给 --isolated 时拒绝执行。

set -euo pipefail

APP="build/FileDrawer.app"
ISOLATED=0
DOMAIN="com.wangxiao.filedrawer"
V3KEY="com.wangxiao.filedrawer.store.v3"
SETTLE=0.7

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --isolated) ISOLATED=1; shift ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

if [[ ! -d "$APP" ]]; then
  echo "❌ 找不到 $APP（先 ./make_app.sh）"; exit 2
fi
if pgrep -x FileDrawer >/dev/null; then
  echo "❌ FileDrawer 正在运行，冒烟动作会进入真实会话——请先退出再试"; exit 2
fi

BACKUP=""
domain_has_data() {
  defaults read "$DOMAIN" 2>/dev/null | grep -q "filedrawer" && return 0 || return 1
}
if domain_has_data; then
  if (( ISOLATED )); then
    BACKUP="$(mktemp -t filedrawer-smoke-backup).plist"
    defaults export "$DOMAIN" "$BACKUP"
    echo "ℹ️  域已有数据，已备份到 $BACKUP（结束后恢复）"
  else
    echo "❌ defaults 域 $DOMAIN 已有抽屉数据；加 --isolated 以备份-恢复模式运行"; exit 2
  fi
fi
cleanup() {
  if [[ -n "${SMOKE_PID:-}" ]] && kill -0 "$SMOKE_PID" 2>/dev/null; then kill "$SMOKE_PID"; fi
  if [[ -n "$BACKUP" ]]; then
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    defaults import "$DOMAIN" "$BACKUP"
    echo "ℹ️  已恢复备份的 defaults 域"
  else
    defaults delete "$DOMAIN" "$V3KEY" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "🚀 启动 $APP"
open "$APP"
sleep 1.5
SMOKE_PID=$(pgrep -x FileDrawer | head -1)
[[ -n "$SMOKE_PID" ]] || { echo "❌ app 未运行"; exit 1; }

WORK="$(mktemp -d /tmp/filedrawer-smoke.XXXXXX)"
FILE_A="$WORK/A.txt"; FILE_B="$WORK/B.txt"
echo smoke > "$FILE_A"; echo smoke > "$FILE_B"
GROUP="Smoke$(date +%s)"
GROUP2="${GROUP}B"

fire() { open "$1"; sleep "$SETTLE"; }

# 读取 v3 容器（items/drawers）为 JSON
store_json() {
  defaults export "$DOMAIN" - | python3 -c '
import plistlib, sys, json
data = plistlib.loads(sys.stdin.buffer.read())
raw = data.get("'$V3KEY'")
if raw is None:
    print("{}"); raise SystemExit
# plist 的 Data 已是解码后的 JSON 原始字节（兼容字符串形态）
try:
    schema = json.loads(raw if isinstance(raw, str) else raw.decode("utf-8"))
except Exception:
    print("{}"); raise SystemExit
print(json.dumps({"items": schema.get("items", []), "drawers": schema.get("drawers", [])}))
'
}

# 断言助手：python 表达式在 store JSON 上求值（表达式经 argv 传入，不做 shell 拼接）
assert_store() {
  local desc="$1" expr="$2"
  if store_json | python3 -c '
import sys, json
store = json.load(sys.stdin)
_, _, expr, desc = sys.argv
try:
    ok = bool(eval(expr, {"store": store}))
except Exception:
    ok = False
print(("PASS - " if ok else "FAIL - ") + desc)
raise SystemExit(0 if ok else 1)
' _ "$expr" "$desc"; then :; else FAILURES=$((FAILURES + 1)); fi
}

FAILURES=0
echo "— add ×2 → 分组 $GROUP"
fire "filedrawer://add?path=$FILE_A&group=$GROUP"
fire "filedrawer://add?path=$FILE_B&group=$GROUP"
assert_store "分组存在" 'any(d["name"] == "'$GROUP'" for d in store["drawers"])'
assert_store "分组内 2 条" 'sum(1 for i in store["items"] if i.get("drawerID") == [d["id"] for d in store["drawers"] if d["name"] == "'$GROUP'"][0]) == 2'

echo "— pin 最新 1 条（B）"
fire "filedrawer://pin?group=$GROUP&limit=1"
assert_store "B（最新）已置顶" 'any(i["path"].endswith("B.txt") and i.get("pinned") for i in store["items"])'

echo "— send-to-front 最新 1 条（B）"
fire "filedrawer://send-to-front?group=$GROUP&limit=1"
assert_store "B（最新）位于数组最前" 'store["items"][0]["path"].endswith("B.txt")'

echo "— move 最新 1 条（B）→ $GROUP2"
fire "filedrawer://move?group=$GROUP&to=$GROUP2&limit=1"
assert_store "B（最新）已在 $GROUP2" 'any(i["path"].endswith("B.txt") and i.get("drawerID") == [d["id"] for d in store["drawers"] if d["name"] == "'$GROUP2'"][0] for i in store["items"])'

echo "— rename A → A2.txt"
fire "filedrawer://rename?path=$FILE_A&name=A2.txt"
assert_store "路径已更新为 A2.txt" 'any(i["path"].endswith("A2.txt") for i in store["items"])'

echo "— remove 分组 $GROUP（清 B）"
fire "filedrawer://remove?group=$GROUP"
assert_store "原分组已空" 'sum(1 for i in store["items"] if i.get("drawerID") == [d["id"] for d in store["drawers"] if d["name"] == "'$GROUP'"][0]) == 0'

echo "— clear 分组 $GROUP2"
fire "filedrawer://clear?group=$GROUP2"
assert_store "目标分组已清空" 'sum(1 for i in store["items"] if i.get("drawerID") == [d["id"] for d in store["drawers"] if d["name"] == "'$GROUP2'"][0]) == 0'

echo "— toggle / expand / collapse（不崩溃即可）"
fire "filedrawer://toggle"
fire "filedrawer://expand"
fire "filedrawer://collapse"
kill -0 "$SMOKE_PID" 2>/dev/null || { echo "FAIL - app 存活"; FAILURES=$((FAILURES + 1)); }

rm -rf "$WORK"
if (( FAILURES > 0 )); then
  echo "❌ 冒烟失败：$FAILURES 项断言未通过"
  exit 1
fi
echo "✅ 自动化端到端冒烟全部通过"

#!/usr/bin/env bash
# ============================================================================
# 验收脚本：确认 dsh-scene-skeleton-pipeline 的 apply() 真的被执行了
# ============================================================================
# 用法：bash dsh-scene-skeleton-pipeline/scripts/verify/verify-load.sh
# 退出码 0 = 看到加载日志；1 = 超时 / 宿主提前退出。
#
# 为什么这样验证：
#   - 用工作区内的 .dsh-dev 当 DSH_HOME，不碰你日常的 ~/.dsh profile；
#   - --port 0 让系统随机选端口，--no-open 不弹浏览器，
#     不会和已经开着的 DSH 桌面端抢 60730；
#   - 日志出现 "[dsh-scene-skeleton-pipeline] loaded" 即通过，随后自动关掉宿主。
set -euo pipefail
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"

LOG="$(mktemp -t dsh-scene-load.XXXXXX)"
PATTERN='\[dsh-scene-skeleton-pipeline\] loaded'
HOST_PID=""

cleanup() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

DSH_HOME="$PWD/.dsh-dev" dsh --profile web \
  --patch "$ROOT/scratch-plugin/cordis.yml" \
  --no-open --port 0 >"$LOG" 2>&1 &
HOST_PID=$!

for _ in $(seq 1 120); do
  if grep -q "$PATTERN" "$LOG" 2>/dev/null; then
    echo "PASS: $PATTERN"
    grep -n "$PATTERN" "$LOG" | head -3
    exit 0
  fi
  if ! kill -0 "$HOST_PID" 2>/dev/null; then
    echo "FAIL: 宿主提前退出，日志如下："
    cat "$LOG"
    exit 1
  fi
  sleep 0.5
done

echo "FAIL: 60 秒内没有看到加载日志，日志如下："
cat "$LOG"
exit 1

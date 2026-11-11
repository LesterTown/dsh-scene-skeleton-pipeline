#!/usr/bin/env bash
#
# 阶段 4 验收脚本：真实执行链路（ComfyUI 出图 → Blender 场景骨架）。
#
# 注意：Unity 相关断言已迁至 adapters/unity/verify-unity-adapter.sh
# （流水线核心产物是引擎无关的 Blender 场景骨架，Unity 只是可选适配器）。
#
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-step4.sh                 # 完整验证（真实跑三个软件，约 3-5 分钟）
#   bash dsh-scene-skeleton-pipeline/scripts/verify/verify-step4.sh --skip-real     # 只验证宿主接线（dry-run，不跑软件）
#
# 前提：
#   - 本机 ComfyUI 已在 http://127.0.0.1:8188 运行（ComfyUI Desktop 或 main.py）
#   - Blender 可执行（默认 /Applications/Blender.app/Contents/MacOS/Blender）
#
# 覆盖：
#   A. 真实宿主（隔离 DSH_HOME + --patch 覆盖层）
#      1. 加载日志包含 pipeline engine / pipeline tool
#      2. /state.pipeline：realExecution=true、dryRunOnly=false、stages 两个（comfy → blender）
#      3. POST /config 后 blender/comfy 环境 ok
#      4. POST /pipeline/run（dryRun=true）→ job done，节点全 ok，产物是 dry-run 占位
#      5. client bundle 含真实执行按钮文案
#   B. 真实执行（verify 的核心）
#      6. node scripts/verify/real-e2e.mjs → exit 0、job done、两个节点 ok
#      7. 产物真实存在：png / .blend / .fbx / layout.json，且非空
#
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$PLUGIN_DIR/.." && pwd)"
PATCH="$ROOT/scratch-plugin/cordis.yml"
DEV_HOME="$ROOT/.dsh-dev"
BASE_PATH="/plugins/dsh-scene-skeleton-pipeline"
CONFIG_FILE="$DEV_HOME/scene-skeleton-pipeline/config.json"
UNITY_PROJECT="${UNITY_PROJECT:-$DEV_HOME/unity-e2e-project}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/dsh-scene-e2e}"
COMFY_URL="${COMFY_URL:-http://127.0.0.1:8188}"
CHECKPOINT="${CHECKPOINT:-DreamShaper_8_pruned.safetensors}"
REAL=1
[ "${1:-}" = "--skip-real" ] && REAL=0

PASS=0
FAIL=0
FAILED_NAMES=()
TMP="$(mktemp -d -t dsh-scene-step4.XXXXXX)"
HOST_PID=""
LOG_FILE=""
JAR=""
BASE=""

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}"; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$name"; else fail "$name" "expected [$expected] got [$actual]"; fi
}

json_get() { python3 -c "import json,sys;d=json.load(open('$1'));print($2)"; }

cleanup() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  [ -n "$LOG_FILE" ] && rm -f "$LOG_FILE"
  [ -n "$JAR" ] && rm -f "$JAR"
  rm -rf "$TMP"
}
trap cleanup EXIT

boot_host() {
  LOG_FILE="$(mktemp -t dsh-scene-step4-host.XXXXXX)"
  JAR="$(mktemp -t dsh-scene-step4-jar.XXXXXX)"
  DSH_HOME="$DEV_HOME" dsh --profile web --patch "$PATCH" --no-open --port 0 >"$LOG_FILE" 2>&1 &
  HOST_PID=$!
  local token_url=""
  for _ in $(seq 1 160); do
    token_url=$(grep -o 'http://127.0.0.1:[0-9]*/?token=[A-Za-z0-9_-]*' "$LOG_FILE" | head -1)
    [ -n "$token_url" ] && break
    if ! kill -0 "$HOST_PID" 2>/dev/null; then
      echo '--- host log ---'; cat "$LOG_FILE"; return 1
    fi
    sleep 0.5
  done
  if [ -z "$token_url" ]; then
    echo '--- host log（没等到 dsh web URL）---'; cat "$LOG_FILE"; return 1
  fi
  BASE="${token_url%%/?token=*}"
  curl -sS -c "$JAR" -L "$token_url" -o /dev/null || return 1
  return 0
}

stop_host() {
  if [ -n "$HOST_PID" ] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  HOST_PID=""
  [ -n "$JAR" ] && rm -f "$JAR"
  JAR=""
}

api() { curl -sS -b "$JAR" -m 60 "$BASE$BASE_PATH$1" "${@:2}"; }

# ---------------------------------------------------------------- 0. 前置条件
echo '== 0. 前置条件 =='
comfy_code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "$COMFY_URL/queue" 2>/dev/null || true)"
[ "$comfy_code" = "200" ] && pass "ComfyUI 可达（$COMFY_URL/queue → 200）" \
  || fail "ComfyUI 不可达（$COMFY_URL/queue → ${comfy_code:-连接失败}）" '请先启动 ComfyUI 再跑本脚本'
[ -x /Applications/Blender.app/Contents/MacOS/Blender ] && pass 'Blender 可执行存在' \
  || fail 'Blender 可执行不存在' '/Applications/Blender.app/Contents/MacOS/Blender'

[ "$FAIL" = "0" ] || { echo; echo "前置条件不满足，终止。"; exit 1; }

# ---------------------------------------------------------------- A. 宿主接线
echo
echo '== A. 宿主接线（隔离 DSH_HOME + --patch）=='
rm -f "$CONFIG_FILE"
if ! boot_host; then
  fail '宿主启动' '见上方日志'
  echo; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

grep -q 'pipeline engine ready: comfy -> blender' "$LOG_FILE" \
  && pass '加载日志含 pipeline engine ready' || fail '缺少 pipeline engine ready 日志'
grep -q 'pipeline tool registered: run_scene_pipeline' "$LOG_FILE" \
  && pass '加载日志含 pipeline tool registered' || fail '缺少 pipeline tool registered 日志'

config_body=$(python3 -c 'import json,sys;print(json.dumps({"comfyUrl":sys.argv[1],"comfyCheckpoint":sys.argv[2],"outputDir":sys.argv[3]}))' \
  "$COMFY_URL" "$CHECKPOINT" "$OUTPUT_DIR")
api /config -X POST -H 'content-type: application/json' -d "$config_body" >"$TMP/config.json" 2>&1

assert_eq '/config 保存成功' 'True' "$(json_get "$TMP/config.json" "d['saved']")"
assert_eq '环境 blender' 'ok' "$(json_get "$TMP/config.json" "d['environment']['blender']['status']")"
assert_eq '环境 comfy' 'ok' "$(json_get "$TMP/config.json" "d['environment']['comfy']['status']")"
assert_eq '流水线 realExecution' 'True' "$(json_get "$TMP/config.json" "d['pipeline']['realExecution']")"
assert_eq '流水线 dryRunOnly' 'False' "$(json_get "$TMP/config.json" "d['pipeline']['dryRunOnly']")"
assert_eq '流水线节点数（引擎无关核心）' '2' "$(json_get "$TMP/config.json" "len(d['pipeline']['stages'])")"
assert_eq '产物目录已配置' "$OUTPUT_DIR" "$(json_get "$TMP/config.json" "d['pipeline']['outputDir']")"

api /pipeline/run -X POST -H 'content-type: application/json' \
  -d '{"prompt":"a quiet stone courtyard with a watchtower","dryRun":true}' >"$TMP/dry.json" 2>&1
assert_eq 'dry-run job done' 'done' "$(json_get "$TMP/dry.json" "d['job']['status']")"
assert_eq 'dry-run 两个节点全 ok' 'True' \
  "$(json_get "$TMP/dry.json" "all(s['status']=='ok' for s in d['job']['stages'])")"
assert_eq 'dry-run 不产出真实文件' '/tmp' "$(python3 - "$TMP/dry.json" <<'PY'
import json, sys
job = json.load(open(sys.argv[1]))['job']
paths = [a.get('path', '') for stage in job['stages'] for a in stage.get('artifacts', [])]
print('/tmp' if all(p == '' for p in paths) else 'has-real-path')
PY
)"

curl -sS -b "$JAR" "$BASE/" -o "$TMP/index.html"
HREF=$(python3 - "$TMP/index.html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding='utf-8').read()
hrefs = re.findall(r'href="(plugins/\?\?[^"]*dsh-scene-skeleton-pipeline/client\.js[^"]*)"', html)
print((hrefs[0] if hrefs else '').replace('&amp;', '&'))
PY
)
if [ -n "$HREF" ]; then
  curl -sS -b "$JAR" "$BASE/$HREF" -o "$TMP/client-bundle.js"
  grep -q '确认真实执行' "$TMP/client-bundle.js" && pass 'client bundle 含真实执行确认文案' \
    || fail 'client bundle 缺少真实执行确认文案'
else
  fail 'index.html 里找不到 client bundle URL'
fi

stop_host

# ---------------------------------------------------------------- B. 真实执行
if [ "$REAL" = "1" ]; then
  echo
  echo '== B. 真实执行（ComfyUI → Blender → Unity，约 3-5 分钟）=='
  rm -rf "$OUTPUT_DIR"
  # 锁定 legacy 模式：本脚本的产物断言覆盖 .blend/.fbx/layout/scene 四类文件，
  # scenic 模式（默认）不产 .blend，其链路由 verify-step6.sh 专门覆盖。
  if node "$PLUGIN_DIR/scripts/verify/real-e2e.mjs" '' "$OUTPUT_DIR" \
      '' legacy >"$TMP/real.log" 2>&1; then
    pass 'real-e2e.mjs exit 0'
  else
    fail 'real-e2e.mjs 失败' "见 $TMP/real.log"
    tail -25 "$TMP/real.log"
  fi
  if [ -f "$OUTPUT_DIR/last-job.json" ]; then
    assert_eq '真实 job done' 'done' "$(json_get "$OUTPUT_DIR/last-job.json" "d['status']")"
    assert_eq '真实执行两个节点全 ok' 'True' \
      "$(json_get "$OUTPUT_DIR/last-job.json" "all(s['status']=='ok' for s in d['stages'])")"

    for kind in image blend mesh layout; do
      path=$(json_get "$OUTPUT_DIR/last-job.json" \
        "next((a['path'] for s in d['stages'] for a in s.get('artifacts',[]) if a.get('kind')=='$kind' and a.get('path')), '')")
      if [ -n "$path" ] && [ -f "$path" ] && [ -s "$path" ]; then
        pass "产物 $kind 存在且非空（$(basename "$path")，$(wc -c <"$path" | tr -d ' ') 字节）"
      else
        fail "产物 $kind 缺失或为空" "${path:-（job 里没有该 kind 的路径）}"
      fi
    done
  else
    fail 'last-job.json 不存在' '真实执行没有产出 job 记录'
  fi
else
  echo
  echo '== B. 真实执行：已跳过（--skip-real）=='
fi

# ---------------------------------------------------------------- 收尾
rm -f "$CONFIG_FILE"
echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" != "0" ]; then
  printf '失败项:\n'
  for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
  exit 1
fi
echo '阶段 4 验收全部通过（引擎无关核心链路；Unity 断言见 adapters/unity/verify-unity-adapter.sh）。'
